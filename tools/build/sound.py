"""Converts the arcade's sound for the Mega Drive at build time.

Every sound command is played alone in the board emulator (qsound.py). A tune's notes are
re-voiced: pitched samples become notes on five YM2612 channels and the three PSG square
channels, with the sample's own pitch found by autocorrelation and the level following the
driver's volume writes frame by frame; unpitched samples (drums) and all effects become 8-bit
PCM for the DAC on channel 6, played by the Z80 one at a time.

usage: sound.py <cd_q.5k> <samples.bin> <cache dir> [command hex ...]   (report only)

Stream bytes, one frame at a time:
  0x00 end of frame            0x01 n   wait n more frames      0x02 stop
  0x03 hi mid lo  go to offset 0x04 v   PSG byte                0x05 r v  YM2612 part 2
  0x06 n  start PCM n (unless an effect is playing)             r v (r >= 0x20)  YM2612 part 1
"""
import hashlib
import math
import pickle
import struct
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qsound

FRAME = 1 / 59.92
TICK = 0.016
YM_RATE = 7670454 / 144
PSG_CLOCK = 3579545
Z80_CLOCK = 3579545
DAC_DELAY = 25
DAC_RATE = Z80_CLOCK / (110 + 13 * DAC_DELAY)
TUNE_SECONDS = 480
EFFECT_SECONDS = 8
PCM_MAX_SECONDS = 4.0
DRUM_MAX_SECONDS = 0.6
SILENT = 0x30
LOUD = 0x900
FM_CHANNELS = 5
PLACES = 8
BANK = 0x80000

PATCHES = {
    'soft': dict(alg=4, fb=0, mod_tl=0x34, mul=(1, 1, 1, 1)),
    'mid': dict(alg=4, fb=3, mod_tl=0x24, mul=(1, 1, 2, 1)),
    'bright': dict(alg=4, fb=5, mod_tl=0x18, mul=(1, 1, 3, 1)),
}


class Samples:
    def __init__(self, rom):
        self.rom = np.frombuffer(rom, dtype=np.int8).astype(np.float32)
        self.memo = {}

    def data(self, sample, end):
        base = sample & ~0xffff
        return self.rom[sample:base + end]

    def analyse(self, sample, end, loop):
        """Returns (base frequency in Hz at pitch 0x1000 or None when unpitched, patch name)."""
        key = (sample, end, loop)
        if key in self.memo:
            return self.memo[key]
        x = self.data(sample, end)
        if loop >= 64:
            x = x[-min(len(x), max(loop * 2, 2048)):]
        else:
            x = x[len(x) // 8:][:4096]
        result = (None, 'mid')
        if len(x) >= 256 and float(np.abs(x).max()) >= 4:
            x = x - x.mean()
            n = len(x)
            spectrum = np.fft.rfft(x, 2 * n)
            ac = np.fft.irfft(spectrum * np.conj(spectrum))[:n // 2]
            ac /= ac[0] + 1e-9
            low = 12
            past = np.argmax(ac[low:] < 0.3) + low if (ac[low:] < 0.3).any() else low
            if past < len(ac) - 2:
                peak = past + int(np.argmax(ac[past:]))
                strength = float(ac[peak])
                lag = peak
                for divisor in (2, 3, 4):
                    early = int(round(peak / divisor))
                    if early > past and ac[early] > 0.85 * strength:
                        lag = early
                if strength > 0.55:
                    a, b, c = ac[lag - 1], ac[lag], ac[lag + 1] if lag + 1 < len(ac) else ac[lag]
                    shift = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) else 0
                    f0 = qsound.RATE / (lag + shift)
                    mags = np.abs(np.fft.rfft(x * np.hanning(n)))
                    freqs = np.fft.rfftfreq(n, 1 / qsound.RATE)
                    centroid = float((mags * freqs).sum() / (mags.sum() + 1e-9)) / f0
                    result = (f0, 'soft' if centroid < 2.2 else 'mid' if centroid < 5 else 'bright')
        self.memo[key] = result
        return result

    def pcm(self, note, limit):
        """The note as unsigned 8-bit PCM at the DAC's rate."""
        x = self.data(note.sample, note.end)
        if len(x) < 16:
            return b'\x80' * 16
        step = (note.pitch / 4096) * qsound.RATE / DAC_RATE
        seconds = min(limit, note.off - note.at)
        if note.loop < 64 or note.loop >= len(x):
            seconds = min(seconds, len(x) / (qsound.RATE * note.pitch / 4096))
        count = max(int(seconds * DAC_RATE), 16)
        pos = np.arange(count) * step
        if note.loop >= 64 and note.loop < len(x):
            over = pos >= len(x)
            pos[over] = len(x) - note.loop + (pos[over] - len(x)) % note.loop
        pos = np.minimum(pos, len(x) - 1.001)
        i = pos.astype(np.int64)
        frac = pos - i
        y = x[i] * (1 - frac) + x[np.minimum(i + 1, len(x) - 1)] * frac
        y *= min(1.0, note.volume / LOUD)
        fade = min(count, int(DAC_RATE * 0.01))
        y[-fade:] *= np.linspace(1, 0, fade)
        return (np.clip(np.round(y), -128, 127).astype(np.int16) + 128).astype(np.uint8).tobytes()


def tl(volume):
    return max(0, min(127, int(round(20 * math.log10(LOUD / max(volume, 1)) / 0.75)) + 14))


def fm_freq(hz):
    block = 0
    fnum = hz * (1 << 21) / YM_RATE
    while fnum >= 2048 and block < 7:
        fnum /= 2
        block += 1
    fnum = min(int(round(fnum)), 2047)
    return block << 11 | fnum


def psg_period(hz):
    while hz < PSG_CLOCK / 32 / 1023:
        hz *= 2
    return max(1, min(1023, int(round(PSG_CLOCK / 32 / hz))))


def psg_level(volume):
    return max(0, min(15, int(round(20 * math.log10(LOUD / max(volume, 1)) / 2)) + 4))


class Stream:
    def __init__(self):
        self.frames = {}

    def at(self, frame):
        return self.frames.setdefault(frame, bytearray())

    def ym(self, frame, channel, reg, value):
        part2, slot = divmod(channel, 3) if reg >= 0x30 else (0, 0)
        self.at(frame).extend(([0x05] if part2 else []) + [reg + slot, value])

    def encode(self, length, loop_frame):
        out, offsets, waiting = bytearray(), {}, 0

        def flush():
            nonlocal waiting
            while waiting:
                n = min(waiting, 256)
                out.extend(b'\x00' if n == 1 else bytes([0x01, n - 1]))
                waiting -= n

        for frame in range(length):
            if frame == loop_frame:
                flush()
                offsets[frame] = len(out)
            body = self.frames.get(frame)
            if body:
                flush()
                out.extend(body)
            waiting += 1
        flush()
        if loop_frame is None:
            out.append(0x02)
        else:
            target = offsets[loop_frame]
            out.extend([0x03, target >> 16, (target >> 8) & 0xff, target & 0xff])
        return bytes(out)


def patch_writes(stream, frame, channel, name):
    patch = PATCHES[name]
    for op, slot in enumerate((0, 8, 4, 12)):
        carrier = op in (1, 3)
        for reg, value in ((0x30, patch['mul'][op]), (0x40, 0x7f if carrier else patch['mod_tl']),
                           (0x50, 0x1f), (0x60, 0x00), (0x70, 0x00), (0x80, 0x0f)):
            stream.ym(frame, channel, reg + slot, value)
    stream.ym(frame, channel, 0xb0, patch['fb'] << 3 | patch['alg'])
    stream.ym(frame, channel, 0xb4, 0xc0)


def key(stream, frame, channel, on):
    stream.at(frame).extend([0x28, (0xf0 if on else 0) | (channel + channel // 3)])


def silence(stream, frame):
    for channel in range(FM_CHANNELS):
        key(stream, frame, channel, False)
    for p in range(3):
        stream.at(frame).extend([0x04, 0x9f | p << 5])


def periodic(events, period):
    """events: one voice's [(tick, sample, pitch)]. Returns (first tick, ticks covered) of the
    stretch up to the end over which every event recurs one period later, give or take 2 ticks."""
    b = len(events) - 1
    a = next((i for i in range(b - 1, -1, -1)
              if abs(events[b][0] - events[i][0] - period) <= 2 and events[i][1:] == events[b][1:]), None)
    if a is None:
        return None
    while a > 0 and events[a - 1][1:] == events[b - 1][1:] and abs(events[b - 1][0] - events[a - 1][0] - period) <= 2:
        a, b = a - 1, b - 1
    return events[a][0], events[-1][0] - events[b][0]


def find_loop(notes):
    """Returns (loop start, period) in seconds when the tune repeats to the end. The period
    is looked for in the busiest voice: of all distances at which its last note recurs, the
    one whose repetition reaches furthest back is the tune's own (a riff repeats only inside
    its section). The loop starts where the last voice has become periodic."""
    voices = {}
    for n in notes:
        voices.setdefault(n.voice, []).append((int(round(n.at / TICK)), n.sample, n.pitch))
    busiest = max(voices.values(), key=len)
    if len(busiest) < 64:
        return None
    final = max(v[-1][0] for v in voices.values())
    best, tried = None, []
    for i in range(len(busiest) - 2, -1, -1):
        period = busiest[-1][0] - busiest[i][0]
        if period < 250 or busiest[i][1:] != busiest[-1][1:] or any(abs(period - t) <= 2 for t in tried):
            continue
        tried.append(period)
        start, span, quiet = 0, final, 0
        for v in voices.values():
            if v[-1][0] < final - 2 * period:
                quiet = max(quiet, v[-1][0] + 1)
                continue
            found = periodic(v, period)
            if not found:
                span = 0
                break
            start, span = max(start, found[0]), min(span, found[1])
        if span >= period and quiet <= start and (best is None or span > best[0]):
            best = (span, start, period)
    if best is None:
        return None
    return best[1] * TICK, best[2] * TICK


def convert_tune(notes, samples, seconds, pcm_index):
    """Returns (stream bytes, statistics)."""
    loop = find_loop(notes)
    if loop:
        start, period = loop
        end = start + period
    else:
        end = min(seconds / 2, max(n.off for n in notes) + 0.1)
    length = int(end / FRAME) + 1
    loop_frame = int(start / FRAME) if loop else None
    stream = Stream()
    places = [dict(voice=None, free_at=-1, keyed=-1, patch=None, freq=None, level=None, on=False, pending=None) for _ in range(PLACES)]

    def release(place, upto):
        index = places.index(place)
        if place['pending'] is not None and place['pending'] <= upto:
            if index < FM_CHANNELS:
                key(stream, place['pending'], index, False)
            else:
                stream.at(place['pending']).extend([0x04, 0x9f | (index - FM_CHANNELS) << 5])
        place['pending'] = None

    stats = dict(notes=0, fm=0, psg=0, drums=0, stolen=0, dropped=0, loop=loop, seconds=end)
    silence(stream, 0)
    for note in sorted(notes, key=lambda n: n.at):
        if note.at >= end:
            break
        f0, patch = samples.analyse(note.sample, note.end, note.loop)
        frame = int(note.at / FRAME)
        stats['notes'] += 1
        if f0 is None:
            stats['drums'] += 1
            stream.at(frame).extend([0x06, pcm_index(note, DRUM_MAX_SECONDS)])
            continue
        steps, last = [], None
        off = min(note.off, end)
        for at, pitch, volume in note.frames:
            if at >= off:
                break
            if volume < SILENT:
                off = at
                break
            f = int(at / FRAME)
            if steps and steps[-1][0] == f:
                steps[-1] = (f, pitch, volume)
            else:
                steps.append((f, pitch, volume))
        if not steps:
            stats['dropped'] += 1
            continue
        choice = next((p for p in places if p['voice'] == note.voice), None)
        if choice is None:
            free = [p for p in places if not p['on'] or p['free_at'] <= frame]
            if free:
                choice = min(free, key=lambda p: (places.index(p) >= FM_CHANNELS, p['free_at']))
            else:
                choice = min(places, key=lambda p: p['keyed'])
                stats['stolen'] += 1
        index = places.index(choice)
        for p in places:
            if p['voice'] == note.voice:
                p['voice'] = None
        off_frame = max(int(off / FRAME), frame + 1)
        release(choice, frame)
        choice.update(voice=note.voice, keyed=frame, free_at=off_frame, on=True)
        if index < FM_CHANNELS:
            stats['fm'] += 1
            key(stream, frame, index, False)
            if choice['patch'] != patch or (loop_frame is not None and frame >= loop_frame and not choice.get('reloaded')):
                patch_writes(stream, frame, index, patch)
                choice['patch'], choice['level'] = patch, None
                choice['reloaded'] = loop_frame is not None and frame >= loop_frame
            choice['freq'] = None
            for f, pitch, volume in steps:
                word = fm_freq(f0 * pitch / 4096)
                if choice['freq'] is None or word >> 11 != choice['freq'] >> 11 or abs(word - choice['freq']) >= 3:
                    stream.ym(f, index, 0xa4, word >> 8)
                    stream.ym(f, index, 0xa0, word & 0xff)
                    choice['freq'] = word
                level = tl(volume)
                if choice['level'] is None or abs(level - choice['level']) >= 2 or (f == frame and level != choice['level']):
                    stream.ym(f, index, 0x48, level)
                    stream.ym(f, index, 0x4c, level)
                    choice['level'] = level
                if f == frame:
                    key(stream, frame, index, True)
            choice['pending'] = off_frame
        else:
            stats['psg'] += 1
            p = index - FM_CHANNELS
            choice['freq'] = choice['level'] = None
            for f, pitch, volume in steps:
                period = psg_period(f0 * pitch / 4096)
                if period != choice['freq']:
                    stream.at(f).extend([0x04, 0x80 | p << 5 | (period & 15), 0x04, period >> 4])
                    choice['freq'] = period
                level = psg_level(volume)
                if level != choice['level']:
                    stream.at(f).extend([0x04, 0x90 | p << 5 | level])
                    choice['level'] = level
            choice['pending'] = off_frame
    for place in places:
        release(place, length - 1)
    silence(stream, length - 1)
    return stream.encode(length, loop_frame), stats


def z80_driver():
    """Plays PCM through the DAC. Mailbox at 0x1F00: flag, Z80 bank (2), address in the
    bank window (2), length (3). The 68000 writes the fields, then the flag."""
    code = bytearray()
    labels, fixups = {}, []

    def emit(*b):
        code.extend(b)

    def label(name):
        labels[name] = len(code)

    def jr(opcode, name):
        fixups.append((len(code) + 1, name, True))
        emit(opcode, 0)

    def jp(opcode, name):
        fixups.append((len(code) + 1, name, False))
        emit(opcode, 0, 0)

    emit(0xf3, 0x31, 0x00, 0x1f)
    label('main')
    emit(0x3a, 0x00, 0x1f, 0xb7)
    jr(0x28, 'main')
    label('start')
    emit(0xaf, 0x32, 0x00, 0x1f)
    emit(0x3e, 0x2a, 0x32, 0x00, 0x40)
    emit(0x2a, 0x03, 0x1f)
    emit(0xed, 0x5b, 0x05, 0x1f)
    emit(0x3a, 0x07, 0x1f, 0x4f)
    jp(0xcd, 'setbank')
    label('loop')
    emit(0x7e, 0x32, 0x01, 0x40, 0x23, 0x7c, 0xb7)
    jr(0x20, 'nowrap')
    emit(0x26, 0x80, 0xe5, 0x2a, 0x01, 0x1f, 0x23, 0x22, 0x01, 0x1f, 0xe1)
    jp(0xcd, 'setbank')
    label('nowrap')
    emit(0x1b, 0x7a, 0xb3)
    jr(0x20, 'cont')
    emit(0x79, 0xb7)
    jr(0x28, 'done')
    emit(0x0d)
    label('cont')
    emit(0x3a, 0x00, 0x1f, 0xb7)
    jr(0x20, 'start')
    emit(0x06, DAC_DELAY)
    label('delay')
    jr(0x10, 'delay')
    jr(0x18, 'loop')
    label('done')
    emit(0x3e, 0x80, 0x32, 0x01, 0x40)
    jr(0x18, 'main')
    label('setbank')
    emit(0xe5, 0x21, 0x00, 0x60, 0x3a, 0x01, 0x1f, 0x06, 0x08)
    label('bit')
    emit(0x77, 0x0f)
    jr(0x10, 'bit')
    emit(0x3a, 0x02, 0x1f, 0x77, 0xe1, 0xc9)
    for at, name, relative in fixups:
        if relative:
            code[at] = (labels[name] - (at + 1)) & 0xff
        else:
            code[at:at + 2] = struct.pack('<H', labels[name])
    return bytes(code)


class Packer:
    """Places blobs in 512 KB banks from `first_bank` on; no blob crosses a bank."""

    def __init__(self, first_bank):
        self.first, self.banks = first_bank, [bytearray()]

    def add(self, blob):
        assert len(blob) <= BANK
        if len(self.banks[-1]) + len(blob) > BANK:
            self.banks.append(bytearray())
        offset = len(self.banks[-1])
        self.banks[-1].extend(blob)
        return self.first + len(self.banks) - 1, offset

    def image(self):
        return b''.join(bytes(b) + b'\xff' * (BANK - len(b)) for b in self.banks)


def convert(sound_rom, sample_rom, cache, first_bank, pcm_region=0x280000, only=None, log=print):
    """Returns (table, image): the command and PCM table for the fixed part of the ROM and the
    banks that hold streams and PCM, to be placed from ROM bank `first_bank`."""
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    board = qsound.Board(sound_rom, cache)
    digest = hashlib.sha1(sound_rom + (HERE / 'qsound_board.c').read_bytes() +
                          (HERE / 'qsound.py').read_bytes() + bytes([TUNE_SECONDS >> 4])).hexdigest()[:16]
    notes_file = cache / f'notes_{digest}.pickle'
    commands = [c for c in list(qsound.TUNES) + list(qsound.EFFECTS) + list(qsound.ALIASES) if only is None or c in only]
    if notes_file.exists() and only is None:
        played = pickle.loads(notes_file.read_bytes())
    else:
        def play(command):
            seconds = TUNE_SECONDS if command in qsound.TUNES else EFFECT_SECONDS
            found = qsound.notes(board.play(command, seconds), seconds)
            return command, [(n.at, n.voice, n.sample, n.end, n.loop, n.frames, n.off) for n in found]
        with ThreadPoolExecutor(8) as pool:
            played = dict(pool.map(play, commands))
        if only is None:
            notes_file.write_bytes(pickle.dumps(played))

    def rebuild(rows):
        out = []
        for at, voice, sample, end, loop, frames, off in rows:
            note = qsound.Note(at, voice, sample, end, loop)
            note.frames, note.off = frames, off
            out.append(note)
        return out

    samples = Samples(sample_rom)
    packer = Packer(first_bank)
    pcm_entries, pcm_keys, effect_entries = [], {}, {}

    def entry(kind, bank, offset, length=0, frames=0):
        if kind == 2:
            address = pcm_region + offset
            return struct.pack('>BB', kind, bank) + struct.pack('<HHHB', address >> 15, 0x8000 | (address & 0x7fff),
                                                                length & 0xffff, length >> 16) + b'\0' + struct.pack('>H', frames)
        return struct.pack('>BBHI', kind, bank, 0, offset) + bytes(4)

    def pcm_index(note, limit):
        k = (note.sample, note.end, note.loop, note.pitch, min(note.volume, LOUD) >> 9, limit)
        if k not in pcm_keys:
            if len(pcm_entries) >= 255:
                return 0
            blob = samples.pcm(note, limit)
            bank, offset = packer.add(blob)
            pcm_keys[k] = len(pcm_entries)
            pcm_entries.append(entry(2, bank, offset, len(blob) | 1, int(len(blob) / DAC_RATE * 60) + 1))
        return pcm_keys[k]

    table = [bytes(12)] * 256
    totals = dict(tunes=0, looped=0, effects=0, stream_bytes=0, notes=0, fm=0, psg=0, drums=0, stolen=0, dropped=0)
    for command in commands:
        notes = rebuild(played.get(command, []))
        if not notes:
            continue
        if command in qsound.TUNES:
            stream, stats = convert_tune(notes, samples, TUNE_SECONDS, pcm_index)
            bank, offset = packer.add(stream)
            table[command] = entry(1, bank, offset)
            totals['tunes'] += 1
            totals['looped'] += stats['loop'] is not None
            totals['stream_bytes'] += len(stream)
            for k in ('notes', 'fm', 'psg', 'drums', 'stolen', 'dropped'):
                totals[k] += stats[k]
            where = f"repeats from {stats['loop'][0]:.1f} s every {stats['loop'][1]:.1f} s" if stats['loop'] else f"ends at {stats['seconds']:.1f} s"
            log(f"tune {command:02x}: {where}, {stats['notes']} notes ({stats['fm']} FM, {stats['psg']} PSG, "
                f"{stats['drums']} PCM, {stats['stolen']} took a sounding place, {stats['dropped']} silent), {len(stream)} bytes")
        else:
            first = min(notes, key=lambda n: n.at)
            k = (first.sample, first.end, first.loop, first.pitch, first.volume)
            if k not in effect_entries:
                blob = samples.pcm(first, PCM_MAX_SECONDS)
                bank, offset = packer.add(blob)
                effect_entries[k] = entry(2, bank, offset, len(blob) | 1, int(len(blob) / DAC_RATE * 60) + 1)
            table[command] = effect_entries[k]
            totals['effects'] += 1
    image = packer.image()
    pcm_bytes = len(image) - (BANK - len(packer.banks[-1])) - totals['stream_bytes']
    log(f"sound: {totals['tunes']} tunes ({totals['looped']} repeat) in {totals['stream_bytes']} bytes; "
        f"{totals['notes']} notes: {totals['fm']} FM, {totals['psg']} PSG, {totals['drums']} PCM, "
        f"{totals['stolen']} took a sounding place; {totals['effects']} effects and {len(pcm_entries)} drum sounds, "
        f"{pcm_bytes} bytes of PCM at {DAC_RATE:.0f} Hz; {len(packer.banks)} banks")
    driver = z80_driver()
    fixed = b''.join(table) + b''.join(pcm_entries) + bytes(12) * (256 - len(pcm_entries)) + struct.pack('>H', len(driver)) + driver
    return fixed, image


HERE = Path(__file__).resolve().parent

if __name__ == '__main__':
    chosen = {int(c, 16) for c in sys.argv[4:]} or None
    fixed, image = convert(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes(), sys.argv[3], 12, only=chosen)
    print(f'fixed part {len(fixed)} bytes, banks {len(image)} bytes')
