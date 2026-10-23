#!/usr/bin/env bash
# Verify enacted ownership/routing and exercise the actual capture guards.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
action="$root/.github/actions/capture-source/action.yaml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$action" >"$work/action.json"
yq -o=json '.jobs."frame-capture-head".steps' "$root/.github/workflows/ci.yaml" >"$work/callers.json"
pin=$(jq -er '[.[] | .uses? // "" | select(startswith("devantler-tech/world-at-ruin/.github/actions/capture-source@"))] |
  if length==1 then .[0] | split("@")[1] else error("expected exactly one pinned source action") end' "$work/callers.json")
[[ $pin =~ ^[0-9a-f]{40}$ ]] || {
  echo 'FAIL: owner-local action is not fully pinned' >&2
  exit 1
}
# The input validator compares GitHub's loaded metadata to the candidate at
# runtime, so enactment proof does not depend on retaining a source branch.
contract() {
  # Protect group ownership and forwarding, not each capture implementation.
  # shellcheck disable=SC2016 # Literal GitHub expressions are parsed as data.
  jq -e '
    . as $action |
    .runs.using=="composite" and .author=="devantler-tech" and
    (.inputs|keys)==["first-run","gpu-gated","group","visual"] and .inputs.group.required==true and
    all(["first-run","gpu-gated","visual"][]; . as $key | $action.inputs[$key].default=="false") and
    all(.runs.steps[]; .shell=="bash" and (has("continue-on-error")|not)) and
    .runs.steps[0].run=="bash tools/source-capture-inputs.sh" and
    .runs.steps[0].env=={CAPTURE_GROUP:"${{ inputs.group }}",FIRST_RUN:"${{ inputs.first-run }}",
      VISUAL:"${{ inputs.visual }}",GPU_GATED:"${{ inputs.gpu-gated }}"} and
    all(.runs.steps[] | select(.name=="Install Godot (pinned, checksum-verified)" or .name=="Headless import + class-name scan" or .name=="Frames actually exist"); (has("if")|not)) and
    any(.runs.steps[]; .run=="bash tools/install-ci-macos-godot.sh") and
    any(.runs.steps[]; .name=="Capture frames" and .if=="inputs.group == '\''world'\''") and
    any(.runs.steps[]; .name=="Capture the opted-in ground previews" and .if=="inputs.group == '\''world'\''") and
    any(.runs.steps[]; .name=="Capture the first-run UI" and .if=="inputs.group == '\''world'\'' && inputs.first-run == '\''true'\''") and
    any(.runs.steps[]; .name=="Capture the breathing idle" and .if=="inputs.group == '\''activity'\'' && inputs.visual == '\''true'\''") and
    all(.runs.steps[] | select(.name|startswith("Capture ")); .if=="inputs.group == '\''world'\''" or
      .if=="inputs.group == '\''activity'\''" or .if=="inputs.group == '\''world'\'' && inputs.first-run == '\''true'\''" or
      .if=="inputs.group == '\''activity'\'' && inputs.visual == '\''true'\''")
  ' "$1" >/dev/null
}
contract "$work/action.json" || {
  echo 'FAIL: owner-local action bypasses selector or guard ownership' >&2
  exit 1
}
for mutation in '.runs.steps[0].run="true"' '.runs.steps[4].if="false"' '.runs.steps[4]["continue-on-error"]=true' '.runs.steps[4].shell="true {0}"'; do
  jq "$mutation" "$work/action.json" >"$work/changed.json"
  if contract "$work/changed.json"; then
    echo "FAIL: accepted $mutation" >&2
    exit 1
  fi
done
# Only the expensive external renderer is replaced. Execute the shipping Bash
# body and assert its actual refusal/acceptance, never the stub's invocation.
jq -er '.runs.steps[]|select(.name=="Capture frames")|.run' "$work/action.json" >"$work/capture.sh"
mkdir "$work/bin"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$FIXTURE_RENDER_LOG\"" "exit \"\${FIXTURE_RENDER_EXIT:-0}\"" >"$work/bin/godot"
chmod +x "$work/bin/godot"
for scenario in valid missing-pass missing-boot script-error engine-error metal-retry; do
  dir="$work/$scenario"
  mkdir -p "$dir/temp" "$dir/client/recipes"
  printf '{}\n' >"$dir/client/recipes/wanderer.json"
  log=$'CAPTURE PASS\nBOOT_OK'
  engine_exit=0
  case $scenario in
  missing-pass) log=BOOT_OK ;;
  missing-boot) log='CAPTURE PASS' ;;
  script-error) log+=$'\nSCRIPT ERROR: fixture failure' ;;
  engine-error) engine_exit=17 ;;
  metal-retry) log+=$'\nERROR: timeout waiting for fence' ;;
  esac
  result=0
  (cd "$dir" && PATH="$work/bin:$PATH" RUNNER_TEMP="$dir/temp" \
    FIXTURE_RENDER_LOG="$log" FIXTURE_RENDER_EXIT="$engine_exit" \
    bash -e -o pipefail "$work/capture.sh") >"$dir/output" 2>&1 || result=$?
  case $scenario in
  valid | metal-retry) [[ $result == 0 ]] || {
    echo "FAIL: rejected $scenario" >&2
    exit 1
  } ;;
  *) [[ $result != 0 ]] || {
    echo "FAIL: accepted $scenario" >&2
    exit 1
  } ;;
  esac
done
echo 'PASS: pinned capture ownership, routing and actual renderer failure guards'
