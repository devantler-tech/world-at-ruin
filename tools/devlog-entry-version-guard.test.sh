#!/usr/bin/env bash
# Proves tools/devlog-entry-version-guard.sh refuses exactly the mislabelling it
# claims to, and nothing else.
#
# Three layers, kept apart on purpose. Comparison logic is driven through the
# sourced functions; the decision is driven end-to-end against real commits and
# real tags, because that is where a wrong diff mode or an unfetched tag list
# would hide; and the CI wiring is asserted separately, since a guard that is
# correct but unwired passes every one of its own tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/devlog-entry-version-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0

t_fail() {
	printf 'dev-log entry version guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

# --- Layer 1: comparison logic --------------------------------------------
# Exercise the production functions rather than a copy, so drift is impossible.
# shellcheck source=/dev/null
source "$GUARD"

expect_gt() {
	version_gt "$1" "$2" || t_fail "expected $1 > $2"
}
expect_not_gt() {
	! version_gt "$1" "$2" || t_fail "expected $1 to NOT be > $2"
}

expect_gt 0.61.5 0.61.4
expect_gt 0.62.0 0.61.9
expect_gt 1.0.0 0.99.99
# The distinction a lexical compare gets wrong. Without it the guard would wave
# through an entry numbered 0.9.0 once 0.10.0 had shipped.
expect_gt 0.10.0 0.9.0
expect_not_gt 0.9.0 0.10.0
# Equality is not "ahead": naming the release that just shipped is the exact
# failure this guard exists for.
expect_not_gt 0.61.4 0.61.4
expect_not_gt 0.59.0 0.60.0

[ "$(printf '0.58.0\n0.61.4\n0.9.0\n' | newest_version)" = '0.61.4' ] ||
	t_fail 'newest_version did not pick the highest version'
# A tag list carrying nothing usable must come back empty so the caller can fail
# closed, rather than silently choosing a bogus baseline.
[ -z "$(printf 'not-a-version\n\n' | newest_version)" ] ||
	t_fail 'newest_version accepted a non-version'

is_version 0.61.4 || t_fail 'is_version rejected a valid version'
! is_version 'v0.61.4' || t_fail 'is_version accepted a leading v'
! is_version '0.61' || t_fail 'is_version accepted a two-component version'

[ "$(next_patch 0.61.4)" = '0.61.5' ] || t_fail 'next_patch is wrong'
[ "$(next_patch 0.9.0)" = '0.9.1' ] || t_fail 'next_patch is wrong at a nine boundary'

# oldest_version picks the FIRST release containing a change, so the same
# numeric comparison has to hold in the other direction: lexically "0.10.0"
# sorts below "0.9.0", which would name the wrong release as the one that
# shipped a change.
[ "$(printf '0.61.4\n0.9.0\n0.10.0\n' | oldest_version)" = '0.9.0' ] ||
	t_fail 'oldest_version did not pick the lowest version'
[ "$(printf '0.10.0\n0.60.0\n' | oldest_version)" = '0.10.0' ] ||
	t_fail 'oldest_version compared lexically rather than numerically'
[ -z "$(printf 'not-a-version\n\n' | oldest_version)" ] ||
	t_fail 'oldest_version accepted a non-version'

# --- Layer 2: the decision, against real commits and tags -----------------
# Builds a repository whose newest release is v0.61.4 and whose history already
# holds a long-shipped entry, then runs the guard as CI runs it.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Fixtures carry realistic prose on purpose. A stub entry is small enough that
# the version string dominates it, so git scores a move between two versions
# below the rename threshold and reports delete-plus-add — which would make the
# rename case below pass no matter how the guard asks for its diff. Real entries
# are several sentences, and at that size a move IS detected as a rename, which
# is the condition that case has to reproduce.
entry() {
	printf '{\n\t"date": "2026-07-27",\n\t"notes": [\n\t\t"%s",\n\t\t"%s"\n\t],\n\t"title": "The wanderer gains a visible improvement",\n\t"version": "%s"\n}\n' \
		'The ground under the Reach used to read as a single flat sheet of noise, with nothing to tell one stretch of it apart from another as you walked.' \
		'Stone now breaks into slabs with seams between them, so the surface has edges to catch the light and a sense of scale underfoot.' \
		"$1"
}

repo="$scratch/repo"
mkdir -p "$repo/client/devlog"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
entry 0.58.0 >"$repo/client/devlog/0.58.0.json"
git -C "$repo" add -A
git -C "$repo" commit -qm 'base'
base="$(git -C "$repo" rev-parse HEAD)"
for t in v0.58.0 v0.59.0 v0.61.4; do git -C "$repo" tag "$t"; done

# Runs the guard over a working tree that has `$1` staged on top of the base.
# Each case commits, so the guard sees a real added-file diff.
run_case() {
	local out rc=0
	out="$(cd "$repo" && BASE_SHA="$base" bash "$GUARD" 2>&1)" || rc=$?
	printf '%s' "$out"
	return $rc
}

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

commit_all() {
	git -C "$repo" add -A
	git -C "$repo" commit -qm "$1"
}

expect_pass() {
	local out rc=0
	out="$(run_case)" || rc=$?
	[ "$rc" -eq 0 ] || t_fail "$1: expected a pass, got rc=$rc: $out"
}

# A control that fails for the wrong reason proves nothing, so every refusal is
# matched on its message and not merely on a non-zero status.
expect_fail_matching() {
	local label="$1" needle="$2" out rc=0
	out="$(run_case)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected a refusal, but the guard passed"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

# GREEN: an entry above every existing release is what a correct author writes.
reset_tree
entry 0.61.5 >"$repo/client/devlog/0.61.5.json"
commit_all 'correct entry'
expect_pass 'entry above the newest release'

# RED: the observed #427 failure — the predicted version was cut while the
# branch was in flight, so the entry names a build that shipped without it.
reset_tree
entry 0.61.4 >"$repo/client/devlog/0.61.4.json"
commit_all 'entry equal to newest release'
expect_fail_matching 'entry equal to the newest release' 'v0.61.4 is already released'

# RED: the observed #412 failure — a sibling released ahead, leaving the entry
# below. This is the shape currently on main as 0.59.0 against v0.60.0.
reset_tree
entry 0.59.0 >"$repo/client/devlog/0.59.0.json"
commit_all 'entry below newest release'
expect_fail_matching 'entry below the newest release' 'must be above every existing release'

# RED, and the case that pins the comparison as NUMERIC end-to-end. Lexically
# "0.9.0" sorts above "0.61.4", so a string compare at the decision would wave
# this through. That is not hypothetical here: the project is already past
# 0.10.0, so every minor is two digits and a stale entry from an older base is
# exactly the shape that would slip past.
reset_tree
entry 0.9.0 >"$repo/client/devlog/0.9.0.json"
commit_all 'entry that only a lexical compare would accept'
expect_fail_matching 'entry below the newest release lexically above it' 'v0.61.4 is already released'

# The refusal has to name the floor, or it is not actionable: the whole point is
# turning a silent mislabelling into a one-line rename.
reset_tree
entry 0.59.0 >"$repo/client/devlog/0.59.0.json"
commit_all 'entry below newest release'
expect_fail_matching 'refusal names the minimum acceptable version' '0.61.5 at the lowest'

# RED, and the reason rename detection must be off. Renaming an entry is what
# this guard's own failure message asks an author to do, and entry files are
# near-identical in shape, so git reports the rename as R rather than A. With
# detection left on, a second rename onto a still-stale version is never
# examined — the guard would refuse once and then wave the retry through.
reset_tree
git -C "$repo" mv client/devlog/0.58.0.json client/devlog/0.59.0.json
entry 0.59.0 >"$repo/client/devlog/0.59.0.json"
commit_all 'rename a shipped entry onto another stale version'
expect_fail_matching 'renamed entry landing on a stale version' 'v0.61.4 is already released'

# GREEN control, and the reason only ADDED files are checked: correcting the
# prose of an entry that shipped long ago must stay legal. Under a rule that
# looked at every changed entry, this would be refused.
reset_tree
entry 0.58.0 | sed 's/catch the light/catch the light, and a corrected typo/' >"$repo/client/devlog/0.58.0.json"
commit_all 'edit a shipped entry'
expect_pass 'editing an already-released entry'

# GREEN control: a validation-only PR adds no entry by contract and must not be
# made to.
reset_tree
printf 'x\n' >"$repo/unrelated.txt"
commit_all 'no entry at all'
expect_pass 'a change with no dev-log entry'

# GREEN, and the case that pins WHICH commit the diff runs from. A forge builds
# a merge commit for the PR, and BASE_SHA is the base as of the event — so once
# the base moves on, every entry a sibling landed since reads as "added by this
# change". Measured against BASE_SHA directly, this correct PR is refused for
# somebody else's already-released entry. Entries land on most player-visible
# PRs, so that misfire would be routine rather than rare.
reset_tree
git -C "$repo" checkout -q -b sibling
entry 0.61.4 >"$repo/client/devlog/0.61.4.json"
commit_all 'a sibling lands an entry for a release that has since been cut'
git -C "$repo" checkout -q -B pr "$base"
entry 0.61.5 >"$repo/client/devlog/0.61.5.json"
commit_all 'our own, correct, forward-looking entry'
git -C "$repo" checkout -q sibling
git -C "$repo" merge -q --no-ff pr -m 'forge merge commit'
expect_pass 'a stale base, with a sibling entry landed since'
git -C "$repo" checkout -q main
git -C "$repo" branch -qD sibling pr

# --- Fail-closed cases ----------------------------------------------------
# A checkout that cannot see the tags would make every comparison vacuously
# true. That is what a shallow fetch produces, so it must be an error and not a
# pass — the failure mode this guard would otherwise share with a broken scanner.
reset_tree
entry 0.61.5 >"$repo/client/devlog/0.61.5.json"
commit_all 'correct entry'
saved_tags="$(git -C "$repo" tag)"
while IFS= read -r t; do [ -n "$t" ] && git -C "$repo" tag -d "$t" >/dev/null; done <<<"$saved_tags"
expect_fail_matching 'no visible release tags' 'refusing to pass vacuously'
while IFS= read -r t; do [ -n "$t" ] && git -C "$repo" tag "$t" "$base"; done <<<"$saved_tags"

# An entry whose version cannot be read is unverifiable, not acceptable.
reset_tree
printf '{ this is not json' >"$repo/client/devlog/0.61.5.json"
commit_all 'unreadable entry'
expect_fail_matching 'unreadable entry' 'declares no readable version'

# A base commit that is absent means the added-file set cannot be computed; a
# guard that shrugged here would pass every PR on a shallow checkout.
missing_base_out=$( (cd "$repo" && BASE_SHA=0000000000000000000000000000000000000000 bash "$GUARD" 2>&1) || true)
printf '%s' "$missing_base_out" | grep -qF 'is not present in the checkout' ||
	t_fail "an absent base commit was not refused: $missing_base_out"

unset_base_out=$( (cd "$repo" && BASE_SHA='' bash "$GUARD" 2>&1) || true)
printf '%s' "$unset_base_out" | grep -qF 'BASE_SHA is unset' ||
	t_fail "an unset BASE_SHA was not refused: $unset_base_out"

# --- Corrections: the containment proof -----------------------------------
# A correction names a release that has already happened, so the forward-looking
# rule above necessarily refuses it. These cases pin that the alternative proof
# is a REAL check and not an exemption: the same listing that lets a correct
# number through must refuse a wrong one, and an entry that is not listed must
# be unaffected.
#
# Needs its own history. In the repo above every tag sits on the base commit, so
# every commit is contained in every release and containment cannot discriminate.
# Here the feature commit is reachable from v0.60.0 onward but not from v0.58.0,
# which is the shape a real correction is measured against.
repo="$scratch/corrections"
mkdir -p "$repo/client/devlog" "$repo/tools"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
entry 0.58.0 >"$repo/client/devlog/0.58.0.json"
git -C "$repo" add -A
git -C "$repo" commit -qm 'before the feature'
git -C "$repo" tag v0.58.0
printf 'the feature\n' >"$repo/client/feature.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'the change an entry describes'
feature="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" tag v0.60.0
printf 'later work\n' >"$repo/client/later.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'later, released work'
git -C "$repo" tag v0.61.4
base="$(git -C "$repo" rev-parse HEAD)"
# A commit no release contains — the state a change is in before it ships.
printf 'unreleased\n' >"$repo/client/unreleased.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'unreleased work'
unreleased="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" reset -q --hard "$base"

corrections() {
	# reset_tree's `git clean -fd` takes the directory with it, since an empty
	# tools/ is not tracked — so recreate it rather than assuming it survived.
	mkdir -p "$repo/tools"
	printf '# a comment line, and a blank line, are not listings\n\n%s\t%s\tbecause\n' "$1" "$2" \
		>"$repo/tools/devlog-entry-corrections.tsv"
}

# GREEN: the correction this mechanism exists for. 0.60.0 is below the newest
# release 0.61.4 — refused by the ordinary rule — but it is exactly the release
# that first contains the change, which is the stronger property.
reset_tree
entry 0.60.0 >"$repo/client/devlog/0.60.0.json"
corrections client/devlog/0.60.0.json "$feature"
commit_all 'correct a mislabelled entry'
expect_pass 'a correction naming the release that contains its change'

# RED, and the ablation that proves the listing is not an exemption. Same
# listing, same anchor — only the declared version is wrong. If the containment
# comparison were dropped, this would pass and the mechanism would be a hole.
reset_tree
entry 0.59.0 >"$repo/client/devlog/0.59.0.json"
corrections client/devlog/0.59.0.json "$feature"
commit_all 'a correction onto the wrong release'
expect_fail_matching 'a listed correction naming the wrong release' 'first shipped in v0.60.0'

# RED: an anchor whose change has not shipped cannot support a correction —
# there is no release to name, and the forward-looking rule is the right test.
reset_tree
entry 0.60.0 >"$repo/client/devlog/0.60.0.json"
corrections client/devlog/0.60.0.json "$unreleased"
commit_all 'a correction anchored to unreleased work'
expect_fail_matching 'a correction anchored to an unreleased commit' 'no release contains that commit'

# RED: an anchor that is not a commit is unverifiable, so it fails closed rather
# than being taken on trust.
reset_tree
entry 0.60.0 >"$repo/client/devlog/0.60.0.json"
corrections client/devlog/0.60.0.json 0000000000000000000000000000000000000000
commit_all 'a correction anchored to a missing commit'
expect_fail_matching 'a correction anchored to a missing commit' 'is not a commit in this checkout'

# RED, and the non-weakening control: a corrections file EXISTS and is valid,
# but it lists a different entry. A listing must cover the one path it names and
# must not read as a general licence for the directory.
reset_tree
entry 0.60.0 >"$repo/client/devlog/0.60.0.json"
corrections client/devlog/0.59.0.json "$feature"
commit_all 'an unlisted entry alongside a valid corrections file'
expect_fail_matching 'an entry that is not the listed one' 'is already released'

# GREEN control: the ordinary forward-looking path still passes with a
# corrections file present, so the lookup itself has not broken authoring.
reset_tree
entry 0.61.5 >"$repo/client/devlog/0.61.5.json"
corrections client/devlog/0.60.0.json "$feature"
commit_all 'a normal forward-looking entry with corrections present'
expect_pass 'a forward-looking entry while a corrections file exists'

# --- Layer 3: wiring ------------------------------------------------------
# A correct guard that CI never runs passes all of the above and protects
# nothing, so the wiring is asserted rather than assumed.
grep -Fq 'tools/devlog-entry-version-guard.sh' "$WORKFLOW" ||
	t_fail 'CI does not run the dev-log entry version guard'
grep -Fq 'tools/devlog-entry-version-guard.test.sh' "$WORKFLOW" ||
	t_fail 'CI does not run this guard test'

if [ "$failures" -ne 0 ]; then
	printf 'dev-log entry version guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'dev-log entry version guard test: PASS\n'
