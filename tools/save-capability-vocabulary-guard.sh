#!/usr/bin/env bash
# Refuse newly writable character-recipe vocabulary unless the published save
# capability advances with it.
#
# Runtime tests prove each shipped registry still agrees with the current
# CharacterFactory, but both sides live in one checkout: a new piece or skin can
# enter both and remain internally consistent while UpdateManifest continues to
# advertise the old write capability. This guard supplies the missing immutable
# anchor by comparing the explicit save-bearing ledgers with the pull request's
# base revision.
#
# Keep WATCHED_LEDGERS explicit. Inferring shipped_*.txt would incorrectly gate
# presentation, creature, balance and schema ledgers that do not add values to a
# player character recipe. docs/design/save-data.md records the full boundary.
set -euo pipefail

MANIFEST='client/scripts/update_manifest.gd'
CAPABILITY_LEDGER='client/tests/data/shipped_save_capability.txt'
WATCHED_LEDGERS=(
	'client/tests/data/shipped_equipment.txt'
	'client/tests/data/shipped_skins.txt'
	'client/tests/data/shipped_piece_slots.txt'
)
SCRATCH_DIR=''

fail() {
	printf 'save-capability vocabulary guard: FAIL — %s\n' "$1" >&2
	exit 1
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}

normalise_vocabulary() {
	local source="$1"
	sed \
		-e '/^[[:space:]]*#/d' \
		-e '/^[[:space:]]*$/d' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' \
		-e 's/[[:space:]][[:space:]]*/ /g' \
		"$source" |
		LC_ALL=C sort -u
}

manifest_capability() {
	local source="$1"
	sed -n \
		's/^[[:space:]]*const[[:space:]][[:space:]]*SAVE_CAPABILITY_WRITES[[:space:]]*:=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
		"$source"
}

ledger_ceiling() {
	local source="$1"
	sed -n \
		's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
		"$source" |
		sort -n |
		tail -n 1
}

read_base_file() {
	local base="$1" path="$2" destination="$3"
	git cat-file -e "$base:$path" 2>/dev/null ||
		fail "$path is absent at base commit $base — refusing an unanchored comparison"
	git show "$base:$path" >"$destination" ||
		fail "could not read $path at base commit $base"
}

main() {
	local base="${BASE_SHA:-}"
	[ -n "$base" ] ||
		fail 'BASE_SHA is unset — cannot tell which persisted vocabulary this change adds'
	git cat-file -e "$base^{commit}" 2>/dev/null ||
		fail "base commit $base is not present in the checkout — cannot compare persisted vocabulary"

	[ -f "$MANIFEST" ] || fail "$MANIFEST is missing"
	[ -f "$CAPABILITY_LEDGER" ] || fail "$CAPABILITY_LEDGER is missing"

	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT

	read_base_file "$base" "$MANIFEST" "$SCRATCH_DIR/base-manifest"
	read_base_file "$base" "$CAPABILITY_LEDGER" "$SCRATCH_DIR/base-capability-ledger"

	local base_capability head_capability
	local base_ledger_capability head_ledger_capability
	base_capability="$(manifest_capability "$SCRATCH_DIR/base-manifest")"
	head_capability="$(manifest_capability "$MANIFEST")"
	[ -n "$base_capability" ] ||
		fail "SAVE_CAPABILITY_WRITES is unreadable in $MANIFEST at base commit $base"
	[ -n "$head_capability" ] ||
		fail "SAVE_CAPABILITY_WRITES is unreadable in $MANIFEST"

	base_ledger_capability="$(ledger_ceiling "$SCRATCH_DIR/base-capability-ledger")"
	head_ledger_capability="$(ledger_ceiling "$CAPABILITY_LEDGER")"
	[ -n "$base_ledger_capability" ] ||
		fail "$CAPABILITY_LEDGER has no readable capability at base commit $base"
	[ -n "$head_ledger_capability" ] ||
		fail "$CAPABILITY_LEDGER has no readable capability"
	[ "$base_capability" = "$base_ledger_capability" ] ||
		fail "base SAVE_CAPABILITY_WRITES is $base_capability but shipped_save_capability.txt ends at $base_ledger_capability"
	[ "$head_capability" = "$head_ledger_capability" ] ||
		fail "SAVE_CAPABILITY_WRITES is $head_capability but shipped_save_capability.txt ends at $head_ledger_capability"

	local ledger name additions
	for ledger in "${WATCHED_LEDGERS[@]}"; do
		name="${ledger##*/}"
		[ -f "$ledger" ] || fail "$ledger is missing"
		read_base_file "$base" "$ledger" "$SCRATCH_DIR/base-$name"
		normalise_vocabulary "$SCRATCH_DIR/base-$name" >"$SCRATCH_DIR/base-normalised-$name"
		normalise_vocabulary "$ledger" >"$SCRATCH_DIR/head-normalised-$name"
		additions="$(comm -13 "$SCRATCH_DIR/base-normalised-$name" "$SCRATCH_DIR/head-normalised-$name")"
		[ -z "$additions" ] && continue
		if [ "$head_capability" -le "$base_capability" ]; then
			fail "$name gained persisted vocabulary ($(printf '%s' "$additions" | tr '\n' ' ')) but SAVE_CAPABILITY_WRITES did not advance beyond $base_capability. Follow expand -> bake -> contract: land reader support without exposing the value to production writers, retain that reader, then add writable vocabulary and advance the capability ledger."
		fi
	done

	printf 'save-capability vocabulary guard: PASS — watched ledgers are compatible with write capability %s\n' \
		"$head_capability"
}

main "$@"
