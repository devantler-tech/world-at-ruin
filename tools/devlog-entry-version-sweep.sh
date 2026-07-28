#!/usr/bin/env bash
# Report which dev-log entries name a release that does not contain them.
#
# The version guard checks entries a change ADDS, which is prevention: it stops
# the next mislabelling and says nothing about the ones already on main. This
# sweeps what is already there, so "is any other entry wrong?" is a question
# with an evaluable answer rather than an assumption.
#
# ANCHORING. An entry's own add-commit cannot answer it: the one-file-per-entry
# migration created every existing entry file in a single commit, so that commit
# is identical for all of them. The usable anchor is the commit that first
# introduced the entry's version string — into client/scripts/devlog.gd for
# entries authored while the log was one shared array, or into the entry file
# itself for anything authored since. That is the change the entry describes,
# because an entry lands in the same change as the work it announces.
#
# WHAT A VERDICT MEANS.
#   OK          the entry names the first release containing its change.
#   MISLABELLED it names some other release — the reported one is where the
#               change actually first shipped.
#   NEVER-CUT   it names a version that was never released at all. Entries
#               predating the first tag read this way.
#   UNRELEASED  its change is not in any release yet, so the forward-looking
#               rule applies and there is nothing to correct.
#   NO-ANCHOR   the version string cannot be traced to an introducing commit, so
#               this entry is not judged either way rather than guessed at.
#
# Read-only: it prints a report and changes nothing. Exit status is 0 whatever
# it finds — it is a survey, not a gate, and correcting an entry is a reviewed
# act through tools/devlog-entry-corrections.tsv.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Reuse the guard's comparison and containment logic rather than a second copy,
# so the sweep can never disagree with the check it feeds.
# shellcheck source=/dev/null
source "$ROOT/tools/devlog-entry-version-guard.sh"

[ -n "$(released_versions | newest_version)" ] ||
	fail 'no release tags are visible in this checkout — every entry would read as never-cut (a shallow fetch hides them)'

# The commit that first introduced this version string, in either era.
#
# Takes the first line by expansion rather than by piping to `head`: under
# `pipefail` the early close sends git SIGPIPE, which reads as a failed lookup
# and aborts the sweep on its first entry.
introducing_commit() {
	local out
	out=$(git log --reverse --format='%h' -S"\"version\": \"$1\"" \
		-- client/scripts/devlog.gd "$ENTRY_DIR") || return 0
	printf '%s' "${out%%$'\n'*}"
}

total=0
wrong=0
printf '%-10s  %-9s  %-9s  %s\n' ENTRY ANCHOR SHIPPED VERDICT
while IFS= read -r file; do
	version=$(declared_version "$file")
	[ -n "$version" ] || {
		printf '%-10s  %-9s  %-9s  %s\n' "$(basename "$file")" - - 'NO-ANCHOR (unreadable entry)'
		continue
	}
	total=$((total + 1))

	anchor=$(correction_anchor "$file")
	[ -n "$anchor" ] || anchor=$(introducing_commit "$version")
	if [ -z "$anchor" ]; then
		printf '%-10s  %-9s  %-9s  %s\n' "$version" - - NO-ANCHOR
		continue
	fi
	anchor=$(git rev-parse --short "$anchor")

	shipped=$(first_release_containing "$anchor")
	if [ -z "$shipped" ]; then
		printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" - UNRELEASED
	elif [ "$shipped" = "$version" ]; then
		printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" OK
	elif [ -z "$(git tag --list "v$version")" ]; then
		wrong=$((wrong + 1))
		printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" 'NEVER-CUT'
	else
		wrong=$((wrong + 1))
		printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" MISLABELLED
	fi
done < <(find "$ENTRY_DIR" -name '*.json' | sort)

printf '\n%d of %d entries name a release that does not contain them.\n' "$wrong" "$total"
