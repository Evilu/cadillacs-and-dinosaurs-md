# Save states for every stage

Until now every measurement covered attract mode and stage 1: as far as a blind script could walk. This document is how the other seven stages were reached, on the arcade board and on the Mega Drive build, and how to keep them as save states. The method follows the one worked out for the RoboCop port ([Evilu/robocop-md](https://github.com/Evilu/robocop-md), `docs/05-save-states.md` there).

Everything here was measured on MAME 0.289 with the `dino` set and the build of 2026-11-19. Tools: `tools/level.sh`, `tools/level_states.sh`, `tools/compare_levels.sh`, `tools/mame/level.lua`. The skill `level-states` has the commands.

## What a MAME save state is

`manager.machine:save("name")` from Lua writes `<state_directory>/<system>/<name>.sta`: `dino/` for the arcade, `genesis/` for the Mega Drive build (the system's name, not the software-list entry's).

- The file starts with a 32-byte header: the text `MAMESAVE`, a version byte (2), a flags byte and the system's name. The rest is one zlib stream.
- The arcade's stage 4 state is 124 KB on disk and 531 KB inflated; the Mega Drive's is 44 KB and 8.9 MB.
- A state does not hold the ROM. A Mega Drive state is only good for the ROM it was made with: rebuild, and the hardware layer's variables and the VRAM it filled no longer match the code. Remake the states after every build.
- **A state carries the machine's clock.** MAME's `-seconds_to_run` counts emulated time from power-on, so a run that loads a state taken 40 seconds in and asks for 20 seconds ends at once, with no output and exit code 0. `level.sh` adds an hour to the limit and lets the script end the run.

## Where the game keeps the stage

`A5 = 0xFFFF8000`, so the addresses below are `A5` offsets in the program.

| Address | Offset | Meaning |
|---|---|---|
| `0xFF84D9` | `0x4D9` | Stage, 0 to 7. 153 instructions use it |
| `0xFF8786` | `0x786` | Area inside the stage, 0 to 3 |
| `0xFF84D0` | `0x4D0` | Main loop mode: index into the jump table at `0xA958`. 4 through the select screen, 12 in play |
| `0xFF84CC` | `0x4CC` | 1 in a game (set at `0x9D15C`), `0xFF` in the attract demo (`0xA6CFC`), 0 otherwise |
| `0xFF8000` | `0x000` | Word the main loop adds 1 to on every pass (`0xA942`): the game's step counter |
| `0xFFB2E0` | | Player 1's health, a word; 100 is full |

The stage ends in `0xABE8`:

```
addq.b  #1, $4d9(a5)
andi.b  #7, $4d9(a5)
clr.b   $786(a5)
move.b  #8, $4d0(a5)
```

Mode 0 (`0xA978`) holds the game's own stage select: when the word at `0x4AA(A5)` is set (`0xA702` toggles it) and a game is running, it copies the low three bits of `0x22(A5)`, which the VBlank handler loads from DIP switch A (`0x80001A`), into the stage. It was not used: what sets `0x4AA` was not traced.

The stages, by what the arcade shows. The game numbers its episodes from 1 (stage 3 opens with `EPISODE 4`); the other names are descriptions of the pictures.

| Stage | Opening scene |
|---|---|
| 0 | City rooftop by the sea |
| 1 | Jungle |
| 2 | Desert |
| 3 | Yard of tyres and barrels at night |
| 4 | Plain below mountains |
| 5 | Wooden town |
| 6 | Bridge in the flooded city |
| 7 | Laboratory with tanks |

## Starting in any stage

`level.lua` writes the stage to `0xFF84D9` every frame from power-on until play begins (`0xFF84CC` = 1 and mode 12), while it presses coin, start and attack in a 120-frame cycle (coin at 0, start at 60, attack at 90, to leave the select screen). That is all it takes: stages 0 to 7 load this way on both machines. Play begins at frame 461 on the arcade and frame 949 on the Mega Drive build, whose start-up takes longer. The state is saved 60 frames later.

Forcing the area as well does not work. Stage 0 with `0xFF8786` held at 1 starts in the right place on both machines but with a black background, on the arcade too: the scenery is loaded on the way in from the area before.

`0xABE8` has not been tried as a way to clear a stage from Lua.

## The same on the Mega Drive

The port runs the arcade's program, and the arcade's work RAM sits at the same addresses. Every address above works unchanged, and so does the script: only the pad's button names differ. MAME's `genesis` driver saves and loads states for the software-list cartridge `run_md.sh` makes.

ares takes no scripted input and cannot load MAME's states, so for ares the forcing is built into a test ROM: `build_md.py ... --stage N` assembles a few instructions into the pad routine (`BOOT_STAGE` in `src/hal.s`) that press coin, start and attack on the same cycle and write the stage until play begins. Without the option the ROM is byte for byte what it was. In MAME the stage 5 ROM shows its scenery by frame 1,500.

## What a state is good for, and what it is not

- It starts a stage in a second instead of walking there, on both machines from the same point of the game.
- The two machines do not stay together after loading: timing changes what the enemies do, and the port runs fewer game steps a second (see `docs/06-levels-arcade-vs-md.md`). Compare pictures and rates.
- The script plays blind. With health held it walks through the first screens of each stage; the sheets show those. Deeper points need a state saved from a run that reached them (`SAVE=name@frame`), or a person at the pad.
- No boss has been reached in any stage, and no area after the first except stage 0's second.
