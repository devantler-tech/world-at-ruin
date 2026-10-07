#!/usr/bin/env bash
# Build only reviewed runtime bytes and the checksum-verified engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
context="$(mktemp -d)"
trap 'rm -rf "$context"' EXIT
cp "$(command -v godot)" "$context/godot"
docker build --pull --file "$root/.github/containers/trusted-regressions.Dockerfile" \
  --tag "world-trusted-regressions:build-$$" "$context" >&2
digest="$(docker image inspect "world-trusted-regressions:build-$$" --format '{{.Id}}')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo '::error::trusted runtime image identity is missing' >&2
  exit 1
}
printf '%s\n' "$digest"
