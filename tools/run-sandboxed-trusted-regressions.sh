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
image="$(bash "$root/tools/build-trusted-regression-runtime.sh")"
cp "$root/tools/sandbox-godot.sh" "$bin/godot"
chmod +x "$bin/godot"
PATH="$bin:$PATH" GODOT_SANDBOX_IMAGE="$image" GODOT_SANDBOX_CACHE_GUARD="$bin/cache-guard" GODOT_SANDBOX_METADATA="$bin/import-metadata" "$1/tools/required-regression-control.sh" "$1" "$2"
