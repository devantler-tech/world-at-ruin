#!/usr/bin/env bash
# Assemble and judge on the host; execute candidate Godot only in containment.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: run-sandboxed-trusted-regressions.sh <trusted-root> <candidate-root>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$root/tools/trusted-regression-lifecycle.sh"
bin="$(mktemp -d)"
mkdir "$bin/containers"
export GODOT_SANDBOX_CONTAINERS="$bin/containers"
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  result=$?
  trap - EXIT INT TERM
  trusted_stop_child
  if bash "$root/tools/trusted-regression-phase.sh" "sandbox cleanup" bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$GODOT_SANDBOX_CONTAINERS"; then
    rm -rf "$bin"
  else
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
GOTOOLCHAIN=local GOWORK=off trusted_wait bash "$root/tools/trusted-regression-phase.sh" "host cache guard build" go build -o "$bin/cache-guard" "$root/tools/trusted-regression-cache.go"
mkdir "$bin/import-metadata"
# This historical image is an oracle, so it comes from the trusted base.
for path in docs docs/phase-0 docs/phase-0/cave-chamber.png; do
  if [ -L "$1/$path" ]; then
    echo '::error::trusted frame fixture has a symlinked path' >&2
    exit 1
  fi
done
cp "$1/docs/phase-0/cave-chamber.png" "$bin/frozen-frame.png"
trusted_wait bash "$root/tools/build-trusted-regression-runtime.sh" >"$bin/image"
image="$(cat "$bin/image")"
cp "$root/tools/sandbox-godot.sh" "$bin/godot"
cp "$root/tools/trusted-regression-phase.sh" "$root/tools/trusted-regression-lifecycle.sh" "$bin/"
chmod +x "$bin/godot"
PATH="$bin:$PATH" GODOT_SANDBOX_IMAGE="$image" GODOT_SANDBOX_CACHE_GUARD="$bin/cache-guard" GODOT_SANDBOX_METADATA="$bin/import-metadata" GODOT_SANDBOX_FRAME="$bin/frozen-frame.png" trusted_wait "$root/tools/required-regression-control.sh" "$1" "$2"
