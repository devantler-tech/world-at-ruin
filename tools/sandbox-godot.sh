#!/usr/bin/env bash
# Candidate code sees immutable source and private generated import state.
# The controller and verdict runner stay outside the process/network boundary.
set -euo pipefail
phase_runner="$(cd "$(dirname "$0")" && pwd -P)/trusted-regression-phase.sh"
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$(dirname "$phase_runner")/trusted-regression-lifecycle.sh"
image="$GODOT_SANDBOX_IMAGE"
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo '::error::trusted runtime image must be an exact local digest' >&2
  exit 1
}
project="$PWD/client"
metadata="$GODOT_SANDBOX_METADATA"
frame="$GODOT_SANDBOX_FRAME"
if [ ! -f "$frame" ] || [ -L "$frame" ]; then
  echo '::error::trusted frame fixture is missing or symlinked' >&2
  exit 1
fi
if [ ! -d "$project" ] || [ -L "$project" ] || [ -L "$project/.godot" ] ||
  [ ! -d "$metadata" ] || [ -L "$metadata" ]; then
  echo '::error::sandbox project and generated-state paths must be real directories' >&2
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
    rm -rf -- "$project/.godot"
    mkdir "$project/.godot"
    cache_mount="type=bind,source=$project/.godot,target=/project/client/.godot"
    break
  fi
done
extra_mounts=(--mount "$cache_mount")
# Godot writes sidecars next to assets. Private editor settings use direct writes
# because an atomic rename needs a writable source directory. Only generated files may change;
# their host parents are never exposed, so candidate code cannot replace a bind
# source with a symlink before a later container starts.
while IFS= read -r -d '' file; do
  relative="${file#"$project/"}"
  if [[ ! "$relative" =~ ^(assets/[A-Za-z0-9_./-]+|icon[.]svg)$ ]] || [ -L "$file.import" ] ||
    { [ -e "$file.import" ] && [ ! -f "$file.import" ]; }; then
    echo '::error::unsafe asset import metadata path' >&2
    exit 1
  fi
  sidecar="$metadata/$relative.import"
  if [ "$editor" = true ]; then
    mkdir -p "$(dirname "$sidecar")"
    if [ -f "$file.import" ]; then
      cp "$file.import" "$sidecar"
    else
      : >"$sidecar"
      : >"$file.import"
    fi
  fi
  if [ ! -f "$sidecar" ] || [ -L "$sidecar" ]; then
    echo '::error::generated asset metadata is missing or symlinked' >&2
    exit 1
  fi
  mount="type=bind,source=$sidecar,target=/project/client/$relative.import"
  if [ "$editor" = false ]; then mount="$mount,readonly"; fi
  extra_mounts+=(--mount "$mount")
done < <(find "$project" -type d -name .godot -prune -o -type f \( -name '*.png' -o -name '*.glb' -o -name '*.svg' \) -print0)
cache_guard="$GODOT_SANDBOX_CACHE_GUARD"
if [ ! -x "$cache_guard" ] || [ -L "$cache_guard" ]; then
  echo '::error::trusted import-cache validator is missing' >&2
  exit 1
fi
if [ "$editor" = false ]; then "$cache_guard" "$project"; fi
# Candidate workflow commands stay log data. The private nonce is never passed
# into the sandbox or written beneath the mounted project.
nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
container="war-trusted-$nonce"
records="${GODOT_SANDBOX_CONTAINERS:-}"
private_records=false
if [ -z "$records" ]; then
  records="$(mktemp -d)"
  private_records=true
fi
if [ ! -d "$records" ] || [ -L "$records" ]; then
  echo '::error::sandbox container records must be a private real directory' >&2
  exit 2
fi
: >"$records/$container"
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  result=$?
  trap - EXIT INT TERM
  trusted_stop_child
  if ! bash "$phase_runner" "sandbox cleanup" bash "$phase_runner" --cleanup-containers "$records"; then
    result=1
  elif [ "$private_records" = true ]; then
    rmdir "$records"
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
printf '::stop-commands::%s\n' "$nonce"
status=0
phase='sandbox execution'
if [ "$editor" = true ]; then phase='editor import'; fi
trusted_wait bash "$phase_runner" "$phase" docker run --name "$container" --rm --network none --cap-drop ALL \
  --security-opt no-new-privileges --read-only --user "$(id -u):$(id -g)" \
  --pids-limit 256 --memory 4g --cpus 2 \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=2g,mode=1777 \
  --env HOME=/tmp --env XDG_CACHE_HOME=/tmp/cache --env XDG_CONFIG_HOME=/tmp/config \
  --mount "type=bind,source=$project,target=/project/client,readonly" \
  --mount "type=bind,source=$PWD/server/wire/wire.go,target=/project/server/wire/wire.go,readonly" \
  --mount "type=bind,source=$PWD/.github/workflows/ci.yaml,target=/project/.github/workflows/ci.yaml,readonly" \
  --mount "type=bind,source=$frame,target=/project/docs/phase-0/cave-chamber.png,readonly" \
  --workdir /project --entrypoint /bin/sh "${extra_mounts[@]}" "$image" -c '
    set -eu
    mkdir -p /tmp/config/godot
    printf "%s\n" \
      "[gd_resource type=\"EditorSettings\" format=3]" "[resource]" \
      "filesystem/on_save/safe_save_on_backup_then_rename = false" \
      > /tmp/config/godot/editor_settings-4.7.tres
    exec /usr/local/bin/godot --main-loop SceneTree "$@"
  ' sandbox "$@" || status=$?
if [ "$status" -eq 0 ] && [ "$editor" = true ]; then "$cache_guard" "$project" || status=$?; fi
printf '::%s::\n' "$nonce"
exit "$status"
