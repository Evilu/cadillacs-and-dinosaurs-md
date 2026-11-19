---
name: level-states
description: Start the arcade game (dino) or the Mega Drive build in any stage, make and load MAME save states for each stage, and compare the two machines stage by stage in MAME and ares. Use when asked to test, compare or debug a stage other than stage 1, to make save states, or to check a stage in ares.
---

# Stage save states

`docs/05-save-states.md` explains how this works; `docs/06-levels-arcade-vs-md.md` is the list of faults found with it. Run from the repository root. Everything is written under `analysis/`, which git ignores: save states hold the game's program and are never committed.

## The handles

| Address | Meaning |
|---|---|
| `0xFF84D9` | Stage, 0 to 7. Held from power-on until play begins, the game starts in that stage |
| `0xFF8786` | Area inside the stage, 0 to 3. Forcing it loads no scenery: do not |
| `0xFF84D0` | Main loop mode; 12 in play |
| `0xFF84CC` | 1 in a game, `0xFF` in the attract demo |
| `0xFF8000` | Game step counter (word), 60 a second on the arcade |
| `0xFFB2E0` | Player 1's health (word); 100 is full. Held every frame it keeps the player alive |

Stages: 0 city rooftop, 1 jungle, 2 desert, 3 yard at night, 4 plain, 5 wooden town, 6 flooded city, 7 laboratory. The same addresses work on the Mega Drive build: it runs the same program on the same work RAM.

## Make the states

```sh
tools/level_states.sh test/roms/md/cadillacs_md.md            # all eight stages, both machines
tools/level_states.sh test/roms/md/cadillacs_md.md "3 4"      # some
```

Writes `analysis/mame/states/dino/stage<N>.sta` and `analysis/mame/states/genesis/stage<N>.sta`, taken 60 frames after play begins. **Remake the Mega Drive states after every build**: a state holds the hardware layer's RAM and VRAM, and the ROM under it has changed.

## Run one stage

```sh
LOAD=stage3 TRACE_FRAMES=3600 HOLD="ffb2e0=0064" tools/level.sh arcade analysis/mame/level_runs/a3
LOAD=stage3 TRACE_FRAMES=3600 HOLD="ffb2e0=0064" tools/level.sh test/roms/md/cadillacs_md.md analysis/mame/level_runs/m3
```

`tools/mame/level.lua` reads its settings from the environment:

- `LEVEL=n` starts a game in stage n instead of loading a state.
- `LOAD=name`, `SAVE=name@frame[,name@+frames]`: states by name; `+` counts from the frame play begins. Save deeper states (a boss, a screen with a fault) from a run that reached them.
- `HOLD="addr=value"` every frame and `POKE="addr=value@frame"` once; two hex digits write a byte, four a word.
- `PLAY=none`, `SNAP_EVERY`, `DUMP_RAM=1`, `STOP_AFTER=n` (frames after play begins).
- Output: snapshots, `level.csv` (stage, area, mode, steps, player state, PC) and `mame.log`.

## Compare all stages

```sh
tools/compare_levels.sh test/roms/md/cadillacs_md.md 3600 > analysis/out/levels/compare.txt
```

One sheet per stage in `analysis/out/levels/stage<N>.png`, arcade above the Mega Drive, and the two `level.csv` files side by side. Read the sheets. The machines drift apart within seconds: compare what is drawn and how fast the step counter runs, not positions.

## When the game stops

A step counter that stops while the PC keeps changing is a task waiting, not a crash. Save a state there (`SAVE=hang@frame`), read the task slots at `0xFF0052` (16 bytes each; the long at offset 8 is the task's saved stack pointer) and the stack above 60 bytes of saved registers: the return addresses name the routine that waits. That is how the second anti-tamper check was found.

## In ares

ares takes no scripted input and cannot load MAME's states. Build a ROM that starts by itself in a stage:

```sh
analysis/venv/bin/python3 -I build_md.py dino.zip test/roms/md/cadillacs_md_stage3.md --stage 3
tools/check_ares.sh test/roms/md/cadillacs_md_stage3.md analysis/mame/ares_stage3 12 4
```

The ROM presses coin, start and attack itself and forces the stage; the stage appears about 25 seconds in. Nobody holds the pad, so the player stands still. Never hand a `--stage` ROM out as the game.

If every capture is black with no frame rate in ares's status bar, run a ROM known to work (Final Fight MD) the same way before blaming the build: ares draws nothing when the Mac's screen is asleep or locked, and has been black with its window behind others. Ask the user for a few minutes with the screen awake. Do not use `osascript` to bring ares forward: it hung waiting for a permission prompt.

## Limits

- Scripted play is blind. A sheet shows the first screens of a stage unless a deeper state was saved.
- No boss has been reached, and no area after a stage's first except stage 0's second.
- A loaded state carries the machine's clock: `-seconds_to_run` shorter than the state's age ends the run at once with no output. `level.sh` allows for it; a hand-written MAME command must too.
- A state made by one MAME version may not load in another.
