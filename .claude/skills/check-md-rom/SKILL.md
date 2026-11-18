---
name: check-md-rom
description: Run a Mega Drive ROM headless and check that it boots, what it draws and how it uses the VDP (DMA per frame, sprites, palettes, VRAM layout). Use after building the port's ROM, when asked whether a build works, or to inspect any Mega Drive ROM such as Final Fight MD.
---

# Check a Mega Drive ROM

## One command

```sh
tools/check_md.sh <rom.bin> <out dir> [frames=600] [snapshot every=120]
```

Runs the ROM in MAME's `genesis` driver with no window and no input, then prints:

- `RESULT: running`, `CPU stuck at one address`, or `CPU appears stuck in an exception handler`
- picture width, visible sprites, colours in CRAM
- the largest per-frame VRAM DMA and the worst sprite-limit overflow

Snapshots (`genesis/*.png`), VDP dumps (`vdp_*.bin`) and the per-frame trace (`md_frames.csv`) are in the output folder. **Look at the snapshots**: "running" only means the CPU is executing, not that the picture is right.

## Inspect the picture

```sh
analysis/venv/bin/python3 -I tools/analysis/md_vdp_dump.py <out dir>/vdp_000600.bin --render <out dir>/layers
```

Prints the VRAM layout and, per plane and for sprites, the cells used, distinct patterns, palette lines and priority bits; renders plane A, plane B, the window and the sprites to separate PNGs.

## With input

`tools/mame/md_trace.lua` presses Start and A through menus and then plays (written for Final Fight MD). Run it directly as in `tools/README.md`, or edit the `press(...)` block for another game. `TRACE_INPUT=none` disables it.

## Budgets to compare against

| | Limit (NTSC, H40) | Final Fight MD in stage 1 |
|---|---|---|
| VRAM DMA per frame | about 7,300 bytes in VBlank | 1,070 mean, 3,560 p95 |
| Sprites per frame | 80 | 23 mean, 46 max |
| Sprite pixels per line | 320 | over in 5% of frames |
| Colours | 61 | 46 |
| CPU cycles per frame | 128,000 | — |

## Limits of this check

- MAME performs DMA instantly and is lenient about VDP timing. A build that works here can still glitch on hardware. BlastEm (`blastem <rom>`) is the accuracy reference, but it needs a window: ask the user before launching it, or ask them to run it.
- MAME's Lua cannot read the real VRAM; the trace rebuilds it from decoded writes. If the ROM writes VRAM in a way the decoder does not handle, the dumps will be wrong while the snapshots are right. Trust the snapshots.
- ROMs over 4 MB need the `SEGA SSF` header string for the mapper to be enabled.
