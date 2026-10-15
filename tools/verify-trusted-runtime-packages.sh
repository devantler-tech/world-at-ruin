#!/usr/bin/env bash
# No executor is returned until a complete installed observation equals the lock.
set -euo pipefail
export LC_ALL=C
[ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ] || exit 1
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
architecture="$(dpkg --print-architecture)"
[ "$architecture" = amd64 ]
dpkg-query -W -f='package\t${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' > "$state/raw"
sort "$state/raw" > "$state/sorted"
if ! cmp -s "$1" "$state/sorted"; then
  echo 'trusted runtime installed package identities differ from the reviewed lock' >&2
  exit 1
fi
count="$(wc -l < "$state/sorted")"
printf 'TRUSTED_RUNTIME_PACKAGES verified=%s architecture=amd64\n' "${count//[[:space:]]/}"
