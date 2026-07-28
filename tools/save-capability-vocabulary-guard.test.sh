#!/usr/bin/env bash
# Proves the save-capability guard follows production writer exposure, not the
# broader reader-compatibility registries, while leaving presentation-only
# additions and unrelated capability advances alone.
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
	"$repo/client/registries" \
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

write_writer_vocabulary() {
	printf '%s\n' \
		'{' \
		'  "equipment": {"shirt_ragged": "torso"},' \
		'  "skins": ["skin_male_light"],' \
		'  "shapes": ["torso_vshape"],' \
		'  "bone_keys": {' \
		'    "bone_girth": ["calf"],' \
		'    "bone_scale": ["hand"],' \
		'    "joint_push": ["upperarm"]' \
		'  }' \
		'}' \
		>"$repo/client/registries/character_writer_vocabulary.json"
}

rewrite_writer_vocabulary() {
	local filter="$1" tmp="$repo/writer-vocabulary.tmp"
	jq "$filter" "$repo/client/registries/character_writer_vocabulary.json" >"$tmp"
	mv "$tmp" "$repo/client/registries/character_writer_vocabulary.json"
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
git -C "$repo" commit -qm 'base before explicit writer vocabulary'
legacy_base="$(git -C "$repo" rev-parse HEAD)"

write_writer_vocabulary
git -C "$repo" add client/registries/character_writer_vocabulary.json
git -C "$repo" commit -qm 'establish writer vocabulary'
base="$(git -C "$repo" rev-parse HEAD)"

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

commit_all() {
	git -C "$repo" add -A
	git -C "$repo" commit -qm "$1"
}

run_guard_from() {
	local anchor="$1" out rc=0
	out="$(cd "$repo" && BASE_SHA="$anchor" bash "$GUARD" 2>&1)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

run_guard() {
	run_guard_from "$base"
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

expect_command_fail_matching() {
	local label="$1" needle="$2"
	shift 2
	local out rc=0
	out="$("$@" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected a nonzero status, but the command passed: $out"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

# Reader expansion is not writer activation. The compatibility ledger may grow
# while the explicit production allowlist stays put and capability 3 continues
# to write only its baked vocabulary.
reset_tree
printf 'boots_worn\n' >>"$repo/client/tests/data/shipped_equipment.txt"
printf 'boots_worn feet\n' >>"$repo/client/tests/data/shipped_piece_slots.txt"
commit_all 'expand equipment reader without writer exposure'
expect_pass 'reader-only equipment expansion'

reset_tree
printf 'skin_female_aged\n' >>"$repo/client/tests/data/shipped_skins.txt"
commit_all 'expand skin reader without writer exposure'
expect_pass 'reader-only skin expansion'

# Contract-stage exposure is the implication this guard owns.
reset_tree
rewrite_writer_vocabulary '.equipment.boots_worn = "feet"'
commit_all 'expose persisted equipment without capability'
expect_fail_matching \
	'writable equipment without a capability advance' \
	'equipment boots_worn -> feet became writable' \
	'expand -> bake -> contract'

reset_tree
rewrite_writer_vocabulary '.skins += ["skin_female_aged"]'
commit_all 'expose persisted skin without capability'
expect_fail_matching \
	'writable skin without a capability advance' \
	'skin skin_female_aged became writable'

reset_tree
rewrite_writer_vocabulary '.shapes += ["wings_span"]'
commit_all 'expose persisted shape without capability'
expect_fail_matching \
	'writable shape without a capability advance' \
	'shape wings_span became writable'

reset_tree
rewrite_writer_vocabulary '.bone_keys.bone_scale += ["tail"]'
commit_all 'expose persisted bone key without capability'
expect_fail_matching \
	'writable bone key without a capability advance' \
	'bone_key bone_scale tail became writable'

# The contract rollout advances the writer and appends the matching capability
# ledger line in the same change.
reset_tree
rewrite_writer_vocabulary '.equipment.boots_worn = "feet"'
write_manifest 4
write_capability_ledger 4
commit_all 'expose persisted equipment with capability'
expect_pass 'writer exposure with a complete capability advance'

# Changing the constant alone is not a durable capability declaration.
reset_tree
rewrite_writer_vocabulary '.equipment.boots_worn = "feet"'
write_manifest 4
commit_all 'advance constant without capability ledger'
expect_fail_matching \
	'capability constant without its ledger line' \
	'SAVE_CAPABILITY_WRITES is 4 but shipped_save_capability.txt ends at 3'

# Presentation registries are outside the explicit writer boundary.
reset_tree
printf 'ember\n' >>"$repo/client/tests/data/shipped_creature_tints.txt"
commit_all 'add presentation-only creature tint'
expect_pass 'presentation-only vocabulary'

# JSON formatting and key order do not become save values.
reset_tree
rewrite_writer_vocabulary '.'
commit_all 'reformat writer vocabulary'
expect_pass 'format-only writer vocabulary change'

# Capabilities also advance for new persisted shapes and vault schema fields.
# This guard owns vocabulary -> capability, not the reverse implication.
reset_tree
write_manifest 4
write_capability_ledger 4
commit_all 'advance capability for a non-vocabulary persistence change'
expect_pass 'capability advance without vocabulary growth'

# The first PR introduces the explicit source of truth. Absence at the base is
# a one-time anchored baseline, not an empty comparison for an established file.
reset_tree
legacy_out="$(run_guard_from "$legacy_base")" || t_fail "writer-vocabulary baseline introduction failed: $legacy_out"
printf '%s' "$legacy_out" | grep -qF 'establishing the base-comparable writer vocabulary' ||
	t_fail "baseline introduction did not report its one-time state: $legacy_out"

# Fail closed when the immutable commit anchor itself is unavailable, and assert
# status as well as prose so a diagnostic followed by exit 0 cannot pass.
expect_command_fail_matching \
	'an absent base commit' \
	'is not present in the checkout' \
	bash -c "cd '$repo' && BASE_SHA=0000000000000000000000000000000000000000 bash '$GUARD'"
expect_command_fail_matching \
	'an unset BASE_SHA' \
	'BASE_SHA is unset' \
	bash -c "cd '$repo' && BASE_SHA='' bash '$GUARD'"

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
