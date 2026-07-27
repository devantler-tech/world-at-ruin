#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

# Exercise the exact function embedded in the CD run block rather than a
# test-only copy that could drift from production.
helper_file="${test_dir}/cask-branch-reset-helper.sh"
sed -n \
	'/# BEGIN cask-branch-reset-helper/,/# END cask-branch-reset-helper/p' \
	"${workflow}" >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"
if ! declare -F cask_branch_needs_reset >/dev/null; then
	echo "missing cask_branch_needs_reset production helper in ${workflow}" >&2
	exit 1
fi

tap="devantler-tech/homebrew-tap"
branch="goreleaser/world-at-ruin"

call_file="${test_dir}/calls"
: >"${call_file}"

# Mock the comparison API the helper reads. `mock_behind` is what the tap would
# report; `mock_fail` makes the read itself fail. Names are deliberately
# `mock_`-prefixed: the helper declares `local behind`, which would otherwise
# shadow a same-named global and (under `set -u`) kill the substitution.
gh() {
	printf '%s\n' "$*" >>"${call_file}"
	if [ "${mock_fail}" = "1" ]; then
		return 1
	fi
	printf '%s\n' "${mock_behind}"
}

# The helper calls this production helper, which lives outside the extracted
# block. Stub it so version agreement can be driven per case.
cask_version_at() {
	if [ "$1" = "main" ]; then
		printf '%s' "${mock_main_version}"
	else
		printf '%s' "${mock_branch_version}"
	fi
}

mock_fail=0
mock_behind=0
# Default: the branch's content has already been delivered to main, which is the
# post-squash-merge state the reset targets.
mock_branch_version="0.43.0"
mock_main_version="0.43.0"

# --- The defect: previous PR squash-merged, branch left behind main. --------
mock_behind=1
if ! cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "a branch behind main with no open PR must be reset — that is the defect" >&2
	exit 1
fi

# The comparison must be asked in the base...head order that makes behind_by
# mean "main has commits the branch does not".
if ! grep -q "compare/main\.\.\.${branch}" "${call_file}"; then
	echo "helper did not compare main...${branch}" >&2
	exit 1
fi

# --- Safety control: never reset while a cask PR is open. ------------------
# A live PR is an in-flight release; resetting would discard it. This must
# hold even when the branch really is behind, so keep mock_behind=1.
: >"${call_file}"
if cask_branch_needs_reset "${tap}" "${branch}" "1248"; then
	echo "reset was allowed while a cask PR was open — that discards an in-flight release" >&2
	exit 1
fi
if [ -s "${call_file}" ]; then
	echo "the open-PR refusal must short-circuit before any API read" >&2
	exit 1
fi

# --- Safety control: an UNREADABLE open-PR state is not "no PR". ----------
# The call site maps a failed PR query to a sentinel rather than the empty
# string, because the query yields empty for "none open" AND for "the call
# failed". Treating those alike would reset under a live release.
: >"${call_file}"
if cask_branch_needs_reset "${tap}" "${branch}" "UNKNOWN"; then
	echo "reset was allowed while the open-PR state was unreadable" >&2
	exit 1
fi

# The call site must actually pass that sentinel, not a bare query.
if ! grep -q 'trusted_open_pr || echo UNKNOWN' "${workflow}"; then
	echo "reset call site does not fail closed on an unreadable PR query" >&2
	exit 1
fi

# --- A DIVERGED branch whose content is delivered must still reset. --------
# The tap squash-merges, so after a merge the branch keeps its own commits
# while main gains a non-ancestor squash: the reported defect measured 4 ahead
# and 1 behind. A guard that refused every diverged branch would make this a
# no-op in exactly the case it targets, so pin that it still resets.
mock_behind=1
mock_branch_version="0.43.0"
mock_main_version="0.43.0"
if ! cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "a diverged branch whose cask version is already on main must reset" >&2
	exit 1
fi

# --- Safety control: UNDELIVERED branch content is never discarded. --------
# A concurrent run that wrote the cask but has not yet opened its PR leaves the
# branch naming a version main does not carry. That content must survive.
mock_branch_version="0.44.0"
mock_main_version="0.43.0"
if cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "reset discarded branch content that main has not received" >&2
	exit 1
fi
mock_branch_version="0.43.0"
mock_main_version="0.43.0"

# --- Safety control: a concurrent run's unmerged write is ahead-only. ------
# A release that has written content but not yet opened its PR leaves the
# branch AHEAD of main, never behind. Resetting there would throw away a
# published release's cask.
mock_behind=0
if cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "an ahead-only branch was reset — that discards a concurrent run's write" >&2
	exit 1
fi

# --- Fail closed: an unreadable comparison must not force-write a ref. -----
mock_fail=1
if cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "a failed comparison must fail closed, not reset on a guess" >&2
	exit 1
fi

# --- Fail closed: a non-numeric body is not a comparison. ------------------
mock_fail=0
mock_behind="not-a-number"
if cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "a non-numeric behind_by must fail closed" >&2
	exit 1
fi

# An empty body (jq found no such field) is the same class.
mock_behind=""
if cask_branch_needs_reset "${tap}" "${branch}" ""; then
	echo "an empty behind_by must fail closed" >&2
	exit 1
fi

# --- The reset call site keeps the properties the step already guarantees. --
# The helper alone cannot prove the workflow wires it in correctly, so pin the
# ordering that makes the reset safe: it happens BEFORE the content
# compare-and-swap, and the force-write is gated on the helper.
reset_line="$(grep -n 'elif cask_branch_needs_reset' "${workflow}" | head -1 | cut -d: -f1)"
patch_line="$(grep -n 'git/refs/heads/.*-X PATCH' "${workflow}" | head -1 | cut -d: -f1)"
put_line="$(grep -n 'contents/Casks/world-at-ruin.rb" -X PUT' "${workflow}" | head -1 | cut -d: -f1)"
for name in reset_line patch_line put_line; do
	if [ -z "${!name}" ]; then
		echo "could not locate ${name} in ${workflow}" >&2
		exit 1
	fi
done
if [ "${reset_line}" -ge "${patch_line}" ]; then
	echo "the ref force-write must be gated by cask_branch_needs_reset" >&2
	exit 1
fi
if [ "${patch_line}" -ge "${put_line}" ]; then
	echo "the branch reset must happen before the cask content write" >&2
	exit 1
fi
