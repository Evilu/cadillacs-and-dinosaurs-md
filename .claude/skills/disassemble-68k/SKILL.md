---
name: disassemble-68k
description: Read, disassemble and decompile the 68000 programs in this project (dino and ffight arcade, Final Fight MD) with the repo's Ghidra and capstone tools. Use when asked what a routine does, where the game touches hardware, to find a routine, or to extend code coverage.
---

# Disassemble the 68000 programs

## Inputs

`python3 -I tools/prep_roms.py analysis/roms analysis/work` builds the flat images: `dino_prg.bin` (1.5 MB), `ffight_prg.bin` (1 MB), `ffmd.bin` (4 MB), and the interleaved graphics images. Arcade program ROMs are byte-swapped on disk; always work from the prepared images.

## Quick look at an address

```sh
analysis/venv/bin/python3 -I tools/analysis/dis68k.py analysis/work/dino_prg.bin 13fa6:60
```

If the listing is nonsense, the address is mid-instruction or in data: try the neighbouring even addresses, or start from a known entry point.

## Ghidra output

`analysis/out/<image>/functions.tsv` (address, size, callers, callees) and `decomp.c`. Regenerate with `tools/ghidra/analyze.sh` then `reanalyze.sh` (see `tools/README.md`); set `JAVA_HOME=/opt/homebrew/opt/openjdk@21`. The three images analyse in parallel in separate projects.

## How the arcade code is laid out

- `A5 = 0xFFFF8000`. A global at `$1234(a5)` is work RAM `0xFF9234`; negative offsets reach `0xFF0000–0xFF7FFF`.
- Game objects are structs addressed through `A6`; state bytes index jump tables (`move.w $20(a6),d0; movea.l table(pc,d0),a1; jmp (a1)`).
- Kernel calls are wrappers around `TRAP`: yield is `jsr $9b6`, sleep `jsr $95a` with frames in `D0`, create task `jsr $8ce` with slot×16 in `D0` and entry in `A0`.
- `jsr $a40` with small constants in `D0/D1` is a debug marker, not game logic.
- Hardware access is by absolute address: `$800100–$80017F` video registers, `$900000–$92FFFF` GFX RAM, `$F18000` sound, `$F1C000` player 3 and EEPROM.

## Coverage is incomplete

Ghidra finds code by following direct calls. Most arcade routines are reached through jump tables and task entry points, so `functions.tsv` covers a fraction of the code. To find more:

1. Use the profiler's addresses (`analysis/mame/*_prof/profile_leaf.csv`, `profile_incl.csv`): they are code that really ran. `profile_incl.csv` keys are call targets; negative keys are indirect call sites.
2. Decode jump tables next to dispatch code and seed their targets (`tools/ghidra/SeedCalls.java` is the place to extend).

Never conclude that a region is data, or that the game never touches some hardware, from Ghidra's function list alone.

## Finding things

- Scan for an absolute address as a 4-byte big-endian value at even offsets to find hardware accesses (data can match by chance; check the instruction).
- For "what runs every frame", start at the game loop `0xE90E` and the VBlank handler `0x542`.
- For "what is slow", use the profile, not intuition.
- Final Fight MD is GCC output on SGDK: arguments on the stack, RAM at `0xE0FF0000`. Its code shares nothing with the arcade.

Disassembly and decompiler output are game code: keep them in `analysis/`, quote only short excerpts in docs.
