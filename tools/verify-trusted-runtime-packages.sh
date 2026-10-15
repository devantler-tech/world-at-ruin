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
comparison_status=0
cmp -s "$1" "$state/sorted" || comparison_status=$?
case "$comparison_status" in
  0) ;;
  1)
    echo 'trusted runtime installed package identities differ from the reviewed lock' >&2
    exit 1;;
  *)
    echo 'trusted runtime package comparison could not complete' >&2
    exit 2;;
esac
count="$(wc -l < "$state/sorted")"
printf 'TRUSTED_RUNTIME_PACKAGES verified=%s architecture=amd64\n' "${count//[[:space:]]/}"
