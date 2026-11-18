"""Build the Mega Drive ROM from the user's arcade program image.

usage: build.py <dino_prg.bin> <access_pcs.csv> <out.bin>

Takes the 1.5 MB arcade 68000 program, redirects its fixed-address hardware
accesses to shadow locations in work RAM, replaces the vectors and the first
header page, and appends the hardware layer assembled from src/hal.s.
"""
import csv
import struct
import subprocess
import sys
import tempfile

from capstone import CS_ARCH_M68K, CS_MODE_BIG_ENDIAN, CS_MODE_M68K_000, Cs
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HAL_BASE = 0x180000
ROM_SIZE = 0x200000

RELOCATIONS = [
    (0x800000, 0x800200, 0xff1000),
    (0xf18000, 0xf18040, 0xff1200),
    (0xf19fe0, 0xf1a020, 0xff1240),
    (0xf1c000, 0xf1c020, 0xff1280),
]


def relocate(addr):
    for lo, hi, to in RELOCATIONS:
        if lo <= addr < hi:
            return to + addr - lo
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


def header(rom_end):
    h = bytearray(b' ' * 0x100)

    def put(off, text, size):
        h[off:off + size] = text.encode().ljust(size)[:size]

    put(0x00, 'SEGA MEGA DRIVE', 16)
    put(0x10, '(C)     2026.NOV', 16)
    put(0x20, 'CADILLACS AND DINOSAURS MD - RESEARCH BUILD', 48)
    put(0x50, 'CADILLACS AND DINOSAURS MD - RESEARCH BUILD', 48)
    put(0x80, 'GM 00000000-00', 14)
    put(0x90, 'J', 16)
    h[0xa0:0xb0] = struct.pack('>4I', 0, rom_end, 0xff0000, 0xffffff)
    put(0xf0, 'JUE', 16)
    return h


def main(prg_path, access_path, out_path):
    rom = bytearray(Path(prg_path).read_bytes())
    assert len(rom) == HAL_BASE, 'expected the 1.5 MB dino program image'
    report = []

    done = set()
    rows = [r for r in csv.DictReader(open(access_path)) if r['region'] in '02']
    for row in rows:
        pc = int(row['pc'], 16)
        for off in range(pc + 2, pc + 10, 2):
            new = relocate(struct.unpack_from('>I', rom, off)[0])
            if new is not None:
                struct.pack_into('>I', rom, off, new)
                done.add(off)
    for row in rows:
        pc = int(row['pc'], 16)
        if not any(pc < off <= pc + 8 for off in done):
            report.append(f'unpatched hardware access through a pointer at {pc:06x} ({row["low"]}-{row["high"]})')
    report.append(f'{len(done)} address operands redirected at instructions seen executing')

    md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_000)
    static, skipped = 0, 0
    for off in range(0x200, len(rom) - 4, 2):
        value = struct.unpack_from('>I', rom, off)[0]
        target = relocate(value)
        if target is None or off in done:
            continue
        operand = f'${value:x}.l'
        for start in (off - 2, off - 4, off - 6):
            ins = next(md.disasm(bytes(rom[start:start + 12]), start), None)
            if ins and start + ins.size >= off + 4 and operand in ins.op_str:
                struct.pack_into('>I', rom, off, target)
                static += 1
                break
        else:
            skipped += 1
    report.append(f'{static} more redirected where the value is the operand of a valid instruction')
    report.append(f'{skipped} values that look like I/O addresses left alone (not an instruction operand)')

    for off, old, new in ((0xb12, 0x900000, 0xff2000), (0xb24, 0x904000, 0xff2800),
                          (0x13fb6, 0x900000, 0xff2000), (0x13fc4, 0x904000, 0xff2800)):
        assert struct.unpack_from('>I', rom, off)[0] == old
        struct.pack_into('>I', rom, off, new)
    report.append('sprite list buffers moved to work RAM (4 operands)')

    hal, sym = assemble_hal()
    struct.pack_into('>I', rom, 0x4c8 + 2, sym['hal_post_reset'])
    assert rom[0x4c8:0x4ca] == b'\x4e\xf9'

    vectors = list(struct.unpack_from('>64I', rom, 0))
    vectors[1] = sym['hal_boot']
    for i in list(range(2, 25)):
        vectors[i] = sym['hal_crash']
    for i in range(25, 32):
        vectors[i] = sym['hal_ignore']
    vectors[30] = sym['hal_vblank']
    for i in range(48, 64):
        vectors[i] = sym['hal_crash']
    struct.pack_into('>64I', rom, 0, *vectors)

    rom += hal
    rom_end = len(rom) - 1
    rom[0x100:0x200] = header(ROM_SIZE - 1)
    rom += b'\xff' * (ROM_SIZE - len(rom))
    checksum = sum(struct.unpack_from(f'>{(len(rom) - 0x200) // 2}H', rom, 0x200)) & 0xffff
    struct.pack_into('>H', rom, 0x18e, checksum)

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_bytes(rom)
    report.append(f'hardware layer: {len(hal)} bytes at {HAL_BASE:06x}; ROM {len(rom)} bytes -> {out_path}')
    print('\n'.join(report))


if __name__ == '__main__':
    main(*sys.argv[1:4])
