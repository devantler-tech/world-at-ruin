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
#   NEVER-CUT   it names a version that was never released at all, and says
#               nothing about where its change actually landed.
#   PRE-RELEASE it names a version that was never cut, AND declares the release
#               its change first reached players in — verified here against
#               containment, so it is a resolved entry rather than drift. This
#               is what the entries written before the first tag look like once
#               they say so; the log renders them as notes rather than builds.
#   UNRELEASED  its change is not in any release yet, so the forward-looking
#               rule applies and there is nothing to correct.
#   NO-ANCHOR   the version string cannot be traced to an introducing commit, so
#               this entry is not judged either way rather than guessed at.
#
# Read-only: it prints a report and changes nothing. Correcting an entry is a
# reviewed act through tools/devlog-entry-corrections.tsv.
#
# TWO MODES.
#   (default)  Survey. Exits 0 whatever it finds, so the whole picture can be
#              read in one pass without a non-zero status truncating it.
#   --gate     CI gate. Exits non-zero when an entry is MISLABELLED, or when a
#              verdict could not be reached at all.
#
# WHY A GATE HERE AND NOT ONLY IN THE VERSION GUARD. The guard checks entries a
# change ADDS, against the tags that exist while the branch is open. That is a
# floor, not a guarantee: the tag an entry must beat does not exist yet when it
# is checked, so two changes merging back-to-back can each pass and still leave
# the second one naming a release cut before its code existed (#467). This runs
# over the whole entry directory instead of over added files, so it sees that
# drift on the next change, and it covers the guard's permutation blind spot —
# a bulk correction moves entries onto paths that already existed, which read as
# modifications rather than additions.
#
# WHAT THE GATE FAILS ON, and why that is not the same as `wrong`.
#   MISLABELLED  fails. The entry names a real release that does not contain it,
#                which is the drift this gate exists to stop regressing.
#   NO-ANCHOR    fails. No verdict was reached, and "could not evaluate" must
#                not read as "passed" — that is the vacuous pass a shallow fetch
#                would otherwise buy. No entry reads this way in a full-history
#                checkout, so it indicates broken anchoring rather than a
#                mislabelled entry, and the message says so.
#   NEVER-CUT    is EXCLUDED, deliberately and by name rather than incidentally.
#                These 17 entries predate the repo's first tag or were overtaken
#                onto a version never released at all. Unlike MISLABELLED they
#                have no one-to-one correction — fourteen of them collide onto
#                v0.1.15 — so what the log should say is an open decision in
#                #466, not a mechanical fix. Failing them would gate every
#                change in the repo on that decision. When #466 lands, this
#                exclusion is what should be removed.
#   OK           passes.
#   UNRELEASED   passes. The entry's change has not shipped, so the
#                forward-looking rule owns it and there is nothing to compare.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Reuse the guard's comparison and containment logic rather than a second copy,
# so the sweep can never disagree with the check it feeds.
# shellcheck source=/dev/null
source "$ROOT/tools/devlog-entry-version-guard.sh"

# An unrecognised argument is an error rather than a silent survey: a typo'd
# `--gate` in CI would otherwise exit 0 on every run and read as a passing gate
# that was never actually enforcing anything.
gate=0
for arg in "$@"; do
	case "$arg" in
	--gate) gate=1 ;;
	*) fail "unknown argument '$arg' — the only option is --gate" ;;
	esac
done

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
mislabelled=0
never_cut=0
no_anchor=0
printf '%-10s  %-9s  %-9s  %s\n' ENTRY ANCHOR SHIPPED VERDICT
while IFS= read -r file; do
	version=$(declared_version "$file")
	[ -n "$version" ] || {
		no_anchor=$((no_anchor + 1))
		printf '%-10s  %-9s  %-9s  %s\n' "$(basename "$file")" - - 'NO-ANCHOR (unreadable entry)'
		continue
	}
	total=$((total + 1))

	anchor=$(correction_anchor "$file")
	[ -n "$anchor" ] || anchor=$(introducing_commit "$version")
	if [ -z "$anchor" ]; then
		no_anchor=$((no_anchor + 1))
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
		# A declared entry is resolved, not drift — but only when its declaration
		# agrees with containment. The guard proves the same claim from tag
		# succession; checking it here against the anchor keeps the two routes
		# independent, so a declaration that satisfies one and not the other is
		# reported rather than averaged away.
		if [ "$(declared_shipped_in "$file")" = "$shipped" ]; then
			printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" 'PRE-RELEASE'
		else
			wrong=$((wrong + 1))
			never_cut=$((never_cut + 1))
			printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" 'NEVER-CUT'
		fi
	else
		wrong=$((wrong + 1))
		mislabelled=$((mislabelled + 1))
		printf '%-10s  %-9s  %-9s  %s\n' "$version" "$anchor" "$shipped" MISLABELLED
	fi
done < <(find "$ENTRY_DIR" -name '*.json' | sort)

printf '\n%d of %d entries name a release that does not contain them.\n' "$wrong" "$total"

[ "$gate" -eq 1 ] || exit 0

# The exclusion is stated on every gate run, passing or failing. A count that is
# only mentioned when it happens to be non-zero is an exclusion nobody can see,
# and this one is load-bearing enough to need reviewing when #466 lands.
printf 'dev-log entry version gate: %d NEVER-CUT entr%s excluded — no one-to-one correction exists for them, tracked in #466.\n' \
	"$never_cut" "$([ "$never_cut" -eq 1 ] && printf y || printf ies)"

if [ "$no_anchor" -ne 0 ]; then
	printf 'dev-log entry version gate: FAIL — %d entr%s could not be anchored to an introducing commit, so no verdict was reached. In a full-history checkout every entry anchors; this points at a shallow fetch or an unreadable entry file, not at a mislabelled version.\n' \
		"$no_anchor" "$([ "$no_anchor" -eq 1 ] && printf y || printf ies)" >&2
	exit 1
fi

if [ "$mislabelled" -ne 0 ]; then
	printf 'dev-log entry version gate: FAIL — %d entr%s name a release that does not contain %s. The SHIPPED column above is the release that actually first contains each one. Correct it by renaming the file and its version field together, and listing it in %s with the anchor commit whose change it describes.\n' \
		"$mislabelled" \
		"$([ "$mislabelled" -eq 1 ] && printf y || printf ies)" \
		"$([ "$mislabelled" -eq 1 ] && printf it || printf them)" \
		"$CORRECTIONS_FILE" >&2
	exit 1
fi

printf 'dev-log entry version gate: PASS — no entry names a release that does not contain it.\n'
