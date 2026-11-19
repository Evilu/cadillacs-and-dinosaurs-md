#!/bin/sh
# usage: level.sh arcade|<rom.md> <out dir> [extra mame options...]
# Runs tools/mame/level.lua headless on the arcade game or on a Mega Drive ROM.
# The script's settings come from the environment (LEVEL, SAVE, LOAD, TRACE_FRAMES,
# SNAP_EVERY, HOLD, POKE, PLAY, DUMP_RAM, STOP_AFTER). Save states are kept in
# analysis/mame/states.
set -e
WHAT=$1; OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
MAME_DIR=$HERE/../analysis/mame
mkdir -p "$OUT" "$MAME_DIR/states"; OUT=$(cd "$OUT" && pwd); STATES=$(cd "$MAME_DIR/states" && pwd)
FRAMES=${TRACE_FRAMES:-3600}
export TRACE_OUT="$OUT"
if [ "$WHAT" = arcade ]; then
  cd "$MAME_DIR"
  mame dino -rompath "qsound_rom;../.." -skip_gameinfo -nothrottle -video none -sound none \
    -seconds_to_run $((FRAMES / 50 + 3600)) -snapshot_directory "$OUT" -state_directory "$STATES" \
    -autoboot_script "$HERE/mame/level.lua" "$@" > "$OUT/mame.log" 2>&1 || true
else
  ROM=$(cd "$(dirname "$WHAT")" && pwd)/$(basename "$WHAT")
  "$HERE/run_md.sh" "$ROM" "$OUT" -video none -sound none \
    -seconds_to_run $((FRAMES / 50 + 3600)) -snapshot_directory "$OUT" -state_directory "$STATES" \
    -autoboot_script "$HERE/mame/level.lua" "$@" > "$OUT/mame.log" 2>&1 || true
fi
grep -h "rror\|Fatal\|play began\|saved" "$OUT/mame.log" | head -8 || true
