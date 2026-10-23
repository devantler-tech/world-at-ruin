#!/usr/bin/env bash
# Preserve every existing editor capture command while splitting its ownership.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
action="$root/.github/actions/capture-source/action.yaml"
[[ -f $action && ! -L $action ]] || {
  echo 'FAIL: missing owner-local source capture component' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$root" --no-replace-objects show ecfc21a687d0dc4e8eff9d807728d386544a453d:.github/workflows/ci.yaml >"$work/reviewed.yaml"
yq -o=json '.' "$work/reviewed.yaml" >"$work/reviewed.json"
yq -o=json '.' "$action" >"$work/action.json"
yq -o=json '.jobs."frame-capture-head".steps' "$root/.github/workflows/ci.yaml" >"$work/callers.json"
pin=$(jq -er '[.[] | .uses? // "" | select(startswith("devantler-tech/world-at-ruin/.github/actions/capture-source@"))] |
  if length==1 then .[0] | split("@")[1] else error("expected exactly one pinned source action") end' "$work/callers.json")
[[ $pin =~ ^[0-9a-f]{40}$ ]] || {
  echo 'FAIL: owner-local capture action is not fully pinned' >&2
  exit 1
}
git -C "$root" --no-replace-objects show "$pin:.github/actions/capture-source/action.yaml" >"$work/pinned-action.yaml"
cmp -s "$action" "$work/pinned-action.yaml" || {
  echo 'FAIL: workflow does not execute the current owner-local capture action' >&2
  exit 1
}
jq -n --slurpfile old "$work/reviewed.json" --slurpfile action "$work/action.json" '{old:$old[0],action:$action[0]}' >"$work/contract.json"
admit() {
  # shellcheck disable=SC2016 # Literal GitHub expressions and jq variables.
  jq -e '
    def world: ["Capture frames","Capture the opted-in ground previews","Capture the first-run UI"];
    def activity: ["Capture the moving-key material response","Capture the replicated population",
      "Capture the authoritative mob chase","Capture the breathing idle","Capture the opt-in grounded walk",
      "Capture the opt-in grounded run","Capture the walk-to-run transition","Capture the controller-driven gait"];
    def common: ["Install Godot (pinned, checksum-verified)","Headless import + class-name scan","Frames actually exist"];
    .old.jobs["frame-capture"].steps as $old |
    .action as $action |
    ($old | map(select(.name as $n | (world+activity+common) | index($n)))) as $expected |
    ($action.runs.steps[1:]) as $actual |
    ($action | keys==["author","description","inputs","name","runs"]) and
    $action.author=="devantler-tech" and $action.runs.using=="composite" and
    ($action.inputs|keys)==["first-run","gpu-gated","group","visual"] and
    $action.inputs.group.required==true and
    all(["first-run","gpu-gated","visual"][]; . as $n | $action.inputs[$n].default=="false") and
    ($action.runs.steps|length)==15 and
    $action.runs.steps[0].name=="Validate source capture inputs" and
    $action.runs.steps[0].run=="bash tools/source-capture-inputs.sh" and
    $action.runs.steps[0].shell=="bash" and
    $action.runs.steps[0].env=={CAPTURE_GROUP:"${{ inputs.group }}",FIRST_RUN:"${{ inputs.first-run }}",
      VISUAL:"${{ inputs.visual }}",GPU_GATED:"${{ inputs.gpu-gated }}"} and
    ($actual|map(.name))==($expected|map(.name)) and
    all($expected[]; . as $step |
      ($actual[]|select(.name==$step.name)) as $moved |
      ($moved|del(.shell,.if))==($step|del(.if)) and $moved.shell=="bash" and
      (if (common|index($step.name))!=null then ($moved|has("if")|not)
       else (if (world|index($step.name))!=null then "world" else "activity" end) as $group |
         ($step.if // "" | gsub("needs.detect-visual-changes.outputs.first_run";"inputs.first-run") |
           gsub("needs.detect-visual-changes.outputs.visual";"inputs.visual")) as $original_if |
         $moved.if==("inputs.group == \u0027"+$group+"\u0027"+
           (if $original_if=="" then "" else " && "+$original_if end))
       end))
  ' "$1" >/dev/null
}
admit "$work/contract.json" || {
  echo 'FAIL: moved source capture commands or their conditions changed' >&2
  exit 1
}
for mutation in \
  'del(.action.runs.steps[4])' \
  '.action.runs.steps[4].run="true"' \
  '.action.runs.steps[4].if="true"' \
  '.action.runs.steps[4]["continue-on-error"]=true' \
  '.action.runs.steps[4].shell="true {0}"' \
  '.action.runs.steps[0].run="true"' \
  '.action.inputs.visual.default="true"'; do
  jq "$mutation" "$work/contract.json" >"$work/mutated.json"
  if admit "$work/mutated.json"; then
    echo "FAIL: source capture accepted $mutation" >&2
    exit 1
  fi
done
echo 'PASS: all moved editor capture commands and flag conditions match their reviewed source'
