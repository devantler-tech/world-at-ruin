#!/usr/bin/env bash
# The pre-write disarm must survive an exhausted GraphQL budget on the shared
# tap account. Disarming has no REST equivalent, so when the mutation is
# refused for quota the previously-armed PR is DELIVERED over REST instead —
# which removes the armed PR rather than disarming it, and so preserves the
# invariant the disarm exists for: nothing is armed when the new content is
# written. Every other disarm failure still aborts before the write.
#
# The helpers are extracted from the CD workflow itself rather than copied, so
# a production edit that breaks them fails here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

helper_file="${test_dir}/cask-disarm-helpers.sh"
sed -n '/# BEGIN cask-rest-merge-helper/,/# END cask-rest-merge-helper/p' \
	"${workflow}" >"${helper_file}"
sed -n '/# BEGIN cask-disarm-helper/,/# END cask-disarm-helper/p' \
	"${workflow}" >>"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"

for fn in merge_cask_pr_when_green disarm_prior_cask_auto_merge; do
	if ! declare -F "${fn}" >/dev/null; then
		echo "missing ${fn} production helper in ${workflow}" >&2
		exit 1
	fi
done

# The disarm CALLS the REST delivery helper, so in production the definition
# must already exist at that point in the script. Extraction order in a test
# cannot prove that — assert the real file's ordering directly.
disarm_def_line="$(grep -n '# BEGIN cask-disarm-helper' "${workflow}" | cut -d: -f1)"
merge_def_line="$(grep -n '# BEGIN cask-rest-merge-helper' "${workflow}" | cut -d: -f1)"
if [ -z "${disarm_def_line}" ] || [ -z "${merge_def_line}" ]; then
	echo "could not locate both helper blocks in ${workflow}" >&2
	exit 1
fi
if [ "${merge_def_line}" -ge "${disarm_def_line}" ]; then
	echo "merge_cask_pr_when_green is defined AFTER the disarm that calls it (${merge_def_line} >= ${disarm_def_line}); the fallback would die on an undefined function" >&2
	exit 1
fi

tap="devantler-tech/homebrew-tap"
branch="goreleaser/world-at-ruin"
pre_pr=1213
call_log="${test_dir}/calls"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

reset_mocks() {
	: >"${call_log}"
	printf '0\n' >"${test_dir}/attempts"
	# Every fixture carries the `mock_` prefix: the helpers declare locals of
	# the obvious names (`pre_state`, `statuses`, `head`), and bash's dynamic
	# scoping would make a stub read the caller's empty local instead of the
	# fixture. That trap silently blanked `pr_state` in the sibling test.
	mock_graphql_rc=1
	mock_graphql_out="API rate limit exceeded for installation"
	mock_armed=true
	mock_merged=false
	# When set, the PR-state endpoint returns this verbatim instead of a
	# well-formed document — how "the read failed or came back malformed" is
	# expressed without changing the stub's dispatch.
	mock_pr_state_override=""
	mock_pr_title="chore(cask): update world-at-ruin to v0.65.7"
	mock_patch_rc=0
	mock_merge_rc=0
	mock_branch_version="0.65.7"
	mock_checks='{"total_count":1,"check_runs":[{"name":"CI - Required Checks","status":"completed","conclusion":"success"}]}'
	mock_statuses='{"state":"success","statuses":[]}'
	mock_required='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI - Required Checks"}]}}]'
}

# Production reads the branch's cask through this; it lives outside the
# extracted blocks.
cask_version_at() {
	printf '%s\n' "${mock_branch_version}"
}

sleep() { :; }

gh() {
	local a token_put=0 token_patch=0 path="" is_graphql=0
	printf '%s\n' "$*" >>"${call_log}"
	for a in "$@"; do
		case "${a}" in
		PUT) token_put=1 ;;
		PATCH) token_patch=1 ;;
		graphql) is_graphql=1 ;;
		repos/*) [ -z "${path}" ] && path="${a}" ;;
		esac
	done

	if [ "${is_graphql}" = "1" ]; then
		[ -n "${mock_graphql_out}" ] && printf '%s\n' "${mock_graphql_out}"
		return "${mock_graphql_rc}"
	fi
	if [ "${token_put}" = "1" ] && [[ "${path}" == */merge ]]; then
		return "${mock_merge_rc}"
	fi
	if [ "${token_patch}" = "1" ] && [[ "${path}" == */pulls/* ]]; then
		return "${mock_patch_rc}"
	fi
	# The title is read through `--jq .title`, which returns a bare string
	# rather than the document the other PR reads yield.
	if [[ "${path}" == */pulls/* ]] && printf '%s' "$*" | grep -q -- '--jq'; then
		printf '%s\n' "${mock_pr_title}"
		return 0
	fi
	if [[ "${path}" == *check-runs* ]]; then
		printf '%s\n' "${mock_checks}"
		return 0
	fi
	if [[ "${path}" == */rules/branches/* ]]; then
		printf '%s\n' "${mock_required}"
		return 0
	fi
	if [[ "${path}" == */status ]]; then
		printf '%s\n' "${mock_statuses}"
		return 0
	fi
	if [[ "${path}" == */pulls/* ]]; then
		if [ -n "${mock_pr_state_override}" ]; then
			printf '%s\n' "${mock_pr_state_override}"
			return 0
		fi
		printf '{"merged":%s,"auto_merge":%s,"node_id":"PR_kwDO","head":{"sha":"cafe1234cafe1234cafe1234cafe1234cafe1234"}}' \
			"${mock_merged}" \
			"$([ "${mock_armed}" = "true" ] && printf '{"enabled_by":{"login":"tap"}}' || printf 'null')"
		return 0
	fi
	return 0
}

merge_calls() { grep -c -- '/merge' "${call_log}" || true; }
patch_calls() { grep -c -- '-X PATCH' "${call_log}" || true; }
graphql_calls() { grep -c -- 'graphql' "${call_log}" || true; }

# ---------------------------------------------------------------------------
# The case the issue is about: budget exhausted, a previous release still
# armed. The hand-off completes instead of reddening main.
# ---------------------------------------------------------------------------

reset_mocks
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] ||
	fail "an exhausted GraphQL budget still aborted the disarm (rc=${rc}) — the release reds main for a quota that belongs to unrelated consumption"
[ "$(merge_calls)" -gt 0 ] ||
	fail "the armed PR was neither disarmed nor delivered; nothing removed the stale-title hazard before the write"
grep -q "repos/${tap}/pulls/${pre_pr}/merge" "${call_log}" ||
	fail "the delivery did not merge the PREVIOUSLY-ARMED PR (#${pre_pr})"

# ---------------------------------------------------------------------------
# Controls. Each flips exactly one fixture and must change the verdict — a
# control that leaves the assertion true proves nothing about it.
# ---------------------------------------------------------------------------

# The disarm SUCCEEDS: the normal path is untouched and delivers nothing.
reset_mocks
mock_graphql_rc=0
mock_graphql_out=""
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "a successful disarm was reported as a failure (rc=${rc})"
[ "$(merge_calls)" -eq 0 ] ||
	fail "a successful disarm still merged the previous PR — the fallback fired when the mutation worked"

# A NON-quota refusal still fails closed, before the write. Permission and
# node-id errors are real problems and must not be papered over by delivering.
reset_mocks
mock_graphql_out="Resource not accessible by integration"
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "a permission failure on the disarm was treated as deliverable; the job would write new content with the PR still armed"
[ "$(merge_calls)" -eq 0 ] ||
	fail "a non-quota disarm failure still merged the previous PR"

# Nothing armed: no mutation is spent and nothing is delivered.
reset_mocks
mock_armed=false
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "an unarmed previous PR was treated as a failure (rc=${rc})"
[ "$(graphql_calls)" -eq 0 ] ||
	fail "a mutation was spent disarming a PR that was never armed"
[ "$(merge_calls)" -eq 0 ] || fail "an unarmed previous PR was merged by the disarm"

# Already merged out from under us: nothing to disarm, nothing to deliver.
reset_mocks
mock_armed=false
mock_merged=true
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "an already-merged previous PR was treated as a failure (rc=${rc})"

# An UNREADABLE PR state is not "not armed". A malformed document makes `jq`
# print nothing, and an empty answer must never be the one that lets the write
# proceed — that would put new content on the branch with the previous PR
# possibly still armed, which is the whole hazard.
reset_mocks
mock_pr_state_override='{"merged": tru'
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "an unreadable PR state was treated as unarmed; the job would write new content without knowing whether auto-merge was live"
[ "$(merge_calls)" -eq 0 ] || fail "an unreadable PR state still merged the previous PR"
[ "$(graphql_calls)" -eq 0 ] || fail "a mutation was spent against an unreadable PR state"

# An EMPTY read is likewise fail-closed.
reset_mocks
mock_pr_state_override=' '
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "an empty PR-state read was treated as unarmed"

# A FAILING required check is not merged past. The fallback does auto-merge's
# waiting, not auto-merge's bypassing.
reset_mocks
mock_checks='{"total_count":1,"check_runs":[{"name":"CI - Required Checks","status":"completed","conclusion":"failure"}]}'
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "the fallback delivered a PR carrying a failing required check"
[ "$(merge_calls)" -eq 0 ] || fail "a red PR was merged by the disarm fallback"

# The branch moved under us, so the armed PR's title no longer describes its
# content. Delivering would ship a lying changelog entry — fail closed.
reset_mocks
mock_branch_version=""
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "the fallback proceeded without being able to read what the branch carries"
[ "$(merge_calls)" -eq 0 ] || fail "an unreadable branch version still merged the previous PR"

# ---------------------------------------------------------------------------
# The delivered PR is merged under a title that DESCRIBES it. The tap
# squash-merges on the title, and the armed PR's title was written by whichever
# run armed it — an out-of-band writer can have moved the branch since.
# ---------------------------------------------------------------------------

# Title already correct: converged, so no PATCH is spent.
reset_mocks
mock_pr_title="chore(cask): update world-at-ruin to v0.65.7"
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "an already-converged title was rejected (rc=${rc})"
[ "$(patch_calls)" -eq 0 ] ||
	fail "the title was rewritten when it already described the branch content"

# Title STALE against what the branch now carries: retitled before the merge,
# and the retitle must come first — merging under the old title is the hazard.
reset_mocks
mock_pr_title="chore(cask): update world-at-ruin to v0.65.0"
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "a stale title could not be converged (rc=${rc})"
[ "$(patch_calls)" -gt 0 ] ||
	fail "the PR was delivered under a title naming a version the branch does not carry — the lying-changelog hazard"
grep -q 'title=chore(cask): update world-at-ruin to v0.65.7' "${call_log}" ||
	fail "the retitle did not name the version the branch actually carries"
[ "$(grep -n -- '-X PATCH' "${call_log}" | head -1 | cut -d: -f1)" \
	-lt "$(grep -n -- '/merge' "${call_log}" | head -1 | cut -d: -f1)" ] ||
	fail "the merge went out before the retitle; the squash would carry the stale title"

# A retitle that FAILS must not fall through to the merge.
reset_mocks
mock_pr_title="chore(cask): update world-at-ruin to v0.65.0"
mock_patch_rc=1
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] || fail "a failed retitle still reported success"
[ "$(merge_calls)" -eq 0 ] || fail "a failed retitle still merged the PR under its stale title"

# ---------------------------------------------------------------------------
# One shared wall-clock deadline bounds every REST wait the job takes, so two
# waits in one job cannot together exceed the runner timeout.
# ---------------------------------------------------------------------------

reset_mocks
# Already expired: the wait must refuse immediately rather than spend its own
# full budget on top of a previous one.
# Read by the SOURCED production helper, not by this file — shellcheck cannot
# see across the `source`.
# shellcheck disable=SC2034
cask_rest_deadline=$(($(date +%s) - 1))
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -ne 0 ] ||
	fail "the REST wait ignored the job's shared deadline; two waits could outlast the runner timeout"
[ "$(merge_calls)" -eq 0 ] || fail "a PR was merged after the shared deadline had passed"
unset cask_rest_deadline

# Unset deadline (a caller that never set one) must not break the wait.
reset_mocks
rc=0
disarm_prior_cask_auto_merge "${tap}" "${pre_pr}" "${branch}" || rc=$?
[ "${rc}" -eq 0 ] || fail "an unset deadline broke the REST wait (rc=${rc})"

# The workflow must actually SET that deadline — a helper that honours a
# variable nobody assigns is an unfireable guard.
# These patterns match the LITERAL shell written in the workflow, so the `$`
# must stay unexpanded — single quotes are the point, not an oversight.
# shellcheck disable=SC2016
if ! grep -q '^ *cask_rest_deadline=\$(( CASK_JOB_START + [0-9]\+ ))' "${workflow}"; then
	fail "the workflow never sets cask_rest_deadline from the job anchor, so the shared bound never applies in production"
fi
# ...and anchor it to the JOB, not this step. `timeout-minutes` bounds the job,
# so a step-relative deadline drifts past it whenever the earlier steps are
# slow, and the runner kills the wait before the deliberate error can fire.
# shellcheck disable=SC2016
if ! grep -q 'CASK_JOB_START=\$(date +%s)" >> "\$GITHUB_ENV"' "${workflow}"; then
	fail "the job never records CASK_JOB_START, so the deadline is measured from the tap step rather than the job"
fi
# shellcheck disable=SC2016
anchor_line="$(grep -n 'CASK_JOB_START=\$(date +%s)' "${workflow}" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
use_line="$(grep -n 'cask_rest_deadline=\$(( CASK_JOB_START' "${workflow}" | head -1 | cut -d: -f1)"
if [ "${anchor_line}" -ge "${use_line}" ]; then
	fail "CASK_JOB_START is recorded at line ${anchor_line}, after its use at ${use_line}; the deadline would fall back every run"
fi
# The offset must leave real headroom under the job timeout, or the deadline
# can never fire before the runner kills the job.
# shellcheck disable=SC2016
offset="$(grep -o 'cask_rest_deadline=\$(( CASK_JOB_START + [0-9]\+' "${workflow}" | grep -o '[0-9]\+$')"
timeout_min="$(awk '/^  homebrew-cask:/{f=1} f && /timeout-minutes:/{print $2; exit}' "${workflow}")"
if [ -z "${offset}" ] || [ -z "${timeout_min}" ]; then
	fail "could not read the deadline offset (${offset}) or the job timeout (${timeout_min})"
fi
if [ "${offset}" -ge "$((timeout_min * 60))" ]; then
	fail "the deadline offset ${offset}s is not inside the ${timeout_min}m job timeout; the runner would kill the wait first"
fi
if [ "$((timeout_min * 60 - offset))" -lt 60 ]; then
	fail "only $((timeout_min * 60 - offset))s of headroom between the deadline and the job timeout — too tight for the merge call and teardown"
fi

echo "PASS: the cask disarm survives an exhausted GraphQL budget and fails closed on every other refusal"
