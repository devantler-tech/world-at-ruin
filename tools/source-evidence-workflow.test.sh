#!/usr/bin/env bash
# Parse the real DAG: native captures must converge through the complete join.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/workflow.json"
admit() {
  # shellcheck disable=SC2016 # Literal GitHub expressions are the data under test.
  jq -e '
    def checkout: .steps[0].with=={ref:"${{ github.sha }}","fetch-depth":0,"persist-credentials":false};
    def safe: (.permissions // {contents:"read"})=={contents:"read"} and
      (has("continue-on-error")|not) and (has("container")|not);
    .jobs as $jobs |
    ($jobs["frame-capture-head"] | safe and checkout and
      .needs==["detect-visual-changes"] and ."runs-on"=="macos-latest" and ."timeout-minutes"==15 and
      .if=="needs.detect-visual-changes.outputs.visual == '\''true'\''" and
      .strategy=={"fail-fast":false,matrix:{group:["world","activity"]}} and
      all(.steps[]; (has("continue-on-error") or has("if"))|not) and
      any(.steps[];(.uses? // "" | test("^devantler-tech/world-at-ruin/\\.github/actions/capture-source@[0-9a-f]{40}$")) and .with=={
        group:"${{ matrix.group }}","first-run":"${{ needs.detect-visual-changes.outputs.first_run }}",
        visual:"${{ needs.detect-visual-changes.outputs.visual }}","gpu-gated":"${{ needs.detect-visual-changes.outputs.gpu_gated }}"}) and
      any(.steps[];.run?=="bash tools/source-evidence-package.sh head" and .env.CAPTURE_GROUP=="${{ matrix.group }}") and
      .steps[-1].with=={name:"source-head-${{ github.sha }}-${{ github.run_attempt }}-${{ matrix.group }}",
        path:"${{ runner.temp }}/shots/","if-no-files-found":"error"}) and
    ($jobs["frame-capture-base"] | safe and checkout and
      .needs==["detect-visual-changes"] and ."runs-on"=="macos-latest" and ."timeout-minutes"==15 and
      .if=="needs.detect-visual-changes.outputs.visual == '\''true'\''" and
      .steps[1]["timeout-minutes"]==1 and
      any(.steps[];.id?=="install" and ."timeout-minutes"==2 and ."continue-on-error"==true) and
      any(.steps[];.id?=="base" and .run=="bash tools/render-source-base.sh" and ."continue-on-error"==true and ."timeout-minutes"==8 and .if=="steps.install.outcome == '\''success'\''") and
      any(.steps[];.run?=="bash tools/source-evidence-package.sh base" and
        .env.INSTALL_RESULT=="${{ steps.install.outcome }}" and .env.RENDER_RESULT=="${{ steps.base.outcome }}" and ."timeout-minutes"==1) and
      .steps[-1]["timeout-minutes"]==1 and
      .steps[-1].with=={name:"source-base-${{ github.sha }}-${{ github.run_attempt }}",
        path:"${{ runner.temp }}/source-base/","if-no-files-found":"error"}) and
    ($jobs["frame-capture"] | safe and checkout and
      ."runs-on"=="ubuntu-latest" and ."timeout-minutes"==5 and
      .needs==["detect-visual-changes","frame-capture-head","frame-capture-base"] and
      .if=="always() && needs.detect-visual-changes.result == '\''success'\'' && needs.detect-visual-changes.outputs.visual == '\''true'\''" and
      any(.steps[];.env.HEAD_RESULT?=="${{ needs.frame-capture-head.result }}" and .env.BASE_RESULT=="${{ needs.frame-capture-base.result }}" and .run=="[[ \"$HEAD_RESULT\" == success && \"$BASE_RESULT\" == success ]]") and
      [.steps[]|select(.uses? | strings | startswith("actions/download-artifact@"))|.with.name]==[
        "source-head-${{ github.sha }}-${{ github.run_attempt }}-world",
        "source-head-${{ github.sha }}-${{ github.run_attempt }}-activity",
        "source-base-${{ github.sha }}-${{ github.run_attempt }}"] and
      any(.steps[];.run?=="go run tools/source-evidence/main.go collect \"$RUNNER_TEMP/source-world\" \"$RUNNER_TEMP/source-activity\" \"$RUNNER_TEMP/source-base\" \"$RUNNER_TEMP/source-joined\"") and
      any(.steps[];.run?=="bash tools/source-evidence-conditions.sh" and .env=={CAPTURE_RUNNER_OS:"macOS",SOURCE_EVIDENCE_DIR:"${{ runner.temp }}/source-joined"} and ((has("continue-on-error") or has("if"))|not)) and
      .steps[-1].with=={name:"frames-${{ github.event.pull_request.head.sha }}",
        path:"${{ runner.temp }}/source-joined/shots/","if-no-files-found":"error"}) and
    ($jobs["ci-required-checks"].needs|index("frame-capture"))!=null and
    all(["frame-capture-head","frame-capture-base","frame-capture"][]; . as $job |
      $jobs[$job].env.BASE_SHA=="${{ github.event.pull_request.base.sha }}" and
      $jobs[$job].env.FIRST_RUN=="${{ needs.detect-visual-changes.outputs.first_run }}" and
      $jobs[$job].env.GPU_GATED=="${{ needs.detect-visual-changes.outputs.gpu_gated }}")
  ' "$1" >/dev/null
}
admit "$work/workflow.json" || {
  echo 'FAIL: native source captures do not converge through a complete source-bound join' >&2
  exit 1
}
for mutation in \
  '.jobs["frame-capture-head"].strategy.matrix.group=["world"]' \
  '.jobs["frame-capture-head"]["runs-on"]="ubuntu-latest"' \
  '.jobs["frame-capture-head"].steps[2]["continue-on-error"]=true' \
  'del(.jobs["frame-capture-base"].steps[3]["timeout-minutes"])' \
  '.jobs["frame-capture-base"].needs += ["frame-capture-head"]' \
  '.jobs["frame-capture"].needs -= ["frame-capture-base"]' \
  '.jobs["frame-capture"].if="true"' \
  '.jobs["frame-capture"].steps[0].with.ref="main"' \
  '.jobs["frame-capture"].env.FIRST_RUN="false"' \
  '.jobs["frame-capture"]["continue-on-error"]=true' \
  '.jobs["frame-capture"].steps[-1].with["if-no-files-found"]="ignore"'; do
  jq "$mutation" "$work/workflow.json" >"$work/mutated.json"
  if admit "$work/mutated.json"; then
    echo "FAIL: accepted source DAG bypass $mutation" >&2
    exit 1
  fi
done
echo 'PASS: isolated native source groups and BASE converge through the complete required join'
