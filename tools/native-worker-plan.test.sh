#!/usr/bin/env bash
# Runner capacity is shared: more native jobs than capacity creates queue waves.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/workflow.json"
# Count expanded jobs, not YAML keys. Refuse matrix forms whose size is unknown.
count_native() {
  jq -er '
    [.jobs[] | select(."runs-on" == "macos-15") |
      if .strategy.matrix == null then 1
      elif (.strategy.matrix | keys) == ["include"] then (.strategy.matrix.include | length)
      elif (.strategy.matrix | keys) == ["group"] then (.strategy.matrix.group | length)
      elif (.strategy.matrix | keys) == ["mode"] then (.strategy.matrix.mode | length)
      else error("unknown native matrix") end] | add
  ' "$1"
}
native_count=$(count_native "$work/workflow.json")
[[ $native_count == 5 ]] || {
  echo "FAIL: complete visual CI allocates $native_count native workers, expected five" >&2
  exit 1
}
# Count alone could pass by omitting work. Bind the five workers to the full
# logical operation set, with unchanged per-operation budgets and failure paths.
admit_plan() {
  # shellcheck disable=SC2016 # GitHub expressions are literal routing data.
  jq -e '
    def required_phase($path):
      (.uses|startswith("devantler-tech/world-at-ruin/"+$path+"@")) and
      (.uses|split("@")|last|test("^[0-9a-f]{40}$")) and
      .["timeout-minutes"]==15 and (has("continue-on-error")|not);
    .jobs as $jobs |
    $jobs["frame-capture-head"] as $source |
    $jobs["frame-capture-cloth"] as $cloth |
    $jobs["client-export-macos"] as $export |
    "always() && !cancelled() && matrix.group == '\''world'\''" as $selected |
    ($selected+" && steps.source-base-checkout.outcome == '\''success'\''") as $checked |
    ($checked+" && steps.source-base-toolchain.outcome == '\''success'\''") as $ready |
    "always() && !cancelled() && needs.detect-visual-changes.outputs.export_affecting == '\''true'\''" as $export_selected |
    ($export_selected+" && steps.export-base-checkout.outcome == '\''success'\''") as $export_ready |
    $source.strategy=={"fail-fast":false,matrix:{group:["world","activity"]}} and
    ($source.steps|length)==25 and $source["timeout-minutes"]==15 and
    $source.steps[0].with=={ref:"${{ github.sha }}","fetch-depth":0,"persist-credentials":false} and
    $source.steps[2].run=="bash tools/source-capture-inputs.sh" and
    $source.steps[2].env=={CAPTURE_GROUP:"${{ matrix.group }}",
      FIRST_RUN:"${{ needs.detect-visual-changes.outputs.first_run }}",
      GPU_GATED:"${{ needs.detect-visual-changes.outputs.gpu_gated }}",
      VISUAL:"${{ needs.detect-visual-changes.outputs.visual }}"} and
    ([$source.steps[19:][]|.["timeout-minutes"]]==[1,1,2,8,1,1]) and
    $source.steps[19].id=="source-base-checkout" and $source.steps[19].if==$selected and
    $source.steps[20].id=="source-base-toolchain" and $source.steps[20].if==$checked and
    $source.steps[21].id=="install" and $source.steps[21].if==$ready and
    $source.steps[22].id=="base" and $source.steps[22].if==($ready+" && steps.install.outcome == '\''success'\''") and
    $source.steps[23].id=="source-base-seal" and $source.steps[23].if==$ready and
    $source.steps[24].id=="source-base-upload" and
      $source.steps[24].if==($ready+" && steps.source-base-seal.outcome == '\''success'\''") and
    all($source.steps[19:][]|select(.id!="install" and .id!="base"); (has("continue-on-error")|not)) and
    $cloth.strategy=={"fail-fast":false,matrix:{include:[
      {pair:"off/on",first:"off",second:"on"},{pair:"drape/both",first:"drape",second:"both"}]}} and
    ($cloth.steps|length)==2 and $cloth["timeout-minutes"]==32 and
    ($cloth.steps[0] | required_phase(".github/actions/capture-cloth-mode") and
      (has("if")|not) and .with=={mode:"${{ matrix.first }}"}) and
    ($cloth.steps[1] | required_phase(".github/actions/capture-cloth-mode") and
      .if=="always() && !cancelled()" and .with=={mode:"${{ matrix.second }}"}) and
    ($export.steps|length)==16 and
    ([$export.steps[10:][]|.["timeout-minutes"]]==[1,2,9,1,1,1]) and
    $export.steps[10].id=="export-base-checkout" and $export.steps[10].if==$export_selected and
    $export.steps[11].id=="base-engine" and $export.steps[11].if==$export_ready and
    $export.steps[12].id=="base-capture" and
      $export.steps[12].if==($export_ready+" && steps.base-engine.outcome == '\''success'\''") and
    $export.steps[13].id=="base-record" and $export.steps[13].if==$export_ready and
    $export.steps[14].id=="base-upload" and
      $export.steps[14].if==($export_ready+" && steps.base-record.outcome == '\''success'\''") and
    $export.steps[15].id=="base-recorded" and
      $export.steps[15].if==($export_selected+" && steps.base-upload.outcome == '\''success'\''") and
    all($export.steps[10:][]|select(.id!="base-engine" and .id!="base-capture"); (has("continue-on-error")|not)) and
    $export.outputs["base-recorded"]=="${{ steps.base-recorded.outputs.recorded }}" and
    any($jobs["client-ordinary"].steps[]; (.run? // "")|contains("bash tools/native-worker-plan.test.sh"))
  ' "$1" >/dev/null
}
admit_plan "$work/workflow.json" || {
  echo 'FAIL: native worker plan omits or bypasses a complete capture phase' >&2
  exit 1
}
# Full-SHA syntax alone could execute unreviewed preparation or stale recipe
# bytes. Require adopted default-branch history and the exact locally tested
# action. This guard does not fetch or choose a remote from workflow content.
admit_component() {
  local repository=$1 pin=$2 action=$3 tested=$4 adopted=$5
  [[ $pin =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$repository" merge-base --is-ancestor "$pin" "$adopted" || return 1
  git -C "$repository" show "$pin:$action" >"$work/pinned-component.yaml" || return 1
  cmp -s "$work/pinned-component.yaml" "$tested"
}
# Exercise provenance refusals against a real local Git history, independently
# of the current portfolio branch or any network service.
fixture="$work/provenance"
git init -q "$fixture"
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m 'base'
mkdir -p "$fixture/action"
printf 'name: complete\n' >"$fixture/action/action.yaml"
git -C "$fixture" add action/action.yaml
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -q -m 'adopt component'
adopted=$(git -C "$fixture" rev-parse HEAD)
admit_component "$fixture" "$adopted" action/action.yaml "$fixture/action/action.yaml" "$adopted"
printf 'name: changed\n' >"$work/changed-action.yaml"
if admit_component "$fixture" "$adopted" action/action.yaml "$work/changed-action.yaml" "$adopted"; then
  echo 'FAIL: changed component bytes passed immutable execution binding' >&2
  exit 1
fi
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m 'unadopted preparation'
unadopted=$(git -C "$fixture" rev-parse HEAD)
if admit_component "$fixture" "$unadopted" action/action.yaml "$fixture/action/action.yaml" "$adopted"; then
  echo 'FAIL: unadopted preparation passed default-branch provenance' >&2
  exit 1
fi
if admit_component "$fixture" "$adopted" missing/action.yaml "$fixture/action/action.yaml" "$adopted" 2>/dev/null; then
  echo 'FAIL: absent pinned component passed execution binding' >&2
  exit 1
fi
for mutation in \
  '.jobs["frame-capture-head"].steps[2].env.VISUAL="false"' \
  '.jobs["frame-capture-head"].steps[22].if="false"' \
  '.jobs["frame-capture-head"].steps[19]["continue-on-error"]=true' \
  '.jobs["frame-capture-cloth"].strategy.matrix.include[1].second="drape"' \
  '.jobs["frame-capture-cloth"].steps[1].if="success()"' \
  '.jobs["frame-capture-cloth"].steps[0]["timeout-minutes"]=1' \
  '(.jobs["client-export-macos"].steps[]|select(.id=="base-capture")).if="false"' \
  '.jobs["client-export-macos"].outputs["base-recorded"]="true"'; do
  jq "$mutation" "$work/workflow.json" >"$work/mutated.json"
  if admit_plan "$work/mutated.json"; then
    echo "FAIL: admitted incomplete native plan: $mutation" >&2
    exit 1
  fi
done
# Execute the actual terminal shell. Incomplete, failed and unknown producer
# outcomes must not turn into a successful native BASE acknowledgement.
jq -er '.jobs["frame-capture-base"].steps[0].run' "$work/workflow.json" >"$work/source-ack.sh"
jq -er '.jobs["frame-capture-exported-base"].steps[0].run' "$work/workflow.json" >"$work/export-ack.sh"
for result in success failure skipped cancelled unknown ''; do
  status=0
  SOURCE_RESULT="$result" bash -e -o pipefail "$work/source-ack.sh" || status=$?
  if [[ $result == success ]]; then
    [[ $status == 0 ]]
  else
    [[ $status != 0 ]]
  fi
  for recorded in true false unknown ''; do
    status=0
    EXPORT_RESULT="$result" BASE_RECORDED="$recorded" bash -e -o pipefail "$work/export-ack.sh" || status=$?
    if [[ $result == success && $recorded == true ]]; then
      [[ $status == 0 ]]
    else
      [[ $status != 0 ]]
    fi
  done
done
# This control cannot be satisfied by counting only job definitions.
jq '.jobs["frame-capture-head"].strategy.matrix.group += ["extra"]' \
  "$work/workflow.json" >"$work/extra.json"
[[ $(count_native "$work/extra.json") == 6 ]] || {
  echo 'FAIL: extra matrix worker escaped capacity accounting' >&2
  exit 1
}
action=".github/actions/capture-cloth-mode/action.yaml"
pin=$(jq -er --arg prefix "devantler-tech/world-at-ruin/${action%/action.yaml}@" '
  [.jobs[].steps[]? | .uses? // "" | select(startswith($prefix)) | split("@")[1]] |
  unique | if length==1 then .[0] else error("ambiguous component pin") end
' "$work/workflow.json")
admit_component "$root" "$pin" "$action" "$root/$action" refs/remotes/origin/main || {
  echo 'FAIL: cloth execution is not the exact tested adopted component' >&2
  exit 1
}
echo 'PASS: complete native evidence uses five expanded Mac workers'
