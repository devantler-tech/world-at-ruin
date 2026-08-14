#!/usr/bin/env bash
# Keep every shipped Google identity-binding and handoff-lease schema reachable
# by preserving their exact historical contracts across revisions. The legacy
# filename remains the required Server CI entry point.
set -euo pipefail

LEDGER='server/nakamaauth/testdata/shipped_google_binding_versions.txt'
GOLDEN_PREFIX='server/nakamaauth/testdata/golden_google_binding_v'
ADDRESS_CONTRACT='server/nakamaauth/testdata/golden_google_identity_address_v1.json'
LEASE_LEDGER='server/nakamalease/testdata/shipped_lease_versions.txt'
LEASE_GOLDEN_PREFIX='server/nakamalease/testdata/golden_lease_v'
SCRATCH_DIR=''

fail() {
	printf 'Google binding durability guard: FAIL — %s\n' "$1" >&2
	exit 1
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}

extract_versions() {
	sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" |
		LC_ALL=C sort -u
}

guard_lease_schemas() {
	local base="$1"
	[ -f "$LEASE_LEDGER" ] ||
		fail "$LEASE_LEDGER was deleted — the permanent lease schema ledger must exist"
	extract_versions "$LEASE_LEDGER" >"$SCRATCH_DIR/head-lease-versions"

	if ! git cat-file -e "$base:$LEASE_LEDGER" 2>/dev/null; then
		printf '%s\n' \
			'Lease durability guard: PASS — establishing the base-comparable lease schema ledger'
		return 0
	fi

	git show "$base:$LEASE_LEDGER" >"$SCRATCH_DIR/base-lease-ledger" ||
		fail "could not read $LEASE_LEDGER at base commit $base"
	extract_versions "$SCRATCH_DIR/base-lease-ledger" >"$SCRATCH_DIR/base-lease-versions"
	local removed
	removed="$(comm -23 "$SCRATCH_DIR/base-lease-versions" "$SCRATCH_DIR/head-lease-versions")"
	if [ -n "$removed" ]; then
		fail "shipped lease schema version(s) removed from $LEASE_LEDGER ($(printf '%s' "$removed" | tr '\n' ' '))"
	fi

	local version golden
	while IFS= read -r version; do
		[ -n "$version" ] || continue
		golden="${LEASE_GOLDEN_PREFIX}${version}.json"
		git cat-file -e "$base:$golden" 2>/dev/null ||
			fail "$golden is missing at base commit $base — the shipped lease ledger was unanchored"
		[ -f "$golden" ] ||
			fail "$golden was deleted — a shipped lease must remain readable"
		git show "$base:$golden" >"$SCRATCH_DIR/base-lease-golden-$version" ||
			fail "could not read $golden at base commit $base"
		cmp -s "$SCRATCH_DIR/base-lease-golden-$version" "$golden" ||
			fail "$golden changed after it shipped — historical lease fixtures are immutable"
	done <"$SCRATCH_DIR/base-lease-versions"

	printf 'Lease durability guard: PASS — %s shipped schema fixture(s) are unchanged\n' \
		"$(wc -l <"$SCRATCH_DIR/base-lease-versions" | tr -d ' ')"
}

main() {
	local base="${BASE_SHA:-}"
	[ -n "$base" ] ||
		fail 'BASE_SHA is unset — cannot anchor shipped binding schemas'
	git cat-file -e "$base^{commit}" 2>/dev/null ||
		fail "base commit $base is not present in the checkout"
	[ -f "$LEDGER" ] ||
		fail "$LEDGER was deleted — the permanent binding schema ledger must exist"
	[ -f "$ADDRESS_CONTRACT" ] ||
		fail "$ADDRESS_CONTRACT was deleted — the permanent identity address contract must exist"

	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT
	extract_versions "$LEDGER" >"$SCRATCH_DIR/head-versions"

	# This feature introduces the ledger and its first fixture together. Once
	# merged, base absence can never recur because head deletion fails above.
	if ! git cat-file -e "$base:$LEDGER" 2>/dev/null; then
		guard_lease_schemas "$base"
		printf '%s\n' \
			'Google binding durability guard: PASS — establishing the base-comparable binding schema ledger'
		return 0
	fi

	git show "$base:$LEDGER" >"$SCRATCH_DIR/base-ledger" ||
		fail "could not read $LEDGER at base commit $base"
	git cat-file -e "$base:$ADDRESS_CONTRACT" 2>/dev/null ||
		fail "$ADDRESS_CONTRACT is missing at base commit $base — the identity address contract was unanchored"
	git show "$base:$ADDRESS_CONTRACT" >"$SCRATCH_DIR/base-address-contract" ||
		fail "could not read $ADDRESS_CONTRACT at base commit $base"
	cmp -s "$SCRATCH_DIR/base-address-contract" "$ADDRESS_CONTRACT" ||
		fail "$ADDRESS_CONTRACT identity address contract changed after it shipped"
	extract_versions "$SCRATCH_DIR/base-ledger" >"$SCRATCH_DIR/base-versions"
	local removed
	removed="$(comm -23 "$SCRATCH_DIR/base-versions" "$SCRATCH_DIR/head-versions")"
	if [ -n "$removed" ]; then
		fail "shipped schema version(s) removed from $LEDGER ($(printf '%s' "$removed" | tr '\n' ' '))"
	fi

	local version golden
	while IFS= read -r version; do
		[ -n "$version" ] || continue
		golden="${GOLDEN_PREFIX}${version}.json"
		git cat-file -e "$base:$golden" 2>/dev/null ||
			fail "$golden is missing at base commit $base — the shipped ledger was unanchored"
		[ -f "$golden" ] ||
			fail "$golden was deleted — a shipped identity binding must remain readable"
		git show "$base:$golden" >"$SCRATCH_DIR/base-golden-$version" ||
			fail "could not read $golden at base commit $base"
		cmp -s "$SCRATCH_DIR/base-golden-$version" "$golden" ||
			fail "$golden changed after it shipped — historical identity fixtures are immutable"
	done <"$SCRATCH_DIR/base-versions"
	guard_lease_schemas "$base"

	printf 'Google binding durability guard: PASS — %s shipped schema fixture(s) are unchanged\n' \
		"$(wc -l <"$SCRATCH_DIR/base-versions" | tr -d ' ')"
}

main "$@"
