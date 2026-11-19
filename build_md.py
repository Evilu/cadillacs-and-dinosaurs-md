"""Build the Mega Drive ROM from your copy of the arcade game.

usage: python3 build_md.py <dino.zip or folder> [out.md] [--stage N]

Takes MAME's "dino" set (Cadillacs and Dinosaurs, World 930201), checks the
sixteen files the port uses, and writes the Mega Drive ROM (default
out/cadillacs_md.md). The set is read straight from the zip; nothing is
extracted to disk.

--stage N (0-7) makes a test ROM that inserts a coin, presses start and begins
in that stage by itself, for emulators that take no scripted input. It is not
the game: do not hand it out.
"""
import os
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tools' / 'build'))

PROGRAM = [('cde_23a.8f', 0x8f4e585e), ('cde_22a.7f', 0x9278aa12), ('cde_21a.6f', 0x66d23de2)]
GRAPHICS = [
    [('cd-1m.3a', 0x8da4f917), ('cd-3m.5a', 0x6c40f603), ('cd-2m.4a', 0x09c8fc2d), ('cd-4m.6a', 0x637ff38f)],
    [('cd-5m.7a', 0x470befee), ('cd-7m.9a', 0x22bfb7a3), ('cd-6m.8a', 0xe7599ac4), ('cd-8m.10a', 0x211b4b15)],
]
SOUND = [('cd_q.5k', 0x605fdb0b)]
SAMPLES = [('cd-q1.1k', 0x60927775), ('cd-q2.2k', 0x770f4c47), ('cd-q3.3k', 0x2f273ffc), ('cd-q4.4k', 0x2c67821d)]
SIZE = 0x80000
SIZES = {'cd_q.5k': 0x20000}


def reader(source):
    if source.is_dir():
        files = {p.name.lower(): p for p in source.rglob('*') if p.is_file()}
        return lambda name: files[name].read_bytes() if name in files else None
    if not zipfile.is_zipfile(source):
        sys.exit(f'{source} is neither a folder nor a zip file')
    archive = zipfile.ZipFile(source)
    members = {Path(i.filename).name.lower(): i for i in archive.infolist() if not i.is_dir()}

    def read(name):
        info = members.get(name)
        if info is None or info.file_size != SIZES.get(name, SIZE):
            return None
        return archive.read(info)
    return read


def load(read):
    data, problems = {}, []
    for name, crc in PROGRAM + GRAPHICS[0] + GRAPHICS[1] + SOUND + SAMPLES:
        blob = read(name)
        if blob is None:
            problems.append(f'  {name}: missing')
        elif len(blob) != SIZES.get(name, SIZE) or zlib.crc32(blob) != crc:
            problems.append(f'  {name}: wrong contents (expected {SIZES.get(name, SIZE)} bytes, CRC32 {crc:08x}; '
                            f'found {len(blob)} bytes, CRC32 {zlib.crc32(blob):08x})')
        data[name] = blob
    if problems:
        sys.exit('This is not the "dino" set the port needs (Cadillacs and Dinosaurs, World 930201):\n' +
                 '\n'.join(problems))
    return data


def swap(b):
    b = bytearray(b)
    b[0::2], b[1::2] = b[1::2], b[0::2]
    return bytes(b)


def interleave64(parts):
    out = bytearray(SIZE * 4)
    for i, p in enumerate(parts):
        out[2 * i::8] = p[0::2]
        out[2 * i + 1::8] = p[1::2]
    return bytes(out)


def main(argv):
    if '--stage' in argv:
        at = argv.index('--stage')
        os.environ['BOOT_STAGE'] = argv[at + 1]
        argv = argv[:at] + argv[at + 2:]
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        sys.exit(__doc__.strip())
    try:
        import numpy  # noqa: F401
        import capstone  # noqa: F401
    except ImportError as missing:
        sys.exit(f'Python package missing ({missing.name}): run  python3 -m pip install -r requirements.txt')
    import build

    source = Path(argv[1])
    out = Path(argv[2]) if len(argv) > 2 else ROOT / 'out' / 'cadillacs_md.md'
    if not source.exists():
        sys.exit(f'{source} not found')
    data = load(reader(source))
    program = b''.join(swap(data[name]) for name, _ in PROGRAM)
    graphics = b''.join(interleave64([data[name] for name, _ in group]) for group in GRAPHICS)
    sound_roms = (data[SOUND[0][0]], b''.join(data[name] for name, _ in SAMPLES))
    build.build(program, graphics, ROOT / 'tools' / 'build' / 'dino_access.csv', out, sound_roms)
    print(f'\nDone: {out}')


if __name__ == '__main__':
    main(sys.argv)
