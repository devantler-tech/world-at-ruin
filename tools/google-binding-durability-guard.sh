#!/usr/bin/env bash
# Preserve every server schema ledger and its historical fixtures against the
# reviewed base. Store tests separately prove that production readers preserve
# those documents. This entry point is shared by local validation and Server CI.
set -euo pipefail
export LC_ALL=C

ADDRESS_CONTRACT='server/nakamaauth/testdata/golden_google_identity_address_v1.json'
SCRATCH_DIR=''

# fail prints the supplied refusal reason to stderr and exits unsuccessfully.
fail() {
	printf 'Server save durability guard: FAIL — %s\n' "$1" >&2
	exit 1
}

# cleanup removes only this invocation's temporary comparison files on exit.
cleanup() {
	if [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
		rm -rf "$SCRATCH_DIR"
	fi
}

# require_file refuses missing paths and symbolic links in any path component.
require_file() {
	local path="$1" part="$1"
	[ -f "$path" ] || fail "$path was deleted or is missing"
	while [ "$part" != "${part%/*}" ]; do
		[ ! -L "$part" ] || fail "$path must not depend on a symbolic link"
		part="${part%/*}"
	done
	[ ! -L "$part" ] || fail "$path must not depend on a symbolic link"
}

# read_versions emits a ledger's consecutive versions or refuses it by label.
read_versions() {
	local file="$1" label="$2"
	# One canonical positive decimal version per line, starting at one. Reject
	# malformed input instead of silently filtering it into an empty history.
	awk '
		$0 !~ /^[1-9][0-9]*$/ || $0 != NR { exit 1 }
		{ print }
		END { if (NR == 0) exit 1 }
	' "$file" || fail "$label has an empty, malformed or non-contiguous schema ledger"
}

# ledger_paths selects conventionally named server ledgers from stdin paths.
ledger_paths() {
	awk '/^server\/([a-zA-Z0-9_-]+\/)+testdata\/shipped_[a-z0-9_]+_versions\.txt$/ { print }'
}

# validate_fixture requires one object or a nonempty object array at the given schema.
validate_fixture() {
	local golden="$1" version="$2"
	require_file "$golden"
	# A fixture is exactly one document, or a nonempty set of shapes for the
	# same schema. Domain validity and zero-loss reads belong to the store tests.
	jq -e -s --argjson version "$version" '
		def document: type == "object" and .schema == $version;
		length == 1 and (.[0] |
			if type == "array" then length > 0 and all(.[]; document)
			else document end)
	' "$golden" >/dev/null 2>&1 || fail "$golden is not a complete schema-$version fixture"
}

# guard_family validates one ledger's fixtures and preserves its base history.
guard_family() {
	local base="$1" ledger="$2" stem prefix version golden
	require_file "$ledger"
	read_versions "$ledger" "$ledger" >"$SCRATCH_DIR/head-versions"
	stem="${ledger##*/shipped_}"
	stem="${stem%_versions.txt}"
	prefix="${ledger%/*}/golden_${stem}_v"
	while IFS= read -r version; do
		validate_fixture "${prefix}${version}.json" "$version"
	done <"$SCRATCH_DIR/head-versions"

	if ! grep -Fxq "$ledger" "$SCRATCH_DIR/base-ledgers"; then
		return
	fi
	git show "$base:$ledger" >"$SCRATCH_DIR/base-ledger" ||
		fail "could not read $ledger at base commit $base"
	read_versions "$SCRATCH_DIR/base-ledger" "$ledger at base" >"$SCRATCH_DIR/base-versions"
	while IFS= read -r version; do
		grep -Fxq "$version" "$SCRATCH_DIR/head-versions" ||
			fail "$ledger removed shipped schema $version"
		golden="${prefix}${version}.json"
		git show "$base:$golden" >"$SCRATCH_DIR/base-golden" ||
			fail "$golden is missing or unreadable at base commit $base"
		cmp -s "$SCRATCH_DIR/base-golden" "$golden" ||
			fail "$golden changed after it shipped — historical fixtures are immutable"
	done <"$SCRATCH_DIR/base-versions"
}

# register_persisted_families binds each collection literal to its own ledger.
# A sibling mapping names the collection explicitly because collection names and
# family names differ. Mappings become immutable once present in the reviewed base.
register_persisted_families() {
	local base="$1" file dir name ledger mapping collection_pattern
	# Go raw strings use literal backticks, not shell command substitution.
	# shellcheck disable=SC2016
	collection_pattern='"world_at_ruin_[a-z0-9_]+"|`world_at_ruin_[a-z0-9_]+`'
	: >"$SCRATCH_DIR/registrations"
	while IFS= read -r ledger; do
		mapping="${ledger%_versions.txt}_collection.txt"
		require_file "$mapping"
		name="$(awk '
			NR != 1 || $0 !~ /^world_at_ruin_[a-z0-9_]+$/ { exit 1 }
			{ print }
			END { if (NR != 1) exit 1 }
		' "$mapping")" || fail "$mapping has an empty or malformed collection mapping"
		if grep -Fxq "$mapping" "$SCRATCH_DIR/base-paths"; then
			git show "$base:$mapping" >"$SCRATCH_DIR/base-mapping" ||
				fail "could not read $mapping at base commit $base"
			cmp -s "$SCRATCH_DIR/base-mapping" "$mapping" ||
				fail "$mapping collection mapping changed after it shipped"
		fi
		dir="${ledger%/testdata/*}"
		printf '%s\t%s\n' "$dir" "$name" >>"$SCRATCH_DIR/registrations"
	done <"$SCRATCH_DIR/head-ledgers"
	awk '!seen[$0]++ { next } { exit 1 }' "$SCRATCH_DIR/registrations" ||
		fail 'a collection is registered by multiple schema ledgers in the same package'

	# Inspect every double-quoted or raw collection literal in production files,
	# including multiple occurrences on one line. This lexical check does not
	# evaluate dynamically constructed collection names; store review covers those.
	while IFS= read -r file; do
		[ -f "$file" ] || continue
		dir="${file%/*}"
		while IFS= read -r name; do
			grep -Fxq "$(printf '%s\t%s' "$dir" "$name")" "$SCRATCH_DIR/registrations" ||
				fail "$dir names Nakama collection $name but registers no schema ledger for that collection ($dir/testdata/shipped_<family>_collection.txt) — every persisted server family must join this gate"
		done < <(grep -oE "$collection_pattern" "$file" | tr -d '"`' | sort -u)
	done < <(awk '/^server\/.*\.go$/ && !/_test\.go$/ { print }' "$SCRATCH_DIR/head-paths")
}

# main anchors discovery to BASE_SHA and checks every base or candidate family.
main() {
	local base="${BASE_SHA:-}" ledger count=0
	[ -n "$base" ] || fail 'BASE_SHA is unset — cannot anchor shipped server schemas'
	base="$(git rev-parse --verify "$base^{commit}" 2>/dev/null)" ||
		fail 'base commit is not present in the checkout'
	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT

	# The base inventory survives deletion of an entire candidate package.
	# Include untracked additions for the same local pre-commit validation path.
	git ls-tree -r --name-only "$base" -- server >"$SCRATCH_DIR/base-paths"
	git ls-files --cached --others --exclude-standard -- server >"$SCRATCH_DIR/head-paths"
	ledger_paths <"$SCRATCH_DIR/base-paths" >"$SCRATCH_DIR/base-ledgers"
	ledger_paths <"$SCRATCH_DIR/head-paths" >"$SCRATCH_DIR/head-ledgers"
	sort -u "$SCRATCH_DIR/base-ledgers" "$SCRATCH_DIR/head-ledgers" >"$SCRATCH_DIR/ledgers"
	[ -s "$SCRATCH_DIR/ledgers" ] || fail 'no server schema ledgers were discovered'
	while IFS= read -r ledger; do
		guard_family "$base" "$ledger"
		count=$((count + 1))
	done <"$SCRATCH_DIR/ledgers"

	# A persisted family is registered by the code that persists it, so a store
	# without a ledger is refused instead of never being discovered.
	register_persisted_families "$base"

	# Identity addressing has its own immutable fixture outside a version ledger.
	require_file "$ADDRESS_CONTRACT"
	if grep -Fxq "$ADDRESS_CONTRACT" "$SCRATCH_DIR/base-paths"; then
		git show "$base:$ADDRESS_CONTRACT" >"$SCRATCH_DIR/base-address" ||
			fail "could not read $ADDRESS_CONTRACT at base commit $base"
		cmp -s "$SCRATCH_DIR/base-address" "$ADDRESS_CONTRACT" ||
			fail "$ADDRESS_CONTRACT identity address contract changed after it shipped"
	elif grep -Fxq 'server/nakamaauth/testdata/shipped_google_binding_versions.txt' "$SCRATCH_DIR/base-ledgers"; then
		fail "$ADDRESS_CONTRACT is missing at base — the shipped identity contract was unanchored"
	fi
	printf 'Server save durability guard: PASS — %d schema families retain their complete history\n' "$count"
}

main "$@"
