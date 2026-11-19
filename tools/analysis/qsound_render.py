"""usage: qsound_render.py <cd_q.5k> <samples.bin> <cache dir> <command hex> <seconds> <out.wav>
Plays one sound command in the board emulator and mixes its voices from the sample ROM
into a mono WAV at 24,038 Hz: the arcade's tune or effect alone, without the DSP's
panning, echo and filters. A reference to compare the Mega Drive build's sound with."""
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build'))
import qsound


def main(rom, samples, cache, command, seconds, out):
    seconds = float(seconds)
    data = np.frombuffer(Path(samples).read_bytes(), dtype=np.int8).astype(np.float32)
    board = qsound.Board(Path(rom).read_bytes(), cache)
    notes = qsound.notes(board.play(int(command, 16), seconds), seconds)
    mix = np.zeros(int(seconds * qsound.RATE) + 1, dtype=np.float32)
    for note in notes:
        x = data[note.sample:(note.sample & ~0xffff) + note.end]
        first, last = int(note.at * qsound.RATE), int(note.off * qsound.RATE)
        if len(x) < 2 or last <= first:
            continue
        times = np.array([f[0] for f in note.frames]) * qsound.RATE - first
        at = np.arange(last - first)
        step = np.array([f[1] for f in note.frames], dtype=np.float64)[np.clip(np.searchsorted(times, at, 'right') - 1, 0, None)] / 4096
        volume = np.array([f[2] for f in note.frames], dtype=np.float32)[np.clip(np.searchsorted(times, at, 'right') - 1, 0, None)]
        pos = np.cumsum(step) - step[0]
        if 0 < note.loop < len(x):
            over = pos >= len(x)
            pos[over] = len(x) - note.loop + (pos[over] - len(x)) % note.loop
        alive = pos < len(x) - 1
        pos = np.minimum(pos, len(x) - 1.001)
        i = pos.astype(np.int64)
        mix[first:last] += (x[i] * (1 - (pos - i)) + x[i + 1] * (pos - i)) * volume * alive
    peak = float(np.abs(mix).max()) or 1.0
    with wave.open(out, 'w') as w:
        w.setparams((1, 2, qsound.RATE, 0, 'NONE', ''))
        w.writeframes((mix / peak * 28000).astype(np.int16).tobytes())
    print(f'{len(notes)} notes -> {out}')


if __name__ == '__main__':
    main(*sys.argv[1:7])
