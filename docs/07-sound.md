# Sound

The arcade's sound is a Z80 program driving a QSound DSP: 16 voices of 8-bit samples, 2 MB of them. The Mega Drive has six FM channels, three square waves, a noise channel and no sample hardware beyond an 8-bit DAC in place of the sixth FM channel. This is the first version of the port's sound and how it was measured. The method is the one the RoboCop port used ([Evilu/robocop-md](https://github.com/Evilu/robocop-md)): run the arcade's sound program at build time, log what it tells its chip, and convert the log.

Measured on MAME 0.289 with the build of 2026-11-19. **Nobody has listened to it yet.** Every claim below is a count or a comparison of recordings.

## The arcade's sound board

| | |
|---|---|
| Program | `cd_q.5k`, 128 KB. The first 32 KB is Kabuki-encrypted, opcodes and data decoded differently (`tools/build/kabuki.py`, keys `76543210 24601357 4343 43`; byte for byte what MAME decodes) |
| CPU | Z80 at 8 MHz, one interrupt at 250 Hz. The driver rewrites every sounding voice's volume and pitch on every fourth interrupt: 16 ms |
| Banked ROM | `0x8000–0xBFFF`, bank n at file offset `0x8000 + n × 0x4000`, chosen by a write to `0xD003` |
| DSP | Written through `0xD000` (data high), `0xD001` (data low), `0xD002` (register). Voice v: register `8v` bank of voice v+1, `8v+1` start, `8v+2` pitch (`0x1000` = 24,038 Hz), `8v+3` phase, `8v+4` loop length, `8v+5` end, `8v+6` volume; `0x80+v` pan; `0x93`, `0xBA–0xC9`, `0xD9` echo |
| Samples | `cd-q1` to `cd-q4`, 2 MB, 8-bit signed, 64 KB banks |

**How the 68000 talks to it.** The shared RAM at `0xF18000` (odd bytes; index = Z80 address − `0xC000`) carries one packet per frame from Capcom's VBlank handler:

- index 0 = `0x00`, 1 = command, 6–12 = seven parameter bytes, 15 = 0 to hand it over;
- index 0 = `0xFF`, 1 = control code, 3 and 4 = parameters. At start-up the game fills the RAM with `0xFF`, writes `0x88` to index `0xFFD`, and sends controls `0x0B`, `0x0B`, `0x00`.

Played in the board emulator: control `0x00` stops everything (13 voices sounding before it, none after, no further note); control `0x0B` stops nothing; a tune command replaces the tune that is playing; an effect leaves the tune alone.

**A note** is: start, end, loop length and bank written, then the phase register, then volume and pitch. A voice is stopped by writing pitch 0.

## The board emulator

`tools/build/qsound_board.c` is the board without the DSP: a Z80 core, the banked ROM, the two shared RAMs, the 250 Hz interrupt and the three DSP ports, which it logs. The build compiles it with the system's C compiler. Fed the 68000's shared-RAM writes from 90 seconds of MAME's own log of the game (`tools/mame/qsound_log.lua`), it makes 163,015 DSP register writes against MAME's 163,526; 163,014 are the same register and value.

## What the commands are

Each of the 256 commands played alone (`tools/analysis/qsound_survey.py`):

| Commands | What |
|---|---|
| `0x00–0x26` | 39 tunes, 8 to 16 voices each. 31 repeat; `0x14`, `0x18`, `0x19`, `0x1D`, `0x1E`, `0x22`, `0x25`, `0x26` play once (4 to 108 seconds) |
| `0x2C–0x91` | 102 effects. Nearly all are one sample on one voice; a few repeat it on three or four voices, four keep sounding (`0x70`, `0x84–0x86`) |
| `0xA0–0xFF` | 96 commands that play the same effects on other voices |

119 different samples are used, 1.87 MB of the 2 MB.

## Conversion (`tools/build/sound.py`)

- **Pitched samples become FM or PSG notes.** A sample's own pitch is found by autocorrelation of its looped part; the note's frequency is that times the driver's pitch word. The level follows the driver's volume writes frame by frame, so attack and decay are the arcade's. The timbre is one of three two-carrier patches chosen by how bright the sample's spectrum is.
- **Places.** Five FM channels and three PSG squares: eight for up to sixteen voices. A voice keeps its place; a new one takes a free place, FM first, or the place keyed longest ago. 3,890 of 46,247 pitched notes (8%) took a place that was still sounding. A voice whose volume word is under `0x30` counts as silent (music voices run at `0x200` to `0x900`).
- **Unpitched samples (drums) and all effects become PCM** at 8,229 Hz for the DAC: 128 drum sounds, each at most 0.6 seconds, and the effects, each at most 4 seconds. An effect is its first note only.
- **Repeats.** A tune is played for 480 seconds. The period is looked for in its busiest voice and has to hold in every voice, give or take two 16 ms steps; of the periods that fit, the one whose repetition reaches furthest back wins, because a riff also repeats, but only inside its section.
- **Size.** 64,471 notes (30,739 FM, 15,508 PSG, 18,184 PCM) in 1.32 MB of streams and 1.10 MB of PCM: five 512 KB banks. The ROM grows from 6 MB to 8.7 MB.

The emulation takes about a minute; the notes are kept in a `cache` folder beside the ROM.

## On the console (`src/sound.s`)

- Capcom's VBlank handler leaves its packet in the shared RAM's stand-in (`0xFF1200`); `sound_frame` takes it straight after. Control 0 stops the tune, a tune command starts a stream, an effect goes to the DAC.
- A stream is a list of YM2612 and PSG writes per frame, with waits, a jump for the repeat and drum triggers. The 68000 plays one frame of it each VBlank.
- The Z80 runs a 104-byte program that plays one PCM sound at a time from ROM. An effect is not interrupted by a drum; a new effect replaces the old one.
- **ROM.** The command table, drum table and Z80 program sit at `0x186000`. Streams and PCM follow the tiles from `0x600000` and are reached through two mapper regions nothing else uses: region 6 (`0x300000`, register `0xA130FD`) for the stream, region 5 (`0x280000`, `0xA130FB`) for the PCM the Z80 reads. Region 4 is read directly for the HUD's tiles and region 7 is the tile window.

## Checked in MAME

- **Notes.** A tune rendered alone from the arcade's samples (`tools/analysis/qsound_render.py`) against the port made to play the same tune alone (`tools/mame/md_sound.lua`), compared by pitch class per tenth of a second (`tools/analysis/compare_audio.py`): best at no lag and no transposition for all four tried, agreement 0.72 (`0x02`), 0.68 (`0x05`), 0.77 (`0x0C`), 0.76 (`0x11`). Transposed by any number of semitones, `0x02` scored 0.44 to 0.64 and `0x05` 0.48 to 0.55 (on the build before the levels were turned down).
- **PCM.** Three effects alone: the same loudness shape and length as the reference, and the strongest frequency within 1 Hz (1,280 against 1,279, 643 against 643, 2,970 against 2,969), so the DAC's rate is what the conversion assumes.
- **Cost.** Game steps per second with sound: 60.2 in stage 0 and 48.9 in stage 1, against 58.7 and 49.2 before; no difference beyond run-to-run. The hardware layer's stack reached `0xFF1D8E` as before.
- 7,200 frames of scripted play end with the game running.

## Found on the way: stray writes from the trap emulator

The first long run with sound crashed at frame 3,351 with an address error in Capcom's code: player 1's state byte held `0x7F`. No instruction had written it at its address. The write came from `TRAP #8`'s emulator to `0xE8B344`, a mirror of work RAM on the Mega Drive.

The emulator loaded an operand's size into the low word of `D2` and added all of `D2` to the address register on post-increment. The upper word was whatever the game had left there, so the saved pointer could gain `0x40002` instead of 2 per instruction and walk out of the tile maps into the RAM mirrors (`0xE00000–0xFEFFFF`; the arcade has nothing there). `ext.l` after the size is loaded fixes it. The same run made 32 such writes before the fix, six of them during start-up, and none after; builds without sound had the bug too.

## Not done, not checked

- **Performance.** Played by hand, the build with the HUD and the sound still has performance problems. The step count above did not show a cost for sound, so it is not the right measure: frames where the VBlank work runs long (bus waits for the Z80, YM2612 busy waits, a tune starting) have not been profiled.
- **By ear, anything.** Balance between FM, PSG and PCM, the three patches, and which voices lose their place are unjudged.
- A sample is called unpitched when its autocorrelation peak is under 0.55. Wrong calls put a melodic voice on the DAC or a drum on FM.
- Panning, echo and the seven parameter bytes of a command (volume and position of an effect) are ignored.
- One PCM sound at a time: an effect silences the drums while it lasts, and the DAC pauses while the 68000 holds the bus each frame.
- Effects of several notes play the first; looping effects stop after 4 seconds.
- A sample started while the Z80 is stepping to the next 32 KB of ROM can leave it reading the wrong bank for that sound.
- A note held across a tune's repeat point is cut there.
- Not run in ares or BlastEm. The ROM is 8.7 MB and needs the mapper.
