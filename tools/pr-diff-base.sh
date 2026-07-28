#!/usr/bin/env bash
# Resolve the commit the player-visible gate diffs against.
#
# `actions/checkout` materialises the PR MERGE REF, which GitHub rebuilds against
# current `main`, while `github.event.pull_request.base.sha` is frozen at
# PR-creation time and never advances on `synchronize`. Diffing the frozen base
# against the merge ref therefore reports every commit merged to `main` since the
# PR opened as though this PR had made it. `main` merges roughly every ten
# minutes here, so any PR open longer than that inherits an unrelated
# `client/**` change and pays for a 30-minute-bounded macOS GPU capture it has no
# use for — and a reviewer sees frame evidence attached to a PR that changed no
# frame.
#
# The merge ref's FIRST parent is the base-branch commit GitHub built it against.
# Diffing that parent against the merge ref reports exactly what merging this PR
# would change about `main`, and stays correct as `main` advances, because the
# parent advances with it.
#
# A stale base can only ADD files to the diff, so the gate it feeds can only
# over-trigger, never under-trigger. That is why this resolves conservatively and
# why callers fail OPEN when it cannot resolve: costing a capture is the safe
# direction, silently skipping evidence is not.
set -euo pipefail

# resolve_pr_diff_base <head_sha> <fallback_base_sha>
#
# Prints the revision to diff FROM. Returns 1 when neither strategy applies, so
# the caller can fail open rather than diff against nothing.
#
# `HEAD^2` alone does not prove we are on a merge ref: a contributor who merges
# `main` into their own branch makes the PR HEAD itself a merge commit, and its
# first parent is that branch's previous commit rather than any base. Requiring
# `HEAD^2` to equal the PR head sha is what distinguishes the two, and it is the
# difference between diffing from the base branch and diffing from an arbitrary
# point in someone's feature branch.
resolve_pr_diff_base() {
	local head_sha="${1-}"
	local fallback="${2-}"
	local second_parent

	if second_parent="$(git rev-parse --verify --quiet 'HEAD^2' 2>/dev/null)"; then
		if [ -n "$head_sha" ] && [ "$second_parent" = "$(git rev-parse --verify --quiet "$head_sha" 2>/dev/null || true)" ]; then
			git rev-parse 'HEAD^1'
			return 0
		fi
	fi

	# Not the merge ref — the head sha itself is checked out, or the event gave
	# us no head to confirm against. The frozen base is still a correct starting
	# point in that shape, because the PR's own commits are what descend from it.
	if [ -n "$fallback" ] && git cat-file -e "$fallback" 2>/dev/null; then
		git merge-base "$fallback" HEAD
		return 0
	fi

	return 1
}

# Executed rather than sourced: print the resolved base for the workflow step.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	resolve_pr_diff_base "${1-}" "${2-}"
fi
