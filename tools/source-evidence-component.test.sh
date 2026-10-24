#!/usr/bin/env bash
# Exercise both the active pinned source recipe and the local source component.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for surface in workflow component; do
  work="$scratch/$surface"
  mkdir "$work"
  if [[ $surface == workflow ]]; then
    # Exercise the recipe the actual workflow executes, not only its local copy.
    # The caller is now pinned to an adopted action rather than inline steps.
    yq -o=json '.jobs."frame-capture-head".steps[1]' "$root/.github/workflows/ci.yaml" >"$work/call.json"
    # shellcheck disable=SC2016 # GitHub expressions are routing data.
    jq -e '
      (.uses|test("^devantler-tech/world-at-ruin/[.]github/actions/capture-source-head@[0-9a-f]{40}$")) and
      .["timeout-minutes"]==15 and (has("if") or has("continue-on-error")|not) and
      .with=={group:"${{ matrix.group }}",
        "first-run":"${{ needs.detect-visual-changes.outputs.first_run }}",
        "gpu-gated":"${{ needs.detect-visual-changes.outputs.gpu_gated }}",
        visual:"${{ needs.detect-visual-changes.outputs.visual }}"}
    ' "$work/call.json" >/dev/null || {
      echo 'FAIL: active source call bypasses its pinned recipe or input routing' >&2
      exit 1
    }
    pin=$(jq -er '.uses|split("@")[1]' "$work/call.json")
    git -C "$root" show "$pin:.github/actions/capture-source-head/action.yaml" |
      yq -o=json '.runs' >"$work/action.json"
  else
    yq -o=json '.runs' "$root/.github/actions/capture-source-head/action.yaml" >"$work/action.json"
  fi
  contract() {
    # Protect group ownership and forwarding, not each capture implementation.
    # shellcheck disable=SC2016 # Literal GitHub expressions are parsed as data.
    jq -e '
    all(.steps[]; (has("continue-on-error")|not)) and
    any(.steps[];.run?=="bash tools/source-capture-inputs.sh" and .env=={
      CAPTURE_GROUP:"${{ inputs.group }}",FIRST_RUN:"${{ inputs.first-run }}",
      VISUAL:"${{ inputs.visual }}",GPU_GATED:"${{ inputs.gpu-gated }}"}) and
    all(.steps[] | select(.name=="Install Godot (pinned, checksum-verified)" or .name=="Headless import + class-name scan" or .name=="Frames actually exist"); (has("if")|not)) and
    any(.steps[]; .run?=="bash tools/install-ci-macos-godot.sh") and
    any(.steps[]; .name=="Capture frames" and .if=="inputs.group == '\''world'\''") and
    any(.steps[]; .name=="Capture the opted-in ground previews" and .if=="inputs.group == '\''world'\''") and
    any(.steps[]; .name=="Capture the first-run UI" and .if=="inputs.group == '\''world'\'' && inputs.first-run == '\''true'\''") and
    any(.steps[]; .name=="Capture the breathing idle" and .if=="inputs.group == '\''activity'\'' && inputs.visual == '\''true'\''") and
    all(.steps[] | select((.name // "")|startswith("Capture ")); .shell=="bash" and
      (.if=="inputs.group == '\''world'\''" or .if=="inputs.group == '\''activity'\''" or
      .if=="inputs.group == '\''world'\'' && inputs.first-run == '\''true'\''" or
      .if=="inputs.group == '\''activity'\'' && inputs.visual == '\''true'\''"))
  ' "$1" >/dev/null
  }
  contract "$work/action.json" || {
    echo 'FAIL: source component bypasses selector or capture guards' >&2
    exit 1
  }
  for mutation in '.steps[2].run="true"' '.steps[5].if="false"' '.steps[5]["continue-on-error"]=true' '.steps[5].shell="true {0}"'; do
    jq "$mutation" "$work/action.json" >"$work/changed.json"
    if contract "$work/changed.json"; then
      echo "FAIL: accepted $mutation" >&2
      exit 1
    fi
  done
  # Only the expensive external renderer is replaced. Execute the shipping Bash
  # body and assert its actual refusal/acceptance, never the stub's invocation.
  jq -er '.steps[]|select(.name=="Capture frames")|.run' "$work/action.json" >"$work/capture.sh"
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
  echo "PASS: $surface source routing and actual renderer failure guards"
done
