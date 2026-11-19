#!/bin/sh
# usage: level_states.sh <rom.md> [stages, default "0 1 2 3 4 5 6 7"]
# Writes one save state per stage for the arcade game and for the Mega Drive ROM, taken
# 60 frames after play begins in that stage.
# States: analysis/mame/states/dino/stage<N>.sta and .../genesis/stage<N>.sta.
set -e
ROM=$1; STAGES=${2:-"0 1 2 3 4 5 6 7"}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/../analysis/mame/level_states
for n in $STAGES; do
  LEVEL=$n SAVE="stage$n@+60" STOP_AFTER=70 TRACE_FRAMES=3000 "$HERE/level.sh" arcade "$WORK/arcade$n" &
  LEVEL=$n SAVE="stage$n@+60" STOP_AFTER=70 TRACE_FRAMES=3000 "$HERE/level.sh" "$ROM" "$WORK/md$n" &
  wait
done
ls -l "$HERE/../analysis/mame/states"/*
