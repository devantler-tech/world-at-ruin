#!/usr/bin/env bash
# Experimental trusted-local native build. No runtime, signing or delivery activation.
set -euo pipefail
if [ "$#" -ne 3 ] || [ "$1" != --experimental ]; then
 echo 'content packs are experimental; use --experimental SOURCE NEW_OUTPUT_DIRECTORY' >&2; exit 2
fi
source_project=$2
output=$3
source_project=$(CDPATH='' cd -- "$source_project" && pwd -P)
output_parent=$(CDPATH='' cd -- "$(dirname -- "$output")" && pwd -P)
output="$output_parent/$(basename -- "$output")"
case "$output" in "$source_project"|"$source_project"/*)
 echo 'content pack output must be outside the source project' >&2; exit 1 ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
 echo 'content pack output must be a new directory' >&2; exit 1
fi
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
probe=$(mktemp -d)
trap 'rm -rf -- "$probe"' EXIT
go -C "$root/server" build -o "$probe/contentpack" ./cmd/contentpack
"$probe/contentpack" -experimental -operation stage -source "$source_project" -work "$probe/work"
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
run_native "$probe/import.log" --headless --editor --import --path "$probe/work/project"
run_native "$probe/pack.log" --headless --path "$probe/work/project" --script "$root/tools/contentpack-packer.gd" -- "$probe/work/selected.json" "$probe/work/content.pck" "$probe/work/resources.json"
"$probe/contentpack" -experimental -operation finalize -work "$probe/work" -output "$output"
"$probe/contentpack" -experimental -operation verify -output "$output"
