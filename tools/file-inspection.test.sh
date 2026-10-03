#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/file-inspection.sh
source "$root/tools/file-inspection.sh"
scratch="$(mktemp -d)"
# macOS temporary roots may contain a symlink; the inspected fixture must
# start at its physical directory without imposing a platform-specific root.
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/real/child"
printf 'ordinary\n' > "$scratch/real/child/data"
ln -s "$scratch/real" "$scratch/linked"
ln -s "$scratch/real/child/data" "$scratch/leaf"
check() {
 local expected="$1" path="$2" got
 got="$(inspect_regular_file "$path")"
 [ "$got" = "$expected" ] || { printf 'file inspection: FAIL %s = %s\n' "$path" "$got" >&2; exit 1; }
}
check ok "$scratch/real/child/data"
check missing "$scratch/absent"
check missing "$scratch/real/child"
check symlink "$scratch/leaf"
check symlink "$scratch/linked/child/data"
(cd "$scratch" && check ok real/child/data && check symlink linked/child/data && check symlink leaf)
printf 'file inspection: PASS — absolute and relative paths, leaf and parent links\n'
