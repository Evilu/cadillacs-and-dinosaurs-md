#!/bin/sh
# usage: compare_levels.sh <rom.md> [frames, default 3600] [stages]
# Loads each stage's save state on the arcade game and on the Mega Drive ROM, plays both
# with the same scripted pad and full health, and writes a sheet per stage with the
# arcade's snapshots above the port's: analysis/out/levels/stage<N>.png.
# Run level_states.sh first. The two machines drift apart (timing changes what the
# enemies do): compare what is drawn, not positions.
set -e
ROM=$1; FRAMES=${2:-3600}; STAGES=${3:-"0 1 2 3 4 5 6 7"}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/../analysis/mame/level_runs
OUT=$HERE/../analysis/out/levels
mkdir -p "$OUT"
for n in $STAGES; do
  rm -rf "$WORK/arcade$n" "$WORK/md$n"
  LOAD=stage$n TRACE_FRAMES=$FRAMES SNAP_EVERY=${SNAP_EVERY:-300} HOLD="ffb2e0=0064" "$HERE/level.sh" arcade "$WORK/arcade$n" &
  LOAD=stage$n TRACE_FRAMES=$FRAMES SNAP_EVERY=${SNAP_EVERY:-300} HOLD="ffb2e0=0064" "$HERE/level.sh" "$ROM" "$WORK/md$n" &
  wait
done
for n in $STAGES; do
  "$HERE/../analysis/venv/bin/python3" -I "$HERE/analysis/level_sheet.py" "$WORK/arcade$n" "$WORK/md$n" "$OUT/stage$n.png"
done
