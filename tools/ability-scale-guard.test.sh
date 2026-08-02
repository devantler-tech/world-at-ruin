#!/usr/bin/env bash
# Proves new ability categories are compared to shipped categories by literal
# role|effect key before their power and throughput scale is accepted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/ability-scale-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0

t_fail() {
	printf 'ability scale guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
data="$repo/client/tests/data"
mkdir -p "$data"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t

write_base_ledgers() {
	printf '%s\n' 'damage|damage=100' >"$data/shipped_class_power.txt"
	printf '%s\n' 'damage|damage=1000' >"$data/shipped_class_cycle_floor.txt"
}

write_base_ledgers
git -C "$repo" add client/tests/data
git -C "$repo" commit -qm 'ship initial ability scale'
base="$(git -C "$repo" rev-parse HEAD)"

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

run_guard() {
	local out rc=0
	out="$(cd "$repo" && "$GUARD" "$base" 2>&1)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

expect_pass() {
	local label="$1" out rc=0
	out="$(run_guard)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		t_fail "$label: expected a pass, got rc=$rc: $out"
	fi
}

expect_fail_matching() {
	local label="$1" needle="$2" out rc=0
	out="$(run_guard)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected a refusal, but the guard passed"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

if [ ! -x "$GUARD" ]; then
	t_fail 'production ability scale guard is missing or not executable'
else
	expect_pass 'unchanged shipped categories'

	# This is the production break: regex membership reads this key as a
	# pattern matching damage|damage, so the new over-budget category is skipped.
	reset_tree
	printf '%s\n' 'damage|damage.*=101' >>"$data/shipped_class_power.txt"
	expect_fail_matching 'metacharacter power key' 'above the highest shipped budget'

	reset_tree
	printf '%s\n' 'damage|damage.*=999' >>"$data/shipped_class_cycle_floor.txt"
	expect_fail_matching 'metacharacter cycle key' 'below the fastest shipped floor'

	# Literal comparison must not buy safety by rejecting every addition.
	reset_tree
	printf '%s\n' 'healer|healing=100' >>"$data/shipped_class_power.txt"
	printf '%s\n' 'healer|healing=1000' >>"$data/shipped_class_cycle_floor.txt"
	expect_pass 'in-scale new category'

	missing_out="$(cd "$repo" && "$GUARD" 0000000000000000000000000000000000000000 2>&1)" &&
		missing_rc=0 || missing_rc=$?
	if [ "$missing_rc" -eq 0 ] ||
		! printf '%s' "$missing_out" | grep -qF 'is not present in the checkout'; then
		t_fail "missing base commit did not fail closed: $missing_out"
	fi
fi

grep -Fq './tools/ability-scale-guard.test.sh' "$WORKFLOW" ||
	t_fail 'CI does not run the ability scale guard regression'
grep -Fq './tools/ability-scale-guard.sh "$BASE_SHA"' "$WORKFLOW" ||
	t_fail 'CI does not run the production ability scale guard'

if [ "$failures" -ne 0 ]; then
	printf 'ability scale guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'ability scale guard test: PASS\n'
