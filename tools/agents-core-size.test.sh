#!/usr/bin/env bash
# Keep AGENTS.md small enough that every agent lane reads all of it (#1459).
#
# Codex reads at most 32,768 bytes of project instructions and silently drops the
# rest, so a rule past that point is a rule a Codex session never sees. The core
# file therefore has a budget of 29,696 bytes (32 KiB minus room for growth), and
# this check also refuses a core that leaves less than 500 bytes of that budget,
# so the next addition moves text into a guide under docs/agents/ instead of
# quietly reaching the cut. Bytes are counted with `wc -c`, never characters:
# the limit is a byte limit, and this file is full of multi-byte punctuation.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
budget=29696
headroom=500
limit=$((budget - headroom))
failures=0

# Prints the verdict for one file and returns 0 only when it fits with headroom.
check_size() {
	local file="$1" bytes
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		printf 'agents core size: %s is missing or not a regular file\n' "$file" >&2
		return 2
	fi
	bytes="$(wc -c <"$file" | tr -d '[:space:]')"
	if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
		printf 'agents core size: could not measure %s\n' "$file" >&2
		return 2
	fi
	if [ "$bytes" -gt "$limit" ]; then
		printf 'agents core size: %s is %s bytes; the limit is %s (a %s-byte budget minus %s bytes of headroom). Move a section into a guide under docs/agents/ and link it from the core.\n' \
			"$file" "$bytes" "$limit" "$budget" "$headroom" >&2
		return 1
	fi
	printf 'agents core size: %s is %s bytes, %s under the %s-byte limit\n' "$file" "$bytes" "$((limit - bytes))" "$limit"
}

fail() {
	printf 'agents core size test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Positive control: a file exactly at the limit fits.
head -c "$limit" /dev/zero | tr '\0' 'a' >"$scratch/at-limit.md"
check_size "$scratch/at-limit.md" >/dev/null || fail "a ${limit}-byte core was refused"

# Negative controls: one byte into the headroom is refused, and so is a file that
# fits the budget only by character count. Each must fail as a finding (1), not as
# an unreadable input (2).
head -c "$((limit + 1))" /dev/zero | tr '\0' 'a' >"$scratch/into-headroom.md"
status=0
check_size "$scratch/into-headroom.md" 2>/dev/null || status=$?
[ "$status" -eq 1 ] || fail "a core one byte into the headroom was not refused (exit ${status})"

# 9,800 three-byte em dashes: 9,800 characters but 29,400 bytes.
for _ in $(seq 1 9800); do printf '—'; done >"$scratch/multibyte.md"
status=0
check_size "$scratch/multibyte.md" 2>/dev/null || status=$?
[ "$status" -eq 1 ] || fail "a core over the limit in bytes but not in characters was not refused (exit ${status})"

status=0
check_size "$scratch/absent.md" 2>/dev/null || status=$?
[ "$status" -eq 2 ] || fail "a missing core was not reported as unreadable (exit ${status})"

# The real core.
check_size "$root/AGENTS.md" || fail "AGENTS.md does not fit"

if [ "$failures" -ne 0 ]; then
	exit 1
fi
printf 'TEST PASS — AGENTS.md fits what every agent reads, and the controls refuse an oversized core\n'
