#!/usr/bin/env bash
# Candidate code sees a read-only project and private temporary state.
# The controller and verdict runner stay outside the process/network boundary.
set -euo pipefail
image="$GODOT_SANDBOX_IMAGE"
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo '::error::trusted runtime image must be an exact local digest' >&2
  exit 1
}
project="$PWD/client"
if [ ! -d "$project" ] || [ -L "$project" ] || [ -L "$project/.godot" ]; then
  echo '::error::sandbox project and import-cache paths must be real directories' >&2
  exit 1
fi
# Only the two source data files used by existing frozen regressions are exposed.
for directory in "$PWD/server" "$PWD/server/wire" "$PWD/.github" "$PWD/.github/workflows"; do
  if [ ! -d "$directory" ] || [ -L "$directory" ]; then
    echo '::error::sandbox source-data directory is missing or symlinked' >&2
    exit 1
  fi
done
for file in "$PWD/server/wire/wire.go" "$PWD/.github/workflows/ci.yaml"; do
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo '::error::sandbox source-data file is missing or symlinked' >&2
    exit 1
  fi
done
editor=false
cache_mount="type=bind,source=$project/.godot,target=/project/client/.godot,readonly"
for arg in "$@"; do
  if [ "$arg" = --editor ]; then
    editor=true
    # Only disposable candidate-derived import data is writable.
    rm -rf -- "$project/.godot"
    mkdir "$project/.godot"
    cache_mount="type=bind,source=$project/.godot,target=/project/client/.godot"
    break
  fi
done
cache_guard="$GODOT_SANDBOX_CACHE_GUARD"
if [ ! -x "$cache_guard" ] || [ -L "$cache_guard" ]; then
  echo "::error::trusted import-cache validator is missing" >&2
  exit 1
fi
if [ "$editor" = false ]; then
  "$cache_guard" "$project"
fi
# Candidate workflow commands stay log data. The private nonce is never
# passed into the sandbox or written beneath the mounted project.
nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
printf '::stop-commands::%s\n' "$nonce"
status=0
docker run --rm --network none --cap-drop ALL \
  --security-opt no-new-privileges --read-only --user "$(id -u):$(id -g)" \
  --pids-limit 256 --memory 4g --cpus 2 \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=2g,mode=1777 \
  --env HOME=/tmp --env XDG_CACHE_HOME=/tmp/cache \
  --mount "type=bind,source=$project,target=/project/client,readonly" \
  --workdir /project --mount "$cache_mount" "$image" "$@" || status=$?
if [ "$status" -eq 0 ] && [ "$editor" = true ]; then
  "$cache_guard" "$project" || status=$?
fi
printf '::%s::\n' "$nonce"
exit "$status"
