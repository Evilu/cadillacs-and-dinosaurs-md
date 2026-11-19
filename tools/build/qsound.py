"""The arcade's sound, run at build time. The QSound board's Z80 program is decoded
(kabuki.py) and run in a small emulator of the board (qsound_board.c, compiled on first
use); each sound command is played alone and the DSP register writes are logged.

Shared RAM packet the 68000 writes at 0xF18000 (odd bytes; index = Z80 address - 0xC000):
  [0] 0x00, [1] command, [6]-[0xC] seven parameter bytes, [0xF] = 0 to hand it over.
  [0] 0xFF, [1] control code, [3], [4] parameters: board control (0x0B twice and 0x00 at start-up).
DSP registers: voice v (0-15) uses v*8 + 0 bank of voice v+1, 1 start, 2 pitch (0x1000 = 24,038 Hz),
  4 loop length, 5 end, 6 volume; 0x80 + v pan.
"""
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kabuki

HERE = Path(__file__).resolve().parent
RATE = 24038
TUNES = range(0x00, 0x27)
EFFECTS = range(0x2c, 0x92)
ALIASES = range(0xa0, 0x100)
DEFAULT_PARAMS = (0, 0x10, 0, 0, 0, 0, 0)


class Board:
    def __init__(self, sound_rom, cache):
        cache = Path(cache)
        cache.mkdir(parents=True, exist_ok=True)
        self.exe = cache / 'qsound_board'
        source = HERE / 'qsound_board.c'
        if not self.exe.exists() or self.exe.stat().st_mtime < source.stat().st_mtime:
            cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
            if not cc:
                sys.exit('a C compiler (cc) is needed to run the sound program at build time')
            subprocess.run([cc, '-O2', '-o', str(self.exe), str(source)], check=True)
        opcodes, data = kabuki.decode(sound_rom)
        self.files = [cache / 'z80_opcodes.bin', cache / 'z80_data.bin', cache / 'z80_rom.bin']
        for path, blob in zip(self.files, (opcodes, data, sound_rom)):
            path.write_bytes(blob)

    def run(self, packets, seconds):
        """packets: (time, {index: byte}) in time order. Returns [(time, register, data)]."""
        lines = [f'0.5 {i:x} ff' for i in range(0x1000)] + ['0.5 ffd 88']
        for at, control in ((0.6, 0x0b), (0.65, 0x0b), (0.7, 0x00)):
            lines += [f'{at} {i:x} {v:x}' for i, v in ((0, 0xff), (1, control), (3, 0), (4, 0), (0xf, 0))]
        for at, packet in packets:
            lines += [f'{at} {i:x} {v:x}' for i, v in packet.items()]
        out = subprocess.run([str(self.exe)] + [str(f) for f in self.files] + [str(seconds)],
                             input='\n'.join(lines) + '\n', capture_output=True, text=True, check=True).stdout
        return [(float(t), int(r, 16), int(d, 16)) for t, r, d in (line.split() for line in out.splitlines())]

    def play(self, command, seconds, params=DEFAULT_PARAMS, start=1.0):
        """Plays one command alone; times in the result count from the command."""
        packet = {0: 0, 1: command, 0xf: 0}
        packet.update({6 + i: p for i, p in enumerate(params)})
        packet = dict(sorted(packet.items(), key=lambda kv: kv[0] == 0xf))
        return [(t - start, r, d) for t, r, d in self.run([(start, packet)], start + seconds) if t >= start]


class Note:
    """One key-on. frames: [(time, pitch, volume)] at every change of either."""
    __slots__ = ('at', 'voice', 'sample', 'end', 'loop', 'frames', 'off')

    def __init__(self, at, voice, sample, end, loop):
        self.at, self.voice, self.sample, self.end, self.loop = at, voice, sample, end, loop
        self.frames = []
        self.off = None

    @property
    def pitch(self):
        return next((p for _, p, _ in self.frames if p), 0)

    @property
    def volume(self):
        return max((v for _, _, v in self.frames), default=0)


def notes(log, until):
    """Turns a register log into notes. The driver starts a note by writing the voice's
    start, end, loop and bank, then its phase register (3), then volume and pitch, which it
    rewrites every 16 ms. It stops a voice by writing pitch 0."""
    state = [dict(bank=0, start=0, loop=0, end=0, pitch=0, volume=0) for _ in range(16)]
    current = [None] * 16
    out = []
    for at, reg, data in log:
        if reg >= 0x80:
            continue
        v, field = reg >> 3, reg & 7
        s, note = state[v], current[v]
        if field == 0:
            state[(v + 1) & 15]['bank'] = data & 0x7f
        elif field == 1:
            s['start'] = data
        elif field == 4:
            s['loop'] = data
        elif field == 5:
            s['end'] = data
        elif field == 3:
            if note and note.off is None:
                note.off = at
            current[v] = Note(at, v, s['bank'] << 16 | s['start'], s['end'], s['loop'])
            out.append(current[v])
            s['pitch'] = s['volume'] = 0
        elif field in (2, 6):
            s['pitch' if field == 2 else 'volume'] = data
            if note and note.off is None:
                if field == 2 and data == 0 and note.frames:
                    note.off = at
                elif s['pitch'] and (not note.frames or note.frames[-1][1:] != (s['pitch'], s['volume'])):
                    note.frames.append((at, s['pitch'], s['volume']))
    for note in out:
        if note.off is None:
            note.off = until
    return [n for n in out if n.pitch and n.volume]
