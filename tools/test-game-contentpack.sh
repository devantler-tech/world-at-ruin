#!/usr/bin/env bash
# Full game bytes must load from a base containing only shell owners and class metadata.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
probe=$(mktemp -d)
trap 'rm -rf -- "$probe"' EXIT
run_native() {
 local log=$1 status=0 native_pid timer_pid
 shift
 godot "$@" > "$log" 2>&1 & native_pid=$!
 ( sleep 180; kill "$native_pid" 2>/dev/null || true ) & timer_pid=$!
 wait "$native_pid" || status=$?
 kill "$timer_pid" 2>/dev/null || true
 wait "$timer_pid" 2>/dev/null || true
 cat "$log"
 if [ "$status" -ne 0 ] || grep -qE 'SCRIPT ERROR|^ERROR:' "$log"; then return 1; fi
}
# Derive the immutable base's class catalogue through a clean native import,
# rather than depending on or changing a checkout-local editor cache.
go -C "$root/server" build -o "$probe/contentpack" ./cmd/contentpack
"$probe/contentpack" -experimental -operation stage -source "$root/client" -work "$probe/catalogue"
run_native "$probe/catalogue.log" --headless --editor --import --path "$probe/catalogue/project"
for build in one two; do
 bash "$root/tools/build-contentpack.sh" --experimental "$root/client" "$probe/$build" > "$probe/$build.log" 2>&1 || { cat "$probe/$build.log"; exit 1; }
done
cmp "$probe/one/content.pck" "$probe/two/content.pck"
cmp "$probe/one/receipt.json" "$probe/two/receipt.json"
base="$probe/base"
mkdir -p "$base/.godot" "$base/scripts"
printf 'config_version=5\n[application]\nconfig/name="Immutable pack proof base"\n' > "$base/project.godot"
cp "$probe/catalogue/project/.godot/global_script_class_cache.cfg" "$base/.godot/global_script_class_cache.cfg"
while IFS= read -r owner; do
 cp "$root/client/$owner" "$base/$owner"
 if [ -f "$root/client/$owner.uid" ]; then cp "$root/client/$owner.uid" "$base/$owner.uid"; fi
done < "$root/server/internal/contentpack/shell-resources.txt"
run_native "$probe/game.log" --headless --path "$base" --script "$root/tools/contentpack-game-probe.gd" -- "$probe/one/content.pck"
grep -q 'GAME PACK PASS' "$probe/game.log"
if run_native "$probe/no-pack.log" --headless --path "$base" --script "$root/tools/contentpack-game-probe.gd" -- "$probe/absent.pck"; then
 echo 'game closure proof passed without any game pack' >&2; exit 1
fi
echo 'TEST PASS — two identical full game packs load from a base without game content'
