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

# A whole report ROW, matched as a pattern. The survey pads its columns to a
# fixed width, so a fixed-string needle for a row would encode that padding and
# break on any column change; and asserting the verdict alone would pass on a
# row that reached it from the wrong anchor. This pins version, anchor, shipped
# and verdict together, which is what makes an anchoring case discriminating.
expect_row() {
	local label="$1" out="$2" pattern="$3"
	grep -qE "$pattern" <<<"$out" ||
		t_fail "$label: no row matching /$pattern/, got: $out"
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

# RED: a NEVER-CUT entry that HAS a one-to-one correction. The entry names
# 0.9.9, never released at all; its change first shipped in v0.2.0, no entry
# occupies that release and no other entry wants it. One honest answer exists, so
# this is drift like any other and the gate must refuse it.
#
# This is the 0.65.17 -> v0.66.1 shape measured on main (#522): an entry authored
# above every release at the time, stranded when a sibling feat: cut the next
# minor. Being never-cut rather than mislabelled is an accident of which number
# the release train skipped, not a reason the log may keep naming a build that
# does not exist.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.9.9 >"$d/client/devlog/0.9.9.json"
step "$d" 'an entry naming a version that was never released' v0.2.0
expect_gate_fail 'a NEVER-CUT entry whose containing release is free and uniquely wanted' "$d" \
	'has one release that contains it and nothing else claims'

# GREEN CONTROL for the UNIQUENESS half of the test, and the case a
# free-file-only rule gets wrong. Two never-cut entries whose changes both first
# shipped in v0.2.0: the destination file does not exist, so "is the target free?"
# alone would call both correctable and demand two entries take one name. They
# genuinely collide, so both stay excluded and the gate passes.
#
# This is the shape of the historical pair #466 had to decide by hand rather than
# rename; without this case the split would degrade into failing every never-cut
# entry, which is the blanket the exclusion existed to prevent.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.9.8 >"$d/client/devlog/0.9.8.json"
entry 0.9.9 >"$d/client/devlog/0.9.9.json"
step "$d" 'two entries naming versions that were never released' v0.2.0
expect_gate_pass 'two NEVER-CUT entries competing for one release' "$d"
expect_output_matching 'both colliding entries are counted as excluded' \
	"$(run_sweep "$d" --gate)" '2 NEVER-CUT entries excluded'

# GREEN CONTROL for the FREE half: the containing release already has an entry.
# 0.9.9's change first shipped in v0.2.0, but v0.2.0's own entry is sitting there
# and is correct. Renaming onto it would collide, so this one is excluded too —
# resolving it needs a permutation, which is a decision rather than a mechanical
# fix.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
entry 0.9.9 >"$d/client/devlog/0.9.9.json"
step "$d" 'an entry whose containing release already has an entry' v0.2.0
expect_gate_pass 'a NEVER-CUT entry whose target release is occupied' "$d"
# The exclusion is only reviewable if it is visible, so the count is asserted
# rather than inferred from the pass — and it must count only what it excluded.
expect_output_matching 'the occupied entry is the only one excluded' \
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

# RED: the anchor must not depend on the topology the branch reached its history
# through. `main` introduces the entry and the release is cut on it; the branch
# independently authors a BYTE-IDENTICAL copy, then merges `main` in.
#
# That merge is TREESAME to BOTH parents across the entry paths, and a
# pathspec-restricted `git log` simplifies by following only the FIRST such
# parent — the branch. The commit that really introduced the string is pruned,
# the lookup answers with the branch's later copy, and the entry reads
# UNRELEASED against a release that demonstrably contains it.
#
# UNRELEASED is a PASSING verdict, so the gate's status cannot discriminate here
# and the row itself is the assertion: without --full-history this same fixture
# reports `0.2.0  <branch sha>  -  UNRELEASED`.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
git -C "$d" branch feature
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'main introduces the entry' v0.2.0
# Captured after the tag, so the expected anchor is main's commit rather than
# whatever the branch goes on to add.
main_anchor="$(git -C "$d" rev-parse --short HEAD)"
git -C "$d" checkout -q feature
# Re-created because checking out a branch that never had the directory removes
# it, and the copy has to be byte-identical for the merge to be TREESAME.
mkdir -p "$d/client/devlog"
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'the branch authors a byte-identical copy of the same entry'
git -C "$d" merge -q --no-edit main -m 'merge main into the branch'
expect_row 'an entry anchored past a merge that is TREESAME to both parents' \
	"$(run_sweep "$d")" \
	"^0\.2\.0 +${main_anchor} +0\.2\.0 +OK\$"

# RED, and the MIRROR of the case above — the one that decides the lookup cannot
# rank its candidates by walk order. Here the BRANCH authors the entry first and
# is never tagged; the release is cut on the copy that lands on `main` after it.
#
# Both introductions are visible, and the older of the two is the branch commit
# no release contains. Answering with it reports UNRELEASED for an entry the
# tagged release demonstrably carries — and UNRELEASED PASSES, so this is a
# vacuous pass rather than a visible refusal. Only ranking the candidates by the
# release they reach picks the tagged one.
#
# Kept alongside its mirror deliberately: each case alone is satisfied by a rule
# that gets the other wrong, so the pair is what pins the ranking.
d="$(new_repo)"
printf 'x\n' >"$d/base.txt"
step "$d" base v0.1.0
git -C "$d" checkout -q -b feature
mkdir -p "$d/client/devlog"
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'the branch authors the entry first, and is never tagged'
git -C "$d" checkout -q main
mkdir -p "$d/client/devlog"
entry 0.2.0 >"$d/client/devlog/0.2.0.json"
step "$d" 'the release is cut on the copy that lands on main' v0.2.0
released_anchor="$(git -C "$d" rev-parse --short HEAD)"
git -C "$d" merge -q --no-edit feature -m 'merge the branch into main'
expect_row 'an entry anchored to the released copy, not the older unreleased one' \
	"$(run_sweep "$d")" \
	"^0\.2\.0 +${released_anchor} +0\.2\.0 +OK\$"

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
