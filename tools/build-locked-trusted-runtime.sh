#!/usr/bin/env bash
# Run inside the existing build phase so proof validation shares its deadline.
set -euo pipefail
if [ "$#" -ne 5 ]; then exit 2; fi
root="$1" context="$2" mode="$3" tag="$4" policy="$5"
case "$mode:$policy" in 0:locked|1:locked|1:proposal) ;; *) exit 2;; esac
GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-bases/main.go" --check "$root" >&2
GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-packages/main.go" --emit "$root" > "$context/expected-packages.tsv"
if [ "$policy" = locked ]; then
  GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-archives/main.go" --emit "$root" > "$context/expected-archives.json"
else
  # The proposal cannot inherit stale authority. The observer refuses to read this
  # placeholder and publishes evidence only after the authenticated offline install.
  printf '{}\n' > "$context/expected-archives.json"
fi
cp "$root/tools/verify-trusted-runtime-packages.sh" "$context/verify-trusted-runtime-packages.sh"
exec docker build --pull --platform linux/amd64 \
  --file "$root/.github/containers/trusted-regressions.Dockerfile" \
  --build-arg "WAR_RUNTIME_INVENTORY=$mode" \
  --build-arg "WAR_RUNTIME_ARCHIVE_POLICY=$policy" --tag "$tag" "$context"
