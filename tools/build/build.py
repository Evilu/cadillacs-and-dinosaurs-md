"""Build the Mega Drive ROM from the user's arcade program and graphics images.

usage: build.py <dino_prg.bin> <dino_gfx.bin> <access_pcs.csv> <out.md>

Most people want build_md.py at the top of the repository, which starts from dino.zip.

Takes the 1.5 MB arcade 68000 program, redirects its fixed-address hardware
accesses to shadow locations in work RAM, replaces the vectors and the first
header page, appends the hardware layer assembled from src/hal.s, and adds the
arcade graphics converted to Mega Drive tiles behind the Sega (SSF2) mapper.

ROM layout:
  0x000000  arcade program (patched)
  0x180000  hardware layer
  0x187F00  colour table: [brightness][nibble] -> Mega Drive level << 1
  0x188000  tile flags: one byte per arcade 16x16 tile, bit 0 if it has pixels, bit 1 if it has no transparent pixel
  0x190000  patch table: count, then per instruction replaced by TRAP #8:
            long address, word length, four words of the original instruction
  0x1A0000  far background flags: one byte per 32x32 tile, nonzero if it has pixels
  0x1A2000  text flags: one byte per 8x8 text pattern (code * 2 + half), nonzero if it has pixels
  0x200000  all 32768 arcade 16x16 tiles as four Mega Drive patterns each
            (TL, BL, TR, BR), behind the Sega/Krikzz SSF mapper
"""
import csv
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from capstone import CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_000, Cs

ROOT = Path(__file__).resolve().parents[2]
PROGRAM_SIZE = 0x180000
HAL_BASE = 0x180000
COLOUR_TABLE = 0x187F00
SOUND_TABLE = 0x186000
SOUND_FIXED = 2 * 256 * 12 + 2
TILE_FLAGS = 0x188000
PATCH_TABLE = 0x190000
PATCH_HASH = 0x198000
PATCH_HASH_SIZE = 1024
TILE_FLAGS3 = 0x1A0000
FAR_TILES = (0x1C00, 0x2000)
TEXT_FLAGS = 0x1A2000
TEXT_CODES = 0x1000
TILE_DATA = 0x200000

IO_RELOCATIONS = [
    (0x800000, 0x800200, 0xff1000),
    (0xf18000, 0xf18040, 0xff1200),
    (0xf19fe0, 0xf1a020, 0xff1240),
    (0xf1c000, 0xf1c020, 0xff1280),
]
GFX_RELOCATIONS = [
    (0x914000, 0x915000, 0xff3000),
]
TABLE_RANGES = [(0x908000, 0x914000), (0x915000, 0x930000)]
TRAP8 = 0x4e48
NOP = 0x4e71
FAST_PATHS = [
    (0x000ba0, '30c030c1b1c9', 11),
    (0x021446, '20db20db41e8003820db20db', 9),
    (0x020500, '20db20db41e8003820db20db', 9),
    (0x020564, '20db20db41e8003820db20db', 9),
    (0x0205ac, '20d951ccfffc', 10),
    (0x016726, '3010c044805930c054483010c044805930c0d0fc007a51cdffe8', 13),
    (0x016760, '3010c044805930c054483010c044805930c0d0fc007a51cdffe8', 13),
    (0x000c34, '32c03282', 14),
    (0x000c8a, '32c03282', 14),
    (0x000cc2, '32c03282', 14),
    (0x08506a, '32c032c20640001032c032c2', 15),
    (0x017a00, '31590000314100023159000431410006', 15),
    (0x017408, '31590000314100023159000431410006', 15),
    (0x017660, '317c00200000316b00080002', 15),
]
INLINE_PATCHES = [
    (0x00cc96, '7a1f22d851cdfffc', '41e8008043e90080', None),
    (0x0130e4, '41f90090c00034302002', '4eb9{:08x}4e714e71', 'hal_attr'),
    (0x01366a, '41f90090c00034302002', '4eb9{:08x}4e714e71', 'hal_attr'),
    (0x099f14, '41ed8e667000' '30c0b0fc800066f8', '4eb9{:08x}' + '4e71' * 4, 'hal_clear_game_ram'),
    (0x01f18a, '7000207c00000030', '203c000137e84e75', None),
    (0x05a454, '7000207c00000030', '203c000137e84e75', None),
    (0x05dd30, '7000207c00000030', '203c000137e84e75', None),
    (0x0104f6, '207c00000564', '80404e754e71', None),
    (0x02a5b6, '207c00000564', '80404e754e71', None),
    (0x05124e, '207c00000564', '80404e754e71', None),
]
# The last six are Capcom's anti-tamper checks. Three copies sum bytes 0x30-0x419, which
# hold the vectors the port replaces; when the sum is wrong they spawn enemies in a state
# that crashes. Three more compare 38 bytes of the VBlank handler at 0x564, which the port
# patches, with a table; when they differ an enemy in stage 5 (of 0-7) stops the game for 1,200
# frames of character profiles. Each copy now returns the passing result.
FAST_PATH_HANDLERS = {9: 'trap_meta', 10: 'trap_copy', 11: 'trap_fill', 13: 'trap_recolour', 14: 'trap_text', 15: 'trap_hud'}
SKIPPED_ROUTINES = [
    (0x00a7b8, '207c00918000', 'fills 0x918000, a table the port drops'),
]
DEBUG_MARKERS = [(0x000a40, '48e7e080'), (0x000a48, '48e7e080')]
DEBUG_MARKER_BODY = (0xa40, 0xa76)
SKIP_RANGES = [(0xaa944, 0xaac00)]
GFX_RAM = (0x900000, 0x930000)
SPRITE_LISTS = [(0xb12, 0x900000, 0xff2000), (0xb24, 0x904000, 0xff2800),
                (0x13fb6, 0x900000, 0xff2000), (0x13fc4, 0x904000, 0xff2800)]
POST_RESET_JUMP = 0x4c8


def relocate(addr, table, end_bound=False):
    for lo, hi, to in table:
        if lo <= addr < hi or (end_bound and addr == hi):
            return to + addr - lo
    return None


def loaded_before(md, rom, start):
    for back in range(2, 14, 2):
        ins = next(md.disasm(bytes(rom[start - back:start + 10]), start - back), None)
        if ins and ins.address + ins.size == start and ins.mnemonic in ('lea.l', 'movea.l'):
            m = re.match(r'#?\$([0-9a-f]+)(\.l)?,', ins.op_str)
            if m:
                return int(m.group(1), 16)
    return None


def binutils_prefix():
    prefixes = [os.environ['M68K_PREFIX']] if os.environ.get('M68K_PREFIX') else ['m68k-elf-', 'm68k-linux-gnu-']
    for prefix in prefixes:
        if all(shutil.which(prefix + tool) for tool in ('as', 'ld', 'objcopy', 'nm')):
            return prefix
    sys.exit('68000 GNU binutils not found (tried ' + ', '.join(p + 'as' for p in prefixes) +
             '); install them or set M68K_PREFIX')


def assemble_hal():
    tool = binutils_prefix()
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (Path(tmp) / n for n in ('hal.o', 'hal.elf', 'hal.bin'))
        stage = os.environ.get('BOOT_STAGE')
        subprocess.run([tool + 'as', '-m68000', '--register-prefix-optional', '-I', str(ROOT / 'src')] +
                       (['--defsym', f'BOOT_STAGE={int(stage)}'] if stage else []) +
                       [str(ROOT / 'src' / 'hal.s'), '-o', str(obj)], check=True)
        subprocess.run([tool + 'ld', '-Ttext', hex(HAL_BASE), '-e', hex(HAL_BASE), '-o', str(elf), str(obj)],
                       check=True)
        subprocess.run([tool + 'objcopy', '-O', 'binary', str(elf), str(out)], check=True)
        nm = subprocess.run([tool + 'nm', str(elf)], check=True, capture_output=True, text=True).stdout
        symbols = {line.split()[2]: int(line.split()[0], 16) for line in nm.splitlines() if len(line.split()) == 3}
        return out.read_bytes(), symbols


def patch_executed(rom, access_path, report):
    done = set()
    rows = [r for r in csv.DictReader(open(access_path)) if r['region'] in '02']
    for row in rows:
        pc = int(row['pc'], 16)
        for off in range(pc + 2, pc + 10, 2):
            new = relocate(struct.unpack_from('>I', rom, off)[0], IO_RELOCATIONS)
            if new is not None:
                struct.pack_into('>I', rom, off, new)
                done.add(off)
    for row in rows:
        pc = int(row['pc'], 16)
        if not any(pc < off <= pc + 8 for off in done):
            report.append(f'unpatched hardware access through a pointer at {pc:06x} ({row["low"]}-{row["high"]})')
    report.append(f'{len(done)} I/O address operands redirected at instructions seen executing')
    return done


def patch_static(rom, table, done, immediates, label, report):
    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_000)
    patched, skipped, bounds = 0, 0, 0

    def ours(addr):
        return addr is not None and any(lo <= addr < hi or to <= addr < to + hi - lo for lo, hi, to in table)

    for off in range(0x200, PROGRAM_SIZE - 4, 2):
        value = struct.unpack_from('>I', rom, off)[0]
        target = relocate(value, table, end_bound=True)
        if target is None or off in done:
            continue
        absolute, immediate = f'${value:x}.l', f'#${value:x}'
        for start in (off - 2, off - 4, off - 6):
            ins = next(md.disasm(bytes(rom[start:start + 12]), start), None)
            if not ins or start + ins.size < off + 4:
                continue
            if not (absolute in ins.op_str or (
                    immediates and immediate in ins.op_str and ins.mnemonic in ('lea.l', 'movea.l', 'move.l'))):
                continue
            before = loaded_before(md, rom, start)
            if relocate(value, table) is None and not ours(before):
                bounds += 1
            elif any(value == lo for lo, _, _ in table) and before is not None \
                    and GFX_RAM[0] <= before < GFX_RAM[1] and not ours(before):
                bounds += 1
            else:
                struct.pack_into('>I', rom, off, target)
                done.add(off)
                patched += 1
            break
        else:
            skipped += 1
    report.append(f'{label}: {patched} operands redirected statically, {skipped} look-alike values left alone, '
                  f'{bounds} end markers of other tables left alone')


def apply_fast_paths(rom, sym, report):
    covered = []
    for addr, original, trap in FAST_PATHS:
        length = len(original) // 2
        assert rom[addr:addr + length].hex() == original, f'unexpected code at {addr:06x}'
        rom[addr:addr + length] = struct.pack('>H', 0x4e40 | trap) + struct.pack('>H', NOP) * (length // 2 - 1)
        covered.append((addr, addr + length))
    for addr, original, new, symbol in INLINE_PATCHES:
        length = len(original) // 2
        assert rom[addr:addr + length].hex() == original, f'unexpected code at {addr:06x}'
        rom[addr:addr + length] = bytes.fromhex(new.format(sym[symbol]) if symbol else new)
        covered.append((addr, addr + length))
    for addr, original, _ in SKIPPED_ROUTINES:
        assert rom[addr:addr + len(original) // 2].hex() == original, f'unexpected code at {addr:06x}'
        rom[addr:addr + 2] = b'\x4e\x75'
        covered.append((addr, addr + 0x42))
    for addr, original in DEBUG_MARKERS:
        assert rom[addr:addr + 4].hex() == original, f'unexpected code at {addr:06x}'
        rom[addr:addr + 2] = b'\x4e\x75'
    covered.append(DEBUG_MARKER_BODY)
    report.append(f'{len(FAST_PATHS)} tilemap routines replaced by fast paths, {len(INLINE_PATCHES)} patched in place, {len(SKIPPED_ROUTINES)} skipped')
    return covered


STORED_TABLES = [(0x908000, 0x914000)]


def drop_replacement(ins):
    m = re.match(r'(move|clr|and|or)\.([bwl])$', ins.mnemonic)
    if not m:
        return None
    op, size = m.group(1), {'b': 1, 'w': 2, 'l': 4}[m.group(2)]
    operands = [o.strip() for o in re.split(r',(?![^(]*\))', ins.op_str)]
    code = []
    for operand in operands[:-1] if op in ('move', 'and', 'or') else []:
        inc = re.fullmatch(r'\(a([0-7])\)\+', operand)
        dec = re.fullmatch(r'-\(a([0-7])\)', operand)
        if inc:
            code.append(0x5088 | ((size & 7) << 9) | int(inc.group(1)))
        if dec:
            code.append(0x5188 | ((size & 7) << 9) | int(dec.group(1)))
    dest = operands[-1]
    reg = re.fullmatch(r'd([0-7])', dest)
    inc = re.fullmatch(r'\(a([0-7])\)\+', dest)
    dec = re.fullmatch(r'-\(a([0-7])\)', dest)
    if reg:
        if op != 'move':
            return None
        r = int(reg.group(1))
        code.append({1: 0x4200 | r, 2: 0x4240 | r, 4: 0x7000 | (r << 9)}[size])
    elif inc:
        code.append(0x5088 | ((size & 7) << 9) | int(inc.group(1)))
    elif dec:
        code.append(0x5188 | ((size & 7) << 9) | int(dec.group(1)))
    if len(code) * 2 > ins.size:
        return None
    return struct.pack(f'>{len(code)}H', *code) + struct.pack('>H', NOP) * (ins.size // 2 - len(code))


def build_patch_table(rom, access_path, covered, report):
    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_000)
    entries = {}
    dropped = 0
    for row in csv.DictReader(open(access_path)):
        if row['region'] != '1':
            continue
        lo, hi = int(row['low'], 16), int(row['high'], 16)
        if not any(lo < b and hi >= a for a, b in TABLE_RANGES):
            continue
        pc = int(row['pc'], 16)
        if any(a <= pc < b for a, b in covered + SKIP_RANGES):
            continue
        ins = next(md.disasm(bytes(rom[pc:pc + 12]), pc))
        if not any(lo < b and hi >= a for a, b in STORED_TABLES):
            replacement = drop_replacement(ins)
            if replacement is not None:
                rom[pc:pc + ins.size] = replacement
                dropped += 1
                continue
        assert ins.size <= 8, f'{pc:06x} {ins.mnemonic} {ins.op_str} is too long to record'
        entries[pc] = bytes(rom[pc:pc + ins.size])
    order = sorted(entries)
    table = bytearray(struct.pack('>H', len(order)))
    for pc in order:
        original = entries[pc]
        table += struct.pack('>IH', pc, len(original)) + original.ljust(10, b'\0')
        rom[pc:pc + len(original)] = struct.pack('>H', TRAP8) + struct.pack('>H', NOP) * (len(original) // 2 - 1)
    slots = [0xffff] * PATCH_HASH_SIZE
    for index, pc in enumerate(order):
        h = (pc >> 1) & (PATCH_HASH_SIZE - 1)
        while slots[h] != 0xffff:
            h = (h + 1) & (PATCH_HASH_SIZE - 1)
        slots[h] = index * 16
    table = table.ljust(PATCH_HASH - PATCH_TABLE, b'\xff') + struct.pack(f'>{PATCH_HASH_SIZE}H', *slots)
    report.append(f'{len(entries)} instructions that touch arcade tilemaps replaced by TRAP #8; '
                  f'{dropped} that only touch layers not drawn yet reduced to their register side effects')
    return bytes(table)


def convert_tiles(gfx):
    tiles = np.frombuffer(gfx, dtype=np.uint8).reshape(-1, 16, 2, 4)
    bits = np.unpackbits(tiles, axis=3).reshape(-1, 16, 2, 4, 8)
    pen = (bits[:, :, :, 3] << 3) | (bits[:, :, :, 2] << 2) | (bits[:, :, :, 1] << 1) | bits[:, :, :, 0]
    pixels = pen.reshape(-1, 16, 16)
    flags = (pixels != 15).any(axis=(1, 2)).astype(np.uint8) | ((pixels != 15).all(axis=(1, 2)).astype(np.uint8) << 1)
    md = np.where(pixels == 15, 0, pixels + 1).astype(np.uint8)
    packed = (md[:, :, 0::2] << 4) | md[:, :, 1::2]
    quads = [packed[:, 0:8, 0:4], packed[:, 8:16, 0:4], packed[:, 0:8, 4:8], packed[:, 8:16, 4:8]]
    data = np.stack(quads, axis=1).reshape(len(packed), 128)
    return data.tobytes(), flags.tobytes()


def convert_far_tiles(gfx):
    first, end = FAR_TILES
    raw = np.frombuffer(gfx[first * 512:end * 512], dtype=np.uint8).reshape(-1, 32, 4, 4)
    bits = np.unpackbits(raw, axis=3).reshape(-1, 32, 4, 4, 8)
    pen = (bits[:, :, :, 3] << 3) | (bits[:, :, :, 2] << 2) | (bits[:, :, :, 1] << 1) | bits[:, :, :, 0]
    pixels = pen.reshape(-1, 32, 32)
    md = np.where(pixels == 15, 0, pixels + 1).astype(np.uint8)
    packed = (md[:, :, 0::2] << 4) | md[:, :, 1::2]
    cells = [packed[:, y * 8:y * 8 + 8, x * 4:x * 4 + 4] for x in range(4) for y in range(4)]
    data = np.stack(cells, axis=1).reshape(len(packed), 512)
    flags = np.zeros(0x2000, dtype=np.uint8)
    flags[first:end] = (pixels != 15).any(axis=(1, 2))
    return data.tobytes(), flags.tobytes()


def text_flags(gfx):
    raw = np.frombuffer(gfx[:TEXT_CODES * 64], dtype=np.uint8).reshape(TEXT_CODES, 8, 2, 4)
    return (raw != 0xff).any(axis=(1, 3)).astype(np.uint8).tobytes()


def colour_table():
    table = bytearray(256)
    for bright in range(16):
        for nibble in range(16):
            level = nibble * 0x11 * (0x0f + 2 * bright) // 0x2d
            table[bright * 16 + nibble] = round(level * 7 / 255) << 1
    return bytes(table)


def header(rom_end):
    h = bytearray(b' ' * 0x100)

    def put(off, text, size):
        h[off:off + size] = text.encode().ljust(size)[:size]

    put(0x00, 'SEGA SSF', 16)
    put(0x10, '(C)     2026.NOV', 16)
    put(0x20, 'CADILLACS AND DINOSAURS MD - RESEARCH BUILD', 48)
    put(0x50, 'CADILLACS AND DINOSAURS MD - RESEARCH BUILD', 48)
    put(0x80, 'GM 00000000-00', 14)
    put(0x90, 'J', 16)
    h[0xa0:0xb0] = struct.pack('>4I', 0, rom_end, 0xff0000, 0xffffff)
    put(0xf0, 'JUE', 16)
    return h


def main(prg_path, gfx_path, access_path, out_path):
    build(Path(prg_path).read_bytes(), Path(gfx_path).read_bytes(), access_path, out_path)


def build(prg, gfx, access_path, out_path, sound_roms=None):
    rom = bytearray(prg)
    assert len(rom) == PROGRAM_SIZE, 'expected the 1.5 MB dino program image'
    report = []

    done = patch_executed(rom, access_path, report)
    patch_static(rom, IO_RELOCATIONS, done, False, 'I/O', report)
    patch_static(rom, GFX_RELOCATIONS, done, True, 'palettes and row scroll', report)
    for off, old, new in SPRITE_LISTS:
        assert struct.unpack_from('>I', rom, off)[0] == old
        struct.pack_into('>I', rom, off, new)
    report.append('sprite list buffers moved to work RAM (4 operands)')

    hal, sym = assemble_hal()
    covered = apply_fast_paths(rom, sym, report)
    patch_table = build_patch_table(rom, access_path, covered, report)
    assert rom[POST_RESET_JUMP:POST_RESET_JUMP + 2] == b'\x4e\xf9'
    struct.pack_into('>I', rom, POST_RESET_JUMP + 2, sym['hal_post_reset'])

    vectors = list(struct.unpack_from('>64I', rom, 0))
    vectors[1] = sym['hal_boot']
    for i in range(2, 25):
        vectors[i] = sym['hal_crash']
    for i in range(25, 32):
        vectors[i] = sym['hal_ignore']
    vectors[30] = sym['hal_vblank']
    vectors[40] = sym['gfx_trap']
    for trap, handler in FAST_PATH_HANDLERS.items():
        vectors[32 + trap] = sym[handler]
    for i in range(48, 64):
        vectors[i] = sym['hal_crash']
    struct.pack_into('>64I', rom, 0, *vectors)

    assert len(hal) <= SOUND_TABLE - HAL_BASE
    rom += hal
    tiles, flags = convert_tiles(gfx)
    rom += b'\xff' * (COLOUR_TABLE - len(rom))
    rom += colour_table()
    rom += b'\xff' * (TILE_FLAGS - len(rom))
    rom += flags
    rom += b'\xff' * (PATCH_TABLE - len(rom))
    rom += patch_table
    far_tiles, far_flags = convert_far_tiles(gfx)
    assert len(rom) <= TILE_FLAGS3
    rom += b'\xff' * (TILE_FLAGS3 - len(rom))
    rom += far_flags
    assert len(rom) == TEXT_FLAGS
    rom += text_flags(gfx)
    assert len(rom) <= TILE_DATA
    rom += b'\xff' * (TILE_DATA - len(rom))
    tiles = bytearray(tiles)
    tiles[FAR_TILES[0] * 512:FAR_TILES[1] * 512] = far_tiles
    rom += tiles
    rom[SOUND_TABLE:SOUND_TABLE + SOUND_FIXED] = bytes(SOUND_FIXED)
    if sound_roms:
        import sound
        assert len(rom) % sound.BANK == 0
        fixed, image = sound.convert(sound_roms[0], sound_roms[1], Path(out_path).parent / 'cache',
                                     len(rom) // sound.BANK, log=report.append)
        assert len(fixed) <= COLOUR_TABLE - SOUND_TABLE
        rom[SOUND_TABLE:SOUND_TABLE + len(fixed)] = fixed
        rom += image
    report.append(f'far background: {sum(far_flags)} of {FAR_TILES[1] - FAR_TILES[0]} 32x32 tiles have pixels')
    rom[0x100:0x200] = header(len(rom) - 1)
    checksum = sum(struct.unpack_from(f'>{(len(rom) - 0x200) // 2}H', rom, 0x200)) & 0xffff
    struct.pack_into('>H', rom, 0x18e, checksum)

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_bytes(rom)
    report.append(f'hardware layer: {len(hal)} bytes at {HAL_BASE:06x}; {len(flags)} tiles converted, '
                  f'{np.count_nonzero(np.frombuffer(flags, dtype=np.uint8))} with pixels; ROM {len(rom) // 1024} KB -> {out_path}')
    print('\n'.join(report))


if __name__ == '__main__':
    main(*sys.argv[1:5])
