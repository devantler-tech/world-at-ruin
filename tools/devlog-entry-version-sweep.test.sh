#!/usr/bin/env bash
# Proves tools/devlog-entry-version-sweep.sh --gate refuses exactly the drift it
# claims to, excludes exactly what it says it excludes, and stays a survey when
# it is not asked to be a gate.
#
# Two layers, kept apart on purpose. The decision is driven end-to-end against
# real commits and real tags, because a verdict here is a statement about
# containment and nothing smaller than a tagged history can exercise it; and the
# CI wiring is asserted separately, since a gate that is correct but unwired
# passes every one of its own tests and protects nothing.
#
# Each case builds its OWN repository rather than resetting a shared one. A
# verdict depends on which release first contains an entry's introducing commit,
# so cases have to differ in their TAG history, not just their working tree —
# and tags accumulated by an earlier case would silently change a later one's
# answer.
#
# The sweep resolves its own root from its location and cd's there, so the tools
# are copied into each fixture repo and run from inside it. That is the honest
# end-to-end shape: it is the production file being exercised, against a history
# built for the case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/tools/devlog-entry-version-sweep.sh"
GUARD="$ROOT/tools/devlog-entry-version-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0

t_fail() {
	printf 'dev-log entry version sweep test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# An entry in the shape the real ones use. The version string must appear
# exactly as `"version": "X"`, because that is the needle the sweep anchors on.
entry() {
	printf '{\n\t"date": "2026-07-28",\n\t"notes": [\n\t\t"%s"\n\t],\n\t"title": "The wanderer gains a visible improvement",\n\t"version": "%s"\n}\n' \
		'Stone now breaks into slabs with seams between them, so the surface has edges to catch the light and a sense of scale underfoot.' \
		"$1"
}

# A fresh repository carrying the production tools, with no history yet.
#
# The directory name comes from mktemp rather than a counter: every call site is
# `d="$(new_repo)"`, which runs this in a subshell, so an incremented counter
# would not survive back into the caller and every case would silently reuse one
# repository — inheriting the previous case's tree and tags.
new_repo() {
	local d
	d="$(mktemp -d "$scratch/repoXXXXXX")"
	mkdir -p "$d/tools" "$d/client/devlog"
	cp "$SWEEP" "$GUARD" "$d/tools/"
	git -C "$d" init -q -b main
	git -C "$d" config user.email t@example.com
	git -C "$d" config user.name t
	printf '%s' "$d"
}

# Commit everything staged, and optionally tag the result as a release.
step() {
	local d="$1" msg="$2" tag="${3:-}"
	git -C "$d" add -A
	git -C "$d" commit -qm "$msg"
	[ -n "$tag" ] && git -C "$d" tag "$tag"
	return 0
}

# Runs the sweep inside the fixture, capturing output and status together.
run_sweep() {
	local d="$1"
	shift
	local out rc=0
	out="$(cd "$d" && bash tools/devlog-entry-version-sweep.sh "$@" 2>&1)" || rc=$?
	printf '%s' "$out"
	return $rc
}

expect_gate_pass() {
	local label="$1" d="$2" out rc=0
	out="$(run_sweep "$d" --gate)" || rc=$?
	[ "$rc" -eq 0 ] || t_fail "$label: expected the gate to pass, got rc=$rc: $out"
}

# A refusal that fires for the wrong reason proves nothing, so every expected
# failure is matched on its message as well as on a non-zero status.
#
# Matched through a here-string rather than `printf ... | grep -qF`. Under
# `pipefail` a matching `grep -q` closes the pipe as soon as it decides, which
# can kill the writer with SIGPIPE and make the pipeline report 141 — so a
# successful match reads as a failed one. The writer here is a small builtin
# that finishes first, so the pipe form happens to work, but the here-string has
# no such dependency on output size.
expect_gate_fail() {
	local label="$1" d="$2" needle="$3" out rc=0
	out="$(run_sweep "$d" --gate)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected the gate to refuse, but it passed"
	elif ! grep -qF "$needle" <<<"$out"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

expect_output_matching() {
	local label="$1" out="$2" needle="$3"
	grep -qF "$needle" <<<"$out" ||
		t_fail "$label: wanted '$needle' in the output, got: $out"
}

# --- Layer 1: the decision, against real commits and tags -----------------

# GREEN: an entry naming the release that first contains it. Without this case
# every refusal below could be satisfied by a gate that fails unconditionally.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'an entry that names its own release' v0.2.0
expect_gate_pass 'an entry naming the release that contains it' "$d"

# RED: the drift this gate exists for. The entry names v0.1.0, a release that
# was really cut, but its change first shipped in v0.2.0 — the shape #467
# describes, and the shape that regressed onto main after #452.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.1.0 >"$d/client/devlog/0.1.0.json"
step "$d" 'an entry naming a release cut before its code existed' v0.2.0
# Matched on a phrase unique to the GATE's refusal, not on "name a release that
# does not contain" — the survey summary line above it carries that wording on
# every run, passing or failing, so a needle built from it matches the report
# rather than the decision and would hold however the refusal was worded.
expect_gate_fail 'an entry naming a release that does not contain it' "$d" \
	'The SHIPPED column above'

# GREEN CONTROL, and the criterion the exclusion has to meet: NEVER-CUT alone
# does NOT fail. The entry names 0.9.9, which was never released at all, so it
# is wrong in the sweep's summary and still deliberately excluded from the gate
# while #466 is open. Without this case the gate would be indistinguishable from
# one that fails on every wrong entry, which would gate the whole repo on an
# open decision.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.9.9 >"$d/client/devlog/0.9.9.json"
step "$d" 'an entry naming a version that was never released' v0.2.0
expect_gate_pass 'a NEVER-CUT entry alone' "$d"
# The exclusion is only reviewable if it is visible, so the count is asserted
# rather than inferred from the pass.
expect_output_matching 'the NEVER-CUT exclusion is stated with its count' \
	"$(run_sweep "$d" --gate)" '1 NEVER-CUT entry excluded'

# GREEN: an entry whose change has not shipped yet. This is every open PR's own
# new entry, so a gate that failed here would refuse the entire repository.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'an entry whose release has not been cut yet'
expect_gate_pass 'an entry whose change is not in any release' "$d"

# RED: an entry no verdict could be reached for. "Could not evaluate" must not
# read as "passed" — that is the vacuous pass a shallow fetch would otherwise
# buy, and it is the one failure mode a silent gate shares with a working one.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
printf '{ not json at all\n' >"$d/client/devlog/0.2.0.json"
step "$d" 'an entry that cannot be read' v0.2.0
expect_gate_fail 'an unreadable entry' "$d" 'could not be anchored'

# GREEN: a correction is verified by CONTAINMENT through the corrections file.
# Its own introducing commit would make it MISLABELLED, so this passes only if
# the listed anchor is actually consulted.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
anchor="$(git -C "$d" rev-parse HEAD)"
entry 0.1.0 >"$d/client/devlog/0.1.0.json"
printf 'client/devlog/0.1.0.json\t%s\tthe change it describes first shipped in v0.1.0\n' \
	"$anchor" >"$d/tools/devlog-entry-corrections.tsv"
step "$d" 'a listed correction pointing at the commit it describes' v0.2.0
expect_gate_pass 'a listed correction verified by containment' "$d"

# RED, the discriminating control for the case above: the SAME tree and the SAME
# history with the listing removed must fail. Without it, that pass could come
# from anything in the fixture rather than from the listing being honoured.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.1.0 >"$d/client/devlog/0.1.0.json"
step "$d" 'the same correction, unlisted' v0.2.0
expect_gate_fail 'the same entry without its listing' "$d" \
	'The SHIPPED column above'

# --- Mode separation ------------------------------------------------------
# The survey must stay a survey. It is run by hand to read the whole picture,
# including the NEVER-CUT class, and a non-zero status there would make it
# unusable inside a pipeline.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.1.0 >"$d/client/devlog/0.1.0.json"
step "$d" 'a mislabelled entry' v0.2.0
out="" rc=0
out="$(run_sweep "$d")" || rc=$?
[ "$rc" -eq 0 ] ||
	t_fail "survey mode returned rc=$rc on a mislabelled entry; it must stay a survey: $out"
expect_output_matching 'survey mode still reports the drift it found' "$out" 'MISLABELLED'

# A mistyped flag must not degrade into a silent survey: `--gat` in CI would
# otherwise exit 0 forever and read as a gate that was never enforcing anything.
rc=0
out="$(run_sweep "$d" --gat)" || rc=$?
[ "$rc" -ne 0 ] || t_fail 'an unknown argument was accepted instead of failing closed'
expect_output_matching 'an unknown argument names itself' "$out" "unknown argument"

# --- Layer 2: wiring ------------------------------------------------------
# A correct gate that CI never runs passes everything above and protects
# nothing, so the wiring is asserted rather than assumed. Matched on the flag
# too: running the sweep without --gate would wire in a survey that can never
# fail.
grep -Fq 'tools/devlog-entry-version-sweep.sh --gate' "$WORKFLOW" ||
	t_fail 'CI does not run the dev-log entry version sweep as a gate'
grep -Fq 'tools/devlog-entry-version-sweep.test.sh' "$WORKFLOW" ||
	t_fail 'CI does not run this sweep test'

if [ "$failures" -ne 0 ]; then
	printf 'dev-log entry version sweep test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'dev-log entry version sweep test: PASS\n'
