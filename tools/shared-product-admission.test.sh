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
mkdir -p "$work/trusted/tools" "$work/temp" "$work/bin"
cp "$driver" "$root/tools/trusted-regression-lifecycle.sh" "$root/tools/resolve-trusted-regression-event.sh" "$work/trusted/tools/"
cat >"$work/trusted/tools/fetch-trusted-regression-data.sh" <<'FETCH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == candidate && $2 == "$GITHUB_SHA" && ! -e candidate ]]
git -c core.hooksPath=/dev/null clone --quiet --no-hardlinks --no-checkout "$EXPECTED_TRUSTED" candidate
checkout_sha=${FETCH_SHA:-$GITHUB_SHA}
git -C candidate -c core.hooksPath=/dev/null checkout --quiet --detach "$checkout_sha"
# Match the production depth-one fetch: graph-format output hides its parents,
# but the immutable commit object's header must remain available to the witness.
printf '%s\n' "$checkout_sha" >candidate/.git/shallow
[[ -z $(git -C candidate show -s --format=%P HEAD) ]]
printf 'fetched\n' >>"$TRACE"
FETCH
cat >"$work/trusted/tools/run-sandboxed-trusted-regressions.sh" <<'CONTROL'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == "$EXPECTED_TRUSTED" && $2 == "$PWD/candidate" && -d $2 ]]
[[ -z ${GH_TOKEN+x} && -z ${GITHUB_TOKEN+x} ]]
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
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 15 && $1 == --disable && $2 == --fail && $3 == --silent && $4 == --show-error &&
  $5 == --connect-timeout && $6 == 5 && $7 == --max-time && $8 == 30 &&
  $9 == --header && ${10} == 'Authorization: Bearer fixture-read-token' &&
  ${11} == --header && ${12} == 'Accept: application/vnd.github+json' &&
  ${13} == --header && ${14} == 'X-GitHub-Api-Version: 2026-03-10' ]]
[[ ${!#} == "https://api.github.com/repos/devantler-tech/world-at-ruin/compare/$EXPECTED_BASE...$EXPECTED_PARENT?per_page=1" ]]
printf 'compared\n' >>"$TRACE"
cat "$COMPARISON_BODY"
exit "${COMPARISON_EXIT:-0}"
CURL
chmod +x "$work/bin/curl"
git -C "$work/trusted" init -q
git -C "$work/trusted" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false add tools
git -C "$work/trusted" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm trusted
base=$(git -C "$work/trusted" rev-parse HEAD)
# Real Git objects independently witness the event's base/head pair. Put fake
# parent text and more than a pipe buffer in the message: it is data, not headers.
tree=$(git -C "$work/trusted" rev-parse 'HEAD^{tree}')
commit_object() {
  git -C "$work/trusted" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit-tree "$tree" "$@"
}
head=$(printf 'candidate head\n' | commit_object -p "$base")
extra_head=$(printf 'another head\n' | commit_object -p "$base")
advanced_base=$(printf 'main advanced after the event base\n' | commit_object -p "$base")
advanced_candidate=$(printf 'rebuilt native integration\n' | commit_object -p "$advanced_base" -p "$head")
printf 'integration\n\nparent 0000000000000000000000000000000000000000\n' >"$work/message"
printf '%100000s\n' '' >>"$work/message"
candidate=$(commit_object -p "$base" -p "$head" <"$work/message")
reversed=$(printf 'reversed parents\n' | commit_object -p "$head" -p "$base")
extra_parent=$(printf 'extra parent\n' | commit_object -p "$base" -p "$head" -p "$extra_head")
# An indented signature continuation is not a second top-level parent header.
signature_parent=$(printf 'tree %s\nparent %s\nauthor fixture <fixture@example.invalid> 1700000000 +0000\ncommitter fixture <fixture@example.invalid> 1700000000 +0000\ngpgsig fixture\n parent %s\n\nnot a merge\n' \
  "$tree" "$base" "$head" | git -C "$work/trusted" hash-object -t commit -w --stdin)
workflow=2222222222222222222222222222222222222222
jq -n --arg base "$base" --arg head "$head" --arg candidate "$candidate" '{repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},pull_request:{base:{repo:{full_name:"devantler-tech/world-at-ruin"},ref:"main",sha:$base},head:{sha:$head},merge_commit_sha:$candidate},merge_group:{base_ref:"refs/heads/main",base_sha:$base,head_sha:$candidate}}' >"$work/event.json"
invoke() {
  env GITHUB_REPOSITORY=devantler-tech/world-at-ruin \
    GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/main \
    GITHUB_WORKFLOW_SHA="$workflow" GITHUB_SHA="$candidate" CANDIDATE_SHA="$candidate" \
    GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$work/event.json" RUNNER_TEMP="$work/temp" \
    TRACE="$work/trace" EXPECTED_TRUSTED="$work/trusted" PATH="$work/bin:$PATH" "$@" \
    bash "$work/trusted/tools/shared-product-admission.sh" "$mode"
}
mode=check
invoke
invoke GITHUB_EVENT_NAME=merge_group
# Native PR events can retain another integration snapshot in merge_commit_sha.
# Check the event context here; run must independently bind the fetched commit.
jq '.pull_request.merge_commit_sha="3333333333333333333333333333333333333333"' "$work/event.json" >"$work/native-event.json"
invoke GITHUB_EVENT_PATH="$work/native-event.json" || {
  echo 'FAIL: valid native event context rejected a different merge snapshot' >&2
  exit 1
}
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
    '.pull_request.head.sha="main"'; do
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
# A stale, missing or null payload merge pointer is harmless only because the
# fetched object's exact two ordered parents independently bind base and head.
for mutation in '.pull_request.merge_commit_sha=null' 'del(.pull_request.merge_commit_sha)' \
  '.pull_request.merge_commit_sha="3333333333333333333333333333333333333333"'; do
  jq "$mutation" "$work/event.json" >"$work/native-event.json"
  rm "$work/trace"
  invoke GITHUB_EVENT_PATH="$work/native-event.json"
  [[ $(paste -sd, "$work/trace") == fetched,contained ]] || exit 1
done
# An event's base can predate the current main parent of a rebuilt integration.
# Keep its reviewed implementation, bind the second parent exactly, and prove
# the first parent's ancestry through the canonical read-only comparison API.
jq -n --arg base "$base" --arg parent "$advanced_base" \
  '{url:("https://api.github.com/repos/devantler-tech/world-at-ruin/compare/"+$base+"..."+$parent),
    status:"ahead",ahead_by:1,behind_by:0,total_commits:1,
    base_commit:{sha:$base},merge_base_commit:{sha:$base}}' >"$work/comparison.json"
rm "$work/trace"
invoke GITHUB_SHA="$advanced_candidate" CANDIDATE_SHA="$advanced_candidate" \
  GH_TOKEN=fixture-read-token GITHUB_TOKEN=fixture-other-token \
  EXPECTED_BASE="$base" EXPECTED_PARENT="$advanced_base" \
  COMPARISON_BODY="$work/comparison.json"
[[ $(paste -sd, "$work/trace") == fetched,compared,contained ]] || {
  echo 'FAIL: advanced integration did not prove canonical base ancestry before containment' >&2
  exit 1
}
for mutation in '.status="behind"' '.status="diverged"' '.status="identical"' \
  '.base_commit.sha="0000000000000000000000000000000000000000"' \
  '.merge_base_commit.sha="0000000000000000000000000000000000000000"' \
  '.url="https://example.invalid/comparison"' '.ahead_by=0' '.ahead_by=-1' \
  '.ahead_by=1.5' '.ahead_by="1"' '.behind_by=1' '.total_commits=2' '{}'; do
  jq "$mutation" "$work/comparison.json" >"$work/invalid-comparison.json"
  rm "$work/trace"
  if invoke GITHUB_SHA="$advanced_candidate" CANDIDATE_SHA="$advanced_candidate" \
    GH_TOKEN=fixture-read-token EXPECTED_BASE="$base" EXPECTED_PARENT="$advanced_base" \
    COMPARISON_BODY="$work/invalid-comparison.json" >"$work/log" 2>&1; then
    echo "FAIL: inconsistent ancestry admitted: $mutation" >&2
    exit 1
  fi
  [[ $(paste -sd, "$work/trace") == fetched,compared ]] || exit 1
  rm -rf "$work/temp"
  mkdir "$work/temp"
done
for control in malformed multiple operational-error missing-token; do
  args=()
  case "$control" in
  malformed) printf '{broken' >"$work/invalid-comparison.json" ;;
  multiple) cat "$work/comparison.json" "$work/comparison.json" >"$work/invalid-comparison.json" ;;
  operational-error)
    cp "$work/comparison.json" "$work/invalid-comparison.json"
    args=(COMPARISON_EXIT=22)
    ;;
  missing-token) args=(GH_TOKEN=) ;;
  esac
  rm "$work/trace"
  if invoke GITHUB_SHA="$advanced_candidate" CANDIDATE_SHA="$advanced_candidate" \
    GH_TOKEN=fixture-read-token EXPECTED_BASE="$base" EXPECTED_PARENT="$advanced_base" \
    COMPARISON_BODY="$work/invalid-comparison.json" "${args[@]}" >"$work/log" 2>&1; then
    echo "FAIL: incomplete ancestry evidence admitted: $control" >&2
    exit 1
  fi
  expected=fetched,compared
  [[ $control != missing-token ]] || expected=fetched
  [[ $(paste -sd, "$work/trace") == "$expected" ]] || exit 1
  rm -rf "$work/temp"
  mkdir "$work/temp"
done
# Valid-looking but wrong event heads, wrong checkouts, wrong parent order and
# extra parents must fail after the real fetch and before contained execution.
for control in event-head checkout parent-order extra-parent signature-parent; do
  rm "$work/trace"
  case "$control" in
  event-head)
    jq '.pull_request.head.sha="0000000000000000000000000000000000000000"' "$work/event.json" >"$work/changed.json"
    args=(GITHUB_EVENT_PATH="$work/changed.json")
    ;;
  checkout) args=(FETCH_SHA="$base") ;;
  parent-order) args=(GITHUB_SHA="$reversed" CANDIDATE_SHA="$reversed") ;;
  extra-parent) args=(GITHUB_SHA="$extra_parent" CANDIDATE_SHA="$extra_parent") ;;
  signature-parent) args=(GITHUB_SHA="$signature_parent" CANDIDATE_SHA="$signature_parent") ;;
  esac
  if invoke "${args[@]}" >"$work/log" 2>&1; then
    echo "FAIL: admitted mismatched integration: $control" >&2
    exit 1
  fi
  [[ $(cat "$work/trace") == fetched ]] || {
    echo "FAIL: $control did not reach the real object check or executed candidate code" >&2
    exit 1
  }
  # Refusal retains uncertain scratch for diagnosis; this fixture owns it all.
  rm -rf "$work/temp"
  mkdir "$work/temp"
done
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
    .runs.using=="composite" and (.runs.steps|length)==4 and
    all(.runs.steps[]; (has("if") or has("continue-on-error"))|not) and
    .runs.steps[0].shell=="bash" and .runs.steps[0].env=={CANDIDATE_SHA:"${{ inputs.candidate-sha }}"} and
    .runs.steps[0].run=="bash \"$GITHUB_ACTION_PATH/../../../tools/shared-product-admission.sh\" check" and
    .runs.steps[1].uses=="actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e" and
    .runs.steps[1].with=={"go-version":"1.27.3",cache:false} and
    .runs.steps[2].shell=="bash" and .runs.steps[2].env=={
      GODOT_VERSION:"4.7.1",
      GODOT_SHA512:"4ccdab7a48eeccbe8819a2fc1f6262f8d72065d98601bcb3743fcbd7ebd39f373758a788ee3293a05ec5b2c48538266c437404312e372225cd2df273945a2de9"} and
    .runs.steps[2].run=="engine_dir=$(mktemp -d \"$RUNNER_TEMP/world-admission-engine.XXXXXX\")\ntrap '\''rm -rf \"$engine_dir\"'\'' EXIT\ncd \"$engine_dir\"\nbash \"$GITHUB_ACTION_PATH/../../../tools/install-ci-godot.sh\"\n" and
    .runs.steps[3].shell=="bash" and .runs.steps[3].env=={
      CANDIDATE_SHA:"${{ inputs.candidate-sha }}",GH_TOKEN:"${{ github.token }}"} and
    .runs.steps[3].run=="bash \"$GITHUB_ACTION_PATH/../../../tools/shared-product-admission.sh\" run"' "$1" >/dev/null
}
contract "$work/action.json"
# Exercise the actual composite shell step with a cold, unrelated working
# directory. Only the reviewed installer is substituted; its pins, lookup,
# temporary download directory and cleanup remain the production step's own.
engine_base="$work/engine-base"
mkdir -p "$engine_base/.github/actions/pr-admission" "$engine_base/tools" "$work/engine-runner" "$work/unrelated"
cat >"$engine_base/tools/install-ci-godot.sh" <<'INSTALL'
set -euo pipefail
[[ $GODOT_VERSION == 4.7.1 && ${#GODOT_SHA512} == 128 ]]
[[ $PWD == "$RUNNER_TEMP"/world-admission-engine.* && -d $PWD ]]
[[ $GITHUB_ACTION_PATH == "$ENGINE_BASE/.github/actions/pr-admission" ]]
printf '%s\n' "$PWD" >"$ENGINE_RECEIPT"
exit "${ENGINE_INSTALL_STATUS:-0}"
INSTALL
jq -r '.runs.steps[2].run' "$work/action.json" >"$work/install-engine-step.sh"
run_engine_step() (
  cd "$work/unrelated"
  export GITHUB_ACTION_PATH="$engine_base/.github/actions/pr-admission" RUNNER_TEMP="$work/engine-runner"
  export ENGINE_BASE="$engine_base" ENGINE_RECEIPT="$work/engine-receipt"
  export GODOT_VERSION GODOT_SHA512
  GODOT_VERSION=$(jq -r '.runs.steps[2].env.GODOT_VERSION' "$work/action.json")
  GODOT_SHA512=$(jq -r '.runs.steps[2].env.GODOT_SHA512' "$work/action.json")
  bash -e -o pipefail "$work/install-engine-step.sh"
)
run_engine_step
[[ -s $work/engine-receipt && ! -e $(cat "$work/engine-receipt") ]]
engine_status=0
ENGINE_INSTALL_STATUS=19 run_engine_step || engine_status=$?
[[ $engine_status == 19 && ! -e $(cat "$work/engine-receipt") ]] || {
  echo 'FAIL: engine installer failure or temporary cleanup lost' >&2
  exit 1
}
# shellcheck disable=SC2016 # Candidate expressions are literal refusal fixtures.
for mutation in '.runs.steps[0].run="true"' '.runs.steps[0].env.CANDIDATE_SHA="main"' \
  '.runs.steps[1].with.cache=true' 'del(.runs.steps[2])' \
  '.runs.steps[2].run="true"' '.runs.steps[2].env.GODOT_VERSION="latest"' \
  '.runs.steps[2].env.GODOT_SHA512="unchecked"' '.runs.steps[2].env.GODOT_SHA512="${{ inputs.digest }}"' \
  '.runs.steps[2]["continue-on-error"]=true' '.runs.steps[2].if="false"' \
  '.runs.steps |= .[0:2] + [.[3], .[2]]' '.runs.steps[3].run="true"' \
  '.runs.steps[3]["continue-on-error"]=true' '.runs.steps[3].if="false"' '.runs.steps[3].shell="true {0}"' \
  '.runs.steps[3].env.GH_TOKEN="other"' 'del(.runs.steps[3].env.GH_TOKEN)'; do
  jq "$mutation" "$work/action.json" >"$work/changed.json"
  if contract "$work/changed.json"; then
    echo "FAIL: action bypass admitted: $mutation" >&2
    exit 1
  fi
done
jq -e '.=={version:1,"timeout-minutes":15}' "$root/.github/pr-admission.json" >/dev/null
echo 'PASS: shared admission binds reviewed source, GitHub identities, containment and failure propagation'
