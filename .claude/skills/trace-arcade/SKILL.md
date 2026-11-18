---
name: trace-arcade
description: Measure what a CPS-1 arcade game (dino, ffight) does per frame in MAME - sprites, tilemaps, palettes, graphics on screen, CPU work and a per-routine profile. Use when asked to trace, measure or profile the arcade game, or to get numbers for a new stage or scene.
---

# Trace and profile the arcade game

Run everything from `analysis/mame`. Output stays under `analysis/`, which git ignores.

## Trace (video load)

```sh
TRACE_OUT=dino_run TRACE_FRAMES=21600 TRACE_SNAP_EVERY=600 LAYER_CTRL=0a LAYER_MASKS=16,16,16 \
  mame dino -rompath "qsound_rom;../.." -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -snapshot_directory dino_run -autoboot_script ../../tools/mame/cps1_trace.lua \
  > dino_run/mame.log 2>&1
python3 -I ../../tools/analysis/summarise_traces.py --cps1 dino_run/cps1_frames.csv --broad
```

- Create the output folder first. 21,600 frames take about 6 minutes; run in the background.
- `ffight` uses `LAYER_CTRL=2e LAYER_MASKS=02,04,08`, `-rompath ../..`, and no `--broad`.
- Check `grep -c "trace error" <dir>/mame.log` is 0 and the CSV has `TRACE_FRAMES + 1` lines.

## Profile (CPU)

```sh
TRACE_OUT=dino_prof TRACE_FRAMES=21600 TASK_PTR=ff0158 TASK_BASE=ff0052 \
  IDLE=83c-8a2 KERNEL=8a2-a40 SPIN_SLOT=15 SPIN=9e38c-9e41c \
  mame dino -rompath "qsound_rom;../.." -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -autoboot_script ../../tools/mame/cps1_profile.lua > dino_prof/mame.log 2>&1
python3 -I ../../tools/analysis/profile_report.py dino_prof ../out/dino_prg/functions.tsv
```

- `profile_frames.csv` has real-work samples per frame for every frame; cycles = `work / samples × clock / 59.637`.
- `PROFILE_FRAMES=<file>` (one frame number per line) limits the per-address totals to those frames, for example steady-play frames picked from `profile_frames.csv` of an earlier run. Without it every frame is included, bursts and menus too.
- `ffight`: `TASK_PTR=ff1106 TASK_BASE=ff1000 ROM_SIZE=100000 IDLE=752-7cc KERNEL=7cc-984 SPIN_SLOT=11 SPIN=4a8e-4b32`.
- `FOCUS_SLOT=n` writes the user-mode addresses one task runs to `profile_slot.csv`; use it to find what a slot is doing.

## Always look at what was played

Build a contact sheet and read it before trusting any statistic:

```sh
../venv/bin/python3 -I ../../tools/analysis/contact_sheet.py dino_run/dino ../out/sheet.png 1
```

The input script is blind. A run that sat on a menu or stood still produces clean-looking but meaningless numbers.

## Traps

- **Polling tasks are not work.** `dino` slot 15 and `ffight` slot 11 loop on yield. The `idle_reads` column and the CPU-load lines of `summarise_traces.py` count them as work and overstate load by about a third. Use the profiler for CPU figures.
- **Per-frame profile figures are noisy.** About 200 samples a frame gives ±7,000 cycles on one frame; quote means and percentiles over many frames.
- **Gameplay filters differ.** The default filter needs sprites and both background layers (right for Final Fight's streets); `--broad` needs sprites and a scroll 2 picture (needed for Cadillacs' interiors) and lets cutscenes in. Say which one a figure used.
- **Bursts.** Frames where the arcade CPU is saturated come in runs at scene changes, dialogue and the continue screen. Report steady play and bursts separately.
- **Pattern counts are for the 384-wide picture** and count only 8×8 cells with visible pixels.
- **Determinism.** The same script gives the same run frame for frame, so a second run can be joined to the first by frame number.
- To reach another stage, extend the input script or load a save state; do not assume stage 1 numbers carry over.
