#!/usr/bin/env bash
# Produce review evidence and an archive-lock proposal from one disposable cold build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$#" -ne 1 ] || [[ "$1" != /* ]]; then exit 2; fi
destination="$1"
parent="$(dirname "$destination")"
if [ -e "$destination" ] || [ -L "$destination" ] || [ ! -d "$parent" ] || [ -L "$parent" ]; then exit 2; fi
state="$(mktemp -d)"
cleanup() {
  local status=$?
  local cleanup_image=""
  if [ -s "$state/image" ] && [ ! -L "$state/image" ] && [ "$(wc -l < "$state/image")" -eq 1 ]; then
    cleanup_image="$(cat "$state/image")"
    if [[ "$cleanup_image" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      docker image rm "$cleanup_image" >/dev/null 2>&1 || status=1
    fi
  fi
  rm -rf "$state" || status=1
  exit "$status"
}
trap cleanup EXIT

if ! WAR_TRUSTED_RUNTIME_INVENTORY=1 WAR_TRUSTED_RUNTIME_ARCHIVE_PROPOSAL=1 \
  bash "$root/tools/build-trusted-regression-runtime.sh" > "$state/image" 2> "$state/build.log"; then
  cat "$state/build.log" >&2
  exit 1
fi
cat "$state/build.log" >&2
if [ "$(grep -c '^TRUSTED_RUNTIME_INVENTORY ' "$state/build.log")" -ne 1 ]; then
  echo 'archive proposal requires exactly one complete inventory report' >&2
  exit 1
fi
sed -n 's/^TRUSTED_RUNTIME_INVENTORY //p' "$state/build.log" > "$state/report.json"
if [ ! -s "$state/report.json" ] || [ "$(wc -c < "$state/report.json")" -gt 2097152 ]; then exit 1; fi
image="$(cat "$state/image")"
if ! [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || [ "$(wc -l < "$state/image")" -ne 1 ]; then exit 1; fi
if ! GOTOOLCHAIN=local GOWORK=off go run "$root/tools/trusted-runtime-archives/main.go" \
  --from-report "$state/report.json" "$root" > "$state/trusted-runtime-archives.lock.json"; then
  exit 1
fi
if [ ! -s "$state/trusted-runtime-archives.lock.json" ] || [ "$(wc -c < "$state/trusted-runtime-archives.lock.json")" -gt 2097152 ]; then exit 1; fi

mkdir -m 0700 "$destination"
install -m 0644 "$state/report.json" "$destination/report.json"
install -m 0644 "$state/image" "$destination/source-image.txt"
install -m 0644 "$state/trusted-runtime-archives.lock.json" "$destination/trusted-runtime-archives.lock.json"
printf 'trusted runtime archive proposal written to %s\n' "$destination"
