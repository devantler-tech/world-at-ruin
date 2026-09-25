#!/usr/bin/env bash
# Keep dev-log entry versions honest: a new entry never predicts its release, and
# an entry that names a released version proves it.
#
# A NEW ENTRY CARRIES "next". Its release cannot be known on its branch: several
# releases are cut an hour, so any number written there is a prediction a
# sibling can overtake before the branch merges, and the log then tells the
# maintainer a change arrived in a build that does not contain it (`0.59.0` for
# a change first contained in `v0.60.0`; an entry numbered `0.59.2` written after
# `v0.59.2` was cut). The release build answers exactly instead:
# tools/devlog-stamp.sh rewrites every "next" entry to the first release
# containing the commit that added it (#518). So an entry a change ADDS must
# carry the placeholder, and a numbered one is refused with the rename that
# fixes it.
#
# This replaces the rule this guard used to enforce — that a new entry's number
# be above every existing release. That rule was a floor, never a guarantee: two
# PRs merging back-to-back could both pass it and still release in an order that
# left the second one low, because the tag it had to beat did not exist yet when
# it was checked (#467). A placeholder has no number to be low.
#
# THE ONE WAY A PLACEHOLDER CAN STILL LIE is by being added in a change that also
# removes an entry already on its base. Converting a shipped entry to "next", or
# moving one while editing it, makes the stamp date it by THIS change rather than
# by the change it describes. So a placeholder added alongside a removed entry is
# refused unless it is a byte-identical copy of one of them — an exact rename,
# which the stamp follows back to the original add.
#
# ADDED entry files are checked, and so is any entry a change overwrites in place
# while LISTING it as a correction. Editing the prose of an entry that has long
# since shipped is legitimate and must stay so, so an unlisted modification stays
# unchecked.
#
# CORRECTIONS are the one kind of new entry that names a released version: an
# entry already on main that carries the wrong number, re-pointed at the right
# one. An entry listed in tools/devlog-entry-corrections.tsv is measured against
# CONTAINMENT — the release it names must be the first release containing the
# anchor commit whose change it describes. The listing substitutes a
# machine-checked proof rather than an exemption: a wrong number still fails.
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
# The version a new entry carries until the release build stamps it. The same
# string as DevLog.NEXT_VERSION and tools/devlog-stamp.sh's PLACEHOLDER.
PLACEHOLDER_VERSION='next'
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

# The glob every release-tag lookup in this file uses, so the forward-looking
# rule, the containment index and its fallback cannot disagree about what counts
# as a release. It admits a prerelease suffix; is_version refuses that.
RELEASE_TAG_GLOB='v[0-9]*.[0-9]*.[0-9]*'

# The release tags this checkout can see, as bare versions.
released_versions() {
	git tag --list "$RELEASE_TAG_GLOB" | sed 's/^v//'
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

# Every release tag this checkout can see, one `<commit> <version>` per line
# with annotated tags peeled to the commit they name. Empty when the checkout
# has no release tag; non-zero when git could not read the tags, which a caller
# must treat as "no index", never as "no releases". is_version drops what the
# glob admits but oldest_version would refuse, so the index only ever answers
# with a version the per-anchor lookup it stands in for could return.
release_tag_commits() {
	local refs sha peeled name version
	refs=$(git for-each-ref --format='%(objectname)|%(*objectname)|%(refname:short)' \
		"refs/tags/$RELEASE_TAG_GLOB") || return 1
	while IFS='|' read -r sha peeled name; do
		[ -n "$name" ] || continue
		version=${name#v}
		is_version "$version" || continue
		printf '%s %s\n' "${peeled:-$sha}" "$version"
	done <<<"$refs"
}

# One `<commit> <version>` line for every commit some release contains, naming
# the LOWEST release that contains it — what `git tag --contains` piped through
# oldest_version answers, computed for the whole history in one walk instead of
# once per anchor (#602). `git rev-list --children --topo-order` over every
# tagged commit prints each commit after all of its children, so a commit's
# answer is the lowest of the tag on itself and its children's answers;
# containment is exactly reachability through children, across a fork in the
# history as much as along a straight line. A commit no release contains gets
# no line. Non-zero when git could not enumerate the tags or the history, and
# then NOTHING is printed: a partial index would be a wrong one.
build_containment_index() {
	local tags commits
	tags=$(release_tag_commits) || return 1
	[ -n "$tags" ] || return 0
	# shellcheck disable=SC2046 # commit ids never contain whitespace
	commits=$(git rev-list --children --topo-order $(printf '%s\n' "$tags" | cut -d' ' -f1)) || return 1
	# lt orders versions exactly as version_gt does; the equivalence case in
	# devlog-entry-version-guard.test.sh holds the two together.
	awk '
		function lt(a, b,   x, y, i) {
			split(a, x, "."); split(b, y, ".")
			for (i = 1; i <= 3; i++) {
				if (x[i] + 0 < y[i] + 0) return 1
				if (x[i] + 0 > y[i] + 0) return 0
			}
			return 0
		}
		function take(sha, v) {
			if (v != "" && (first[sha] == "" || lt(v, first[sha]))) first[sha] = v
		}
		FNR == NR { take($1, $2); next }
		{
			for (i = 2; i <= NF; i++) take($1, first[$i])
			if (first[$1] != "") print $1, first[$1]
		}' <(printf '%s\n' "$tags") <(printf '%s\n' "$commits")
}

# Path of the index file for the release tags this checkout sees RIGHT NOW,
# built when absent. It lives under the repository's common git directory,
# named by the hash of every release-tag ref and the object it points at, so a
# tag created, moved or deleted while a run is under way hashes to a name no
# file has and the next lookup rebuilds — never an answer from a stale index.
# The key reads refs only, never objects, so it cannot fail on a checkout whose
# history is incomplete. A file rather than a shell variable because every
# caller reads this through a command substitution, whose subshell discards a
# variable the moment it returns, and the whole saving is that one walk serves
# every lookup. Only the current tag set's file is kept, so the cache never
# grows; a concurrent run in another worktree that loses its file to that sweep
# simply rebuilds. Non-zero when no index can be had — the tags or history
# unreadable, or nowhere writable to keep the file — and then nothing is cached,
# so a broken build is never remembered as an answer.
containment_index_file() {
	local refs key dir file tmp index
	refs=$(git for-each-ref --format='%(objectname) %(refname)' "refs/tags/$RELEASE_TAG_GLOB" 2>/dev/null) || return 1
	key=$(printf '%s\n' "$refs" | git hash-object --stdin 2>/dev/null) || return 1
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	dir="$dir/devlog-containment-index"
	file="$dir/$key"
	if [ -f "$file" ]; then
		printf '%s\n' "$file"
		return 0
	fi
	index=$(build_containment_index 2>/dev/null) || return 1
	mkdir -p "$dir" 2>/dev/null || return 1
	tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 1
	if printf '%s\n' "$index" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
		find "$dir" -type f ! -name "$key" ! -name '.tmp.*' -delete 2>/dev/null || true
		printf '%s\n' "$file"
		return 0
	fi
	rm -f "$tmp" 2>/dev/null || true
	return 1
}

# Resolves the index once for this process and exports its path, so every
# later first_release_containing in the process opens the file directly instead
# of re-deriving the key: two processes per lookup instead of five. Each entry
# point calls this once, outside any command substitution, before its first
# lookup. A process that changed tags after priming would keep reading the file
# it primed; neither entry point writes a tag, and a caller that does must not
# prime. Harmless when no index can be had — lookups then fall back.
prime_containment_index() {
	local file
	if file=$(containment_index_file 2>/dev/null); then
		export DEVLOG_CONTAINMENT_INDEX_FILE="$file"
	fi
}

# The first release containing $1, as a bare version. Empty when no release
# contains it — which is the honest answer for a change that has not shipped,
# not a reason to pass — and empty for a name that is not a commit here. Reads
# the primed index when there is one, else the index for the current tags, else
# asks git the one-walk way for this call alone: a lookup never fails and never
# answers from an index it could not build. Always exits 0, because callers
# assign its output under `set -e`.
first_release_containing() {
	local sha file
	sha=$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null) || return 0
	file=${DEVLOG_CONTAINMENT_INDEX_FILE:-}
	if [ -z "$file" ] || [ ! -f "$file" ]; then
		file=$(containment_index_file 2>/dev/null) || file=''
	fi
	if [ -n "$file" ] && awk -v sha="$sha" '$1 == sha { print $2; exit }' "$file" 2>/dev/null; then
		return 0
	fi
	git tag --list "$RELEASE_TAG_GLOB" --contains "$sha" 2>/dev/null |
		sed 's/^v//' | oldest_version || return 0
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
		[ "$version" != "$PLACEHOLDER_VERSION" ] ||
			fail "$file carries \"$PLACEHOLDER_VERSION\" and declares shipped_in — its release is stamped at build time, so there is no never-cut number to explain; remove shipped_in"
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
			fail "$(printf '%s declares it first shipped in v%s, but no release above %s exists yet — this entry has not shipped at all. shipped_in records where an already-released change landed; a new entry carries "next" instead.' \
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
		[[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
			fail "$CORRECTIONS_FILE line $lineno lists $path with anchor '$commit', which is not a full 40-character commit SHA"
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

# The commit that ADDED an entry file: the newest add, following an exact rename
# only. This is the anchor tools/devlog-stamp.sh stamps a placeholder from, and
# it must stay the same question — devlog-entry-version-sweep.test.sh holds the
# sweep's answer against the stamp's. Empty when git cannot say, which a caller
# treats as "no anchor", never as an answer.
placeholder_anchor() {
	git log --follow -M100% --diff-filter=A --max-count=1 --format=%H -- "$1" 2>/dev/null || true
}

# The blob of every entry file this change REMOVES, one per line.
#
# A placeholder added in the same change as a removal is how a shipped entry
# gets re-dated: converted to "next", or moved while edited, it is stamped by
# this change instead of by the change it describes. Blobs rather than paths so
# an exact rename — the one move the stamp follows back — can be recognised.
# Non-zero when git could not answer: an empty list must mean "nothing removed",
# never "could not tell".
removed_entry_blobs() {
	local base="$1" paths path blob
	paths=$(git diff --no-renames --diff-filter=D --name-only "$base" HEAD -- "$ENTRY_DIR") || return 1
	while IFS= read -r path; do
		case "$path" in *.json) ;; *) continue ;; esac
		blob=$(git rev-parse -q --verify "$base:$path") || return 1
		printf '%s\n' "$blob"
	done <<<"$paths"
}

main() {
	local base="${BASE_SHA:-}"
	[ -n "$base" ] || fail 'BASE_SHA is unset — cannot tell which entries this change adds'
	git cat-file -e "$base" 2>/dev/null ||
		fail "base commit $base is not present in the checkout — cannot verify entry versions"
	prime_containment_index

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

	local removed
	removed=$(removed_entry_blobs "$change_base") ||
		fail "could not list the entries this change removes, so a re-dated placeholder cannot be ruled out"

	local file version anchor shipped blob placeholders=0 corrections=0
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		[ -f "$file" ] || fail "$file is added but missing from the working tree"
		version=$(declared_version "$file")
		[ -n "$version" ] ||
			fail "$file declares no readable version — the field is missing or the file is not parseable JSON"

		if [ "$version" = "$PLACEHOLDER_VERSION" ]; then
			# The stamp dates a placeholder by the commit that added its file, so
			# one added while a base entry is removed is re-dating that entry
			# unless it is the same bytes under a new name.
			if [ -n "$removed" ]; then
				blob=$(git rev-parse -q --verify "HEAD:$file") ||
					fail "$file is added but not in HEAD, so its origin cannot be checked"
				grep -qxF "$blob" <<<"$removed" ||
					fail "$(printf '%s carries "%s" but this change also removes an existing entry. The release build dates a placeholder by the commit that added its file, so converting or rewriting an entry that already shipped would stamp it with a later release than the one that carried it. Keep the existing entry as it was; correct a wrong number through %s instead. Only a byte-identical rename keeps a placeholder dated by its original add.' \
						"$file" "$PLACEHOLDER_VERSION" "$CORRECTIONS_FILE")"
			fi
			placeholders=$((placeholders + 1))
			continue
		fi

		# A sanctioned correction is the one new entry that names a release: it
		# must name the first release that actually contains the change it
		# describes.
		anchor=$(correction_anchor "$file")
		if [ -z "$anchor" ]; then
			fail "$(printf '%s names version %s. A new entry does not predict its release — a sibling release cut before this merges makes that number wrong. Name the file for the change and let the release build stamp it:\n  git mv %s %s/<words-for-the-change>.json\nthen set its "version" to "%s". Only a correction listed in %s names a released version.' \
				"$file" "$version" "$file" "$ENTRY_DIR" "$PLACEHOLDER_VERSION" "$CORRECTIONS_FILE")"
		fi
		is_version "$version" ||
			fail "$file is listed in $CORRECTIONS_FILE but declares version '$version', which is not an X.Y.Z release version"
		git rev-parse -q --verify "$anchor^{commit}" >/dev/null 2>&1 ||
			fail "$file is listed in $CORRECTIONS_FILE against '$anchor', which is not a commit in this checkout — the correction cannot be verified"
		shipped=$(first_release_containing "$anchor")
		[ -n "$shipped" ] ||
			fail "$file is listed in $CORRECTIONS_FILE against $anchor, but no release contains that commit — an unshipped change is a new entry, which carries \"$PLACEHOLDER_VERSION\", not a correction"
		[ "$version" = "$shipped" ] ||
			fail "$(printf '%s declares version %s, but the change it is anchored to (%s) first shipped in v%s. A correction must name the release that actually contains it.' \
				"$file" "$version" "$anchor" "$shipped")"
		printf 'dev-log entry version guard: %s verified by containment — first released in v%s\n' "$file" "$shipped"
		corrections=$((corrections + 1))
	done <<<"$added"

	printf 'dev-log entry version guard: PASS — %d new entr%s carrying "%s" for the release build to stamp, %d correction%s verified by containment (newest release %s)\n' \
		"$placeholders" "$([ "$placeholders" -eq 1 ] && printf y || printf ies)" "$PLACEHOLDER_VERSION" \
		"$corrections" "$([ "$corrections" -eq 1 ] || printf s)" "$newest"
}

# Sourced by tools/devlog-entry-version-guard.test.sh to drive these functions
# directly; only a direct invocation runs the check.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi
