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

# Run the guard in a scratch tree; expect it to ACCEPT. Asserts the PASS line
# rather than the exit status alone, so a zero exit with unexpected output cannot
# be read as acceptance.
expect_pass() {
	local dir="$1" what="$2"
	local output status=0
	output="$(cd "${dir}" && ./"${GUARD_REL}" 2>&1)" || status=$?
	if [ "${status}" -ne 0 ]; then
		fail "${what}: the guard REFUSED valid input. Got: ${output}"
		return
	fi
	case "${output}" in
	*PASS*) ;;
	*) fail "${what}: exited 0 without a PASS line, got: ${output}" ;;
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
# Matched WITHOUT a `\t` escape or an anchor: BSD grep reads `\t` as a tab and
# GNU grep reads it as a literal `t`, so an indented pattern written that way
# matches on macOS, matches nothing in CI, and leaves the case proving nothing.
# This substring occurs exactly once.
grep -v '"schema": SCHEMA,' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
# The needle is the guard's own distinctive phrase, NOT the bare word `schema`:
# the shape reference declares `save_schema` and `save_schema.min`, so a bare
# match would also be satisfied by an unrelated refusal that merely lists one of
# those paths — the case would then pass while reporting a failure it did not
# cause, which is the exact defect this file's header sets out to prevent.
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'manifest lost schema'; then
	expect_refusal "${dir}" 'reads first' 'manifest lost schema'
fi
rm -rf "${dir}"

# --- the ledger must actually explain, and only while it can see ---

# An empty reason satisfies a field-count test while accounting for nothing.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "signature" { print $1, ""; next } { print }' \
	"${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'withheld field carries an empty reason'; then
	expect_refusal "${dir}" 'no explanation' 'withheld field carries an empty reason'
fi
rm -rf "${dir}"

# A deferred block fed by an expression is invisible to this parser, so the row
# excusing its contents would go on excusing fields nobody can see — passing most
# confidently at the moment delivery switches on.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's/"rollback_targets": \[\],/"rollback_targets": build_targets(),/' \
	"${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'deferred block stopped being a literal'; then
	expect_refusal "${dir}" 'rollback_targets' 'deferred block stopped being a literal'
fi
rm -rf "${dir}"

# --- the regression that motivated tracking array frames ---

# A rollback catalogue with MORE THAN ONE element must keep every element's
# fields UNDER the array key. Popping the array key with the first element's
# closing brace emits the second element's fields at the manifest root instead.
#
# The needle is what distinguishes the two parsers. With the array frame held,
# the refusal is about `rollback_targets.version` — a deferred block that started
# publishing. With the key popped, the second element's fields land at the root
# and the refusal instead names a bare `version`/`url` as undocumented, never
# mentioning the qualified path.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
awk '
	/"rollback_targets": \[\],/ {
		print "\t\t\t\"rollback_targets\": ["
		print "\t\t\t\t{"
		print "\t\t\t\t\t\"version\": \"0.1.13\","
		print "\t\t\t\t\t\"url\": \"u1\","
		print "\t\t\t\t},"
		print "\t\t\t\t{"
		print "\t\t\t\t\t\"version\": \"0.1.12\","
		print "\t\t\t\t\t\"url\": \"u2\","
		print "\t\t\t\t},"
		print "\t\t\t],"
		next
	}
	{ print }
' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'multi-element rollback catalogue'; then
	expect_refusal "${dir}" 'rollback_targets.version' 'multi-element rollback catalogue'
fi
rm -rf "${dir}"

# --- inputs where `#` is not a comment ---

# A `#` inside a quoted manifest value. Stripping comments line-wide before the
# quote-aware scan cuts the string short, takes the terminating `,` with it, and
# the field silently vanishes from the guard's view — measured: `channel`
# disappeared, leaving 20 paths instead of 21, with no error anywhere.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's|"channel": CHANNEL,|"channel": "live#anchor",|' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'hash inside a quoted value'; then
	expect_pass "${dir}" 'hash inside a quoted value'
fi
rm -rf "${dir}"

# A backslash-escaped quote inside a manifest value. Ending the token at the
# escaped quote leaves the rest of the string scanned as structure, where its
# punctuation desynchronizes depth and fields land under the wrong parent.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's|"channel": CHANNEL,|"channel": "li\\"ve, }] #x",|' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'escaped quote inside a value'; then
	expect_pass "${dir}" 'escaped quote inside a value'
fi
rm -rf "${dir}"

# A `#` inside a ledger REASON is free text, not a comment. Issue references are
# the common case, and truncating there can empty a reason that was written.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
printf 'shell_authorization\tblocked on the offline root #490 and nothing else\n' \
	>"${dir}/extra"
grep -v '^shell_authorization	' "${dir}/before" >"${dir}/kept"
cat "${dir}/kept" "${dir}/extra" >"${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'hash inside a ledger reason'; then
	expect_pass "${dir}" 'hash inside a ledger reason'
fi
rm -rf "${dir}"

# --- overlapping ledger rows ---

# Two rows may legitimately cover the same field — a narrower `key.epoch` nested
# under the broader `key`, where NEITHER is published. Recording only the first
# match would leave the other looking unused, and the stale-row check would
# refuse while naming a row that is entirely correct.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
printf 'key.epoch\ta narrower row nested under the broader key row\n' >>"${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'overlapping ledger rows'; then
	expect_pass "${dir}" 'overlapping ledger rows'
fi
rm -rf "${dir}"

# A row may only excuse what is actually withheld. Once the block publishes one
# of those fields the row is excusing shipping content, and the guard would
# report agreement about something nobody checked.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
awk '
	/"rollback_targets": \[\],/ {
		print "\t\t\t\"rollback_targets\": ["
		print "\t\t\t\t{"
		print "\t\t\t\t\t\"version\": \"0.1.13\","
		print "\t\t\t\t},"
		print "\t\t\t],"
		next
	}
	{ print }
' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'deferred block started publishing'; then
	expect_refusal "${dir}" 'rollback_targets.version' 'deferred block started publishing'
fi
rm -rf "${dir}"

# --- constructs the parser cannot resolve must fail closed ---

# A CALL whose argument is a literal. The `[` belongs to the argument, not to the
# key, so treating it as the key's own collection classifies whatever the helper
# returns as readable — and its element fields stay invisible while the row
# excuses them.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's/"rollback_targets": \[\],/"rollback_targets": build_targets([]),/' \
	"${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'call with a literal argument'; then
	expect_refusal "${dir}" 'rollback_targets' 'call with a literal argument'
fi
rm -rf "${dir}"

# A key named by an identifier rather than a quoted string. GDScript allows it,
# and the field would ship entirely invisible to every check here.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
sed 's/"schema": SCHEMA,/SMUGGLED_KEY: 1,\
\t\t\t"schema": SCHEMA,/' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'computed manifest key'; then
	expect_refusal "${dir}" 'SMUGGLED_KEY' 'computed manifest key'
fi
rm -rf "${dir}"

# The literal bound to a local instead of returned. It can then be mutated before
# it is returned, and the emitter's canonical-form test cannot catch that either:
# a builder-side addition moves both sides of its comparison together.
dir="$(scratch_tree)"
cp "${dir}/${MANIFEST_REL}" "${dir}/before"
awk '/^\treturn \{$/ && !seen { print "\tvar built := {"; seen = 1; next } { print }' \
	"${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${MANIFEST_REL}"
if assert_changed "${dir}/before" "${dir}/${MANIFEST_REL}" 'literal not returned directly'; then
	expect_refusal "${dir}" 'not returned directly' 'literal not returned directly'
fi
rm -rf "${dir}"

# An emptied ledger must not be refused merely for being empty — that is the
# valid end state once every documented field has graduated. It must still be
# refused for the fields it no longer explains, BY NAME.
dir="$(scratch_tree)"
cp "${dir}/${LEDGER_REL}" "${dir}/before"
grep '^#' "${dir}/before" >"${dir}/mutated"
mv "${dir}/mutated" "${dir}/${LEDGER_REL}"
if assert_changed "${dir}/before" "${dir}/${LEDGER_REL}" 'emptied ledger'; then
	expect_refusal "${dir}" 'does not explain' 'emptied ledger'
	emptied_output="$(cd "${dir}" && ./"${GUARD_REL}" 2>&1 || true)"
	case "${emptied_output}" in
	*"lists no fields"*)
		fail "emptied ledger: refused for being empty rather than for the fields it stopped explaining — an empty ledger is the valid fully-graduated end state"
		;;
	esac
fi
rm -rf "${dir}"

if [ "${failures}" -ne 0 ]; then
	echo "update-manifest shape guard test: ${failures} FAILED" >&2
	exit 1
fi
echo "update-manifest shape guard test: PASS — drift in either direction is refused, the ledger must stay complete, current and actually explanatory, a row may not excuse a field the build publishes, every element of a multi-element array is attributed to its array key, a block that stops being a literal refuses rather than being excused unseen, '#' is treated as a comment only where it is one, and a misread field set refuses instead of passing vacuously"
