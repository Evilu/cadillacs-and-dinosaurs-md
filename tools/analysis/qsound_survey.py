"""usage: qsound_survey.py <cd_q.5k> <cache dir> [seconds=30]
Plays every sound command alone in the board emulator and lists what it does: how long
it writes, the voices and notes it uses, the most voices sounding at once and the samples."""
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build'))
import qsound


def survey(board, command, seconds):
    notes = qsound.notes(board.play(command, seconds), seconds)
    if not notes:
        return None
    edges = sorted([(n.at, 1) for n in notes] + [(n.off, -1) for n in notes])
    most = now = 0
    for _, step in edges:
        now += step
        most = max(most, now)
    last = max(n.off for n in notes)
    samples = {(n.sample, n.end, n.loop) for n in notes}
    return command, last, sorted({n.voice for n in notes}), len(notes), most, samples


def main(rom, cache, seconds=30):
    board = qsound.Board(Path(rom).read_bytes(), cache)
    seconds = float(seconds)
    every = set()
    with ThreadPoolExecutor(8) as pool:
        for row in pool.map(lambda c: survey(board, c, seconds), range(0x100)):
            if not row:
                continue
            command, last, voices, count, most, samples = row
            every |= samples
            kind = 'tune' if command in qsound.TUNES else 'effect'
            ends = 'goes on' if last >= seconds - 0.1 else f'{last:5.2f} s'
            print(f'{command:02x} {kind:6} {ends:8} voices {len(voices):2} notes {count:4} at once {most:2} '
                  f'samples {len(samples):2}')
    size = sum(end - (sample & 0xffff) for sample, end, loop in every)
    print(f'{len(every)} samples in all, {size} bytes')


if __name__ == '__main__':
    main(*sys.argv[1:4])
