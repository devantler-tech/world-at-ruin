#!/usr/bin/env bash
# Proves tools/devlog-stamp.sh stamps a placeholder dev-log entry with exactly
# the release that first contains it, leaves everything else alone, and refuses
# the histories it cannot answer from.
#
# Each case builds its OWN repository with real commits and real tags: the
# answer is a statement about containment, so nothing smaller than a tagged
# history exercises it, and tags left over from an earlier case would change a
# later case's answer.
#
# The CI and CD wiring is asserted separately, since a correct stamp that never
# runs passes all of its own tests and stamps nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/tools/devlog-stamp.sh"
CI="$ROOT/.github/workflows/ci.yaml"
CD="$ROOT/.github/workflows/cd.yaml"

failures=0
# Set only once every case has run. Bash 3.2 (the macOS runner's) reports an
# aborted `set -e` script through an EXIT trap as success, so the verdict must
# not depend on the status the trap sees.
completed=0
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"; [ "$completed" = 1 ] || exit 1' EXIT

t_fail() {
	printf 'dev-log stamp test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

entry() {
	printf '{\n\t"date": "2026-09-25",\n\t"notes": [\n\t\t"%s"\n\t],\n\t"title": "%s",\n\t"version": "%s"\n}\n' \
		'The ash settles differently underfoot, so a step leaves a mark you can follow back.' \
		"$2" "$1"
}

new_repo() {
	local d
	d="$(mktemp -d "$scratch/repoXXXXXX")"
	mkdir -p "$d/tools" "$d/client/devlog"
	cp "$STAMP" "$d/tools/"
	git -C "$d" init -q -b main
	git -C "$d" config user.email t@example.com
	git -C "$d" config user.name t
	# Throwaway fixture history: never signed, never pushed.
	git -C "$d" config commit.gpgsign false
	git -C "$d" config tag.gpgsign false
	printf '%s' "$d"
}

step() {
	local d="$1" msg="$2" tag="${3:-}"
	git -C "$d" add -A
	git -C "$d" commit -qm "$msg"
	if [ -n "$tag" ]; then
		git -C "$d" tag "$tag"
	fi
	return 0
}

run_stamp() {
	local d="$1"
	shift
	local out rc=0
	out="$(cd "$d" && bash tools/devlog-stamp.sh "$@" 2>&1)" || rc=$?
	printf '%s' "$out"
	return $rc
}

version_of() {
	jq -r '.version' "$1"
}

# --- 1. The first release containing the add commit, across later releases ---
d="$(new_repo)"
printf 'seed\n' > "$d/README"
step "$d" "seed" v0.8.0
entry next "Early" > "$d/client/devlog/early-ash.json"
step "$d" "add early entry" v0.9.0
printf 'more\n' >> "$d/README"
step "$d" "later work" v0.10.0
entry next "Middle" > "$d/client/devlog/middle-ash.json"
step "$d" "add middle entry"
printf 'rc\n' >> "$d/README"
# Tags that contain the entry and sort BEFORE the real release: a pre-release
# of a patch that never shipped, and a v-prefixed tag that is not a version.
# Neither is a release a player receives, so neither may be the answer.
step "$d" "release candidate" v0.10.1-rc.1
git -C "$d" tag vendor-snapshot
git -C "$d" tag build-7
printf 'release\n' >> "$d/README"
step "$d" "release" v0.11.0
entry 0.9.0 "Numbered" > "$d/client/devlog/0.9.0.json"
cp "$d/client/devlog/0.9.0.json" "$scratch/numbered.before"
step "$d" "add a numbered entry"
cp "$d/client/devlog/early-ash.json" "$scratch/early.before"

out="$(run_stamp "$d" --require-all)" && rc=0 || rc=$?
[ "$rc" = 0 ] || t_fail "a fully released tree did not stamp cleanly (exit $rc): $out"
# v0.9.0 and v0.10.0 both contain it; a lexical sort would answer 0.10.0.
[ "$(version_of "$d/client/devlog/early-ash.json")" = "0.9.0" ] ||
	t_fail "an entry in v0.9.0 and every later release was stamped $(version_of "$d/client/devlog/early-ash.json"), not 0.9.0"
[ "$(version_of "$d/client/devlog/middle-ash.json")" = "0.11.0" ] ||
	t_fail "an entry first released in v0.11.0 (behind an earlier pre-release and non-version tags) was stamped $(version_of "$d/client/devlog/middle-ash.json")"
cmp -s "$d/client/devlog/0.9.0.json" "$scratch/numbered.before" ||
	t_fail "a numbered entry was rewritten"
# Formatting is kept: exactly the version line differs.
changed="$(diff "$scratch/early.before" "$d/client/devlog/early-ash.json" | grep -c '^[<>]' || true)"
[ "$changed" = 2 ] || t_fail "stamping changed $changed line(s) of the entry instead of only its version line"
printf '%s' "$out" | grep -q '2 stamped, 0 unreleased, 1 numbered untouched' ||
	t_fail "the summary does not report what was stamped: $out"

# --- 2. A rename keeps the release of the original add ---
d="$(new_repo)"
entry next "Moved" > "$d/client/devlog/old-name.json"
step "$d" "add entry" v1.0.0
git -C "$d" mv client/devlog/old-name.json client/devlog/new-name.json
step "$d" "rename it" v1.1.0
# A move that also rewrites the entry is a new entry, dated by that commit:
# following it would mean following by similarity, which is what attributes a
# sibling to the wrong release (case 1's middle entry).
entry next "Moved and rewritten" > "$d/client/devlog/edit-me.json"
step "$d" "add another" v1.2.0
git -C "$d" mv client/devlog/edit-me.json client/devlog/edited.json
entry next "Moved and rewritten, with a different title entirely" > "$d/client/devlog/edited.json"
step "$d" "move and rewrite it" v1.3.0
out="$(run_stamp "$d")" || t_fail "a renamed entry could not be stamped: $out"
[ "$(version_of "$d/client/devlog/new-name.json")" = "1.0.0" ] ||
	t_fail "a renamed entry was attributed to its rename ($(version_of "$d/client/devlog/new-name.json")), not its original add (1.0.0)"
[ "$(version_of "$d/client/devlog/edited.json")" = "1.3.0" ] ||
	t_fail "a moved-and-rewritten entry was stamped $(version_of "$d/client/devlog/edited.json"), not the release of its rewrite (1.3.0)"

# --- 3. Unreleased: left alone, and fatal only when a release is being built ---
d="$(new_repo)"
printf 'seed\n' > "$d/README"
step "$d" "seed" v2.0.0
entry next "Pending" > "$d/client/devlog/pending.json"
step "$d" "add after the last release"
out="$(run_stamp "$d")" && rc=0 || rc=$?
[ "$rc" = 0 ] || t_fail "an unreleased entry failed a stamp that did not require all (exit $rc)"
[ "$(version_of "$d/client/devlog/pending.json")" = "next" ] ||
	t_fail "an unreleased entry was stamped $(version_of "$d/client/devlog/pending.json")"
printf '%s' "$out" | grep -q '^UNRELEASED ' || t_fail "an unreleased entry was not reported: $out"
out="$(run_stamp "$d" --require-all)" && rc=0 || rc=$?
[ "$rc" = 1 ] || t_fail "--require-all accepted an entry in no release (exit $rc)"

# --- 4. An entry that was never committed has no release ---
d="$(new_repo)"
printf 'seed\n' > "$d/README"
step "$d" "seed" v3.0.0
entry next "Loose" > "$d/client/devlog/loose.json"
out="$(run_stamp "$d")" && rc=0 || rc=$?
[ "$rc" = 1 ] || t_fail "an uncommitted entry did not fail (exit $rc): $out"

# --- 5. A shallow checkout is refused, and nothing is rewritten ---
d="$(new_repo)"
entry next "Deep" > "$d/client/devlog/deep.json"
step "$d" "add entry" v4.0.0
printf 'more\n' > "$d/README"
step "$d" "later" v4.1.0
shallow="$scratch/shallow"
git clone -q --depth 1 --branch v4.1.0 "file://$d" "$shallow" 2>/dev/null
cp "$STAMP" "$shallow/tools/" 2>/dev/null || { mkdir -p "$shallow/tools" && cp "$STAMP" "$shallow/tools/"; }
out="$(run_stamp "$shallow" --require-all)" && rc=0 || rc=$?
[ "$rc" = 2 ] || t_fail "a shallow checkout was not refused (exit $rc): $out"
[ "$(version_of "$shallow/client/devlog/deep.json")" = "next" ] ||
	t_fail "a refused shallow checkout still rewrote an entry"

# --- 6. Bad usage is refused ---
out="$(run_stamp "$d" --bogus)" && rc=0 || rc=$?
[ "$rc" = 2 ] || t_fail "an unknown flag was accepted (exit $rc)"

# --- 7. Wiring: CI runs this test; CD stamps on full history before export ---
grep -qE '^[[:space:]]+run: \./tools/devlog-stamp\.test\.sh[[:space:]]*$' "$CI" ||
	t_fail "ci.yaml does not run ./tools/devlog-stamp.test.sh"
grep -q 'tools/devlog-stamp.sh --require-all' "$CD" ||
	t_fail "cd.yaml does not stamp dev-log entries with --require-all"
checkout_block="$(awk '/Checkout the released tag/{on=1} on{print} on&&/persist-credentials/{exit}' "$CD")"
printf '%s' "$checkout_block" | grep -qE 'fetch-depth: 0' ||
	t_fail "cd.yaml's release checkout is shallow, so the stamp would refuse every release"
stamp_line="$(grep -n 'tools/devlog-stamp.sh' "$CD" | head -n 1 | cut -d: -f1)"
export_line="$(grep -n 'Export .app' "$CD" | head -n 1 | cut -d: -f1)"
if [ -z "$stamp_line" ] || [ -z "$export_line" ] || [ "$stamp_line" -ge "$export_line" ]; then
	t_fail "cd.yaml does not stamp the entries before it exports the build"
fi

completed=1
if [ "$failures" -gt 0 ]; then
	printf 'dev-log stamp test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'dev-log stamp test: OK\n'
