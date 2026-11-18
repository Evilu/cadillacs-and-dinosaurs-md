# Cadillacs and Dinosaurs MD

A port of Capcom's 1993 CPS-1 arcade game *Cadillacs and Dinosaurs* to the Sega Mega Drive / Genesis.

Work in progress.

## Research

- [CPS-1 vs Mega Drive architecture](docs/01-architecture-cps1-vs-mega-drive.md)
- [Final Fight: arcade vs Final Fight MD](docs/02-final-fight-arcade-vs-md.md)
- [Cadillacs and Dinosaurs, measured](docs/03-cadillacs-and-dinosaurs-measured.md)
- [Port plan](docs/04-port-plan.md)
- [Analysis tools](tools/README.md)

## ROMs

This repository contains no ROM data. To build, you supply your own dump of the arcade ROM set.

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
