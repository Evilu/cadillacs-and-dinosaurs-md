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
| `mame/md_trace.lua` | Decodes every 68000 write to the VDP: DMA size, target and source, fills, copies, CRAM and register writes, writes during active display. Keeps its own VRAM and CRAM copies (MAME does not expose the real VRAM to Lua), walks the sprite table each frame, and dumps VRAM, CRAM and registers at snapshot frames. Plays the game by script |

`dino` also needs MAME's QSound DSP ROM set (`qsound.zip`) in the ROM folder.

## 4. Summarise

```sh
python3 tools/analysis/summarise_traces.py --cps1 analysis/mame/ff_run/cps1_frames.csv --md analysis/mame/ffmd_run/md_frames.csv
python3 tools/analysis/md_vdp_dump.py analysis/mame/ffmd_run/vdp_019200.bin --render analysis/out/layers
```

`summarise_traces.py` prints per-metric distributions for gameplay frames and the arcade CPU load (`--clock 12e6` for `dino`); `md_vdp_dump.py` prints the VRAM layout and which patterns, palette lines and priority bits each plane and the sprites use, and can render each layer to PNG.
