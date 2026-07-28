#!/usr/bin/env bash
# Refuse newly production-writable character-recipe vocabulary unless the
# published save capability advances with it.
#
# Reader registries expand before writing as part of the retained-reader
# rollout, so they are intentionally NOT the anchor. CharacterCreator filters
# those wider registries through character_writer_vocabulary.json. Comparing
# that production resource to the immutable base catches the contract-stage
# exposure and leaves the safe expansion state representable.
set -euo pipefail

MANIFEST='client/scripts/update_manifest.gd'
CAPABILITY_LEDGER='client/tests/data/shipped_save_capability.txt'
WRITER_VOCABULARY='client/registries/character_writer_vocabulary.json'
SCRATCH_DIR=''

fail() {
	printf 'save-capability vocabulary guard: FAIL — %s\n' "$1" >&2
	exit 1
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
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

normalise_writer_vocabulary() {
	local source="$1" destination="$2"
	if ! jq -er '
		def unique_nonempty_strings:
			type == "array"
			and length > 0
			and all(.[]; type == "string" and length > 0)
			and (length == (unique | length));
		if (keys | sort) != ["bone_keys", "equipment", "shapes", "skins"]
			or (.equipment | type) != "object"
			or (.equipment | length) == 0
			or (all(.equipment | to_entries[];
				(.key | length) > 0 and (.value | type) == "string" and (.value | length) > 0) | not)
			or (.skins | unique_nonempty_strings | not)
			or (.shapes | unique_nonempty_strings | not)
			or (.bone_keys | type) != "object"
			or (.bone_keys | keys | sort) != ["bone_girth", "bone_scale", "joint_push"]
			or (all(.bone_keys[]; unique_nonempty_strings) | not)
		then error("invalid character writer vocabulary")
		else
			(.equipment | to_entries[] | "equipment \(.key) -> \(.value)"),
			(.skins[] | "skin \(.)"),
			(.shapes[] | "shape \(.)"),
			(.bone_keys | to_entries[] as $field
				| $field.value[] | "bone_key \($field.key) \(.)")
		end
	' "$source" | LC_ALL=C sort -u >"$destination"; then
		fail "$source is malformed — expected unique non-empty equipment, skin, shape and bone-key vocabulary"
	fi
}

main() {
	local base="${BASE_SHA:-}"
	[ -n "$base" ] ||
		fail 'BASE_SHA is unset — cannot tell which production vocabulary this change exposes'
	git cat-file -e "$base^{commit}" 2>/dev/null ||
		fail "base commit $base is not present in the checkout — cannot compare production vocabulary"

	[ -f "$MANIFEST" ] || fail "$MANIFEST is missing"
	[ -f "$CAPABILITY_LEDGER" ] || fail "$CAPABILITY_LEDGER is missing"
	[ -f "$WRITER_VOCABULARY" ] || fail "$WRITER_VOCABULARY is missing"

	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT

	read_base_file "$base" "$MANIFEST" "$SCRATCH_DIR/base-manifest"
	read_base_file "$base" "$CAPABILITY_LEDGER" "$SCRATCH_DIR/base-capability-ledger"
	normalise_writer_vocabulary "$WRITER_VOCABULARY" "$SCRATCH_DIR/head-vocabulary"

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

	# This PR introduces the writer source of truth after the reader registries
	# have long existed. Once merged, deletion cannot recreate this state: a
	# missing head file fails above, so every future base contains the resource.
	if ! git cat-file -e "$base:$WRITER_VOCABULARY" 2>/dev/null; then
		printf '%s\n' \
			'save-capability vocabulary guard: PASS — establishing the base-comparable writer vocabulary'
		return 0
	fi

	read_base_file "$base" "$WRITER_VOCABULARY" "$SCRATCH_DIR/base-vocabulary-raw"
	normalise_writer_vocabulary "$SCRATCH_DIR/base-vocabulary-raw" "$SCRATCH_DIR/base-vocabulary"

	local additions
	additions="$(comm -13 "$SCRATCH_DIR/base-vocabulary" "$SCRATCH_DIR/head-vocabulary")"
	if [ -n "$additions" ] && [ "$head_capability" -le "$base_capability" ]; then
		local writable
		writable="$(printf '%s\n' "$additions" | sed 's/$/ became writable/' | tr '\n' '; ')"
		fail "production writer vocabulary gained ($writable) but SAVE_CAPABILITY_WRITES did not advance beyond $base_capability. Follow expand -> bake -> contract: land reader support without exposing the value, retain that reader, then add the value to $WRITER_VOCABULARY and advance the capability ledger."
	fi

	printf 'save-capability vocabulary guard: PASS — production vocabulary is compatible with write capability %s\n' \
		"$head_capability"
}

main "$@"
