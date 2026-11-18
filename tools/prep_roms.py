"""Build flat images from user-supplied ROM sets.

usage: prep_roms.py <roms_dir> <out_dir>
<roms_dir> holds one extracted folder per set: dino/, ffight/, ffmd/.
"""
import glob
import sys
from pathlib import Path


def swap(b):
    b = bytearray(b)
    b[0::2], b[1::2] = b[1::2], b[0::2]
    return bytes(b)


def interleave(*parts):
    out = bytearray(len(parts[0]) * len(parts))
    for i, p in enumerate(parts):
        out[i::len(parts)] = p
    return bytes(out)


def gfx64(roms):
    out = bytearray(len(roms[0]) * 4)
    for i, r in enumerate(roms):
        out[2 * i::8] = r[0::2]
        out[2 * i + 1::8] = r[1::2]
    return bytes(out)


def main(roms, out):
    rd = lambda s, n: (roms / s / n).read_bytes()
    out.mkdir(parents=True, exist_ok=True)
    if (roms / 'dino').is_dir():
        prg = b''.join(swap(rd('dino', n)) for n in ('cde_23a.8f', 'cde_22a.7f', 'cde_21a.6f'))
        (out / 'dino_prg.bin').write_bytes(prg)
        gfx = gfx64([rd('dino', n) for n in ('cd-1m.3a', 'cd-3m.5a', 'cd-2m.4a', 'cd-4m.6a')])
        gfx += gfx64([rd('dino', n) for n in ('cd-5m.7a', 'cd-7m.9a', 'cd-6m.8a', 'cd-8m.10a')])
        (out / 'dino_gfx.bin').write_bytes(gfx)
    if (roms / 'ffight').is_dir():
        prg = interleave(rd('ffight', 'ff_36.11f'), rd('ffight', 'ff_42.11h')).ljust(0x40000, b'\xff')
        prg += interleave(rd('ffight', 'ff_37.12f'), rd('ffight', 'ffe_43.12h')).ljust(0x40000, b'\xff')
        prg += swap(rd('ffight', 'ff-32m.8h'))
        (out / 'ffight_prg.bin').write_bytes(prg)
        gfx = gfx64([rd('ffight', n) for n in ('ff-5m.7a', 'ff-7m.9a', 'ff-1m.3a', 'ff-3m.5a')])
        (out / 'ffight_gfx.bin').write_bytes(gfx)
    md = glob.glob(str(roms / 'ffmd' / '*'))
    if md:
        (out / 'ffmd.bin').write_bytes(Path(md[0]).read_bytes())


if __name__ == '__main__':
    main(Path(sys.argv[1]), Path(sys.argv[2]))
