#!/usr/bin/env bash
# Parse the actual independent workflow and reject routing or evidence bypasses.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
workflow="$root/.github/workflows/lavapipe-capture.yaml"
[[ -f $workflow ]] || {
  echo 'TEST FAIL -- advisory capture still shares required CI' >&2
  exit 1
}
yq -o=json '.' "$workflow" >"$scratch/capture.json"
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$scratch/ci.json"
jq -s '{capture:.[0],ci:.[1]}' "$scratch/capture.json" "$scratch/ci.json" >"$scratch/source.json"
admit() {
  jq -e '
    def pinned($action): test("^"+$action+"@[0-9a-f]{40}$");
    . as $all |
    (.capture | keys==["env","jobs","name","on","permissions"]
      and .on=={pull_request:null,merge_group:null}
      and .permissions=={contents:"read"}
      and .env=={GODOT_VERSION:$all.ci.env.GODOT_VERSION,GODOT_SHA512:$all.ci.env.GODOT_SHA512}
      and (.jobs|keys)==["collect-lavapipe","frame-capture-lavapipe","select"])
    and (.capture.jobs.select |
      keys==["if","name","outputs","runs-on","steps","timeout-minutes"]
      and .if=="github.event_name == '\''pull_request'\''"
      and ."runs-on"=="ubuntu-latest" and ."timeout-minutes"==5
      and .outputs=={capture:"${{ steps.select.outputs.capture }}","tested-sha":"${{ steps.select.outputs.tested-sha }}"}
      and (.steps|length)==2
      and (.steps[0]|keys==["uses","with"] and (.uses|pinned("actions/checkout"))
        and .with=={ref:"${{ github.sha }}","fetch-depth":0,"persist-credentials":false})
      and (.steps[1]|keys==["env","id","name","run"] and .id=="select"
        and .env=={BASE_SHA:"${{ github.event.pull_request.base.sha }}",HEAD_SHA:"${{ github.event.pull_request.head.sha }}"}
        and (.run|contains("bash tools/select-lavapipe-capture.sh select"))
        and (.run|contains("tested-sha=%s"))))
    and (.capture.jobs["frame-capture-lavapipe"] |
      keys==["if","name","needs","runs-on","steps","strategy","timeout-minutes"]
      and .needs==["select"]
      and .if=="needs.select.outputs.capture == '\''true'\'' && needs.select.outputs.tested-sha == github.sha"
      and ."runs-on"=="ubuntu-24.04" and ."timeout-minutes"==15
      and .strategy=={"fail-fast":false,matrix:{vantage:["sunward","crossfield","shrine","bonepale","cinderreach","cave-chamber","cave-walkout","cave-mouth"]}}
      and all(.steps[]; (has("if") or has("continue-on-error"))|not)
      and (.steps[0]|keys==["uses","with"] and (.uses|pinned("actions/checkout"))
        and .with=={ref:"${{ needs.select.outputs.tested-sha }}","fetch-depth":0,"persist-credentials":false})
      and (.steps[1]|.run=="bash tools/select-lavapipe-capture.sh verify"
        and .env=={BASE_SHA:"${{ github.event.pull_request.base.sha }}",HEAD_SHA:"${{ github.event.pull_request.head.sha }}"})
      and any(.steps[];.run?=="bash tools/install-ci-godot.sh")
      and any(.steps[];.id?=="capture" and .env=={CAPTURE_VANTAGE:"${{ matrix.vantage }}"}
        and (.run|contains("./tools/lavapipe-capture-guard.sh"))
        and (.run|contains("WAR_WORLD_VANTAGE=\"${CAPTURE_VANTAGE}\"")))
      and (.["steps"][-1]|(.uses|pinned("actions/upload-artifact"))
        and .with.name=="lavapipe-volumetric-frames-${{ github.sha }}-${{ matrix.vantage }}"
        and .with["if-no-files-found"]=="error"))
    and (.capture.jobs["collect-lavapipe"] |
      keys==["if","name","needs","runs-on","steps","timeout-minutes"]
      and .needs==["select","frame-capture-lavapipe"]
      and .if=="always() && needs.select.result == '\''success'\'' && needs.select.outputs.capture == '\''true'\''"
      and ."runs-on"=="ubuntu-latest" and ."timeout-minutes"==5
      and all(.steps[]; (has("if") or has("continue-on-error"))|not)
      and (.steps[0]|keys==["uses","with"] and (.uses|pinned("actions/checkout"))
        and .with=={ref:"${{ needs.select.outputs.tested-sha }}","fetch-depth":0,"persist-credentials":false})
      and (.steps[1]|.env.MATRIX_RESULT=="${{ needs.frame-capture-lavapipe.result }}"
        and (.run|contains("[[ \"$MATRIX_RESULT\" == success ]]"))
        and (.run|contains("bash tools/select-lavapipe-capture.sh verify")))
      and (.steps[2]|(.uses|pinned("actions/download-artifact"))
        and .with.pattern=="lavapipe-volumetric-frames-${{ github.sha }}-*"
        and .with["merge-multiple"]==false)
      and (.steps[3]|.run=="bash tools/collect-lavapipe-captures.sh \"$RUNNER_TEMP/lavapipe-parts\" \"$RUNNER_TEMP/lavapipe-complete\" \"$GITHUB_SHA\"")
      and (.["steps"][-1]|(.uses|pinned("actions/upload-artifact"))
        and .with.name=="lavapipe-volumetric-frames-${{ github.sha }}"
        and .with["if-no-files-found"]=="error"))
    and (.ci.jobs|has("frame-capture-lavapipe")|not)
    and (.ci.jobs["ci-required-checks"]|.if=="${{ always() }}"
      and (.needs|index("frame-capture-lavapipe"))==null
      and (.needs|index("detect-visual-changes"))!=null
      and (.needs|index("frame-capture"))!=null
      and (.needs|index("frame-capture-exported"))!=null)
  ' "$1" >/dev/null
}
admit "$scratch/source.json" || {
  echo 'TEST FAIL -- independent capture source contract changed' >&2
  exit 1
}
for mutation in \
  '.capture.on.workflow_run={workflows:["CI"],types:["completed"]}' \
  '.capture.on.pull_request={paths:["client/**"]}' \
  '.capture.permissions.contents="write"' \
  '.capture.jobs.select.if="false"' \
  ".capture.jobs.select.steps[0].with.ref=\"\${{ github.event.pull_request.head.sha }}\"" \
  '.capture.jobs.select.steps[0].with["persist-credentials"]=true' \
  '.capture.jobs["frame-capture-lavapipe"].if="true"' \
  '.capture.jobs["frame-capture-lavapipe"]["timeout-minutes"]=90' \
  '.capture.jobs["frame-capture-lavapipe"].strategy.matrix.vantage |= .[:-1]' \
  '.capture.jobs["frame-capture-lavapipe"].strategy.matrix.vantage += ["sunward"]' \
  '.capture.jobs["frame-capture-lavapipe"].steps[6].env.CAPTURE_VANTAGE="sunward"' \
  '.capture.jobs["frame-capture-lavapipe"].steps[1].run="true"' \
  '.capture.jobs["frame-capture-lavapipe"].steps[2]["continue-on-error"]=true' \
  '.capture.jobs["frame-capture-lavapipe"].steps[-1].with["if-no-files-found"]="ignore"' \
  '.capture.jobs["frame-capture-lavapipe"].steps[-1].with.name="unbound-frames"' \
  '.capture.jobs["collect-lavapipe"].if="true"' \
  '.capture.jobs["collect-lavapipe"].steps[1].env.MATRIX_RESULT="success"' \
  '.capture.jobs["collect-lavapipe"].steps[2].with["merge-multiple"]=true' \
  '.capture.jobs["collect-lavapipe"].steps[3].run="true"' \
  '.ci.jobs["ci-required-checks"].needs += ["frame-capture-lavapipe"]' \
  '.ci.jobs["ci-required-checks"].needs -= ["frame-capture"]'; do
  jq "$mutation" "$scratch/source.json" >"$scratch/mutant.json"
  if admit "$scratch/mutant.json"; then
    echo "TEST FAIL -- accepted $mutation" >&2
    exit 1
  fi
done
echo 'Independent advisory workflow routing, identity, permissions and evidence controls passed'
