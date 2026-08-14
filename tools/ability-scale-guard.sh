#!/usr/bin/env bash
# Refuses new ability categories that widen the shipped power or throughput
# scale. Category identity is literal: role|effect keys are data, not patterns.
set -euo pipefail

BASE_SHA="${1:-${BASE_SHA:-}}"
BUDGETS=client/tests/data/shipped_class_power.txt
FLOORS=client/tests/data/shipped_class_cycle_floor.txt

if [ -z "$BASE_SHA" ]; then
	printf '::error::BASE_SHA is unset — cannot verify the shipped ability scale\n' >&2
	exit 1
fi
if ! git cat-file -e "$BASE_SHA" 2>/dev/null; then
	printf '::error::base commit %s is not present in the checkout — cannot verify the shipped ability scale\n' "$BASE_SHA" >&2
	exit 1
fi
for ledger in "$BUDGETS" "$FLOORS"; do
	if [ ! -f "$ledger" ]; then
		printf '::error::%s was deleted — the shipped ability scale must remain anchored\n' "$ledger" >&2
		exit 1
	fi
done

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Whitespace is not part of the runtime key/value format. A comments-only
# ledger is a valid empty bootstrap input, so the filter must not abort under
# pipefail when it emits no pairs.
pairs() {
	grep -v '^[[:space:]]*#' | sed 's/[[:space:]]//g' | grep -v '^$' || true
}

base_of() {
	if git cat-file -e "$BASE_SHA:$1" 2>/dev/null; then
		git show "$BASE_SHA:$1" | pairs
	fi
}

contains_key() {
	local key="$1" ledger="$2"
	ABILITY_SCALE_CANDIDATE="$key" awk -F= '
		$1 == ENVIRON["ABILITY_SCALE_CANDIDATE"] { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$ledger"
}

# The introducing commit has no base scale and is the one allowed bootstrap.
base_of "$BUDGETS" >"$scratch/budget-base"
pairs <"$BUDGETS" >"$scratch/budget-head"
if [ -s "$scratch/budget-base" ]; then
	max_budget="$(cut -d= -f2 "$scratch/budget-base" | sort -n | tail -1)"
	while IFS= read -r line; do
		key="${line%%=*}"
		value="${line#*=}"
		if contains_key "$key" "$scratch/budget-base"; then
			continue
		fi
		if [ "$value" -gt "$max_budget" ]; then
			printf '::error::New category [%s] claims power budget %s, above the highest shipped budget (%s) — a new category may not widen the power scale\n' \
				"$key" "$value" "$max_budget" >&2
			exit 1
		fi
	done <"$scratch/budget-head"
fi

base_of "$FLOORS" >"$scratch/floor-base"
pairs <"$FLOORS" >"$scratch/floor-head"
if [ -s "$scratch/floor-base" ]; then
	min_floor="$(cut -d= -f2 "$scratch/floor-base" | sort -n | head -1)"
	while IFS= read -r line; do
		key="${line%%=*}"
		value="${line#*=}"
		if contains_key "$key" "$scratch/floor-base"; then
			continue
		fi
		if [ "$value" -lt "$min_floor" ]; then
			printf '::error::New category [%s] claims cycle floor %sms, below the fastest shipped floor (%sms) — a new category may not widen the throughput scale\n' \
				"$key" "$value" "$min_floor" >&2
			exit 1
		fi
	done <"$scratch/floor-head"
fi
