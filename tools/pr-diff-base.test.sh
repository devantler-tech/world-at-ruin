#!/usr/bin/env bash
# Proves tools/pr-diff-base.sh resolves the base the player-visible gate should
# diff against, and that the gate is actually wired to it.
#
# Three layers, kept apart on purpose. The resolution logic is driven through the
# sourced function rather than a copy; the DECISION is driven end-to-end against
# real commits in a real repository, because a stale base only reproduces when
# the base branch moves after the PR is opened and no amount of string checking
# would show that; and the CI wiring is asserted separately, since a resolver
# that is correct but unwired passes every one of its own tests.
#
# The end-to-end layer greps with the pattern EXTRACTED FROM ci.yaml rather than
# a copy pasted here, so the classification this test blesses cannot drift from
# the one that ships.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/tools/pr-diff-base.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0
SCRATCH_DIR=''

t_fail() {
	printf 'pr diff base test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

SCRATCH_DIR="$(mktemp -d)"

# shellcheck source=/dev/null
. "$RESOLVER"

# --- The production visual pattern, read out of the workflow ----------------
# Pulling it from ci.yaml is what stops this test proving something about a
# pattern the workflow no longer uses.
visual_pattern="$(
	grep -oE "grep -qE '\^client/\(scripts\|shaders[^']*'" "$WORKFLOW" |
		head -1 | sed -E "s/^grep -qE '//; s/'$//"
)"
if [ -z "$visual_pattern" ]; then
	t_fail "could not extract the visual path pattern from ci.yaml — the end-to-end layer would prove nothing"
fi

# --- Fixture: a docs-only PR, with main advancing underneath it -------------
# This is the shape from #494: the PR changes no client path, but a client
# change lands on main after the PR is opened.
build_fixture() {
	local dir="$1" pr_change="$2"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q -b main
	git -C "$dir" config user.email t@example.com
	git -C "$dir" config user.name t
	mkdir -p "$dir/docs" "$dir/client/scripts"
	echo base > "$dir/docs/readme.md"
	echo base > "$dir/client/scripts/foo.gd"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m c0
	# The frozen base: what github.event.pull_request.base.sha would carry.
	git -C "$dir" rev-parse HEAD > "$dir/.frozen_base"

	git -C "$dir" checkout -q -b pr
	mkdir -p "$dir/$(dirname "$pr_change")"
	echo pr > "$dir/$pr_change"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m pr-change
	git -C "$dir" rev-parse HEAD > "$dir/.head_sha"

	# main advances with an unrelated client change, exactly as #494 measured.
	git -C "$dir" checkout -q main
	echo advanced > "$dir/client/scripts/foo.gd"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m unrelated-client-change

	# GitHub's merge ref: parent1 = current main, parent2 = the PR head.
	git -C "$dir" merge -q --no-ff pr -m merge-ref
}

# Takes the git-diff arguments verbatim, so the control can drive the frozen
# three-dot form and the fix can drive a plain two-revision diff without this
# helper quietly reshaping either one.
classify() {
	local dir="$1"
	shift
	git -C "$dir" diff --name-only "$@" > "$dir/changed.txt"
	if grep -qE "$visual_pattern" "$dir/changed.txt"; then echo true; else echo false; fi
}

# --- Layer 1 + 2: the docs-only PR ------------------------------------------
FIX="$SCRATCH_DIR/docs-only"
build_fixture "$FIX" "docs/new.md"
frozen="$(cat "$FIX/.frozen_base")"
head_sha="$(cat "$FIX/.head_sha")"

# CONTROL. The fixture is only meaningful if the OLD form actually misfires on
# it. If this ever reads false, the fixture stopped reproducing #494 and every
# assertion below would pass vacuously.
old_verdict="$(classify "$FIX" "$frozen...HEAD" 2>/dev/null || echo ERROR)"
if [ "$old_verdict" != "true" ]; then
	t_fail "control: the frozen-base form should misclassify this docs-only PR as visual (got '$old_verdict') — the fixture no longer reproduces #494"
fi

resolved="$(cd "$FIX" && resolve_pr_diff_base "$head_sha" "$frozen" || echo NONE)"
if [ "$resolved" = "NONE" ]; then
	t_fail "resolver returned nothing on a merge-ref checkout"
else
	expected_parent="$(git -C "$FIX" rev-parse 'HEAD^1')"
	if [ "$resolved" != "$expected_parent" ]; then
		t_fail "resolver should return the merge ref's first parent ($expected_parent), got $resolved"
	fi
	new_verdict="$(classify "$FIX" "$resolved" HEAD)"
	if [ "$new_verdict" != "false" ]; then
		t_fail "a docs-only PR must report visual=false regardless of what merged to main (got '$new_verdict')"
	fi
fi

# --- Layer 2a: the EXECUTABLE form, which is what the workflow actually runs --
# The sourced function and the executed script are different entry points, and
# ci.yaml calls the executed one. Testing only the function would leave the
# shipping invocation — including its argument order — unproven.
exec_resolved="$(cd "$FIX" && "$RESOLVER" "$head_sha" "$frozen" || echo NONE)"
if [ "$exec_resolved" = "NONE" ]; then
	t_fail "executing tools/pr-diff-base.sh resolved nothing on a merge-ref checkout"
elif [ "$exec_resolved" != "$(git -C "$FIX" rev-parse 'HEAD^1')" ]; then
	t_fail "the executed script disagrees with the sourced function (got '$exec_resolved')"
elif [ "$(classify "$FIX" "$exec_resolved" HEAD)" != "false" ]; then
	t_fail "the executed script's base still misclassifies a docs-only PR as visual"
fi

# --- Layer 2b: a genuine visual change is still caught -----------------------
# The fix must not buy quiet by loosening the gate.
FIX_VIS="$SCRATCH_DIR/visual"
build_fixture "$FIX_VIS" "client/scripts/bar.gd"
resolved_vis="$(cd "$FIX_VIS" && resolve_pr_diff_base "$(cat "$FIX_VIS/.head_sha")" "$(cat "$FIX_VIS/.frozen_base")" || echo NONE)"
if [ "$resolved_vis" = "NONE" ]; then
	t_fail "resolver returned nothing on the visual fixture"
elif [ "$(classify "$FIX_VIS" "$resolved_vis" HEAD)" != "true" ]; then
	t_fail "a PR that genuinely touches a visual path must still report visual=true"
fi

# --- Layer 2c: HEAD is a merge commit that is NOT the merge ref --------------
# A contributor who merges main into their own branch makes the PR head itself a
# merge commit. Taking HEAD^1 blindly would diff from that branch's previous
# commit and silently under-report.
FIX_OWN="$SCRATCH_DIR/own-merge"
build_fixture "$FIX_OWN" "client/scripts/bar.gd"
git -C "$FIX_OWN" checkout -q pr
git -C "$FIX_OWN" merge -q --no-ff main -m "contributor merges main" || true
own_head="$(git -C "$FIX_OWN" rev-parse HEAD)"
# The event's head sha IS this merge commit, so HEAD^2 (main) must not be
# mistaken for it — the resolver must fall back rather than take HEAD^1.
resolved_own="$(cd "$FIX_OWN" && resolve_pr_diff_base "$own_head" "$(cat "$FIX_OWN/.frozen_base")" || echo NONE)"
if [ "$resolved_own" = "NONE" ]; then
	t_fail "resolver should fall back to the frozen base when HEAD is the contributor's own merge, not the merge ref"
elif [ "$resolved_own" = "$(git -C "$FIX_OWN" rev-parse 'HEAD^1')" ]; then
	t_fail "resolver took HEAD^1 on a non-merge-ref checkout — that diffs from an arbitrary point in the feature branch"
fi

# --- Layer 2d: fail open when nothing resolves -------------------------------
FIX_NONE="$SCRATCH_DIR/none"
rm -rf "$FIX_NONE"; mkdir -p "$FIX_NONE"
git -C "$FIX_NONE" init -q -b main
git -C "$FIX_NONE" config user.email t@example.com
git -C "$FIX_NONE" config user.name t
echo x > "$FIX_NONE/f"; git -C "$FIX_NONE" add -A; git -C "$FIX_NONE" commit -q -m only
if (cd "$FIX_NONE" && resolve_pr_diff_base "" "0000000000000000000000000000000000000000") >/dev/null 2>&1; then
	t_fail "resolver must return non-zero when neither a merge ref nor a reachable base exists, so the caller fails open"
fi

# The same failure must surface through the EXECUTED script's exit status, or
# `if ! DIFF_BASE="$(...)"` in the workflow never reaches its fail-open branch.
if (cd "$FIX_NONE" && "$RESOLVER" "" "0000000000000000000000000000000000000000") >/dev/null 2>&1; then
	t_fail "the executed script must exit non-zero when it cannot resolve, so the workflow fails open"
fi

# --- Layer 3: the CI wiring --------------------------------------------------
# A resolver nothing calls is a resolver that proves nothing.
detect_block="$(sed -n '/^  detect-visual-changes:/,/^  frame-capture:/p' "$WORKFLOW")"

if ! printf '%s' "$detect_block" | grep -q 'pr-diff-base\.sh'; then
	t_fail "detect-visual-changes does not call tools/pr-diff-base.sh — the gate still resolves its own base"
fi

# The single quotes are the point: this matches the LITERAL text `$BASE_SHA` in
# the workflow, so expanding it here would search for this shell's value instead.
# shellcheck disable=SC2016
if printf '%s' "$detect_block" | grep -qE 'git diff --name-only "\$BASE_SHA"\.\.\.HEAD'; then
	t_fail "detect-visual-changes still diffs from the frozen \$BASE_SHA — that is the #494 defect"
fi

# The fail-open guard is the reason a stale base was only ever a cost defect.
# Losing it would turn this from over-triggering into silently skipping evidence.
for output in visual first_run export_affecting gpu_gated; do
	if ! printf '%s' "$detect_block" | grep -q "echo \"$output=true\""; then
		t_fail "the fail-open branch no longer sets $output=true"
	fi
done

if ! grep -q './tools/pr-diff-base.test.sh' "$WORKFLOW"; then
	t_fail "this test is not wired into ci.yaml — it would never run"
fi

# --- Layer 3b: the gate must not be classified by its OWN resolver -----------
# A PR that changes the resolver cannot be classified by it: a regression
# returning an empty diff would zero all four outputs and skip the required
# capture on a player-visible change in the same PR.
#
# Note WHY a path pattern cannot close this, and why this test does not check
# for one: with an empty changed.txt no pattern matches, including the
# resolver's own. The guard must therefore run BEFORE the resolver and use a
# resolver-independent base.
resolver_rel="tools/$(basename "$RESOLVER")"

if ! printf '%s' "$detect_block" | grep -qE "grep -qE '\^tools/pr-diff-base\\\\\.sh\\\$'"; then
	t_fail "no resolver-change guard in detect-visual-changes — a PR editing $resolver_rel would be classified by the very file it changes"
fi

# The guard is only resolver-independent if it derives its own diff, before the
# resolver is consulted. Order is the property, so assert it by line position.
guard_line="$(printf '%s' "$detect_block" | grep -n 'gate_machinery\.txt' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # literal workflow text, must not expand
resolve_line="$(printf '%s' "$detect_block" | grep -n 'DIFF_BASE="\$(\./tools/pr-diff-base\.sh' | head -1 | cut -d: -f1)"
if [ -z "$guard_line" ] || [ -z "$resolve_line" ]; then
	t_fail "could not locate both the resolver-change guard and the resolve step — cannot prove their order"
elif [ "$guard_line" -ge "$resolve_line" ]; then
	t_fail "the resolver-change guard runs at or after the resolver (guard line $guard_line, resolve line $resolve_line) — it must precede it to stay independent"
fi

# It must key off the FROZEN base, which no resolver regression can influence.
# shellcheck disable=SC2016  # literal workflow text, must not expand
if ! printf '%s' "$detect_block" | grep -qE 'git diff --name-only "\$BASE_SHA" HEAD > gate_machinery\.txt'; then
	t_fail "the resolver-change guard does not diff from the frozen \$BASE_SHA — a resolver regression could then suppress the guard that exists to catch it"
fi

# And the guard's pattern must name the file that actually ships, or a rename
# leaves a guard that matches nothing while still reading as present.
if [ ! -f "$ROOT/$resolver_rel" ]; then
	t_fail "the guarded path $resolver_rel does not exist — the guard would match nothing"
fi

if [ "$failures" -ne 0 ]; then
	printf 'pr diff base test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'pr diff base test: OK\n'
