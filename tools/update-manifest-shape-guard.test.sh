#!/usr/bin/env bash
# Proves tools/update-manifest-shape-guard.sh actually catches drift between the
# published manifest and its documented shape reference — in BOTH directions.
#
# THE GUARD IS A SUBSET CHECK, WHICH IS EXACTLY THE SHAPE THAT PASSES VACUOUSLY.
# If the field extractor silently matched nothing, "everything emitted is
# documented" would hold forever and the guard would look perfect while proving
# nothing. So the emitter's field set is misread deliberately here — an ambiguous
# anchor, no anchor, and a manifest that lost `schema` — and each case must be
# REFUSED rather than waved through.
#
# EVERY CASE MUTATES A REAL COPY AND ASSERTS THE MUTATION LANDED. A sed pattern
# that quietly matched nothing would leave the tree untouched, the guard would
# pass, and a test asserting only "non-zero exit" would report a clean failure it
# never actually caused. Each case therefore checks the file changed before it
# checks the guard, and then checks the failure MESSAGE NAMES THE FIELD — a guard
# that failed for some unrelated reason must not be read as having caught this.
#
# The positive control runs the same harness over an UNMUTATED copy. Without it a
# broken scratch tree — a missing file, a bad path — would fail every case above
# and look like a perfect score.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_REL='tools/update-manifest-shape-guard.sh'
MANIFEST_REL='client/scripts/update_manifest.gd'
REFERENCE_REL='docs/design/client-update-manifest.example.json'
LEDGER_REL='tools/update-manifest-deferred-fields.tsv'
failures=0

fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

# A throwaway copy of just the files the guard reads.
scratch_tree() {
	local dir
	dir="$(mktemp -d)"
	mkdir -p "${dir}/client/scripts" "${dir}/docs/design" "${dir}/tools"
	cp "${ROOT}/${MANIFEST_REL}" "${dir}/${MANIFEST_REL}"
	cp "${ROOT}/${REFERENCE_REL}" "${dir}/${REFERENCE_REL}"
	cp "${ROOT}/${LEDGER_REL}" "${dir}/${LEDGER_REL}"
	cp "${ROOT}/${GUARD_REL}" "${dir}/${GUARD_REL}"
	chmod +x "${dir}/${GUARD_REL}"
	printf '%s' "${dir}"
}

# Assert a mutation actually changed the file it targeted.
assert_changed() {
	local before="$1" after="$2" what="$3"
	if cmp -s "${before}" "${after}"; then
		fail "${what}: the mutation changed nothing, so the case that follows proves nothing"
		return 1
	fi
	return 0
}

# Run the guard in a scratch tree; expect refusal whose message names `needle`.
expect_refusal() {
	local dir="$1" needle="$2" what="$3"
	local output status=0
	output="$(cd "${dir}" && ./"${GUARD_REL}" 2>&1)" || status=$?
	if [ "${status}" -eq 0 ]; then
		fail "${what}: the guard PASSED — the drift went undetected"
		return
	fi
	case "${output}" in
	*"${needle}"*) ;;
	*)
		fail "${what}: the guard refused, but its message never named '${needle}' — it may have failed for an unrelated reason. Got: ${output}"
		;;
	esac
}

# --- the positive control: the harness itself works ---

control_dir="$(scratch_tree)"
if ! control_output="$(cd "${control_dir}" && ./"${GUARD_REL}" 2>&1)"; then
	fail "positive control: the guard refused an UNMUTATED tree (${control_output}) — every refusal below would be meaningless"
fi
case "${control_output}" in
*PASS*) ;;
*) fail "positive control: expected a PASS line, got: ${control_output}" ;;
esac
rm -rf "${control_dir}"

# --- direction 1: the emitter invents a field the reference never declared ---

dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
awk '
	!done && /"schema"[[:space:]]*:/ { print; print "\t\t\t\"smuggled_field\": 1,"; done = 1; next }
	{ print }
' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'undeclared emitted field'; then
	expect_refusal "${dir}" 'smuggled_field' 'undeclared emitted field'
fi
rm -rf "${dir}"

# --- direction 2: the reference promises a field nothing emits or explains ---

dir="$(scratch_tree)"
cp "${dir}/${REFERENCE_REL}" "${dir}/before"
jq '. + {"unowned_promise": "nothing emits this"}' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${REFERENCE_REL}"
if assert_changed "${dir}/before" "${dir}/${REFERENCE_REL}" 'unowned documented field'; then
	expect_refusal "${dir}" 'unowned_promise' 'unowned documented field'
fi
rm -rf "${dir}"

# --- the ledger must stay both complete and current ---

# A withheld field whose reason was deleted is a silent promise again.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
grep -v '^signature	' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'withheld field lost its reason'; then
	expect_refusal "${dir}" 'signature' 'withheld field lost its reason'
fi
rm -rf "${dir}"

# One row covers a whole withheld block, so losing it must surface the NESTED
# fields too — not just the block's own name. A guard matching entries exactly
# would still refuse here, on `key` alone, and leave every `key.*` field silently
# unexplained.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
grep -v '^key	' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'withheld block lost its reason'; then
	expect_refusal "${dir}" 'key.epoch' 'withheld block lost its reason'
fi
rm -rf "${dir}"

# A row that explains nothing outlived the field it described.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
printf 'retired_field\ta reason for a field that no longer exists\n' >>"${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'stale ledger row'; then
	expect_refusal "${dir}" 'retired_field' 'stale ledger row'
fi
rm -rf "${dir}"

# --- the vacuity guards: a misread field set must REFUSE, never pass ---

# Two multi-line literals: which one is the manifest is no longer decidable.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
awk '
	{ print }
	!done && /"manifest"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ { print "\t\t\"manifest\": {"; done = 1 }
' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'ambiguous manifest literal'; then
	expect_refusal "${dir}" 'exactly one' 'ambiguous manifest literal'
fi
rm -rf "${dir}"

# No multi-line literal at all — the extractor can read nothing.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's/"manifest"\([[:space:]]*\):\([[:space:]]*\){[[:space:]]*$/"manifest"\1:\2{ "schema": 1 }/' \
	"${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'unreadable manifest literal'; then
	expect_refusal "${dir}" 'found 0' 'unreadable manifest literal'
fi
rm -rf "${dir}"

# The manifest lost the field every client reads first.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
grep -v '^\t\t\t"schema": SCHEMA,$' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'manifest lost schema'; then
	expect_refusal "${dir}" 'schema' 'manifest lost schema'
fi
rm -rf "${dir}"

if [ "${failures}" -ne 0 ]; then
	echo "update-manifest shape guard test: ${failures} FAILED" >&2
	exit 1
fi
echo "update-manifest shape guard test: PASS — drift in either direction is refused, the ledger must stay complete and current, and a misread field set refuses instead of passing vacuously"
