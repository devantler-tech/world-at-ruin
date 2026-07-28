#!/usr/bin/env bash
# Proves the save-capability guard notices newly persistable character
# vocabulary, while leaving presentation-only ledgers and unrelated capability
# advances alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/save-capability-vocabulary-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0

t_fail() {
	printf 'save-capability vocabulary guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"

mkdir -p \
	"$repo/client/scripts" \
	"$repo/client/tests/data"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t

write_manifest() {
	printf 'class_name UpdateManifest\nconst SAVE_CAPABILITY_WRITES := %s\n' "$1" \
		>"$repo/client/scripts/update_manifest.gd"
}

write_capability_ledger() {
	{
		printf '# shipped save capabilities\n'
		for capability in $(seq 1 "$1"); do
			printf '%s\n' "$capability"
		done
	} >"$repo/client/tests/data/shipped_save_capability.txt"
}

write_manifest 3
write_capability_ledger 3
printf '# persisted piece names\nshirt_ragged\n' \
	>"$repo/client/tests/data/shipped_equipment.txt"
printf '# persisted skin names\nskin_male_light\n' \
	>"$repo/client/tests/data/shipped_skins.txt"
printf '# persisted piece-to-slot pairs\nshirt_ragged torso\n' \
	>"$repo/client/tests/data/shipped_piece_slots.txt"
printf '# presentation-only creature tints\nash\n' \
	>"$repo/client/tests/data/shipped_creature_tints.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

commit_all() {
	git -C "$repo" add -A
	git -C "$repo" commit -qm "$1"
}

run_guard() {
	local out rc=0
	out="$(cd "$repo" && BASE_SHA="$base" bash "$GUARD" 2>&1)" || rc=$?
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
	local label="$1" needle="$2" guidance="${3:-}" out rc=0
	out="$(run_guard)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected a refusal, but the guard passed"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	elif [ -n "$guidance" ] && ! printf '%s' "$out" | grep -qF "$guidance"; then
		t_fail "$label: refusal omitted the required '$guidance' rollout guidance: $out"
	fi
}

# RED: a new selectable equipment name can enter a character save, so leaving
# capability 3 in place would let an older capability-3 rollback reject it.
reset_tree
printf 'boots_worn\n' >>"$repo/client/tests/data/shipped_equipment.txt"
commit_all 'add persisted equipment without capability'
expect_fail_matching \
	'persisted equipment without a capability advance' \
	'shipped_equipment.txt gained persisted vocabulary' \
	'expand -> bake -> contract'

# RED: skin names are recipe values too. Keeping this case independent catches
# a guard that watches only the motivating equipment example.
reset_tree
printf 'skin_female_aged\n' >>"$repo/client/tests/data/shipped_skins.txt"
commit_all 'add persisted skin without capability'
expect_fail_matching \
	'persisted skin without a capability advance' \
	'shipped_skins.txt gained persisted vocabulary'

# RED: the recipe persists the slot key as well as the selected piece. A new
# legal piece-to-slot pair is therefore a newly persistable promise even when
# both individual names already existed.
reset_tree
printf 'shirt_ragged shoulders\n' \
	>>"$repo/client/tests/data/shipped_piece_slots.txt"
commit_all 'add persisted piece-slot pair without capability'
expect_fail_matching \
	'persisted piece-slot pair without a capability advance' \
	'shipped_piece_slots.txt gained persisted vocabulary'

# GREEN: the contract rollout advances the writer and appends the matching
# capability ledger line in the same change.
reset_tree
printf 'boots_worn\n' >>"$repo/client/tests/data/shipped_equipment.txt"
write_manifest 4
write_capability_ledger 4
commit_all 'add persisted equipment with capability'
expect_pass 'persisted vocabulary with a complete capability advance'

# RED: changing the constant alone is not a durable capability declaration.
reset_tree
printf 'boots_worn\n' >>"$repo/client/tests/data/shipped_equipment.txt"
write_manifest 4
commit_all 'advance constant without capability ledger'
expect_fail_matching \
	'capability constant without its ledger line' \
	'SAVE_CAPABILITY_WRITES is 4 but shipped_save_capability.txt ends at 3'

# GREEN negative control: creature tint recipes are generated world content,
# not values the player character save can originate. Broadly watching every
# shipped_*.txt ledger would turn ordinary presentation additions into rollout
# noise and teach contributors to bypass the guard.
reset_tree
printf 'ember\n' >>"$repo/client/tests/data/shipped_creature_tints.txt"
commit_all 'add presentation-only creature tint'
expect_pass 'presentation-only vocabulary'

# GREEN negative control: comments and whitespace do not become save values.
reset_tree
printf '# provenance note only\n' \
	>>"$repo/client/tests/data/shipped_equipment.txt"
commit_all 'document persisted equipment ledger'
expect_pass 'comment-only ledger change'

# GREEN: capabilities also advance for new persisted shapes and vault schema
# fields. This guard owns the implication from vocabulary to capability, not
# the reverse implication.
reset_tree
write_manifest 4
write_capability_ledger 4
commit_all 'advance capability for a non-vocabulary persistence change'
expect_pass 'capability advance without vocabulary growth'

# Fail closed when the immutable comparison anchor is unavailable.
missing_base_out="$(
	(cd "$repo" && BASE_SHA=0000000000000000000000000000000000000000 bash "$GUARD" 2>&1) ||
		true
)"
printf '%s' "$missing_base_out" | grep -qF 'is not present in the checkout' ||
	t_fail "an absent base commit was not refused: $missing_base_out"

unset_base_out="$( (cd "$repo" && BASE_SHA='' bash "$GUARD" 2>&1) || true )"
printf '%s' "$unset_base_out" | grep -qF 'BASE_SHA is unset' ||
	t_fail "an unset BASE_SHA was not refused: $unset_base_out"

# A correct guard that CI never runs protects nothing.
grep -Fq 'tools/save-capability-vocabulary-guard.sh' "$WORKFLOW" ||
	t_fail 'CI does not run the save-capability vocabulary guard'
grep -Fq 'tools/save-capability-vocabulary-guard.test.sh' "$WORKFLOW" ||
	t_fail 'CI does not run this guard test'

if [ "$failures" -ne 0 ]; then
	printf 'save-capability vocabulary guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'save-capability vocabulary guard test: PASS\n'
