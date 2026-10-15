#!/usr/bin/env bash
# Run inside the existing build phase so proof validation shares its deadline.
set -euo pipefail
if [ "$#" -ne 4 ]; then exit 2; fi
root="$1" context="$2" mode="$3" tag="$4"
GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-bases/main.go" --check "$root" >&2
GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-packages/main.go" --emit "$root" > "$context/expected-packages.tsv"
cp "$root/tools/verify-trusted-runtime-packages.sh" "$context/verify-trusted-runtime-packages.sh"
exec docker build --pull --platform linux/amd64 \
  --file "$root/.github/containers/trusted-regressions.Dockerfile" \
  --build-arg "WAR_RUNTIME_INVENTORY=$mode" --tag "$tag" "$context"
