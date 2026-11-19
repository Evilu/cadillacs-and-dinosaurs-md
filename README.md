# Cadillacs and Dinosaurs MD

A port of Capcom's 1993 CPS-1 arcade game *Cadillacs and Dinosaurs* to the Sega Mega Drive / Genesis.

The Mega Drive runs Capcom's own 68000 program; only the hardware layer underneath it is replaced (video, palettes, input, memory map). The goal is a version as close to the arcade as the console allows, at 60 frames a second.

**Status: 0.1.0-alpha.** Stage 1 is playable in emulators, with known issues (below). Music and effects have a first version. **This is a work in progress: the HUD and the sound still cause performance problems in play.** The stages will be fixed one at a time from here.

## ROMs

This repository contains no ROM data. To build, you supply your own dump of the arcade ROM set: you bring a copy of the game you own, and the build turns it into a Mega Drive ROM on your own machine.

## What you need

- **Your own dump of the arcade game:** MAME's `dino` set (*Cadillacs and Dinosaurs*, World 930201), as `dino.zip` or as a folder of its files. The build checks the sixteen files it uses by size and CRC32 and tells you which one is missing or wrong. Clones (`dinou`, `dinoj`, `dinohack` and so on) are not supported.
- **Python 3.9 or newer**, with `numpy` and `capstone` (`requirements.txt`).
- **A C compiler** (`cc`): the build compiles a small emulator of the arcade's sound board and runs the sound program in it. The first build takes about a minute longer for that; the result is kept in a `cache` folder beside the ROM.
- **GNU binutils for the 68000** (`as`, `ld`, `objcopy`, `nm`):
  - macOS: `brew install m68k-elf-binutils`
  - Debian / Ubuntu: `sudo apt install binutils-m68k-linux-gnu`
  - other: any 68000 binutils; set `M68K_PREFIX` to the tool prefix (for example `M68K_PREFIX=m68k-elf-`).
- **An emulator with the Sega SSF mapper**: the ROM is 8.7 MB and banks its graphics and sound through the extended Sega mapper its header announces (`SEGA SSF`). Tried in MAME; the 6 MB build before sound was also tried in ares; BlastEm reads the same header but has not been checked.

## Build

```sh
git clone https://github.com/Evilu/cadillacs-and-dinosaurs-md.git
cd cadillacs-and-dinosaurs-md
python3 -m venv .venv
.venv/bin/python3 -m pip install -r requirements.txt
.venv/bin/python3 build_md.py /path/to/dino.zip
```

The ROM is written to `out/cadillacs_md.md`; a second argument chooses another path. Keep the `.md` extension: some emulators pick the console from it (ares took a `.bin` for an Atari 2600 game). The built ROM contains Capcom's program and graphics: do not share it.

## Play

- **ares** (or BlastEm, unchecked): open `out/cadillacs_md.md`.
- **MAME:** plain `-cart` loading does not switch the mapper on. Use `tools/run_md.sh out/cadillacs_md.md <work folder>`, which writes a one-entry software list that does.

Pad: **A** inserts a coin, **Start** starts, **B** attacks, **C** jumps. One player.

## Known issues (0.1.0-alpha)

Everything here was seen or measured in stage 1 under scripted play in MAME. The other seven stages have been started from save states and watched for a minute each; what that showed is in [the stage comparison](docs/06-levels-arcade-vs-md.md): wrong background colours at the start of some stages, holes in the jungle's playfield, the player's portrait missing from the HUD.

**Sound**
- Music is the arcade's notes re-voiced on FM and PSG with three generic instrument sounds; drums and effects are samples through the DAC, one at a time, so an effect cuts the drums. Panning and echo are gone. Nobody has judged it by ear yet ([details](docs/07-sound.md)).

**Missing**
- Text layer: only the in-game HUD is drawn (player and enemy panels, score, health bars, "insert coin"), with sprites, over the stage as on the arcade. Stage titles, continue and other mid-screen text, and the title and select screen text are not; player 2's full panel and player 3's are left out. HUD colours are the nearest ones in player 1's palette line (lost health shows dark brown, not red), and changed HUD text takes a few frames to appear in full.
- Only one player has been tried.

**Speed**
- The HUD and the sound still slow the game down in play. The HUD measured about 8% fewer sprite lists a second; the sound showed no cost in the headless step count, but it is felt when playing, so that measurement misses something.
- Sprites are converted every frame when the game keeps up, and every second to fourth frame when it falls behind.
- Brawls with many enemies run at about 42–58 game frames a second instead of 60.
- Scene changes and doors opening can stall the game for a few frames while background colours are worked out again.
- The select screen stutters while it loads.

**Colours**
- Both background layers share one 15-colour palette line, so their colours are approximations of the arcade's.
- Sprites have three palette lines. A fourth sprite palette on screen borrows the closest line: some enemies, especially ones fading in, show wrong colours.
- The select screen briefly shows the previous scene's colours on the way into the stage.

**Graphics**
- The title logo may still lack a piece or two where its letters overlap.
- The logo and the select portraits overlap for a moment between the title and select screens.
- Barrels sometimes lose pieces or show green stripes.
- When the tile caches run out, a few background cells can stay blank for up to a second.
- The jungle scene of the attract-mode demo needs about 190 different playfield tiles; the cache holds 160. Cells without a slot draw a neighbouring cell's tile until a slot frees up, so a few cells show the wrong tile for a while. The jungle stage shows the same as black cells.

**Hardware**
- Never run on a real console or flash cart. Do not try yet: some code paths still touch arcade addresses that a real Mega Drive may not tolerate.

## Development

From here on, changes go through branches and pull requests: one branch per change, a pull request into `main`, and a test ROM built and played before merging. The research behind the port, the measurements and the plan are in `docs/`; how to trace the arcade and check a build is in `tools/README.md`.

- [CPS-1 vs Mega Drive architecture](docs/01-architecture-cps1-vs-mega-drive.md)
- [Final Fight: arcade vs Final Fight MD](docs/02-final-fight-arcade-vs-md.md)
- [Cadillacs and Dinosaurs, measured](docs/03-cadillacs-and-dinosaurs-measured.md)
- [Port plan and milestone status](docs/04-port-plan.md)
- [Save states for every stage](docs/05-save-states.md)
- [The stages, arcade against the Mega Drive build](docs/06-levels-arcade-vs-md.md)
- [Sound](docs/07-sound.md)
- [Analysis tools](tools/README.md)

## Rights

All rights reserved by their respective owners. I do not own anything related to *Cadillacs and Dinosaurs*, *Final Fight* or the CP System: the games, their code, graphics, sound, characters and trademarks belong to Capcom and the other rights holders. *Cadillacs and Dinosaurs* is based on Mark Schultz's *Xenozoic Tales*. Sega and Mega Drive are trademarks of Sega. *Final Fight MD* is the work of its fan author and is used here only as a technical reference. This is a non-commercial fan research project with no affiliation with or endorsement by any of them.

## Credits

This project stands on other people's work. Thank you to:

**The game**
- Capcom, for *Cadillacs and Dinosaurs* (1993) and *Final Fight* (1989), and the CP System.
- Mark Schultz, creator of *Xenozoic Tales*, on which the game is based.

**Emulators and tools we run**
- The [MAME](https://www.mamedev.org/) team: its CPS-1, QSound and Mega Drive drivers are our reference for how the hardware behaves, and MAME runs every trace and test in this project.
- Michael Pavone, for [BlastEm](https://www.retrodev.com/blastem/), and the [ares](https://ares-emu.net/) team, for the emulators we play test builds in.
- The NSA's [Ghidra](https://ghidra-sre.org/) team, the [Capstone](https://www.capstone-engine.org/) disassembler authors, and the [GNU Binutils](https://www.gnu.org/software/binutils/) maintainers.

**Hardware documentation and research**
- Fabien Sanglard, for his writing on the CP System.
- Jose Tejada (jotego), for the [jtcps1](https://github.com/jotego/jtcps1) FPGA core and its hardware notes.
- Eduardo Cruz (Arcade Hacker), for reverse engineering Capcom's Kabuki CPU.
- superctr, for the QSound documentation and MDSDRV.
- Charles MacDonald, for the Mega Drive hardware documents.
- [Plutiedev](https://plutiedev.com/), [md.railgun.works](https://md.railgun.works/), [Raster Scroll](https://rasterscroll.com/), [Sega Retro](https://segaretro.org/) and the [SpritesMind](https://gendev.spritesmind.net/) community, for Mega Drive programming knowledge.
- Krikzz, for the documentation of the extended SSF mapper used by flash carts.
- Stéphane Dallongeville, for [SGDK](https://github.com/Stephane-D/SGDK), whose source and documentation we learned from.

**Fan projects we learned from**
- Mauro Xavier (CFX) and the *Final Fight MD* team, including Edmo Caldas and Master Linkuei: their port is our reference for what a CPS-1 brawler can look like on the Mega Drive.
- GameHackFan ([dinore](https://github.com/GameHackFan/dinore)) and zengfr ([romhack](https://github.com/zengfr/romhack)), for their notes on the *Cadillacs and Dinosaurs* program and RAM.
- Nemezes Games, for their *Cadillacs and Dinosaurs* Mega Drive demake.

If we have used your work and missed you here, please open an issue and we will add you.
