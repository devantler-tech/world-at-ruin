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
# Only ADDED entry files are checked. Editing the prose of an entry that has long
# since shipped is legitimate and must stay so; it is the freshly authored entry
# whose version is a guess.
#
# KNOWN INTERACTION. Correcting an entry that is ALREADY mislabelled means giving
# it the number of a release that has already happened, and this guard refuses
# exactly that — it cannot tell "names a release that shipped without it" from
# "names the release it did ship in", because the change is on main either way.
# `main` currently holds one such entry (0.59.0, first contained in v0.60.0).
# Fixing it needs this check taught to verify containment, or a reviewed
# one-off; it is not something to work around by loosening the rule above.
#
# Fail-closed: a missing base commit, an unreadable entry, or a checkout with no
# visible release tags is an error, never a pass. A tagless checkout would
# otherwise make every comparison vacuously true on exactly the misconfiguration
# (a shallow fetch) that hides the tags.
set -euo pipefail

ENTRY_DIR='client/devlog'

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

# The commit this change is measured against.
#
# On a pull_request or merge_group checkout HEAD is the merge commit the forge
# built, whose FIRST parent is the base branch tip; diffing against that yields
# only what this change contributes. BASE_SHA must NOT be used directly there:
# it is the base as of the event, so a PR whose base has moved on sees every
# entry a sibling added since as "added by this change" and is refused for
# someone else's entry. Entries land on most player-visible PRs, so that would
# fire constantly rather than rarely. BASE_SHA remains the fallback for a
# checkout that is not a merge commit — a local run, or the head ref itself.
diff_base() {
	if git rev-parse -q --verify 'HEAD^2' >/dev/null 2>&1; then
		git rev-parse 'HEAD^1'
	else
		printf '%s' "$1"
	fi
}

# Entry files this change ADDS, relative to the base commit.
#
# --no-renames is load-bearing, not tidiness. Rename detection is on by default,
# and two real entries differ only in a version string and some prose, so moving
# one onto a different version scores as a rename and is reported as R rather
# than A — never reaching the check. That is exactly the operation this guard's
# own failure message asks for, so without this a second, still-stale rename
# would sail through. Forcing a rename to read as delete-plus-add puts the
# landing name back under the check.
added_entry_files() {
	git diff --no-renames --diff-filter=A --name-only "$1" HEAD -- "$ENTRY_DIR" |
		grep -E '\.json$' || true
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

	local newest
	newest=$(released_versions | newest_version)
	[ -n "$newest" ] ||
		fail 'no release tags are visible in this checkout — refusing to pass vacuously (a shallow fetch hides them)'

	local added
	added=$(added_entry_files "$(diff_base "$base")")
	if [ -z "$added" ]; then
		printf 'dev-log entry version guard: PASS — no new entry (newest release %s)\n' "$newest"
		return 0
	fi

	local file version floor
	floor=$(next_patch "$newest")
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		[ -f "$file" ] || fail "$file is added but missing from the working tree"
		version=$(declared_version "$file")
		[ -n "$version" ] ||
			fail "$file declares no readable version — the field is missing or the file is not parseable JSON"
		is_version "$version" ||
			fail "$file declares version '$version', which is not an X.Y.Z release version"
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
