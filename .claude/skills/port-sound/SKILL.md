---
name: port-sound
description: Work on the port's sound - survey the arcade's sound commands, run the QSound board's Z80 program in the build-time emulator, convert tunes and effects for the YM2612, PSG and DAC, and check the Mega Drive build's audio against the arcade in MAME. Use when asked about music, effects, sound commands, a tune that sounds wrong, or to compare the port's sound with the arcade's.
---

# Sound

`docs/07-sound.md` has the method, the numbers and what is not done. Run from the repository root; everything is written under `analysis/`.

## Once

```sh
cat analysis/roms/dino/cd-q?.?k > analysis/work/dino_qsamples.bin
```

## What a command does

```sh
analysis/venv/bin/python3 -I tools/analysis/qsound_survey.py analysis/roms/dino/cd_q.5k analysis/sound/cache 30
analysis/venv/bin/python3 -I tools/build/sound.py analysis/roms/dino/cd_q.5k analysis/work/dino_qsamples.bin analysis/sound/cache 02 30
```

The first lists every command; the second converts only the commands named (hex) and prints the repeat it found, where the notes went (FM, PSG, PCM, places taken while sounding) and the stream's size. `0x00-0x26` are tunes, `0x2C-0x91` effects, `0xA0-0xFF` the same effects on other voices.

## Check a tune against the arcade

```sh
analysis/venv/bin/python3 -I tools/analysis/qsound_render.py analysis/roms/dino/cd_q.5k analysis/work/dino_qsamples.bin analysis/sound/cache 02 60 analysis/mame/snd/ref_02.wav
SOUND_CMD=02 TRACE_FRAMES=4200 tools/run_md.sh test/roms/md/cadillacs_md.md analysis/mame/snd -video none -sound none \
  -seconds_to_run 200 -wavwrite $PWD/analysis/mame/snd/md_02.wav -autoboot_script $PWD/tools/mame/md_sound.lua
analysis/venv/bin/python3 -I tools/analysis/compare_audio.py analysis/mame/snd/ref_02.wav analysis/mame/snd/md_02_cut.wav 2 58
```

Cut the first 600 frames (10.01 s) off the port's recording first: the command is sent at frame 600. Right notes give the best agreement at lag 0 and shift 0, about 0.7, with every other shift clearly lower. A flat row of scores means one side is silent or noise.

For an effect, compare loudness per tenth of a second and the strongest frequency of the two recordings: the same shape and the same frequency mean the DAC rate and the sample are right.

## Check the board emulator against MAME

`tools/mame/qsound_log.lua` on the arcade writes `sound_log.csv`. Feed its `c` rows to `analysis/sound/cache/qsound_board` and compare its output with the `q` rows: the same registers and values, within a fraction of a percent.

## Traps

- The measurements say the notes and the timing are right. They say nothing about how it sounds: say so, and ask the user to listen.
- The arcade's attract mode is silent; in-game audio is full of effects. Compare tunes alone.
- A poke of the packet between frames is overwritten by the hardware layer's ready flag: use `md_sound.lua`.
- After any change to `src/` rerun a long scripted check (`TRACE_INPUT=arcade HOLD_HEALTH=1 tools/check_md.sh <rom> <dir> 7200 1800`): sound changes the timing of everything else.
- The conversion's cache is keyed on the sound program and the emulator, not on `sound.py`: only the note extraction is cached.
