#!/usr/bin/env bash
# Refuse a dev-log entry that names a version which has already been released.
#
# An entry's version is hand-written when a branch is authored — a prediction of
# the next semantic-release bump. With several releases an hour that prediction
# is routinely overtaken before the PR merges, and nothing downstream notices:
# `devlog_storage_test` compares each file against its OWN declared version and
# `devlog_entries_test` checks uniqueness and ordering, so a stale-but-consistent
# version satisfies both. The log then tells the maintainer a change arrived in a
# build that does not contain it.
#
# The property pinned here is the one that needs no prediction: an entry
# describes a build that HAS NOT SHIPPED YET, so its version must be strictly
# greater than every release that already exists. That is provable from the tags
# in the checkout rather than guessed, and it catches the observed failures —
# `0.59.0` for a change first contained in `v0.60.0`, and an entry numbered
# `0.59.2` written after `v0.59.2` had already been cut.
#
# WHAT THIS DOES NOT CLAIM. Being ahead of every existing release is necessary,
# not sufficient. Two PRs merging back-to-back can still both pass here and then
# release in an order that leaves the second one's number low, because the tag it
# would have to beat does not exist yet when it is checked. Closing that needs
# the version stamped at release time from the tag actually cut, the way cd.yaml
# already stamps `DevLog.VERSION` — a different change, tracked separately.
#
# ADDED entry files are checked, and so is any entry a change overwrites in place
# while LISTING it as a correction. Editing the prose of an entry that has long
# since shipped is legitimate and must stay so, so an unlisted modification stays
# unchecked; it is the freshly authored entry whose version is a guess, and the
# listed correction whose number is a claim.
#
# CORRECTIONS take the other proof. Being ahead of every release is the right
# test for an authored entry, and the wrong one for correcting an entry already
# on main that carries the wrong number: the fix necessarily names a release that
# has already happened. An entry listed in tools/devlog-entry-corrections.tsv is
# therefore measured against CONTAINMENT instead — the release it names must be
# the first release containing the anchor commit whose change it describes. That
# is the property the forward-looking rule only approximates, so a listing
# substitutes a stronger machine-checked proof rather than an exemption: a wrong
# number still fails, and an entry that is not listed is unaffected.
#
# The anchor must be the commit the entry DESCRIBES. An entry's own add-commit
# is useless for this — the one-file-per-entry migration created every existing
# entry file in a single commit, so it says nothing about when the change shipped.
#
# Fail-closed: a missing base commit, an unreadable entry, or a checkout with no
# visible release tags is an error, never a pass. A tagless checkout would
# otherwise make every comparison vacuously true on exactly the misconfiguration
# (a shallow fetch) that hides the tags.
set -euo pipefail

ENTRY_DIR='client/devlog'
CORRECTIONS_FILE='tools/devlog-entry-corrections.tsv'
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tools/pr-diff-base.sh
. "$GUARD_DIR/pr-diff-base.sh"

fail() {
	printf 'dev-log entry version guard: FAIL — %s\n' "$1" >&2
	exit 1
}

# A version this scheme can compare: three numeric components, no pre-release.
is_version() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# True when $1 is strictly greater than $2. Compared component-wise as integers
# rather than lexically, so 0.9.0 does not outrank 0.10.0 — the same distinction
# the version-ledger guard depends on.
version_gt() {
	local -a a b
	local i x y
	IFS=. read -r -a a <<<"$1"
	IFS=. read -r -a b <<<"$2"
	for i in 0 1 2; do
		# 10# forces base ten: a zero-padded component would otherwise be read
		# as octal, and 0.0.08 is a parse error rather than a comparison.
		x=$((10#${a[i]:-0}))
		y=$((10#${b[i]:-0}))
		((x > y)) && return 0
		((x < y)) && return 1
	done
	return 1
}

# The release tags this checkout can see, as bare versions.
released_versions() {
	git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//'
}

# The highest version on stdin. Empty when nothing on stdin is a version, which
# the caller must treat as an error rather than as "nothing has been released".
newest_version() {
	local newest='' v
	while IFS= read -r v; do
		is_version "$v" || continue
		if [ -z "$newest" ] || version_gt "$v" "$newest"; then
			newest="$v"
		fi
	done
	printf '%s' "$newest"
}

# The lowest version on stdin, by the same component-wise comparison. Empty when
# nothing on stdin is a version, which the caller must treat as an error.
oldest_version() {
	local oldest='' v
	while IFS= read -r v; do
		is_version "$v" || continue
		if [ -z "$oldest" ] || version_gt "$oldest" "$v"; then
			oldest="$v"
		fi
	done
	printf '%s' "$oldest"
}

# The first release containing $1, as a bare version. Empty when no release
# contains it — which is the honest answer for a change that has not shipped,
# not a reason to pass.
first_release_containing() {
	git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --contains "$1" 2>/dev/null |
		sed 's/^v//' | oldest_version
}

# The lowest release strictly above $1. Empty when $1 is above every release.
#
# This is the whole answer for a PRE-RELEASE entry, and it needs no history
# walk. An entry numbered below the first tag was authored before any release
# existed, so the first release cut after its number is necessarily the one that
# first carried it — the containment lookup and this succession agree by
# construction for that class. Deriving it from tags alone keeps the check
# working on a checkout whose depth hides the commit an anchor search would
# need, which is the misconfiguration most likely to make a gate pass vacuously.
first_release_after() {
	local v
	while IFS= read -r v; do
		# An `if` rather than `&&`: the loop's status is its last iteration's, so
		# a trailing release that is NOT above $1 would leave the while non-zero
		# and `set -e` would abort the run inside the command substitution — no
		# message, no verdict. That is the empty-output failure mode, and it hits
		# exactly when $1 is above every release, which is the case the caller
		# most needs an answer for.
		if version_gt "$v" "$1"; then
			printf '%s\n' "$v"
		fi
	done < <(released_versions) | oldest_version
}

# The release an entry declares it first reached players in, or empty.
#
# Present only on entries whose own version was never cut. It is a claim about a
# release, so it is verified rather than trusted — see check_shipped_in.
declared_shipped_in() {
	jq -er '.shipped_in // empty' "$1" 2>/dev/null || true
}

# Verify every `shipped_in` declaration in the tree.
#
# A declaration is how the log stops presenting a never-released number as a
# build the reader could have played, so it carries the same weight as the
# version field and gets the same treatment: a wrong one fails rather than
# quietly mislabelling the log again. Three properties, each provable from the
# tags in the checkout:
#
#   1. The entry's own version was NEVER released. An entry that shipped as
#      itself has nothing to redirect the reader to, so a declaration on it is
#      false however plausible its target looks.
#   2. The declared release EXISTS. Pointing at another version that was never
#      cut would move the false claim rather than remove it.
#   3. It is the FIRST release above the entry's version. Any later release also
#      contains the change, so "a release containing it" would accept a whole
#      tail of true-but-wrong answers; only the first one dates the work.
#
# Whole-tree rather than diff-scoped, unlike the added-entry rule above. The
# declarations are edits to entries that shipped long ago, which the added-only
# rule deliberately leaves unchecked — so a diff-scoped check would verify these
# on the change that introduces them and never again, and a later edit could
# falsify one silently.
check_shipped_in() {
	local file version shipped expected
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		shipped=$(declared_shipped_in "$file")
		[ -n "$shipped" ] || continue

		version=$(declared_version "$file")
		is_version "$version" ||
			fail "$file declares shipped_in but no readable version of its own"
		is_version "$shipped" ||
			fail "$file declares shipped_in '$shipped', which is not an X.Y.Z release version"

		[ -z "$(git tag --list "v$version")" ] ||
			fail "$(printf '%s declares it first shipped in v%s, but v%s was itself released and contains its own change. shipped_in marks an entry whose version was NEVER cut; remove it.' \
				"$file" "$shipped" "$version")"
		[ -n "$(git tag --list "v$shipped")" ] ||
			fail "$(printf '%s declares it first shipped in v%s, but no such release exists. Naming one never-cut version from another leaves the log claiming a build the reader could not have played.' \
				"$file" "$shipped")"

		expected=$(first_release_after "$version")
		# Nothing has been cut above this entry yet, so it is a freshly authored
		# one under the forward-looking rule — it describes a build that has not
		# shipped, and cannot already know where it landed. Named separately
		# because the comparison below would otherwise refuse it against an
		# empty release and read as the guard malfunctioning.
		[ -n "$expected" ] ||
			fail "$(printf '%s declares it first shipped in v%s, but no release above %s exists yet — this entry has not shipped at all. shipped_in records where an already-released change landed; a new entry takes the forward-looking rule instead.' \
				"$file" "$shipped" "$version")"
		[ "$shipped" = "$expected" ] ||
			fail "$(printf '%s declares it first shipped in v%s, but the first release cut after %s is v%s. A later release contains the change too, so only the first one dates it.' \
				"$file" "$shipped" "$version" "$expected")"
	done < <(find "$ENTRY_DIR" -name '*.json' | sort)
}

# Every listing must carry both a path and an anchor. A half-written line would
# otherwise be indistinguishable from "not listed", so the entry would fall
# through to the ordinary rule and be refused for the wrong reason — which reads
# as the guard misfiring rather than as a listing that needs finishing.
validate_corrections() {
	local path commit rest lineno=0
	[ -f "$CORRECTIONS_FILE" ] || return 0
	while IFS=$'\t' read -r path commit rest || [ -n "$path" ]; do
		lineno=$((lineno + 1))
		case "$path" in '' | '#'*) continue ;; esac
		[ -n "$commit" ] ||
			fail "$CORRECTIONS_FILE line $lineno lists $path with no anchor commit — a correction is verified against the commit it describes, so the listing is unusable without one"
	done <"$CORRECTIONS_FILE"
}

# The anchor commit sanctioning $1 as a correction, or empty when it is not one.
#
# Matched on the exact landing path, so a listing covers one specific entry and
# cannot be read as a pattern. A missing corrections file is not an error: the
# ordinary rule applies to everything and nothing needs sanctioning.
correction_anchor() {
	local file="$1" path commit rest
	[ -f "$CORRECTIONS_FILE" ] || return 0
	while IFS=$'\t' read -r path commit rest || [ -n "$path" ]; do
		case "$path" in '' | '#'*) continue ;; esac
		[ "$path" = "$file" ] || continue
		printf '%s' "$commit"
		return 0
	done <"$CORRECTIONS_FILE"
}

# Entry files this change ADDS, plus listed corrections it OVERWRITES in place.
#
# --no-renames is load-bearing, not tidiness. Rename detection is on by default,
# and two real entries differ only in a version string and some prose, so moving
# one onto a different version scores as a rename and is reported as R rather
# than A — never reaching the check. That is exactly the operation this guard's
# own failure message asks for, so without this a second, still-stale rename
# would sail through. Forcing a rename to read as delete-plus-add puts the
# landing name back under the check.
#
# ADDED is not sufficient on its own, because a bulk correction is a PERMUTATION:
# entries move onto release numbers that other entries are vacating in the same
# change (0.3.0 -> 0.10.0 while 0.10.0 -> 0.28.0). A destination that already
# existed in the base is MODIFIED rather than added, so it would escape the check
# entirely — while sitting in the corrections file, which states that a listed
# entry is verified by containment. Measured on the #452 bulk correction: 6 of 27
# listed corrections were invisible to this guard for exactly that reason, so a
# mistyped anchor or target in any of them would have passed CI under a claim of
# being machine-checked.
#
# Including them is a strict TIGHTENING, and deliberately narrow: a modified
# entry qualifies only when it is ALREADY LISTED in CORRECTIONS_FILE. Editing the
# prose of an entry that has long since shipped stays unchecked and legal, which
# is the freedom the added-only rule existed to protect.
candidate_entry_files() {
	local base="$1" file
	{
		git diff --no-renames --diff-filter=A --name-only "$base" HEAD -- "$ENTRY_DIR"
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			if [ -n "$(correction_anchor "$file")" ]; then
				printf '%s\n' "$file"
			fi
		done < <(git diff --no-renames --diff-filter=M --name-only "$base" HEAD -- "$ENTRY_DIR")
	} | grep -E '\.json$' | sort -u || true
}

# The version an entry declares. The filename must agree with it, but that is
# devlog_storage_test's property; this reads the declared value because that is
# what the game renders.
declared_version() {
	jq -er '.version // empty' "$1" 2>/dev/null || true
}

# The lowest version an entry could legitimately carry: one patch above the
# newest release. A `feat:` needs the next MINOR instead, so this is named as a
# floor rather than as the answer.
next_patch() {
	local -a v
	IFS=. read -r -a v <<<"$1"
	printf '%d.%d.%d' "$((10#${v[0]}))" "$((10#${v[1]}))" "$((10#${v[2]} + 1))"
}

main() {
	local base="${BASE_SHA:-}"
	[ -n "$base" ] || fail 'BASE_SHA is unset — cannot tell which entries this change adds'
	git cat-file -e "$base" 2>/dev/null ||
		fail "base commit $base is not present in the checkout — cannot verify entry versions"

	# The shared resolver distinguishes the forge's merge ref from a contributor
	# whose own head is a merge commit. CI supplies the event head explicitly.
	# Direct callers historically supplied only BASE_SHA, so retain their
	# synthetic-merge behavior by using HEAD^2 as the hint only when HEAD_SHA is
	# absent. A local head-ref check must set HEAD_SHA to that head commit.
	local head="${HEAD_SHA:-}"
	if [ -z "$head" ]; then
		head="$(git rev-parse --verify --quiet 'HEAD^2' 2>/dev/null || true)"
	fi
	local change_base
	change_base="$(resolve_pr_diff_base "$head" "$base")" ||
		fail "could not resolve a diff base from HEAD_SHA '${HEAD_SHA:-unset}' and BASE_SHA '$base'"

	local newest
	newest=$(released_versions | newest_version)
	[ -n "$newest" ] ||
		fail 'no release tags are visible in this checkout — refusing to pass vacuously (a shallow fetch hides them)'

	validate_corrections
	check_shipped_in

	local added
	added=$(candidate_entry_files "$change_base")
	if [ -z "$added" ]; then
		printf 'dev-log entry version guard: PASS — no new or corrected entry (newest release %s)\n' "$newest"
		return 0
	fi

	local file version floor anchor shipped
	floor=$(next_patch "$newest")
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		[ -f "$file" ] || fail "$file is added but missing from the working tree"
		version=$(declared_version "$file")
		[ -n "$version" ] ||
			fail "$file declares no readable version — the field is missing or the file is not parseable JSON"
		is_version "$version" ||
			fail "$file declares version '$version', which is not an X.Y.Z release version"

		# A sanctioned correction is held to containment instead: it must name
		# the first release that actually contains the change it describes.
		anchor=$(correction_anchor "$file")
		if [ -n "$anchor" ]; then
			git rev-parse -q --verify "$anchor^{commit}" >/dev/null 2>&1 ||
				fail "$file is listed in $CORRECTIONS_FILE against '$anchor', which is not a commit in this checkout — the correction cannot be verified"
			shipped=$(first_release_containing "$anchor")
			[ -n "$shipped" ] ||
				fail "$file is listed in $CORRECTIONS_FILE against $anchor, but no release contains that commit — an unshipped change takes the ordinary forward-looking rule, not a correction"
			[ "$version" = "$shipped" ] ||
				fail "$(printf '%s declares version %s, but the change it is anchored to (%s) first shipped in v%s. A correction must name the release that actually contains it.' \
					"$file" "$version" "$anchor" "$shipped")"
			printf 'dev-log entry version guard: %s verified by containment — first released in v%s\n' "$file" "$shipped"
			continue
		fi

		version_gt "$version" "$newest" ||
			fail "$(printf '%s names version %s, but v%s is already released and does not contain this change. An entry describes a build that has not shipped yet, so it must be above every existing release — %s at the lowest, or the next minor for a feat:. Rename the file and its version field together.' \
				"$file" "$version" "$newest" "$floor")"
	done <<<"$added"

	printf 'dev-log entry version guard: PASS — every new entry is above the newest release %s\n' "$newest"
}

# Sourced by tools/devlog-entry-version-guard.test.sh to drive these functions
# directly; only a direct invocation runs the check.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi
