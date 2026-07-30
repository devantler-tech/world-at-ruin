#!/usr/bin/env bash
# Keep every shipped Google identity-binding schema and identity address
# reachable by preserving their exact historical contracts across revisions.
set -euo pipefail

LEDGER='server/nakamaauth/testdata/shipped_google_binding_versions.txt'
GOLDEN_PREFIX='server/nakamaauth/testdata/golden_google_binding_v'
ADDRESS_CONTRACT='server/nakamaauth/testdata/golden_google_identity_address_v1.json'
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

	printf 'Google binding durability guard: PASS — %s shipped schema fixture(s) are unchanged\n' \
		"$(wc -l <"$SCRATCH_DIR/base-versions" | tr -d ' ')"
}

main "$@"
