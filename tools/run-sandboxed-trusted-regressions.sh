#!/usr/bin/env bash
# Assemble and judge on the host; execute candidate Godot only in containment.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: run-sandboxed-trusted-regressions.sh <trusted-root> <candidate-root>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$(mktemp -d)"
trap 'rm -rf "$bin"' EXIT
GOTOOLCHAIN=local GOWORK=off go build -o "$bin/cache-guard" "$root/tools/trusted-regression-cache.go"
mkdir "$bin/import-metadata"
# This historical image is an oracle, so it comes from the trusted base.
for path in docs docs/phase-0 docs/phase-0/cave-chamber.png; do
  if [ -L "$1/$path" ]; then
    echo '::error::trusted frame fixture has a symlinked path' >&2
    exit 1
  fi
done
cp "$1/docs/phase-0/cave-chamber.png" "$bin/frozen-frame.png"
image="$(bash "$root/tools/build-trusted-regression-runtime.sh")"
cp "$root/tools/sandbox-godot.sh" "$bin/godot"
chmod +x "$bin/godot"
PATH="$bin:$PATH" GODOT_SANDBOX_IMAGE="$image" GODOT_SANDBOX_CACHE_GUARD="$bin/cache-guard" GODOT_SANDBOX_METADATA="$bin/import-metadata" GODOT_SANDBOX_FRAME="$bin/frozen-frame.png" "$1/tools/required-regression-control.sh" "$1" "$2"
