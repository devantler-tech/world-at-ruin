#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

# Exercise the exact function embedded in the CD run block rather than a
# test-only copy that could drift from production.
helper_file="${test_dir}/cask-conflict-repair-helper.sh"
sed -n \
	'/# BEGIN cask-conflict-repair-helper/,/# END cask-conflict-repair-helper/p' \
	"${workflow}" >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"
if ! declare -F cask_pr_conflicts >/dev/null; then
	echo "missing cask_pr_conflicts production helper in ${workflow}" >&2
	exit 1
fi

tap="devantler-tech/homebrew-tap"
pr="1248"

call_file="${test_dir}/calls"

# Mock the pull-request read the helper polls. `mock_states` is the sequence of
# mergeable_state values GitHub reports across successive reads, so a case can
# describe a state that RESOLVES rather than only a steady one. `mock_fail`
# makes the read itself fail. Names are `mock_`-prefixed because the helper
# declares `local state`, which would otherwise shadow a same-named global and
# (under `set -u`) kill the substitution.
mock_fail=0
mock_states=()
# The helper reads `gh` through a command substitution, which runs in a
# SUBSHELL — so the cursor cannot be a shell variable, or every read would see
# the first state again and no case could describe a state that resolves.
index_file="${test_dir}/index"
gh() {
	printf '%s\n' "$*" >>"${call_file}"
	if [ "${mock_fail}" = "1" ]; then
		return 1
	fi
	local at last
	at="$(cat "${index_file}")"
	printf '%s\n' "$((at + 1))" >"${index_file}"
	# Hold the last value once the sequence runs out, so a steady state is
	# written as a one-element sequence.
	last=$((${#mock_states[@]} - 1))
	[ "${at}" -gt "${last}" ] && at="${last}"
	printf '%s\n' "${mock_states[at]}"
}

# The polling helper sleeps between attempts. Stub it out so the suite does not
# spend the production backoff, and record the calls so the bound stays pinned.
sleep() { printf 'sleep %s\n' "$1" >>"${call_file}"; }

reset_mock() {
	mock_fail=0
	mock_states=("$@")
	printf '0\n' >"${index_file}"
	: >"${call_file}"
}

# --- The defect: the PR GitHub reports as conflicting must be repaired. -----
# A previous cask PR that auto-merged after the branch-reset check leaves this
# run's PR born conflicting. Nothing else in the step notices, and because the
# PR then stays open it suppresses every later cycle's reset.
reset_mock dirty
if ! cask_pr_conflicts "${tap}" "${pr}"; then
	echo "a conflicting cask PR was not detected — that is the defect" >&2
	exit 1
fi

# The helper must ask about the PR itself, not the branch comparison: the
# comparison is what already went stale.
if ! grep -q "repos/${tap}/pulls/${pr}" "${call_file}"; then
	echo "helper did not read repos/${tap}/pulls/${pr}" >&2
	exit 1
fi

# --- Negative control: a mergeable PR must never be rebuilt. ---------------
# Repairing a clean PR would force-write the shared tap branch on every single
# release, which is the force-write the reset guard exists to bound.
reset_mock clean
if cask_pr_conflicts "${tap}" "${pr}"; then
	echo "a clean cask PR was reported as conflicting — that force-writes the tap branch every release" >&2
	exit 1
fi

# --- Negative control: pending checks are not a conflict. ------------------
# `blocked` and `unstable` mean the required checks have not passed yet, which
# is the ordinary state of a freshly opened cask PR waiting on the tap's
# audit/style/script jobs. Treating either as a conflict would rebuild the
# branch under a PR that was going to merge on its own.
for state in blocked unstable behind has_hooks draft; do
	reset_mock "${state}"
	if cask_pr_conflicts "${tap}" "${pr}"; then
		echo "mergeable_state '${state}' was treated as a conflict" >&2
		exit 1
	fi
done

# --- GitHub computes mergeability ASYNCHRONOUSLY: one read is not an answer. -
# A just-created PR reports `unknown` until GitHub finishes the background
# merge test. A helper that read once would take that for "not conflicting"
# and miss the defect on exactly the PR this run just opened — the common case.
reset_mock unknown unknown dirty
if ! cask_pr_conflicts "${tap}" "${pr}"; then
	echo "helper gave up while GitHub was still computing mergeability — a single read misses every fresh PR" >&2
	exit 1
fi

# A null body is the same state on the wire.
reset_mock null dirty
if ! cask_pr_conflicts "${tap}" "${pr}"; then
	echo "a null mergeable_state must be polled, not taken as clean" >&2
	exit 1
fi

# ...and a resolution to CLEAN is still clean, so the poll cannot be a
# disguised "keep looking until it says dirty".
reset_mock unknown clean
if cask_pr_conflicts "${tap}" "${pr}"; then
	echo "helper kept polling past a resolved clean state" >&2
	exit 1
fi

# --- Fail closed: a state that never resolves is not a conflict. -----------
# Rebuilding on a guess force-writes the tap branch. Leaving it alone keeps
# today's behaviour and the failure stays visible on the PR.
reset_mock unknown
if cask_pr_conflicts "${tap}" "${pr}"; then
	echo "an unresolved mergeable_state authorised a rebuild — that force-writes on a guess" >&2
	exit 1
fi

# The give-up must be BOUNDED, not an open loop against the tap.
attempts="$(grep -c "repos/${tap}/pulls/${pr}" "${call_file}")"
if [ "${attempts}" -gt 8 ]; then
	echo "unresolved polling is not bounded: ${attempts} reads" >&2
	exit 1
fi
if ! grep -q '^sleep ' "${call_file}"; then
	echo "polling must back off between reads" >&2
	exit 1
fi

# --- Fail closed: an unreadable PR state is not a conflict. ----------------
reset_mock dirty
mock_fail=1
if cask_pr_conflicts "${tap}" "${pr}"; then
	echo "a failed PR read must fail closed, not rebuild on a guess" >&2
	exit 1
fi

# --- The repair call site keeps the properties that make it safe. ----------
# The helper alone cannot prove the workflow wires it in correctly, so pin the
# ordering the repair depends on.
line_of() {
	grep -n "$1" "${workflow}" | head -1 | cut -d: -f1
}
# These patterns match the LITERAL shell text written in the workflow, so the
# `$` must stay unexpanded — single quotes are the point, not an oversight.
# shellcheck disable=SC2016
pr_resolved_line="$(line_of '^ *pr="\$(trusted_open_pr)"')"
repair_line="$(line_of 'if cask_pr_conflicts')"
repair_patch_line="$(awk '/if cask_pr_conflicts/ {found=1} found && /git\/refs\/heads\/.*-X PATCH/ {print NR; exit}' "${workflow}")"
arm_line="$(line_of 'enablePullRequestAutoMerge')"
for name in pr_resolved_line repair_line repair_patch_line arm_line; do
	if [ -z "${!name}" ]; then
		echo "could not locate ${name} in ${workflow}" >&2
		exit 1
	fi
done

# The repair needs a PR number, so it must run after one is resolved.
if [ "${pr_resolved_line}" -ge "${repair_line}" ]; then
	echo "the conflict repair must run after the cask PR is resolved" >&2
	exit 1
fi
# The force-write is gated on the helper, exactly as the reset path is.
if [ "${repair_line}" -ge "${repair_patch_line}" ]; then
	echo "the repair's ref force-write must be gated by cask_pr_conflicts" >&2
	exit 1
fi
# BEFORE arming: auto-merge was disarmed earlier in the step, and rebuilding a
# branch under an ARMED PR would let the tap merge whatever head the rebuild
# happens to leave. Repairing first keeps the force-write inside the disarmed
# window.
if [ "${repair_patch_line}" -ge "${arm_line}" ]; then
	echo "the repair must rebuild the branch BEFORE auto-merge is armed" >&2
	exit 1
fi

# The rebuild must write back the version the BRANCH carries, never this run's
# ${VERSION}. A newer concurrent release can own the branch content (the
# compare-and-swap above breaks out and leaves it alone), so re-writing
# ${VERSION} here would silently downgrade the tap while repairing it.
repair_block="$(awk -v a="${repair_line}" -v b="${arm_line}" \
	'NR >= a && NR < b' "${workflow}")"
# shellcheck disable=SC2016 # literal workflow text, as above
if ! printf '%s' "${repair_block}" | grep -q 'content="\${repair_content}"'; then
	echo "the repair must write back the content captured from the branch" >&2
	exit 1
fi
# shellcheck disable=SC2016 # literal workflow text, as above
if printf '%s' "${repair_block}" | grep -q 'content="\${content}"'; then
	echo "the repair re-writes this run's rendered cask, which downgrades a newer branch version" >&2
	exit 1
fi

# The RESET is the destructive step: `force` on the ref API permits a
# non-fast-forward update but gives no head-must-match guard, so a write landing
# between the capture and the force-write is discarded with nothing left to
# recover it from. The captured version must therefore be re-validated in
# between. (Codex P1 on this PR. Its stated scenario — two overlapping CD runs —
# cannot happen, because this job's concurrency group is constant and serialises
# the tap handoff across tags; the residual out-of-band writer is real.)
# It must compare the captured BLOB, not the version: a cask can be rewritten
# without its version moving (a corrected sha256 or url for the same release is
# the ordinary reason a tap is touched by hand), and a version-only check would
# revert that silently.
revalidate_line="$(awk -v a="${repair_line}" -v s='!= "${repair_blob_captured}"' \
	'NR >= a && index($0, s) {print NR; exit}' "${workflow}")"
if [ -z "${revalidate_line}" ] || [ "${revalidate_line}" -ge "${repair_patch_line}" ]; then
	echo "the repair must re-validate the captured BLOB immediately before the force-reset" >&2
	exit 1
fi

# main's cask version must be read AT the sha the branch is about to be reset
# to. Reading it from the `main` ref lets an out-of-band merge land between the
# two reads, so the restore loop's unknown-writer guard fires on main's own
# content — aborting with the captured cask already gone from the branch.
# shellcheck disable=SC2016 # literal workflow text, as above
if ! printf '%s' "${repair_block}" | grep -q 'cask_version_at "\${repair_sha}"'; then
	echo "main's cask version must be read at the captured reset sha, not the moving main ref" >&2
	exit 1
fi

# The blob compare-and-swap does NOT make the restore loop safe on its own: a
# rejected PUT re-reads, so a writer that landed after the reset would have its
# blob sha adopted on the next attempt and be overwritten. The loop must decide
# on the VERSION.
# shellcheck disable=SC2016 # literal workflow text, as above
if ! printf '%s' "${repair_block}" | grep -q '"\${repair_now}" != "\${repair_main_version}"'; then
	echo "the restore loop must refuse a version this run did not write" >&2
	exit 1
fi

# Every give-up path in the repair must ABORT. Continuing would arm auto-merge
# on a PR that can never merge — the silent stuck tap this repair exists to
# prevent. Pair each message with its OWN `exit 1` on the next line rather than
# counting exits in the range.
give_up_exits="$(awk -v a="${repair_line}" -v b="${arm_line}" \
	'NR > a && NR < b && /::error::/ {pending = NR; msgs++; next}
	 pending && NR == pending + 1 && /^[[:space:]]*exit 1$/ {paired++; pending = 0}
	 END {print msgs "/" paired}' "${workflow}")"
case "${give_up_exits}" in
	0/* | */0)
		echo "the repair has no aborting give-up path: ${give_up_exits}" >&2
		exit 1
		;;
esac
msgs="${give_up_exits%%/*}"
paired="${give_up_exits##*/}"
if [ "${msgs}" != "${paired}" ]; then
	echo "each repair give-up path must abort: ${msgs} messages, ${paired} followed by 'exit 1'" >&2
	exit 1
fi

echo "PASS: cask conflict repair"
