#!/bin/bash
# Runs the test harness headless in a throwaway folder (never touches ~/.factorio).
# Usage: tools/run_tests.sh [path to factorio binary]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FACTORIO="${1:-/mnt/GamingSSD/SteamLibrary/steamapps/common/Factorio/bin/x64/factorio}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mods" "$WORK/write"
ln -s "$ROOT/smart-fuel" "$WORK/mods/smart-fuel"
ln -s "$ROOT/tests/sf-tests" "$WORK/mods/sf-tests"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"space-age","enabled":true},{"name":"quality","enabled":true},
{"name":"elevated-rails","enabled":true},{"name":"recycler","enabled":true},
JSON
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$WORK/write" > "$WORK/config.ini"
"$FACTORIO" -c "$WORK/config.ini" --mod-directory "$WORK/mods" --create "$WORK/test.zip" --map-gen-settings "$ROOT/tests/map-gen-settings.json" > "$WORK/create.log" 2>&1 || { cat "$WORK/create.log"; exit 1; }
grep "^STA" "$WORK/create.log" || true
"$FACTORIO" -c "$WORK/config.ini" --mod-directory "$WORK/mods" --benchmark "$WORK/test.zip" \
  --benchmark-ticks 4100 --benchmark-runs 1 > "$WORK/run.log" 2>&1 || true
grep -E "^STA" "$WORK/run.log" || true
grep -q "Error" "$WORK/run.log" && sed -n "/Error/,+12p" "$WORK/run.log" | head -30 || true
grep -q "Error" "$WORK/create.log" && grep -A5 "Error" "$WORK/create.log" || true
