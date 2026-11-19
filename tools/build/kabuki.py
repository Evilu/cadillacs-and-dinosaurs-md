"""Capcom's Kabuki Z80 encryption, as MAME's kabuki.cpp decodes it. The first 32 KB of a
QSound sound program is encrypted, with opcodes and data decoded differently."""

DINO_KEYS = (0x76543210, 0x24601357, 0x4343, 0x43)


def _swap_pairs(src, key, select, order):
    for pair, shift in zip(range(4), order):
        if select & (1 << ((key >> shift) & 7)):
            lo, hi = 1 << (2 * pair), 2 << (2 * pair)
            src = (src & ~(lo | hi)) | ((src & lo) << 1) | ((src & hi) >> 1)
    return src


def _rol(src):
    return ((src & 0x7f) << 1) | (src >> 7)


def _byte(src, key1, key2, xor_key, select):
    src = _swap_pairs(src, key1 & 0xffff, select & 0xff, (0, 4, 8, 12))
    src = _rol(src)
    src = _swap_pairs(src, key1 >> 16, select & 0xff, (12, 8, 4, 0))
    src ^= xor_key
    src = _rol(src)
    src = _swap_pairs(src, key2 & 0xffff, select >> 8, (12, 8, 4, 0))
    src = _rol(src)
    return _swap_pairs(src, key2 >> 16, select >> 8, (0, 4, 8, 12))


def decode(rom, keys=DINO_KEYS, length=0x8000):
    """Returns (opcodes, data) for the first `length` bytes of the sound program."""
    key1, key2, addr_key, xor_key = keys
    opcodes, data = bytearray(length), bytearray(length)
    for a in range(length):
        opcodes[a] = _byte(rom[a], key1, key2, xor_key, (a + addr_key) & 0xffff)
        data[a] = _byte(rom[a], key1, key2, xor_key, ((a ^ 0x1fc0) + addr_key + 1) & 0xffff)
    return bytes(opcodes), bytes(data)
