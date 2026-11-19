/* The CPS-1 QSound board without its DSP: a Z80 at 8 MHz with a 250 Hz interrupt, banked
   ROM, two RAMs shared with the 68000, and the DSP's three write ports.
   usage: qsound_board <opcodes.bin> <data.bin> <rom.bin> <seconds> < writes > log
   opcodes/data: the first 32 KB of the sound program decoded by kabuki.py; rom: the whole file.
   stdin: "<seconds> <offset hex> <value hex>" lines, in time order: bytes the 68000 writes
          to the shared RAM at 0xF18000 (offset = Z80 address - 0xC000).
   stdout: "<seconds> <register hex> <data hex>" for every DSP register write. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;

static u8 opc[0x8000], dat[0x8000], rom[0x40000], ram1[0x1000], ram2[0x1000];
static int bank;
static u8 dsp_hi, dsp_lo;
static long long cycles;

static u8 A, F, B, C, D, E, H, L, A2, F2, B2, C2, D2, E2, H2, L2, I, R, iff1, iff2, im, halted;
static u16 PC, SP, IX, IY;

enum { FC = 1, FN = 2, FP = 4, FH = 16, FZ = 64, FS = 128 };

static u8 rd(u16 a) {
    if (a < 0x8000) return dat[a];
    if (a < 0xc000) return rom[0x8000 + bank * 0x4000 + (a - 0x8000)];
    if (a < 0xd000) return ram1[a - 0xc000];
    if (a == 0xd007) return 0x80;
    if (a >= 0xf000) return ram2[a - 0xf000];
    return 0xff;
}
static void wr(u16 a, u8 v) {
    if (a >= 0xc000 && a < 0xd000) ram1[a - 0xc000] = v;
    else if (a >= 0xf000) ram2[a - 0xf000] = v;
    else if (a == 0xd000) dsp_hi = v;
    else if (a == 0xd001) dsp_lo = v;
    else if (a == 0xd002) printf("%.6f %02x %04x\n", cycles / 8000000.0, v, dsp_hi << 8 | dsp_lo);
    else if (a == 0xd003) bank = v & 15;
}
static u8 op(void) { u16 a = PC++; R++; return a < 0x8000 ? opc[a] : rd(a); }
static u8 arg(void) { return rd(PC++); }
static u16 arg16(void) { u16 l = arg(); return l | arg() << 8; }
static u16 rd16(u16 a) { return rd(a) | rd(a + 1) << 8; }
static void wr16(u16 a, u16 v) { wr(a, v); wr(a + 1, v >> 8); }
static void push(u16 v) { SP -= 2; wr16(SP, v); }
static u16 pop(void) { u16 v = rd16(SP); SP += 2; return v; }

#define BC (B << 8 | C)
#define DE (D << 8 | E)
#define HL (H << 8 | L)
static void setBC(u16 v) { B = v >> 8; C = v; }
static void setDE(u16 v) { D = v >> 8; E = v; }
static void setHL(u16 v) { H = v >> 8; L = v; }

static int parity(u8 v) { v ^= v >> 4; v ^= v >> 2; v ^= v >> 1; return !(v & 1); }
static u8 szp(u8 v) { return (v & FS) | (v ? 0 : FZ) | (parity(v) ? FP : 0); }

static void add8(u8 v, int c) {
    int r = A + v + c;
    F = (r & FS) | ((r & 0xff) ? 0 : FZ) | ((A ^ v ^ r) & FH) | ((~(A ^ v) & (A ^ r) & 0x80) ? FP : 0) | (r > 0xff ? FC : 0);
    A = r;
}
static u8 sub8(u8 v, int c) {
    int r = A - v - c;
    F = (r & FS) | ((r & 0xff) ? 0 : FZ) | ((A ^ v ^ r) & FH) | (((A ^ v) & (A ^ r) & 0x80) ? FP : 0) | FN | (r < 0 ? FC : 0);
    return r;
}
static void alu(int y, u8 v) {
    switch (y) {
    case 0: add8(v, 0); break;
    case 1: add8(v, F & FC); break;
    case 2: A = sub8(v, 0); break;
    case 3: A = sub8(v, F & FC); break;
    case 4: A &= v; F = szp(A) | FH; break;
    case 5: A ^= v; F = szp(A); break;
    case 6: A |= v; F = szp(A); break;
    case 7: sub8(v, 0); break;
    }
}
static u8 inc8(u8 v) { v++; F = (F & FC) | (v & FS) | (v ? 0 : FZ) | ((v & 15) ? 0 : FH) | (v == 0x80 ? FP : 0); return v; }
static u8 dec8(u8 v) { v--; F = (F & FC) | (v & FS) | (v ? 0 : FZ) | ((v & 15) == 15 ? FH : 0) | (v == 0x7f ? FP : 0) | FN; return v; }
static u16 add16(u16 a, u16 b) {
    int r = a + b;
    F = (F & (FS | FZ | FP)) | (((a ^ b ^ r) >> 8) & FH) | (r > 0xffff ? FC : 0);
    return r;
}
static u16 adc16(u16 a, u16 b) {
    int r = a + b + (F & FC);
    F = ((r >> 8) & FS) | ((r & 0xffff) ? 0 : FZ) | (((a ^ b ^ r) >> 8) & FH) | ((~(a ^ b) & (a ^ r) & 0x8000) ? FP : 0) | (r > 0xffff ? FC : 0);
    return r;
}
static u16 sbc16(u16 a, u16 b) {
    int r = a - b - (F & FC);
    F = ((r >> 8) & FS) | ((r & 0xffff) ? 0 : FZ) | (((a ^ b ^ r) >> 8) & FH) | (((a ^ b) & (a ^ r) & 0x8000) ? FP : 0) | FN | (r < 0 ? FC : 0);
    return r;
}
static u8 rot(int y, u8 v) {
    int c = F & FC, o;
    switch (y) {
    case 0: o = v >> 7; v = v << 1 | o; break;
    case 1: o = v & 1; v = v >> 1 | o << 7; break;
    case 2: o = v >> 7; v = v << 1 | c; break;
    case 3: o = v & 1; v = v >> 1 | c << 7; break;
    case 4: o = v >> 7; v <<= 1; break;
    case 5: o = v & 1; v = (v & 0x80) | v >> 1; break;
    case 6: o = v >> 7; v = v << 1 | 1; break;
    default: o = v & 1; v >>= 1; break;
    }
    F = szp(v) | o;
    return v;
}
static int cond(int y) {
    static const u8 mask[4] = { FZ, FC, FP, FS };
    int set = (F & mask[y >> 1]) != 0;
    return (y & 1) ? set : !set;
}

/* idx: 0 = HL, 1 = IX, 2 = IY */
static u16 *ixy(int idx) { return idx == 1 ? &IX : &IY; }
static u8 getr(int r, int idx) {
    switch (r) {
    case 0: return B; case 1: return C; case 2: return D; case 3: return E;
    case 4: return idx ? *ixy(idx) >> 8 : H;
    case 5: return idx ? *ixy(idx) & 0xff : L;
    default: return A;
    }
}
static void setr(int r, int idx, u8 v) {
    switch (r) {
    case 0: B = v; break; case 1: C = v; break; case 2: D = v; break; case 3: E = v; break;
    case 4: if (idx) *ixy(idx) = (*ixy(idx) & 0xff) | v << 8; else H = v; break;
    case 5: if (idx) *ixy(idx) = (*ixy(idx) & 0xff00) | v; else L = v; break;
    default: A = v; break;
    }
}
static u16 gethl(int idx) { return idx ? *ixy(idx) : HL; }
static void sethl(int idx, u16 v) { if (idx) *ixy(idx) = v; else setHL(v); }
static u16 memhl(int idx) { return idx ? (u16)(*ixy(idx) + (int8_t)arg()) : HL; }
static u16 getrp(int p, int idx) { return p == 0 ? BC : p == 1 ? DE : p == 2 ? gethl(idx) : SP; }
static void setrp(int p, int idx, u16 v) {
    if (p == 0) setBC(v); else if (p == 1) setDE(v); else if (p == 2) sethl(idx, v); else SP = v;
}

static int cb(int idx) {
    u16 a = 0;
    int o, x, y, z;
    u8 v;
    if (idx) { a = *ixy(idx) + (int8_t)arg(); o = arg(); } else o = op();
    x = o >> 6; y = (o >> 3) & 7; z = o & 7;
    v = (idx || z == 6) ? rd(idx ? a : HL) : getr(z, 0);
    if (x == 0) v = rot(y, v);
    else if (x == 1) { F = (F & FC) | FH | ((v & (1 << y)) ? 0 : FZ | FP) | ((y == 7 && (v & 0x80)) ? FS : 0); return idx ? 20 : z == 6 ? 12 : 8; }
    else if (x == 2) v &= ~(1 << y);
    else v |= 1 << y;
    if (idx || z == 6) wr(idx ? a : HL, v);
    if (z != 6) setr(z, 0, v);
    return idx ? 23 : z == 6 ? 15 : 8;
}

static int ed(void) {
    int o = op(), x = o >> 6, y = (o >> 3) & 7, z = o & 7, p = y >> 1, q = y & 1;
    u8 v;
    u16 t;
    if (x == 1) {
        switch (z) {
        case 0: v = 0xff; if (y != 6) setr(y, 0, v); F = (F & FC) | szp(v); return 12;
        case 1: return 12;
        case 2: setHL(q ? adc16(HL, getrp(p, 0)) : sbc16(HL, getrp(p, 0))); return 15;
        case 3: t = arg16(); if (q) setrp(p, 0, rd16(t)); else wr16(t, getrp(p, 0)); return 20;
        case 4: v = A; A = 0; A = sub8(v, 0); return 8;
        case 5: PC = pop(); iff1 = iff2; return 14;
        case 6: im = (y & 3) == 2 ? 1 : (y & 3) == 3 ? 2 : 0; return 8;
        default:
            switch (y) {
            case 0: I = A; return 9;
            case 1: R = A; return 9;
            case 2: A = I; F = (F & FC) | (A & FS) | (A ? 0 : FZ) | (iff2 ? FP : 0); return 9;
            case 3: A = R; F = (F & FC) | (A & FS) | (A ? 0 : FZ) | (iff2 ? FP : 0); return 9;
            case 4: v = rd(HL); wr(HL, v >> 4 | A << 4); A = (A & 0xf0) | (v & 15); F = (F & FC) | szp(A); return 18;
            case 5: v = rd(HL); wr(HL, v << 4 | (A & 15)); A = (A & 0xf0) | v >> 4; F = (F & FC) | szp(A); return 18;
            default: return 8;
            }
        }
    }
    if (x == 2 && z <= 3 && y >= 4) {
        int dir = (y & 1) ? -1 : 1, repeat = y >= 6;
        switch (z) {
        case 0:
            wr(DE, rd(HL)); setHL(HL + dir); setDE(DE + dir); setBC(BC - 1);
            F = (F & (FS | FZ | FC)) | (BC ? FP : 0);
            if (repeat && BC) { PC -= 2; return 21; }
            return 16;
        case 1: {
            int c = F & FC;
            sub8(rd(HL), 0); setHL(HL + dir); setBC(BC - 1);
            F = (F & ~(FC | FP)) | c | (BC ? FP : 0);
            if (repeat && BC && !(F & FZ)) { PC -= 2; return 21; }
            return 16;
        }
        case 2: wr(HL, 0xff); setHL(HL + dir); B--; F = (B ? 0 : FZ) | FN; if (repeat && B) { PC -= 2; return 21; } return 16;
        default: rd(HL); setHL(HL + dir); B--; F = (B ? 0 : FZ) | FN; if (repeat && B) { PC -= 2; return 21; } return 16;
        }
    }
    return 8;
}

static int step(void) {
    int idx = 0, o, x, y, z, p, q, t;
    u16 a, w;
    u8 v;
    for (;;) {
        o = op();
        if (o == 0xdd) idx = 1; else if (o == 0xfd) idx = 2; else break;
    }
    x = o >> 6; y = (o >> 3) & 7; z = o & 7; p = y >> 1; q = y & 1;
    if (x == 1) {
        if (o == 0x76) { halted = 1; PC--; return 4; }
        if (z == 6) { setr(y, 0, rd(memhl(idx))); return idx ? 19 : 7; }
        if (y == 6) { a = memhl(idx); wr(a, getr(z, 0)); return idx ? 19 : 7; }
        setr(y, idx, getr(z, idx));
        return 4;
    }
    if (x == 2) {
        if (z == 6) { alu(y, rd(memhl(idx))); return idx ? 19 : 7; }
        alu(y, getr(z, idx));
        return 4;
    }
    if (x == 0) {
        switch (z) {
        case 0:
            if (y == 0) return 4;
            if (y == 1) { v = A; A = A2; A2 = v; v = F; F = F2; F2 = v; return 4; }
            if (y == 2) { t = (int8_t)arg(); if (--B) { PC += t; return 13; } return 8; }
            if (y == 3) { t = (int8_t)arg(); PC += t; return 12; }
            t = (int8_t)arg(); if (cond(y - 4)) { PC += t; return 12; } return 7;
        case 1:
            if (q) { sethl(idx, add16(gethl(idx), getrp(p, idx))); return 11; }
            setrp(p, idx, arg16()); return 10;
        case 2:
            switch (y) {
            case 0: wr(BC, A); return 7;
            case 1: A = rd(BC); return 7;
            case 2: wr(DE, A); return 7;
            case 3: A = rd(DE); return 7;
            case 4: wr16(arg16(), gethl(idx)); return 16;
            case 5: sethl(idx, rd16(arg16())); return 16;
            case 6: wr(arg16(), A); return 13;
            default: A = rd(arg16()); return 13;
            }
        case 3: setrp(p, idx, getrp(p, idx) + (q ? -1 : 1)); return 6;
        case 4: if (y == 6) { a = memhl(idx); wr(a, inc8(rd(a))); return 11; } setr(y, idx, inc8(getr(y, idx))); return 4;
        case 5: if (y == 6) { a = memhl(idx); wr(a, dec8(rd(a))); return 11; } setr(y, idx, dec8(getr(y, idx))); return 4;
        case 6: if (y == 6) { a = memhl(idx); wr(a, arg()); return 10; } setr(y, idx, arg()); return 7;
        default:
            switch (y) {
            case 0: t = A >> 7; A = A << 1 | t; F = (F & (FS | FZ | FP)) | t; return 4;
            case 1: t = A & 1; A = A >> 1 | t << 7; F = (F & (FS | FZ | FP)) | t; return 4;
            case 2: t = A >> 7; A = A << 1 | (F & FC); F = (F & (FS | FZ | FP)) | t; return 4;
            case 3: t = A & 1; A = A >> 1 | (F & FC) << 7; F = (F & (FS | FZ | FP)) | t; return 4;
            case 4: {
                int c = F & FC, h = F & FH, n = F & FN, adj = 0;
                if (h || (A & 15) > 9) adj = 6;
                if (c || A > 0x99) { adj |= 0x60; c = 1; }
                v = n ? A - adj : A + adj;
                F = szp(v) | ((A ^ v) & FH) | n | c;
                A = v;
                return 4;
            }
            case 5: A = ~A; F |= FH | FN; return 4;
            case 6: F = (F & (FS | FZ | FP)) | FC; return 4;
            default: F = ((F & (FS | FZ | FP | FC)) | ((F & FC) ? FH : 0)) ^ FC; return 4;
            }
        }
    }
    switch (z) {
    case 0: if (cond(y)) { PC = pop(); return 11; } return 5;
    case 1:
        if (!q) { w = pop(); if (p == 3) { A = w >> 8; F = w; } else setrp(p, idx, w); return 10; }
        if (p == 0) { PC = pop(); return 10; }
        if (p == 1) {
            v = B; B = B2; B2 = v; v = C; C = C2; C2 = v; v = D; D = D2; D2 = v;
            v = E; E = E2; E2 = v; v = H; H = H2; H2 = v; v = L; L = L2; L2 = v;
            return 4;
        }
        if (p == 2) { PC = gethl(idx); return 4; }
        SP = gethl(idx); return 6;
    case 2: a = arg16(); if (cond(y)) PC = a; return 10;
    case 3:
        switch (y) {
        case 0: PC = arg16(); return 10;
        case 1: return cb(idx);
        case 2: arg(); return 11;
        case 3: arg(); A = 0xff; return 11;
        case 4: w = rd16(SP); wr16(SP, gethl(idx)); sethl(idx, w); return 19;
        case 5: w = DE; setDE(HL); setHL(w); return 4;
        case 6: iff1 = iff2 = 0; return 4;
        default: iff1 = iff2 = 2; return 4;
        }
    case 4: a = arg16(); if (cond(y)) { push(PC); PC = a; return 17; } return 10;
    case 5:
        if (!q) { push(p == 3 ? (A << 8 | F) : getrp(p, idx)); return 11; }
        if (p == 0) { a = arg16(); push(PC); PC = a; return 17; }
        if (p == 2) return ed();
        return 4;
    case 6: alu(y, arg()); return 7;
    default: push(PC); PC = y * 8; return 11;
    }
}

static void load(const char *path, u8 *to, size_t size) {
    FILE *f = fopen(path, "rb");
    if (!f || fread(to, 1, size, f) == 0) { fprintf(stderr, "cannot read %s\n", path); exit(1); }
    fclose(f);
}

int main(int argc, char **argv) {
    double seconds, at = -1;
    unsigned offset = 0, value = 0;
    long long end, next_irq = 32000;
    int pending = 0, have;
    if (argc < 5) { fprintf(stderr, "usage: qsound_board opcodes data rom seconds < writes\n"); return 1; }
    load(argv[1], opc, sizeof opc);
    load(argv[2], dat, sizeof dat);
    load(argv[3], rom, sizeof rom);
    seconds = atof(argv[4]);
    end = (long long)(seconds * 8000000.0);
    memset(ram1, 0, sizeof ram1);
    memset(ram2, 0, sizeof ram2);
    have = scanf("%lf %x %x", &at, &offset, &value) == 3;
    while (cycles < end) {
        while (have && at * 8000000.0 <= cycles) {
            ram1[offset & 0xfff] = value;
            have = scanf("%lf %x %x", &at, &offset, &value) == 3;
        }
        if (cycles >= next_irq) { pending = 1; next_irq += 32000; }
        if (iff1 == 2) iff1 = 1;
        else if (pending && iff1) {
            if (halted) PC++;
            pending = 0; halted = 0; iff1 = iff2 = 0;
            push(PC);
            PC = im == 2 ? rd16(I << 8 | 0xff) : 0x38;
            cycles += 13;
            continue;
        }
        if (halted) { cycles = next_irq < end ? next_irq : end; continue; }
        cycles += step();
    }
    return 0;
}
