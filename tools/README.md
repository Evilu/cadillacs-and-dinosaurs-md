# Analysis tools

Scripts used for the findings in [`docs/`](../docs). They work on ROM sets you supply; nothing here contains game data. Output goes to `analysis/`, which git ignores.

Requirements: Python 3, MAME (0.289 tested, `brew install mame`), Ghidra 12 with a Java 21 runtime, and Pillow for rendering.

## 1. Prepare images

Extract each set into its own folder under `analysis/roms/` (`dino/`, `ffight/`, `ffmd/`), then:

```sh
python3 tools/prep_roms.py analysis/roms analysis/work
```

This writes flat, byte-swapped 68000 program images (`dino_prg.bin`, `ffight_prg.bin`), interleaved graphics ROM images, and a copy of the Mega Drive ROM (`ffmd.bin`).

## 2. Decompile with Ghidra

```sh
tools/ghidra/analyze.sh <ghidra dir> analysis/work/dino_prg.bin   cps1 ffff8000 analysis
tools/ghidra/analyze.sh <ghidra dir> analysis/work/ffight_prg.bin cps1 ffff8000 analysis
tools/ghidra/analyze.sh <ghidra dir> analysis/work/ffmd.bin       md   -        analysis
tools/ghidra/reanalyze.sh <ghidra dir> dino_prg   analysis
tools/ghidra/reanalyze.sh <ghidra dir> ffight_prg analysis
```

| Script | Does |
|---|---|
| `ghidra/Seed68k.java` | Pre-analysis: names memory regions for the machine (`cps1` or `md`), creates functions at the vector table's targets, sets `A5` for the arcade programs |
| `ghidra/SeedCalls.java` | Second pass for the arcade programs: disassembles at absolute `JSR`/`JMP` targets and at `LEA`/`PEA` targets that look like code (task entry points), which the first pass cannot reach |
| `ghidra/ExportC.java` | Writes `functions.tsv` and `decomp.c` to `analysis/out/<image>/` |

Set `JAVA_HOME` to the Java 21 runtime first.

## 3. Trace in MAME

```sh
cd analysis/mame
TRACE_OUT=ff_run TRACE_FRAMES=21600 TRACE_SNAP_EVERY=600 LAYER_CTRL=2e LAYER_MASKS=02,04,08 IDLE_FLAG=ff1100 \
  mame ffight -rompath <rom folder> -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -snapshot_directory ff_run -autoboot_script ../../tools/mame/cps1_trace.lua
TRACE_OUT=ffmd_run TRACE_FRAMES=21600 TRACE_SNAP_EVERY=300 \
  mame genesis -cart ../work/ffmd.bin -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -snapshot_directory ffmd_run -autoboot_script ../../tools/mame/md_trace.lua
```

| Script | Does |
|---|---|
| `mame/cps1_trace.lua` | Per frame: sprite list, visible tilemap cells, palettes in use, and the graphics working set in Mega Drive 8×8 patterns (blank cells skipped, checked against the graphics ROM), plus a VRAM-sized cache model. Plays the game by script. `LAYER_CTRL` and `LAYER_MASKS` are the CPS-B layer-control offset and enable masks from MAME's `cps1_v.cpp` (`dino`: `0a`, `16,16,16`). `IDLE_FLAG` is the frame flag the game's scheduler polls once per task slot (`ffight`: `ff1100`, `dino`: `ff0152`); reads per frame give the time the CPU spent waiting |
| `mame/cps1_scroll1.lua` | Scroll 1 (text layer) probe for `dino`: per frame its scroll position, visible and changed cells, patterns, palettes and the colours drawn (pens used); over the run, how often each of the 48 × 28 screen cells shows a pattern, and for the HUD band (`BAND_ROWS`, default 5) the distinct pattern and palette pairs per frame and every attribute word. `GRID_EVERY=n` writes the screen's tile codes every n frames. Same play script as `cps1_trace.lua` |
| `mame/md_trace.lua` | Decodes every 68000 write to the VDP: DMA size, target and source, fills, copies, CRAM and register writes, writes during active display. Keeps its own VRAM and CRAM copies (MAME does not expose the real VRAM to Lua), walks the sprite table each frame, and dumps VRAM, CRAM and registers at snapshot frames. Plays the game by script |

`dino` also needs MAME's QSound DSP ROM set (`qsound.zip`, containing `dl-1425.bin`) on the ROM path. For `dino`, summarise with `--broad --clock 12e6 --poll-cycles 97.5`.

## 4. Summarise

```sh
python3 tools/analysis/summarise_traces.py --cps1 analysis/mame/ff_run/cps1_frames.csv --md analysis/mame/ffmd_run/md_frames.csv
python3 tools/analysis/md_vdp_dump.py analysis/mame/ffmd_run/vdp_019200.bin --render analysis/out/layers
```

`summarise_traces.py` prints per-metric distributions for gameplay frames and the arcade CPU load (`--clock 12e6` for `dino`); `md_vdp_dump.py` prints the VRAM layout and which patterns, palette lines and priority bits each plane and the sprites use, and can render each layer to PNG.

## 5. Profile the arcade CPU

```sh
TRACE_OUT=dino_prof TRACE_FRAMES=21600 TASK_PTR=ff0158 TASK_BASE=ff0052 \
  IDLE=83c-8a2 KERNEL=8a2-a40 SPIN_SLOT=15 SPIN=9e38c-9e41c \
  mame dino -rompath <rom folders> -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -autoboot_script ../../tools/mame/cps1_profile.lua
python3 tools/analysis/profile_report.py analysis/mame/dino_prof analysis/out/dino_prg/functions.tsv
```

`mame/cps1_profile.lua` samples the program counter about 200 times a frame, with the current task slot and a heuristic call stack, and writes per-frame work counts (`profile_frames.csv`) and per-address totals. `PROFILE_FRAMES` limits the per-address totals to listed frames. For `ffight`: `TASK_PTR=ff1106 TASK_BASE=ff1000 ROM_SIZE=100000 IDLE=752-7cc KERNEL=7cc-984 SPIN_SLOT=11 SPIN=4a8e-4b32`.

The `idle_reads` column of `cps1_trace.lua` and the CPU-load lines of `summarise_traces.py` are an older estimate that counts the polling task as work; use the profiler's figures.

## 6. Check a Mega Drive ROM

```sh
tools/check_md.sh <rom.bin> <out dir> [frames] [snapshot every N frames]
```

Runs the ROM headless in MAME's `genesis` driver (through `tools/run_md.sh`, which enables the mapper) with no input and reports whether the CPU is running, plus picture width, sprites, colours, the largest per-frame DMA and sprite-limit overflow. Snapshots and VDP dumps land in the output folder, with `md_vram_free.txt` listing the VRAM patterns never written after `WATCH_FROM` (default frame 300). `RAM_WATCH=ff1cb0-ff1fff` adds the lowest address written in that range (the hardware layer's stack depth); `HOLD_HEALTH=1` keeps player 1 alive to reach later scenes. BlastEm (`brew install blastem`) is the choice for hands-on testing; it needs a window.

## 7. Map hardware accesses and RAM use

```sh
TRACE_OUT=dino_access TRACE_FRAMES=21600 RAM_FROM_FRAME=300 \
  mame dino -rompath <rom folders> -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 400 -autoboot_script ../../tools/mame/cps1_access.lua
```

Writes `access_pcs.csv` (every instruction that read or wrote arcade I/O, GFX RAM or the sound and EEPROM ports, with counts and address range) and `ram_written.bin` (which work RAM bytes were written).

## 8. Build and probe the Mega Drive ROM

```sh
analysis/venv/bin/python3 -I build_md.py dino.zip test/roms/md/cadillacs_md.md
TRACE_FRAMES=3600 STATE_EVERY=300 PRESS="700:A,800:Start,1000:B,1600:Right" \
  mame genesis -cart test/roms/md/cadillacs_md.md -video none -sound none -skip_gameinfo -nothrottle \
  -seconds_to_run 90 -autoboot_script tools/mame/md_state.lua
```

`build.py` needs `capstone` and the `m68k-elf` binutils. `md_state.lua` prints the arcade kernel's task slots, the shadow video registers and player state while pressing pad buttons at the given frames.

