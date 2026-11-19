# Working on Cadillacs and Dinosaurs MD

A port of Capcom's CPS-1 arcade game *Cadillacs and Dinosaurs* (MAME set `dino`, World 930201) to the Sega Mega Drive. The plan is to run Capcom's original 68000 program on the Mega Drive's 68000 and replace only the hardware layer. Target: as close to the arcade as the console allows, at 60 fps.

Read `docs/` in order before changing anything: 01 hardware comparison, 02 Final Fight arcade vs Final Fight MD, 03 Cadillacs and Dinosaurs measured, 04 the port plan and milestone status, 05 save states for every stage, 06 the stages compared with the arcade.

## Ground rules

- **No game data in the repo.** No ROMs, no extracted graphics or sound, no disassembly or decompiler output, no screenshots of the games. `*.zip`, `*.bin` and `/analysis/` are ignored; keep it that way. The user supplies their own ROMs.
- **Measure, then write.** Every number in `docs/` was computed from a ROM, a trace or a cited source. Re-derive before repeating a figure, say what was not measured, and correct the docs when a measurement turns out wrong.
- **Stage 1 is the only stage measured in depth.** All traces and profiles cover stage 1 under scripted play. The other seven stages have been loaded from save states and looked at (`docs/06`), first minute only. Do not generalise stage 1's numbers to later stages.
- **Extracted archives are untrusted.** Unpack into their own folder under `analysis/roms/`, keep scripts in `tools/`, run Python that reads them with `-I`.
- **Check in MAME while working, and in ares before calling a picture finished.** MAME headless (`-video none`, `tools/check_md.sh`, `tools/level.sh`) is for every iteration and opens nothing on the user's screen. `tools/check_ares.sh` opens ares, captures only its window, closes the ares it started and writes a contact sheet; look at the sheet. Open no other windows unless the user asks, and never kill processes by name.
- Do not write tests or planning documents unless asked. Avoid comments; code should read clearly without them.

## Layout

| Path | Contents |
|---|---|
| `docs/` | Research documents and the port plan |
| `src/hal.s` | The Mega Drive hardware layer: boot, VBlank, sprites, palettes, input (GNU as, Motorola operand syntax, `\|` comments) |
| `src/background.s` | Playfield store, plane B ring, tile cache, and the TRAP #8 instruction emulator |
| `src/hud.s` | Scroll 1 (text layer) HUD drawn with sprites, and the TRAP #13 / #14 fast paths (recolour loop, text printers) |
| `build_md.py` | Builds the Mega Drive ROM from the user's `dino.zip` (calls `tools/build/build.py`) |
| `test/roms/md/` (ignored) | Built ROMs for the user to try |
| `tools/prep_roms.py` | Builds flat program and graphics images from ROM sets |
| `tools/ghidra/` | Headless Ghidra import, seeding and C export |
| `tools/mame/` | Lua scripts: arcade trace, profiler and hardware access map; Mega Drive VDP trace and game-state probe |
| `tools/analysis/` | Trace summaries, profile report, VDP dump renderer, 68000 disassembler |
| `tools/check_md.sh` | One-command headless check of a Mega Drive ROM (`TRACE_INPUT=arcade` plays the port) |
| `tools/run_md.sh` | Runs a ROM in MAME with the Sega mapper enabled |
| `tools/level.sh`, `level_states.sh`, `compare_levels.sh` | Start either machine in any stage, make a save state per stage, compare the stages with the arcade (`tools/mame/level.lua`) |
| `tools/check_ares.sh` | Runs a ROM in ares, captures its window at intervals and makes a contact sheet |
| `analysis/` (ignored) | `roms/`, `work/` images, `ghidra/` projects, `out/` exports, `mame/` runs, `venv/` |

`tools/README.md` has the commands. Skills in `.claude/skills/` cover the recurring jobs: `trace-arcade`, `disassemble-68k`, `check-md-rom`, `level-states`.

## Environment

- ares v148 is at `~/Downloads/ares-v148/ares.app` (`ARES` overrides the binary). It takes no scripted input, so an ares check shows what a ROM does by itself: the attract sequence, or a stage with a `--stage` ROM. **ares draws nothing when the Mac's screen is asleep or locked or its window is behind others**: every capture is black with no frame rate in the status bar, for any ROM. Run Final Fight MD the same way before blaming a build, and ask the user for a few minutes with the screen awake. So far ares has shown only black here; whether it runs the 6 MB ROM is not known.
- MAME 0.289, BlastEm 1.0.0 and `m68k-elf-binutils` from Homebrew. Ghidra needs `JAVA_HOME=/opt/homebrew/opt/openjdk@21`.
- Python helpers that need `capstone` or `Pillow` run from `analysis/venv/bin/python3`.
- MAME needs `qsound.zip` (containing `dl-1425.bin`, CRC `d6cf5ef5`) to run `dino`. A correctly named copy lives in `analysis/mame/qsound_rom/`; pass `-rompath "qsound_rom;../.."` from `analysis/mame`.

## Facts that are easy to get wrong

**The arcade program (`dino`)**

- 68000 at 12 MHz (Final Fight is 10 MHz). Program `0x000000–0x17FFFF`, work RAM `0xFF0000–0xFFFFFF`, GFX RAM `0x900000–0x92FFFF`.
- `A5 = 0xFFFF8000` is the global base everywhere; `A6` is the current object.
- Reset `0x41A`. One interrupt: VBlank, level 2, at `0x542`. It writes nearly all hardware registers, sends one sound command and reads the inputs.
- Cooperative kernel: 16 task slots of 16 bytes at `0xFF0052`, tasks in user mode, services on `TRAP #0`–`#7` and `#12`, scheduler at `0x83C`, current-task pointer at `0xFF0158`, frame flag at `0xFF0152`.
- **Slot 15 (`0x9E38C`) only polls and yields.** It and its kernel calls use about 19% of every arcade frame. Never count it as work; on the Mega Drive it should run once per frame.
- Real work in steady play is about 62,000 cycles per frame (p95 91,000) against the Mega Drive's 128,000. Scene set-up and cutscene bursts saturate the arcade CPU.
- Sprite list builder at `0x13FA6` (per-object writer `0x141F8`) is about a quarter of real work and writes the arcade sprite format: it is the first routine to replace.
- Sprite list is double-buffered at `0x900000` / `0x904000`; scroll 1, 2, 3 tilemaps at `0x908000`, `0x90C000`, `0x910000`; palettes at `0x914000`.
- **The stage is one byte**, `0xFF84D9` (0-7); the area inside it is `0xFF8786` (0-3). Hold the stage from power-on until play begins (`0xFF84CC` = 1 and main loop mode `0xFF84D0` = 12) and the game starts there, on the Mega Drive build as well. Forcing the area loads no scenery. `0xFF8000` is the main loop's step counter.
- **Capcom checks its own code in six places.** Three sum bytes `0x30-0x419`; three (`0x104F6`, `0x2A5B6`, `0x5124E`) compare the VBlank handler at `0x564` with a table. A failed check does nothing until an enemy rolls 1 in 64: stage 5 (the wooden town) then stops for 1,200 frames of character profiles. `build.py` makes all six pass. A stage that goes wrong at random may be a seventh.
- Ghidra's function list covers only part of the code: most routines are reached through jump tables and task entry points. Treat "not in `functions.tsv`" as unknown, not as data.

**The Mega Drive side**

- 128,000 CPU cycles per NTSC frame; about 7.3 KB of DMA per VBlank; 80 sprites, 20 per line, 320 sprite pixels per line; 61 colours.
- Final Fight MD is a from-scratch SGDK rewrite with no arcade code. It is the reference for layer mapping, palettes, sprite cutting and VRAM layout, not for code.
- Its recipe: street on plane B with high priority, far background on plane A with low priority, HUD in the window, one 15-colour palette for the background, static scenery drawn as plane tiles, patterns stored in spare table space, no raster effects.

**The build**

- `--stage n` on the build (`BOOT_STAGE` in `src/hal.s`) makes a test ROM that presses coin and start itself and begins in stage n, for ares. Without it the ROM is unchanged. MAME save states of the Mega Drive build go stale with every rebuild.
- Build with `analysis/venv/bin/python3 -I build_md.py dino.zip test/roms/md/cadillacs_md.md`. It verifies the set by CRC and reads the patch sites from `tools/build/dino_access.csv` (addresses only, from the stage-1 access map; regenerate it from a new trace when the map grows). The output contains Capcom's program and graphics: never commit it. Name ROMs `.md`: emulators pick the system from the extension.
- Hardware accesses with fixed addresses are redirected to shadows at `0xFF1000` (I/O and video registers), `0xFF1200` (sound) and `0xFF1280` (player 3, EEPROM). The game's start-up clears that RAM, so the hardware layer rewrites its inputs every VBlank.
- Stand-in DIP switches must read `0xFF`; a zero in DIP C bit 7 sends the game into test mode.
- **Mapper in MAME.** MAME enables bank switching only for a software-list entry; `tools/run_md.sh` writes one with slot `rom_titan` (Krikzz SSF, 32 banks). The `rom_ssf2` type implements only banks 0–9 and segfaults above. Use byte writes to the bank registers (`0xA130FF`); word writes crashed MAME.
- **Budget: about 13,000 68000 instructions per frame.** Measure with MAME's trace (`trace file,maincpu` from Lua with `-debug -debugger none`) and count per routine; estimates in cycles were wrong by 3x. Capcom's code needs about half.
- **The hardware layer has its own stack** (`hal_enter` / `hal_leave`, `0xFF1CF8–0xFF1FFF`; it reached `0xFF1D7E` in stage 1). Never push more than a few bytes on the arcade's supervisor stack or task stacks.
- **RAM map** (free block `0xFF0FD3–0xFF7FFF` in stage 1): shadows `0xFF1000`, variables `0xFF12C0–0xFF131F`, sprite engine `0xFF1320–0xFF19A0` (with HUD tables in its gaps `0xFF1620–0xFF169F`, `0xFF1720–0xFF179F`, `0xFF1850–0xFF185F`, `0xFF19A0–0xFF19FF`, and after the far background's 40-slot tables `0xFF1A50`, `0xFF1AB0`), far background tables `0xFF1A00–0xFF1C1F`, HUD cell codes `0xFF1C20–0xFF1CF7`, sprite lists `0xFF2000`, palettes `0xFF3000`, playfield store `0xFF4000`, far background store `0xFF6000`, background cache and palette tables `0xFF7000–0xFF7FFF` (full; see the `.equ` lists in `background.s`, `bgpal.s` and `hud.s`). Check new variables against the next block's start; one overlap broke the sprite chain.
- **Tilemap writes** go through `TRAP #8` (table at ROM `0x190000`, hash at `0x198000`), traps #9–#11 and #13 (fast paths), or are reduced to register side effects for layers not drawn yet (`build.py`). A trap costs about 120 instructions: hot sites need fast paths.
- **Static patching pitfalls.** A table's start address is often another table's loop end marker (`lea $914000,a1` ends the scroll 3 clear); `build.py` leaves such end markers alone. Capstone invents operands when its buffer is too short; always give it 10+ bytes.
- **Game RAM is not free.** `0xFF9A00–0xFFAFFF` stays zero in stage 1 dumps but attract mode writes it; the hardware layer's block `0xFF1000–0xFF7FFF` saw only the start-up clear in 5 minutes of attract mode and stage 1 (write tap on the arcade).
- **Palettes:** sprites use CRAM lines 0–2 (arcade palettes as they are), both backgrounds share line 3 through `bgpal.s`, which reduces their colours to 15 and renumbers tile pixels on upload. Background tile cache keys are tile code plus palette.
- **Never release tile slots and redraw over several frames with the display on:** cells not yet redrawn show whatever reused their slot.
- **Scripted play is not repeatable across builds:** timing changes what the enemies do. Hold the player's health (`0xFFB2E0`, word) at 100 from Lua to reach later scenes, on the arcade as well.
- **The window plane replaces plane A** (the far background) wherever it is shown, so the HUD is drawn with sprites, first in the sprite table. A window HUD left a black bar over the sky.
- **VRAM is full.** Sprites 512 patterns, playfield 508, far background 40 slots of 16 patterns squeezed into table gaps, HUD 108 patterns (one per cell, owned by 13 fixed sprites) in the last gaps: `0x001–0x01E`, `0x41C–0x41E`, the unused window table `0x680–0x69F` (the window is off), `0x781–0x79F`, `0x7F4–0x7FF`. Only `0x01F` and `0x41F` are spare. The far background draws only cells the playfield's opaque tiles do not hide.
- **Never walk an unterminated sprite list every frame.** 256 entries cost more than a frame; the hardware layer rebuilds the sprite table only when the game flips its list flag (`0xFFE9B4`).
- The arcade kernel masks interrupts with `0x2600` to shut out its level-2 VBlank; on the Mega Drive that also delays the level-6 VBlank.
- Take hardware-layer addresses from the linker's symbol table. GNU as shortens `jmp label`, so fixed-offset jump tables do not work.
- Verify a build by reading the game's own state with `tools/mame/md_state.lua` (task slots, shadow registers, player state) and comparing with the arcade; a black screen says nothing yet.
- The access map misses some executed instructions. Patch from it first, then statically.

**Tooling**

- MAME's Lua does not expose the Mega Drive's VRAM or the screen's scanline; `md_trace.lua` rebuilds VRAM from decoded writes and reads the HV counter instead.
- In MAME's 68000 state, `SP` is the supervisor stack even in user mode; use `USP` for task stacks.
- A blank `dl-1425.bin` lets MAME boot `dino` without sound if the real file is missing.
- A loaded save state carries the machine's clock. `-seconds_to_run` shorter than the state's age ends MAME at once, silently, with exit code 0.
- A game step counter that stops while the PC keeps moving is a task waiting: read the task's saved stack (slot offset 8) for the routine.
- BlastEm cannot run without a window here.
