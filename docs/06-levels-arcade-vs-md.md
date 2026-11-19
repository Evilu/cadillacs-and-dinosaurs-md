# The stages, arcade against the Mega Drive build

Each stage was loaded from its save state on both machines (`docs/05-save-states.md`) and played for 3,600 frames by the same blind script with player 1's health held at 100. `tools/compare_levels.sh` wrote one sheet per stage, arcade above the port, a snapshot every 300 frames. This is what the sheets and the state rows show for the build of 2026-11-19 in MAME 0.289.

What this covers: the first minute of each stage's first area, one run each. Stage 0 also reached its second area. No boss, no later area, no second player. The two machines do not play the same game after loading, so positions and enemies differ; only what is drawn and how fast the game runs are compared.

## Game speed

Steps of the game's main loop (the word at `0xFF8000`) per second, between frames 300 and 3,600 of each run:

| Stage | Arcade | Mega Drive |
|---|---|---|
| 0 | 63.0 | 58.7 |
| 1 | 60.0 | 49.2 |
| 2 | 60.0 | 58.1 |
| 3 | 62.8 | 58.1 |
| 4 | 60.0 | 52.4 |
| 5 | 60.0 | 56.9 |
| 6 | 60.0 | 58.5 |
| 7 | 60.0 | 54.4 |

The arcade's figures above 60 are runs where the counter also moved outside the loop's usual pass (stage 0 changed area); that was not looked into. The port is slowest in the jungle, where the tile cache is also over its limit.

## Found and fixed: a second anti-tamper check

In the first comparison the port's step counter stopped in stage 5 at frame 2,340 of the run and never moved again, while the CPU kept running. The picture showed the attract mode's character profiles over black.

The main task (slot 2) was waiting inside `0x9A7E6`, a loop of up to 1,200 frames, called from an enemy's routine at `0x41E60`:

```
jsr     $119c           ; random number
andi.w  #$3f, d0
bne     $41e66
jsr     $2a5b6
bcc     $41e66
jsr     $9a7e6
```

`0x2A5B6` compares 19 words of the VBlank handler at `0x564` with a table (each entry less `0x567`) and returns carry set when they differ. The port patches that handler, so the check fails, and one enemy in 64 runs the profile sequence in the middle of play. There are three copies with different tables and offsets: `0x104F6` (called from `0x18902`, `0x554FC`), `0x2A5B6` (`0x340D8`, `0x41E56`) and `0x5124E` (`0xD87A`, `0x199FA`, `0x3F250`). What the other callers do on failure was not followed (`0x340D8` adds 8 to the word at `0x6602(A5)`).

`build.py` now makes all three return the passing result, beside the three checksum checks patched earlier. After the fix the stage 5 run reaches 3,713 steps against the arcade's 4,043.

## Faults seen, by stage

**Every stage but 0**

- Player 1's portrait and name are missing from the HUD; the health bar and the score are there. Stage 0 shows them. Whether a stage reached by playing shows the same is not known.

**Stage 0, city rooftop.** Matches the arcade apart from the known issues in the README. The second area (the hall with statues) loads.

**Stage 1, jungle**

- Black holes in the playfield: single cells and runs of cells, some for the whole run. This is the tile cache overflow already seen in the attract demo, worse here.
- The far background shows patches of sky blue where the arcade shows forest.
- The first snapshot has a grey band across the trees.

**Stage 2, desert.** Close to the arcade. The sky's gradient is flatter.

**Stage 3, yard at night**

- For about the first 1,200 frames the colours are wrong: the sea is yellow, the ground teal. After the screen has scrolled on they are right.

**Stage 4, plain**

- For about the first 900 frames the sky is brown and the grass tan. Later snapshots are right.

**Stage 5, wooden town**

- The freeze described above (fixed).
- From about frame 3,300 the sky and the house fronts turn olive green in blotches when the scenery changes.

**Stage 6, flooded city**

- The orange sky and skyline are pale beige for the whole run.

**Stage 7, laboratory**

- The tanks and what is in them are paler and browner than on the arcade.

The colour faults in stages 3 to 7 all look like the shared 15-colour background line holding the wrong choice, either from before the stage's palettes were loaded (3, 4) or for want of room (6, 7). That is a reading of the pictures, not a measurement.

## Not confirmed in ares

`tools/check_ares.sh` opened ares v148 with the stage 5 ROM and captured its window ten times: every capture was black with no frame rate in the status bar. Final Fight MD gave the same black captures in the same session, so this says nothing about the build: ares was not drawing (the Mac had been idle for eleven minutes and the ares window was not in front). An earlier build was tried in ares by hand (README); none has been captured by this script. The eight `--stage` ROMs are built and waiting for a session with the screen awake.
