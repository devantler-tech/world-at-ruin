#!/usr/bin/env bash
# Exercise the shipping identity boundary and reviewed-helper dispatch.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
driver="$root/tools/shared-product-admission.sh"
[[ -f $driver ]] || {
  echo 'FAIL: product admission entrypoint missing' >&2
  exit 1
}
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/trusted/tools" "$work/temp"
cp "$driver" "$root/tools/trusted-regression-lifecycle.sh" "$root/tools/resolve-trusted-regression-event.sh" "$work/trusted/tools/"
cat >"$work/trusted/tools/fetch-trusted-regression-data.sh" <<'FETCH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == candidate && $2 == "$GITHUB_SHA" && ! -e candidate ]]
mkdir candidate
printf 'fetched\n' >>"$TRACE"
FETCH
cat >"$work/trusted/tools/run-sandboxed-trusted-regressions.sh" <<'CONTROL'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == "$EXPECTED_TRUSTED" && $2 == "$PWD/candidate" && -d $2 ]]
printf 'contained\n' >>"$TRACE"
if [[ ${CONTROL_WAIT:-false} == true ]]; then
  sleep 60 &
  child=$!
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; printf "cancelled\n" >>"$TRACE"; exit 130' TERM
  printf '%s\n' "$PPID" >"$READY"
  wait "$child"
fi
exit "${CONTROL_EXIT:-0}"
CONTROL
git -C "$work/trusted" init -q
git -C "$work/trusted" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false add tools
git -C "$work/trusted" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm trusted
base=$(git -C "$work/trusted" rev-parse HEAD)
candidate=1111111111111111111111111111111111111111
workflow=2222222222222222222222222222222222222222
jq -n --arg base "$base" --arg candidate "$candidate" '{repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},pull_request:{base:{repo:{full_name:"devantler-tech/world-at-ruin"},ref:"main",sha:$base},head:{sha:$candidate},merge_commit_sha:$candidate},merge_group:{base_ref:"refs/heads/main",base_sha:$base,head_sha:$candidate}}' >"$work/event.json"
invoke() {
  env GITHUB_REPOSITORY=devantler-tech/world-at-ruin \
    GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/main \
    GITHUB_WORKFLOW_SHA="$workflow" GITHUB_SHA="$candidate" CANDIDATE_SHA="$candidate" \
    GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$work/event.json" RUNNER_TEMP="$work/temp" \
    TRACE="$work/trace" EXPECTED_TRUSTED="$work/trusted" "$@" \
    bash "$work/trusted/tools/shared-product-admission.sh" "$mode"
}
mode=check
invoke
invoke GITHUB_EVENT_NAME=merge_group
for mode in check run; do
  for invalid in GITHUB_REPOSITORY=other/repository GITHUB_WORKFLOW_REF=untrusted \
    GITHUB_WORKFLOW_REF=devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main \
    GITHUB_WORKFLOW_SHA=main GITHUB_SHA=main CANDIDATE_SHA=0000000000000000000000000000000000000000 \
    GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH=/missing; do
    if invoke "$invalid" >"$work/log" 2>&1; then
      echo "FAIL: accepted $invalid" >&2
      exit 1
    fi
  done
  for mutation in '.repository.default_branch="candidate"' '.pull_request.base.ref="candidate"' \
    '.pull_request.base.repo.full_name="other/repository"' '.pull_request.base.sha="0000000000000000000000000000000000000000"' \
    '.pull_request.head.sha="main"' '.pull_request.merge_commit_sha="0000000000000000000000000000000000000000"'; do
    jq "$mutation" "$work/event.json" >"$work/changed.json"
    if invoke GITHUB_EVENT_PATH="$work/changed.json" >"$work/log" 2>&1; then
      echo "FAIL: accepted $mutation" >&2
      exit 1
    fi
  done
  for mutation in '.merge_group.base_ref="refs/heads/candidate"' \
    '.merge_group.base_sha="0000000000000000000000000000000000000000"' \
    '.merge_group.head_sha="0000000000000000000000000000000000000000"'; do
    jq "$mutation" "$work/event.json" >"$work/changed.json"
    if invoke GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$work/changed.json" >"$work/log" 2>&1; then
      echo "FAIL: accepted $mutation" >&2
      exit 1
    fi
  done
done
[[ ! -e $work/trace ]] || {
  echo 'FAIL: context validation executed candidate helpers' >&2
  exit 1
}
mode=run
invoke
[[ $(paste -sd, "$work/trace") == fetched,contained ]] || {
  echo 'FAIL: trusted dispatch did not complete' >&2
  exit 1
}
[[ -z $(find "$work/temp" -mindepth 1 -print -quit) ]] || {
  echo 'FAIL: successful run retained private candidate state' >&2
  exit 1
}
result=0
invoke CONTROL_EXIT=19 >"$work/log" 2>&1 || result=$?
[[ $result == 19 ]] || {
  echo 'FAIL: contained failure was masked' >&2
  exit 1
}
invoke CONTROL_WAIT=true READY="$work/ready" >"$work/cancel.log" 2>&1 &
invocation=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -s $work/ready ]] || break
  sleep 0.05
done
[[ -s $work/ready ]] || {
  echo 'FAIL: cancellation fixture never started' >&2
  exit 1
}
controller=$(<"$work/ready")
[[ $controller =~ ^[1-9][0-9]*$ ]] || exit 1
kill -TERM "$controller"
result=0
wait "$invocation" || result=$?
[[ $result == 130 && $(tail -n 1 "$work/trace") == cancelled ]] || {
  echo 'FAIL: cancellation lost child cleanup acknowledgment' >&2
  exit 1
}
[[ -z $(find "$work/temp" -mindepth 1 -print -quit) ]] || {
  echo 'FAIL: acknowledged cancellation retained candidate state' >&2
  exit 1
}
result=0
invoke CONTROL_EXIT=2 >"$work/log" 2>&1 || result=$?
[[ $result == 2 && -n $(find "$work/temp" -mindepth 1 -print -quit) ]] || {
  echo 'FAIL: uncertain cleanup did not preserve private state and failure' >&2
  exit 1
}
mode=unknown
if invoke >"$work/log" 2>&1; then
  echo 'FAIL: unknown command admitted' >&2
  exit 1
fi
mode=check
printf '# changed reviewed helper\n' >>"$work/trusted/tools/run-sandboxed-trusted-regressions.sh"
if invoke >"$work/log" 2>&1; then
  echo 'FAIL: changed reviewed files were admitted' >&2
  exit 1
fi

yq -o=json . "$root/.github/actions/pr-admission/action.yaml" >"$work/action.json"
contract() {
  # shellcheck disable=SC2016 # GitHub expressions are literal interface data.
  jq -e '.inputs=={"candidate-sha":{description:"Immutable candidate integration commit supplied by GitHub.",required:true}} and
    .runs.using=="composite" and (.runs.steps|length)==3 and
    all(.runs.steps[]; (has("if") or has("continue-on-error"))|not) and
    .runs.steps[0].shell=="bash" and .runs.steps[0].env=={CANDIDATE_SHA:"${{ inputs.candidate-sha }}"} and
    .runs.steps[0].run=="bash \"$GITHUB_ACTION_PATH/../../../tools/shared-product-admission.sh\" check" and
    .runs.steps[1].uses=="actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e" and
    .runs.steps[1].with=={"go-version":"1.27.3",cache:false} and
    .runs.steps[2].shell=="bash" and .runs.steps[2].env=={CANDIDATE_SHA:"${{ inputs.candidate-sha }}"} and
    .runs.steps[2].run=="bash \"$GITHUB_ACTION_PATH/../../../tools/shared-product-admission.sh\" run"' "$1" >/dev/null
}
contract "$work/action.json"
for mutation in '.runs.steps[0].run="true"' '.runs.steps[0].env.CANDIDATE_SHA="main"' \
  '.runs.steps[1].with.cache=true' '.runs.steps[2].run="true"' \
  '.runs.steps[2]["continue-on-error"]=true' '.runs.steps[2].if="false"' '.runs.steps[2].shell="true {0}"'; do
  jq "$mutation" "$work/action.json" >"$work/changed.json"
  if contract "$work/changed.json"; then
    echo "FAIL: action bypass admitted: $mutation" >&2
    exit 1
  fi
done
jq -e '.=={version:1,"timeout-minutes":15}' "$root/.github/pr-admission.json" >/dev/null
echo 'PASS: shared admission binds reviewed source, GitHub identities, containment and failure propagation'
