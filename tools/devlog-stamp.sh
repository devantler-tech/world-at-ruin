#!/usr/bin/env bash
# Stamp every placeholder dev-log entry with the release that first contains it.
#
# WHY. An entry's shipped version cannot be known on its branch: several
# releases are cut an hour, so any number written there is a prediction a
# sibling can overtake before the branch merges (#518). The release build is the
# one place that can answer exactly — the first plain vX.Y.Z tag that contains
# the commit which ADDED the entry is a pure function of history — so the entry
# carries the placeholder "next" until then, and this rewrites it in the build
# checkout, exactly as cd.yaml already stamps DevLog.VERSION there. Nothing is
# committed back to main.
#
# WHAT IT TOUCHES. Only entries whose "version" is exactly "next". A numbered
# entry is never rewritten: its version is already judged against containment
# by tools/devlog-entry-version-sweep.sh, and a second authority here could only
# disagree with it.
#
# THE ANCHOR is the commit that added the entry's file, followed through an
# EXACT rename only, so `git mv` never moves the release an entry is attributed
# to. Rename detection is held at 100% on purpose: entries share one JSON
# skeleton, and at git's default 50% similarity a newer entry reads as a
# "rename" of an older sibling and inherits its release. A move that also edits
# the file is therefore a new entry, dated by that commit.
# Pre-release tags (vX.Y.Z-rc.1) and anything that is not a plain vX.Y.Z tag are
# ignored: a player never receives them as an update, so they are not a release
# an entry could have shipped in.
#
# Usage: tools/devlog-stamp.sh [--require-all] [--dir <entry-dir>]
#   --require-all  fail if any placeholder entry is contained in no release yet.
#                  CD passes it for a stable release: every entry in the tagged
#                  tree is contained in that tag, so a leftover means the lookup
#                  failed rather than that the entry is genuinely unreleased.
#   --dir          entry directory relative to the repository root
#                  (default client/devlog).
#
# Exit status: 0 every placeholder it could stamp was stamped (and, with
# --require-all, none is left); 1 an entry could not be stamped; 2 it could not
# run at all — not a repository, shallow history, missing jq, bad usage.
set -euo pipefail

PLACEHOLDER="next"
entry_dir="client/devlog"
require_all=0

usage() {
	printf 'usage: tools/devlog-stamp.sh [--require-all] [--dir <entry-dir>]\n' >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--require-all) require_all=1 ;;
		--dir)
			[ "$#" -ge 2 ] || usage
			entry_dir="$2"
			shift
			;;
		*) usage ;;
	esac
	shift
done

die() {
	printf '::error::devlog-stamp: %s\n' "$1" >&2
	exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required to read and verify entries"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$root"

# A shallow checkout has no add commit to find and no older tags to find it in,
# so every lookup would fail — or worse, a grafted boundary commit would read as
# the one that added every file. Refuse rather than stamp from a partial history.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
	die "the checkout is shallow — fetch full history and tags (actions/checkout fetch-depth: 0) before stamping"
fi
[ -d "$entry_dir" ] || die "no entry directory at $entry_dir"

# The first plain vX.Y.Z tag containing a commit, without its leading v, or
# nothing. `--sort=v:refname` orders tags as versions (v0.9.0 before v0.10.0),
# and the filter drops pre-release and non-version tags before taking the first.
first_release_containing() {
	local tags
	# Read the tag list on its own, so a failed lookup is an error rather than
	# an empty list that reads exactly like "in no release yet".
	tags="$(git tag --contains "$1" --sort=v:refname --list 'v*')" || return 1
	printf '%s\n' "$tags" |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
		head -n 1 |
		sed 's/^v//' || true
}

stamped=0
unreleased=0
numbered=0
failed=0

for path in "$entry_dir"/*.json; do
	[ -e "$path" ] || continue
	version="$(jq -er '.version' "$path" 2>/dev/null)" || {
		printf '::error::devlog-stamp: %s has no readable "version"\n' "$path" >&2
		failed=$((failed + 1))
		continue
	}
	if [ "$version" != "$PLACEHOLDER" ]; then
		numbered=$((numbered + 1))
		continue
	fi

	# The oldest add is the original one; --follow at 100% similarity carries
	# it across an exact rename and never across a similar sibling.
	anchor="$(git log --follow -M100% --diff-filter=A --format=%H -- "$path" | tail -n 1)" || {
		printf '::error::devlog-stamp: could not read the history of %s\n' "$path" >&2
		failed=$((failed + 1))
		continue
	}
	if [ -z "$anchor" ]; then
		printf '::error::devlog-stamp: %s was never committed, so no release can contain it\n' "$path" >&2
		failed=$((failed + 1))
		continue
	fi

	release="$(first_release_containing "$anchor")" || {
		printf '::error::devlog-stamp: could not list the tags containing %s\n' "$anchor" >&2
		failed=$((failed + 1))
		continue
	}
	if [ -z "$release" ]; then
		printf 'UNRELEASED %s (added in %s, in no release yet)\n' "$path" "$(git rev-parse --short "$anchor")"
		unreleased=$((unreleased + 1))
		continue
	fi

	# Rewrite the one field in place, keeping the file's own formatting, then
	# prove the rewrite by reading it back as JSON rather than trusting the
	# substitution: a pattern that silently matched nothing would ship "next".
	RELEASE="$release" PLACEHOLDER="$PLACEHOLDER" perl -0pi -e \
		's/("version"\s*:\s*)"\Q$ENV{PLACEHOLDER}\E"/$1"$ENV{RELEASE}"/' "$path"
	if [ "$(jq -r '.version' "$path" 2>/dev/null)" != "$release" ]; then
		printf '::error::devlog-stamp: could not rewrite the version in %s\n' "$path" >&2
		failed=$((failed + 1))
		continue
	fi
	printf 'STAMPED %s %s (added in %s)\n' "$path" "$release" "$(git rev-parse --short "$anchor")"
	stamped=$((stamped + 1))
done

printf 'devlog-stamp: %d stamped, %d unreleased, %d numbered untouched\n' \
	"$stamped" "$unreleased" "$numbered"

if [ "$failed" -gt 0 ]; then
	exit 1
fi
if [ "$require_all" -eq 1 ] && [ "$unreleased" -gt 0 ]; then
	printf '::error::devlog-stamp: %d placeholder entry(s) in no release, yet this build is a release — the tag lookup failed\n' \
		"$unreleased" >&2
	exit 1
fi
exit 0
