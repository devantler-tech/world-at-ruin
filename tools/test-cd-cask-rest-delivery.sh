#!/usr/bin/env bash
# The cask handoff must survive an exhausted GraphQL budget on the shared tap
# account: opening the PR goes over REST, and when auto-merge cannot be armed
# the release is delivered by waiting for the head's checks and merging over
# REST instead. Both helpers are extracted from the CD workflow itself rather
# than copied, so a production edit that breaks them fails here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

helper_file="${test_dir}/cask-rest-delivery-helpers.sh"
sed -n '/# BEGIN cask-pr-create-helper/,/# END cask-pr-create-helper/p' \
	"${workflow}" >"${helper_file}"
sed -n '/# BEGIN cask-rest-merge-helper/,/# END cask-rest-merge-helper/p' \
	"${workflow}" >>"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"

for fn in create_cask_pr merge_cask_pr_when_green; do
	if ! declare -F "${fn}" >/dev/null; then
		echo "missing ${fn} production helper in ${workflow}" >&2
		exit 1
	fi
done

tap="devantler-tech/homebrew-tap"
branch="goreleaser/world-at-ruin"
call_log="${test_dir}/calls"
sleep_log="${test_dir}/sleeps"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

reset_mocks() {
	: >"${call_log}"
	: >"${sleep_log}"
	printf '0\n' >"${test_dir}/attempts"
	mock_create_rc=0
	mock_create_out=""
	mock_merge_rc=0
	mock_pr_state='{"merged":false,"head":{"sha":"cafe1234cafe1234cafe1234cafe1234cafe1234"}}'
	mock_checks=()
	# NOT named `statuses`: the helper declares `local statuses`, and bash's
	# dynamic scoping would make the stub read the caller's empty local instead
	# of this fixture. Every mock here carries the `mock_` prefix for that
	# reason — the same trap silently blanked `pr_state` while this was written.
	mock_statuses='{"state":"success","statuses":[{"context":"CodeRabbit","state":"success","description":"review complete"}]}'
	# What the branch carries, read fresh on each merge attempt. Changing it
	# mid-test is how "another writer landed during the wait" is expressed.
	mock_branch_version="0.65.7"
}

# The production helper calls this; it lives outside the extracted blocks.
cask_version_at() {
	printf '%s\n' "${mock_branch_version}"
}

sleep() {
	printf '%s\n' "$1" >>"${sleep_log}"
}

# One stub for every REST surface the helpers touch. It dispatches on the
# request rather than on call order, so a helper that starts issuing its reads
# in a different order still exercises the same fixtures.
gh() {
	local a token_put=0 token_post=0 path="" attempts
	printf '%s\n' "$*" >>"${call_log}"
	for a in "$@"; do
		case "${a}" in
		PUT) token_put=1 ;;
		POST) token_post=1 ;;
		repos/*) [ -z "${path}" ] && path="${a}" ;;
		esac
	done

	if [ "${token_post}" = "1" ] && [[ "${path}" == */pulls ]]; then
		[ -n "${mock_create_out}" ] && printf '%s\n' "${mock_create_out}"
		return "${mock_create_rc}"
	fi
	if [ "${token_put}" = "1" ] && [[ "${path}" == */merge ]]; then
		return "${mock_merge_rc}"
	fi
	if [[ "${path}" == *check-runs* ]]; then
		read -r attempts <"${test_dir}/attempts"
		attempts=$((attempts + 1))
		printf '%s\n' "${attempts}" >"${test_dir}/attempts"
		# The last fixture repeats once the sequence runs out, so a test can
		# describe "pending, pending, then green forever" in three entries.
		local idx=$((attempts - 1))
		if [ "${idx}" -ge "${#mock_checks[@]}" ]; then
			idx=$((${#mock_checks[@]} - 1))
		fi
		[ "${#mock_checks[@]}" -gt 0 ] && printf '%s\n' "${mock_checks[idx]}"
		return 0
	fi
	if [[ "${path}" == */status ]]; then
		printf '%s\n' "${mock_statuses}"
		return 0
	fi
	if [[ "${path}" == */pulls/* ]]; then
		printf '%s\n' "${mock_pr_state}"
		return 0
	fi
	return 0
}

check_run() { # status conclusion
	printf '{"status":"%s","conclusion":%s}' "$1" \
		"$([ "$2" = "null" ] && echo null || printf '"%s"' "$2")"
}
checks() { # one JSON check-run object per argument
	local joined=""
	local c
	local n=0
	for c in "$@"; do
		[ -n "${joined}" ] && joined="${joined},"
		joined="${joined}${c}"
		n=$((n + 1))
	done
	# `total_count` mirrors the real endpoint, which reports the head's FULL
	# count independently of what this page returned. `checks_truncated` below
	# is what makes the two disagree.
	printf '{"total_count":%d,"check_runs":[%s]}' "${n}" "${joined}"
}
checks_truncated() { # declared-total, then the runs this page returned
	local declared="$1"
	shift
	local body
	body="$(checks "$@")"
	printf '%s' "${body}" | sed "s/\"total_count\":[0-9]*/\"total_count\":${declared}/"
}

green_checks="$(checks "$(check_run completed success)" "$(check_run completed success)")"
pending_checks="$(checks "$(check_run completed success)" "$(check_run in_progress null)")"
failing_checks="$(checks "$(check_run completed success)" "$(check_run completed failure)")"
empty_checks='{"total_count":0,"check_runs":[]}'

merge_calls() { grep -c '/merge' "${call_log}" || true; }

# ---------------------------------------------------------------------------
# create_cask_pr — the PR is opened over REST, never over GraphQL.
# ---------------------------------------------------------------------------

reset_mocks
create_cask_pr "${tap}" "${branch}" "0.65.7" ||
	fail "create_cask_pr rejected a successful create"
if ! grep -q -- '--method POST' "${call_log}"; then
	fail "the create did not go through the REST pulls endpoint"
fi
if ! grep -q "repos/${tap}/pulls" "${call_log}"; then
	fail "the create did not address ${tap}'s pulls endpoint"
fi
# The whole point of #502: `gh pr create` is GraphQL-backed, so its absence is
# the property under test, not an incidental style choice.
if grep -q 'pr create' "${call_log}"; then
	fail "the create still used the GraphQL-backed 'gh pr create'"
fi
if ! grep -q 'v0.65.7' "${call_log}"; then
	fail "the created PR title did not carry the released version"
fi

# A concurrent creator is benign: GitHub refuses the loser, and that refusal
# means the PR this run needs already exists.
reset_mocks
mock_create_rc=1
mock_create_out='HTTP 422: Validation Failed (https://api.github.com/repos/x/pulls)
A pull request already exists for devantler-tech:goreleaser/world-at-ruin.'
create_cask_pr "${tap}" "${branch}" "0.65.7" >/dev/null ||
	fail "create_cask_pr failed on a benign already-exists race"

# Every other refusal must surface WITH the API's reason — the swallowed
# `|| true` that hid it is what made #502 read as an unexplained missing PR.
reset_mocks
mock_create_rc=1
mock_create_out='HTTP 403: Resource not accessible by integration'
if out="$(create_cask_pr "${tap}" "${branch}" "0.65.7" 2>&1)"; then
	fail "create_cask_pr reported success on a genuine refusal"
fi
[[ "${out}" == *"Resource not accessible by integration"* ]] ||
	fail "the create failure did not surface the API's own message"

# ---------------------------------------------------------------------------
# merge_cask_pr_when_green — auto-merge's wait, done over REST.
# ---------------------------------------------------------------------------

# All checks green: merge, pinned to the head those checks describe.
reset_mocks
mock_checks=("${green_checks}")
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "a fully green head was not merged"
[ "$(merge_calls)" -eq 1 ] || fail "expected exactly one merge call on a green head"
grep -q 'sha=cafe1234cafe1234cafe1234cafe1234cafe1234' "${call_log}" ||
	fail "the merge was not pinned to the head whose checks were read"
grep -q 'merge_method=squash' "${call_log}" || fail "the merge was not a squash"
[ "$(wc -l <"${sleep_log}" | tr -d ' ')" -eq 0 ] ||
	fail "an already-green head should merge without waiting"

# Pending checks are waited out, not merged through.
reset_mocks
mock_checks=("${pending_checks}" "${pending_checks}" "${green_checks}")
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "a head that went green on the third read was not merged"
[ "$(merge_calls)" -eq 1 ] || fail "expected exactly one merge, after the wait"
[ "$(wc -l <"${sleep_log}" | tr -d ' ')" -eq 2 ] ||
	fail "expected two waits before the third read went green"

# A failing check is a refusal, never something to wait out. Not merging is
# only half the property: the run must give up IMMEDIATELY and say why, rather
# than burning the whole wait budget on a head that can never go green — so
# assert the absence of waiting too, which is what makes the early return
# load-bearing rather than shadowed by the merge precondition.
reset_mocks
mock_checks=("${failing_checks}")
if out="$(merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" 2>&1)"; then
	fail "a head carrying a failing check was merged"
fi
[ "$(merge_calls)" -eq 0 ] || fail "a failing head must not be merged at all"
[ "$(wc -l <"${sleep_log}" | tr -d ' ')" -eq 0 ] ||
	fail "a failing check should be refused at once, not waited out"
[[ "${out}" == *"failing check"* ]] ||
	fail "the refusal did not say that a check had failed"

# `neutral` and `skipped` are how a check says "not applicable" — a pass.
reset_mocks
mock_checks=("$(checks "$(check_run completed neutral)" "$(check_run completed skipped)")")
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "neutral/skipped conclusions were not treated as green"
[ "$(merge_calls)" -eq 1 ] || fail "expected the neutral/skipped head to merge"

# Everything else that COMPLETED is a refusal, not a pass.
for bad in cancelled timed_out action_required stale; do
	reset_mocks
	mock_checks=("$(checks "$(check_run completed "${bad}")")")
	if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
		fail "a head whose check concluded '${bad}' was merged"
	fi
	[ "$(merge_calls)" -eq 0 ] || fail "'${bad}' must not reach a merge call"
done

# No check runs at all is "not validated yet", never "nothing to validate".
reset_mocks
mock_checks=("${empty_checks}")
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "a head carrying no check runs was merged"
fi
[ "$(merge_calls)" -eq 0 ] || fail "an unchecked head must never be merged"
[ "$(wc -l <"${sleep_log}" | tr -d ' ')" -eq 19 ] ||
	fail "the wait budget is not the bounded 20 reads the comment claims"

# An unreadable check payload fails closed for the same reason.
reset_mocks
mock_checks=("not json at all")
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "an unreadable check payload was treated as green"
fi
[ "$(merge_calls)" -eq 0 ] || fail "an unreadable payload must not reach a merge"

# Legacy commit statuses gate the merge too. A required status lives on this
# surface (the tap's heads carry one), and check runs cannot see it — so a
# non-success status must hold the merge back even when every check run is
# green.
reset_mocks
mock_checks=("${green_checks}")
mock_statuses='{"state":"failure","statuses":[{"context":"tap/audit","state":"failure","description":"cask audit failed"}]}'
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "a head whose legacy status had failed was merged"
fi
[ "$(merge_calls)" -eq 0 ] || fail "a failing legacy status must block the merge"

reset_mocks
mock_checks=("${green_checks}")
mock_statuses='{"state":"pending","statuses":[{"context":"tap/audit","state":"pending","description":"queued"}]}'
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "a head with a pending legacy status was merged"
fi
[ "$(merge_calls)" -eq 0 ] || fail "a pending legacy status must be waited for"

# ...except a review provider reporting ITS OWN quota, which describes the
# provider's billing state rather than this cask. Letting that block delivery
# would reintroduce the exact failure this whole helper exists to remove.
reset_mocks
mock_checks=("${green_checks}")
mock_statuses='{"state":"failure","statuses":[{"context":"CodeRabbit","state":"failure","description":"Review rate limit exceeded"}]}'
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "a review provider's own rate-limit status blocked delivery"
[ "$(merge_calls)" -eq 1 ] || fail "the quota-status carve-out did not reach a merge"

# A head with no legacy statuses at all is not blocked by their absence.
reset_mocks
mock_checks=("${green_checks}")
mock_statuses='{"state":"pending","statuses":[]}'
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "a head carrying no legacy statuses was treated as blocked"

# An unreadable status payload fails closed, like an unreadable check payload.
reset_mocks
mock_checks=("${green_checks}")
mock_statuses='not json at all'
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "an unreadable status payload was treated as green"
fi
[ "$(merge_calls)" -eq 0 ] || fail "an unreadable status payload must not reach a merge"

# A page that did not return every check run is a PARTIAL answer: the pending
# or failing run this page never showed would be invisible, and the head would
# merge on a fraction of its own evidence. Refuse, loudly.
reset_mocks
mock_checks=("$(checks_truncated 130 "$(check_run completed success)" "$(check_run completed success)")")
if out="$(merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" 2>&1)"; then
	fail "a truncated check-runs page was judged as complete"
fi
[ "$(merge_calls)" -eq 0 ] || fail "a partial page must not reach a merge"
[[ "${out}" == *"partial page"* ]] ||
	fail "the refusal did not name the partial page as the cause"
[ "$(wc -l <"${sleep_log}" | tr -d ' ')" -eq 0 ] ||
	fail "a truncated page should be refused at once, not waited out"

# The tap squash-merges on the PR TITLE, which was derived before this wait
# began. If another writer lands on the branch during the wait, merging would
# ship that content under the previous version's changelog entry. Hand it back
# (rc 2) so the caller re-derives the title instead.
reset_mocks
mock_checks=("${green_checks}")
mock_branch_version="0.66.0" # a sibling wrote a newer cask during the wait
rc=0
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1 || rc=$?
[ "${rc}" -eq 2 ] || fail "a branch that moved during the wait returned ${rc}, want 2"
[ "$(merge_calls)" -eq 0 ] ||
	fail "a moved branch must not be merged under the stale title"

# ...and the check is made against the branch as it stands at merge time, not a
# value captured before the wait: a branch that moves back to the expected
# version still delivers.
reset_mocks
mock_checks=("${green_checks}")
mock_branch_version="0.65.7"
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "an unmoved branch was refused"
[ "$(merge_calls)" -eq 1 ] || fail "an unmoved branch should deliver"

# An already-merged PR is delivered, not merged twice.
reset_mocks
mock_pr_state='{"merged":true,"head":{"sha":"cafe1234cafe1234cafe1234cafe1234cafe1234"}}'
mock_checks=("${green_checks}")
merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null ||
	fail "an already-merged cask PR was not reported as delivered"
[ "$(merge_calls)" -eq 0 ] || fail "an already-merged PR must not be merged again"

# A head that moves between the check read and the merge is refused by `sha=`,
# and the helper must re-read rather than retry blind or give up.
reset_mocks
mock_merge_rc=1
mock_checks=("${green_checks}")
if merge_cask_pr_when_green "${tap}" 1337 "${branch}" "0.65.7" >/dev/null 2>&1; then
	fail "a refused merge was reported as delivered"
fi
[ "$(merge_calls)" -eq 20 ] || fail "a refused merge should be re-read each attempt"

# ---------------------------------------------------------------------------
# The wiring: the workflow must actually route an exhausted budget here.
# ---------------------------------------------------------------------------

# Match the INVOCATION, not a mention: the helper's own comment explains what
# it replaced, so strip whole-line comments first and search what is left.
#
# Two traps, both of which made this guard silently unfireable until an
# ablation reinstated `gh pr create` and the test still passed:
#
#   1. `^[[:space:]]*[^#[:space:]].*gh pr create` cannot work — the
#      leading-character class eats the `g` of the very token being searched.
#   2. `grep -v … | grep -q …` cannot work under `set -o pipefail`: `-q` exits
#      at the first match and closes the pipe, the upstream grep dies of
#      SIGPIPE (141), and pipefail hands that to `if`, so a MATCH reads as
#      false. Count instead — `grep -c` drains its input, so nothing is
#      signalled.
uncommented_hits="$(grep -vE '^[[:space:]]*#' "${workflow}" | grep -c 'gh pr create' || true)"
if [ "${uncommented_hits}" != "0" ]; then
	fail "cd.yaml still calls the GraphQL-backed 'gh pr create' (${uncommented_hits} call site(s))"
fi
if ! grep -qF "grep -qiE 'rate limit|RATE_LIMITED'" "${workflow}"; then
	fail "the arming loop does not recognise a GraphQL rate-limit refusal"
fi
# Written without a `$` so shellcheck does not read the literal search pattern
# as a failed expansion (SC2016); `if merge_cask_pr_when_green "` is unique to
# the fallback call site and never matches the definition.
if ! grep -q 'merge_cask_pr_when_green "' "${workflow}"; then
	fail "a rate-limited arm does not fall back to the REST delivery path"
fi
# rc 2 must be routed back into the loop, not treated as a failure: it is how
# the helper says "the branch moved, re-derive the title before delivering".
if ! grep -q 'rest_rc}" -eq 2' "${workflow}"; then
	fail "a moved branch during the REST wait is not routed back for a re-derive"
fi
# The disarm is deliberately NOT given the fallback: there is no REST
# equivalent, so it must keep aborting before the write.
if ! grep -q 'could not disarm auto-merge on' "${workflow}"; then
	fail "the disarm no longer fails closed before the content write"
fi

echo "ok"
