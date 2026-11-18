"""Build the Mega Drive ROM from the user's arcade program and graphics images.

usage: build.py <dino_prg.bin> <dino_gfx.bin> <access_pcs.csv> <out.md>

Takes the 1.5 MB arcade 68000 program, redirects its fixed-address hardware
accesses to shadow locations in work RAM, replaces the vectors and the first
header page, appends the hardware layer assembled from src/hal.s, and adds the
arcade graphics converted to Mega Drive tiles behind the Sega (SSF2) mapper.

ROM layout:
  0x000000  arcade program (patched)
  0x180000  hardware layer
  0x187F00  colour table: [brightness][nibble] -> Mega Drive level << 1
  0x188000  tile flags: one byte per arcade 16x16 tile, nonzero if it has pixels
  0x190000  arcade 16x16 tiles 0x0800-0x6FFF (the sprite range) as four Mega Drive
            patterns each (TL, BL, TR, BR)

The ROM stays under 5 MB because MAME's Sega mapper implements only the ten
512 KB banks Super Street Fighter II used.
"""
import csv
import re
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
TILE_FLAGS = 0x188000
TILE_DATA = 0x190000
SPRITE_TILES = (0x0800, 0x7000)

IO_RELOCATIONS = [
    (0x800000, 0x800200, 0xff1000),
    (0xf18000, 0xf18040, 0xff1200),
    (0xf19fe0, 0xf1a020, 0xff1240),
    (0xf1c000, 0xf1c020, 0xff1280),
]
GFX_RELOCATIONS = [
    (0x914000, 0x918000, 0xff3000),
]
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


def assemble_hal():
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (Path(tmp) / n for n in ('hal.o', 'hal.elf', 'hal.bin'))
        subprocess.run(['m68k-elf-as', '-m68000', '--register-prefix-optional',
                        str(ROOT / 'src' / 'hal.s'), '-o', str(obj)], check=True)
        subprocess.run(['m68k-elf-ld', '-Ttext', hex(HAL_BASE), '-e', hex(HAL_BASE), '-o', str(elf), str(obj)],
                       check=True)
        subprocess.run(['m68k-elf-objcopy', '-O', 'binary', str(elf), str(out)], check=True)
        nm = subprocess.run(['m68k-elf-nm', str(elf)], check=True, capture_output=True, text=True).stdout
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


def convert_tiles(gfx):
    tiles = np.frombuffer(gfx, dtype=np.uint8).reshape(-1, 16, 2, 4)
    bits = np.unpackbits(tiles, axis=3).reshape(-1, 16, 2, 4, 8)
    pen = (bits[:, :, :, 3] << 3) | (bits[:, :, :, 2] << 2) | (bits[:, :, :, 1] << 1) | bits[:, :, :, 0]
    pixels = pen.reshape(-1, 16, 16)
    flags = (pixels != 15).any(axis=(1, 2)).astype(np.uint8)
    md = np.where(pixels == 15, 0, pixels + 1).astype(np.uint8)
    packed = (md[:, :, 0::2] << 4) | md[:, :, 1::2]
    quads = [packed[:, 0:8, 0:4], packed[:, 8:16, 0:4], packed[:, 0:8, 4:8], packed[:, 8:16, 4:8]]
    data = np.stack(quads, axis=1).reshape(len(packed), 128)
    return data.tobytes(), flags.tobytes()


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
    rom = bytearray(Path(prg_path).read_bytes())
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
    assert rom[POST_RESET_JUMP:POST_RESET_JUMP + 2] == b'\x4e\xf9'
    struct.pack_into('>I', rom, POST_RESET_JUMP + 2, sym['hal_post_reset'])

    vectors = list(struct.unpack_from('>64I', rom, 0))
    vectors[1] = sym['hal_boot']
    for i in range(2, 25):
        vectors[i] = sym['hal_crash']
    for i in range(25, 32):
        vectors[i] = sym['hal_ignore']
    vectors[30] = sym['hal_vblank']
    for i in range(48, 64):
        vectors[i] = sym['hal_crash']
    struct.pack_into('>64I', rom, 0, *vectors)

    assert len(hal) <= COLOUR_TABLE - HAL_BASE
    rom += hal
    tiles, flags = convert_tiles(Path(gfx_path).read_bytes())
    rom += b'\xff' * (COLOUR_TABLE - len(rom))
    rom += colour_table()
    rom += b'\xff' * (TILE_FLAGS - len(rom))
    rom += flags
    rom += b'\xff' * (TILE_DATA - len(rom))
    rom += tiles[SPRITE_TILES[0] * 128:SPRITE_TILES[1] * 128]
    assert len(rom) <= 0x500000
    rom[0x100:0x200] = header(len(rom) - 1)
    checksum = sum(struct.unpack_from(f'>{(len(rom) - 0x200) // 2}H', rom, 0x200)) & 0xffff
    struct.pack_into('>H', rom, 0x18e, checksum)

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_bytes(rom)
    report.append(f'hardware layer: {len(hal)} bytes at {HAL_BASE:06x}; {len(flags)} tiles converted, '
                  f'{sum(flags)} with pixels; ROM {len(rom) // 1024} KB -> {out_path}')
    print('\n'.join(report))


if __name__ == '__main__':
    main(*sys.argv[1:5])
