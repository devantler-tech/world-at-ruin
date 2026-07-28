#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

# Exercise the exact functions embedded in the CD run block rather than a
# test-only copy that could drift from production.
helper_file="${test_dir}/cask-graphql-budget-helper.sh"
sed -n \
	'/# BEGIN cask-graphql-budget-helper/,/# END cask-graphql-budget-helper/p' \
	"${workflow}" >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"
for fn in graphql_budget_exhausted cask_checks_green_at cask_rest_check_gated_merge; do
	if ! declare -F "${fn}" >/dev/null; then
		echo "missing ${fn} production helper in ${workflow}" >&2
		exit 1
	fi
done

tap="devantler-tech/homebrew-tap"
merge_file="${test_dir}/merges"
reads_file="${test_dir}/pr_reads"
sleep_file="${test_dir}/sleeps"

# Mock controls. The helpers call `gh` inside command substitutions, so the
# mock can READ these but must record what it saw in files.
mock_remaining="1"
mock_checks=""
mock_checks_until_read=""
mock_checks_early=""
mock_pr=""
mock_merge_ok="yes"
mock_gh_fails="no"
mock_head_after_read=""
mock_head_moved_sha=""

reset_mock_state() {
	: >"${merge_file}"
	: >"${reads_file}"
	: >"${sleep_file}"
}
reset_mock_state

pr_read_count() {
	wc -l <"${reads_file}" | tr -d ' '
}

merge_count() {
	wc -l <"${merge_file}" | tr -d ' '
}

sleep() {
	printf '%s\n' "$1" >>"${sleep_file}"
}

gh() {
	local arg is_put="" path=""
	[ "${mock_gh_fails}" = "no" ] || return 1
	for arg in "$@"; do
		case "${arg}" in
		PUT) is_put="yes" ;;
		rate_limit | repos/*) [ -n "${path}" ] || path="${arg}" ;;
		sha=*) [ -z "${is_put}" ] || printf '%s\n' "${arg#sha=}" >>"${merge_file}" ;;
		esac
	done
	case "${path}" in
	rate_limit)
		printf '%s\n' "${mock_remaining}"
		;;
	*/merge)
		[ "${mock_merge_ok}" = "yes" ]
		;;
	*/check-runs*)
		# Optionally hold the head un-green for the first N PR reads, so a
		# caller that must LOOP actually loops.
		if [ -n "${mock_checks_until_read}" ] && [ "$(pr_read_count)" -le "${mock_checks_until_read}" ]; then
			[ -n "${mock_checks_early}" ] || return 1
			printf '%s\n' "${mock_checks_early}"
			return 0
		fi
		[ -n "${mock_checks}" ] || return 1
		printf '%s\n' "${mock_checks}"
		;;
	*/pulls/*)
		printf 'x\n' >>"${reads_file}"
		[ -n "${mock_pr}" ] || return 1
		# Optionally move the head after N reads, so the merge-binding
		# assertion sees a genuinely different sha than the first one read.
		if [ -n "${mock_head_after_read}" ] && [ "$(pr_read_count)" -gt "${mock_head_after_read}" ]; then
			printf '%s\n' "${mock_pr}" | jq -c --arg s "${mock_head_moved_sha}" '.head.sha = $s'
			return 0
		fi
		printf '%s\n' "${mock_pr}"
		;;
	*)
		return 1
		;;
	esac
}

fail() {
	echo "$1" >&2
	exit 1
}

# --- graphql_budget_exhausted -------------------------------------------------
# The positive case, then the controls that must each flip it back. This
# predicate unlocks a ruleset-bypassing merge, so every non-zero and every
# unreadable answer must fail CLOSED.
mock_remaining="0"
graphql_budget_exhausted || fail "remaining=0 must read as exhausted"

for control in "1" "5000" "" "null" "abc" "-1" "0.0" " "; do
	mock_remaining="${control}"
	if graphql_budget_exhausted; then
		fail "remaining='${control}' must NOT read as exhausted (fail closed)"
	fi
done

# An unreadable budget (gh itself failing) must also fail closed.
mock_remaining="0"
mock_gh_fails="yes"
if graphql_budget_exhausted; then
	fail "an unreadable rate_limit must NOT read as exhausted"
fi
mock_gh_fails="no"

# --- cask_checks_green_at -----------------------------------------------------
green_json='{"total_count":3,"check_runs":[
	{"status":"completed","conclusion":"success"},
	{"status":"completed","conclusion":"skipped"},
	{"status":"completed","conclusion":"neutral"}]}'
pending_json='{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}'

mock_checks="${green_json}"
cask_checks_green_at "${tap}" "deadbeef" || fail "all-complete success/skipped/neutral must read green"

# Each ablation must flip the verdict; a guard that only ever answers "green"
# would pass the case above while pinning nothing.
declare -a not_green=(
	"${pending_json}"
	'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"queued","conclusion":null}]}'
	'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'
	'{"total_count":1,"check_runs":[{"status":"completed","conclusion":"cancelled"}]}'
	'{"total_count":1,"check_runs":[{"status":"completed","conclusion":"timed_out"}]}'
	'{"total_count":1,"check_runs":[{"status":"completed","conclusion":"action_required"}]}'
	'{"total_count":0,"check_runs":[]}'
	'not json at all'
	# A truncated page: every RETURNED run is green, but total_count says
	# more exist than came back, so the unread ones could be pending or red.
	'{"total_count":101,"check_runs":[{"status":"completed","conclusion":"success"}]}'
)
for payload in "${not_green[@]}"; do
	mock_checks="${payload}"
	if cask_checks_green_at "${tap}" "deadbeef"; then
		fail "must NOT read green: ${payload}"
	fi
done

# An unreadable check-runs response is not green either.
mock_checks=""
if cask_checks_green_at "${tap}" "deadbeef"; then
	fail "an unreadable check-runs response must NOT read green"
fi

# --- cask_rest_check_gated_merge ----------------------------------------------
# Already merged: return success WITHOUT attempting a merge of our own.
reset_mock_state
mock_pr='{"merged":true,"head":{"sha":"aaaa1111"}}'
mock_checks="${green_json}"
cask_rest_check_gated_merge "${tap}" "42" || fail "an already-merged PR must succeed"
[ "$(merge_count)" -eq 0 ] || fail "an already-merged PR must not be merged again"

# Green at head: merge, and BIND the merge to the head that was read. An
# unbound merge would ship whatever got pushed after the green read.
reset_mock_state
mock_pr='{"merged":false,"head":{"sha":"aaaa1111"}}'
cask_rest_check_gated_merge "${tap}" "42" || fail "a green head must merge"
[ "$(merge_count)" -eq 1 ] || fail "a green head must merge exactly once"
[ "$(tr -d ' \n' <"${merge_file}")" = "aaaa1111" ] || fail "the merge must be bound to the head sha it read"

# THE SAFETY ASSERTION: while checks are pending, nothing is merged at all.
reset_mock_state
mock_checks="${pending_json}"
if cask_rest_check_gated_merge "${tap}" "42"; then
	fail "a permanently pending head must not report delivery"
fi
[ "$(merge_count)" -eq 0 ] || fail "a pending head must NEVER be merged"
# Bounded: the wait gives up rather than holding the release job forever.
[ "$(pr_read_count)" -eq 30 ] || fail "wait must be bounded to 30 attempts, got $(pr_read_count)"
[ "$(wc -l <"${sleep_file}" | tr -d ' ')" -eq 29 ] || fail "29 sleeps should separate 30 attempts"

# A red check is not merely "not yet" — it must never merge, however long we wait.
reset_mock_state
mock_checks='{"total_count":1,"check_runs":[{"status":"completed","conclusion":"failure"}]}'
if cask_rest_check_gated_merge "${tap}" "42"; then
	fail "a failing head must not report delivery"
fi
[ "$(merge_count)" -eq 0 ] || fail "a failing head must NEVER be merged"

# A head that MOVES while waiting is re-read, and the merge binds to the NEW
# sha. The first iteration is held un-green so the loop actually turns —
# otherwise it would merge before the head ever moved and the assertion would
# pass without exercising the re-read at all.
reset_mock_state
mock_pr='{"merged":false,"head":{"sha":"aaaa1111"}}'
mock_checks="${green_json}"
mock_checks_early="${pending_json}"
mock_checks_until_read="1"
mock_head_after_read="1"
mock_head_moved_sha="bbbb2222"
cask_rest_check_gated_merge "${tap}" "42" || fail "a moved head must still merge"
[ "$(merge_count)" -eq 1 ] || fail "a moved head must merge exactly once"
[ "$(tr -d ' \n' <"${merge_file}")" = "bbbb2222" ] || fail "the merge must bind to the CURRENT head, not the first one read"
mock_checks_early=""
mock_checks_until_read=""
mock_head_after_read=""
mock_head_moved_sha=""

# A refused merge (the head moved between the green read and the PUT) is
# retried rather than reported as delivered.
reset_mock_state
mock_merge_ok="no"
if cask_rest_check_gated_merge "${tap}" "42"; then
	fail "a merge the API refuses must not report delivery"
fi
[ "$(merge_count)" -eq 30 ] || fail "a refused merge must be retried across the bounded wait"
mock_merge_ok="yes"

echo "cd cask GraphQL-budget fallback: all assertions passed"
