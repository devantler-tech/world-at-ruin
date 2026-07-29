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
#                not read as "passed" — that is the vacuous pass a partial
#                checkout would otherwise buy. It says the lookup found no
#                introducing commit, which is not the same as a mislabelled
#                version, so the message hands over the search it ran rather
#                than naming a cause it cannot observe.
#   NEVER-CUT    is SPLIT, because it is not one class. Whether the log can be
#                corrected is decided by the release the change DID first reach,
#                not by the fact that its own number was skipped:
#                  - the containing release has no entry of its own and exactly
#                    one never-cut entry wants it -> a single honest answer
#                    exists, so this FAILS like any other drift;
#                  - the release is already occupied, or several never-cut
#                    entries want it -> renaming would have to pick a winner,
#                    which is a decision rather than a mechanical fix, so it is
#                    EXCLUDED and reported with its count.
#                Both halves are load-bearing. Occupancy alone would call two
#                entries competing for a free release correctable and demand
#                they take one name; uniqueness alone would rename an entry onto
#                a release whose own entry is already correct.
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

# The commit whose containment answers "which release first carried this entry",
# in either era.
#
# TWO INDEPENDENT DECISIONS, and getting either wrong buys a vacuous PASS.
#
# WHICH COMMITS ARE VISIBLE. `--full-history`, because the answer must not depend
# on the topology the branch reached its history through. A pathspec-restricted
# `git log` simplifies by default: where a merge is TREESAME to a parent it
# follows only that parent, and where it is TREESAME to SEVERAL it follows the
# first. A branch carrying its own copy of an entry — a duplicate authored in
# parallel, a cherry-pick, a re-applied correction — makes a merge TREESAME to
# both sides, so which introduction survives is decided by which side happens to
# be the first parent. That is a property of how the merge was typed, not of the
# log.
#
# WHICH OF THEM TO ANSWER WITH. Once several introductions are visible, walk
# order cannot choose between them: `--reverse` reverses the walk, it does not
# rank by release. Taking the oldest picks an unreleased branch commit over the
# tagged one whenever the branch authored its copy first, and the entry then
# reads UNRELEASED though the release demonstrably contains it. So the candidates
# are ranked by CONTAINMENT — the earliest release any of them reaches — which is
# the question the verdict actually asks and is answered the same way whichever
# side of the merge each commit sits on.
#
# Takes the first line by expansion rather than by piping to `head`: under
# `pipefail` the early close sends git SIGPIPE, which reads as a failed lookup
# and aborts the sweep on its first entry.
introducing_commit() {
	local out candidate release best='' best_release=''
	out=$(git log --full-history --reverse --format='%h' -S"\"version\": \"$1\"" \
		-- client/scripts/devlog.gd "$ENTRY_DIR") || return 0
	[ -n "$out" ] || return 0
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		release=$(first_release_containing "$candidate")
		[ -n "$release" ] || continue
		# Same shape as the guard's oldest_version: an `if` rather than `&&`, so
		# a final non-match cannot leave the loop non-zero for `set -e`.
		if [ -z "$best_release" ] || version_gt "$best_release" "$release"; then
			best_release="$release"
			best="$candidate"
		fi
	done <<<"$out"
	# No candidate has reached a release at all, so the change is genuinely
	# unshipped and every candidate answers containment identically. The oldest
	# is taken so the report is stable rather than dependent on the walk.
	[ -n "$best" ] || best="${out%%$'\n'*}"
	printf '%s' "$best"
}

total=0
wrong=0
mislabelled=0
no_anchor=0
# Each never-cut entry as `version<TAB>containing release`. The verdict for one
# of them depends on what the OTHERS want, so the decision cannot be made in the
# loop that discovers them and is deferred until the whole set is known. This
# doubles as the never-cut count, so there is no separate counter to keep in
# step with it.
never_cut_rows=()
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
			never_cut_rows+=("$version"$'\t'"$shipped")
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

# Split the never-cut set by whether a one-to-one correction actually exists.
# Only the gate consumes this, so it is computed after the survey has returned.
#
# A release is available to an entry when no entry file occupies it AND exactly
# one never-cut entry wants it. Both conditions are required: the occupancy test
# alone would call two entries competing for a free release correctable and then
# demand they take one name, and the uniqueness test alone would rename an entry
# onto a release whose own entry is already there and correct.
#
# The occupied case stays excluded even where a PERMUTATION would resolve it —
# 0.65.9 vacating 0.65.10 for the entry that had to move there is a real
# precedent in the corrections file. Chaining those moves is more than this gate
# should decide unattended, and excluding it errs toward the status quo rather
# than toward a refusal nobody can act on.
correctable=0
colliding=0
correctable_report=''
if [ "${#never_cut_rows[@]}" -gt 0 ]; then
	for row in "${never_cut_rows[@]}"; do
		version="${row%%$'\t'*}"
		target="${row##*$'\t'}"
		wanted=0
		for other in "${never_cut_rows[@]}"; do
			# An `if` rather than `&&`: a for loop's status is its last
			# iteration's, so a final non-match would leave the loop non-zero and
			# `set -e` would abort the sweep with no verdict — the same trap the
			# guard's first_release_after documents.
			if [ "${other##*$'\t'}" = "$target" ]; then
				wanted=$((wanted + 1))
			fi
		done
		if [ -e "$ENTRY_DIR/$target.json" ] || [ "$wanted" -ne 1 ]; then
			colliding=$((colliding + 1))
		else
			correctable=$((correctable + 1))
			correctable_report+="$(printf '\n  %-10s -> v%s' "$version" "$target")"
		fi
	done
fi

# The exclusion is stated on every gate run, passing or failing. A count that is
# only mentioned when it happens to be non-zero is an exclusion nobody can see,
# and this one decides whether an entry may keep naming a build that never
# existed. It counts only what it actually excluded — an entry whose containing
# release is free and uniquely wanted is refused below, not counted here — so
# the reason it gives is true of the set it names.
printf 'dev-log entry version gate: %d NEVER-CUT entr%s excluded — the release that first contains each is already occupied or wanted by more than one entry, so no one-to-one correction exists.\n' \
	"$colliding" "$([ "$colliding" -eq 1 ] && printf y || printf ies)"

if [ "$no_anchor" -ne 0 ]; then
	# States what the lookup did and hands over the command to repeat, rather
	# than naming a cause. The earlier wording asserted a shallow fetch or an
	# unreadable file; when neither was true that sent the reader looking for
	# something that was not there, which on a blocking gate costs more than the
	# missing verdict itself. Anything this can say about the cause is a guess —
	# what it can say exactly is which search returned nothing.
	printf 'dev-log entry version gate: FAIL — %d entr%s could not be anchored to an introducing commit, so no verdict was reached; "could not evaluate" must not read as "passed". The anchor is the first commit in THIS checkout whose diff introduces the entry version string under client/scripts/devlog.gd or %s. Repeat that search for an entry listed NO-ANCHOR above with:\n  git log --full-history --reverse -S%s -- client/scripts/devlog.gd %s\nAn empty result means this checkout holds no such commit: its history is partial or rewritten, or the entry file did not parse and no version was read. An entry whose introducing commit genuinely cannot be found is resolved by listing it in %s with the anchor commit whose change it describes.\n' \
		"$no_anchor" "$([ "$no_anchor" -eq 1 ] && printf y || printf ies)" \
		"$ENTRY_DIR" '"\"version\": \"<version>\""' "$ENTRY_DIR" "$CORRECTIONS_FILE" >&2
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

if [ "$correctable" -ne 0 ]; then
	printf 'dev-log entry version gate: FAIL — %d never-cut entr%s below. Each has one release that contains it and nothing else claims, so a single correct answer exists and this is drift rather than an open decision:%s\nRename the file and its version field onto that release together, and list it in %s with the anchor commit whose change it describes.\n' \
		"$correctable" \
		"$([ "$correctable" -eq 1 ] && printf y || printf ies)" \
		"$correctable_report" \
		"$CORRECTIONS_FILE" >&2
	exit 1
fi

printf 'dev-log entry version gate: PASS — no entry names a release that does not contain it.\n'
