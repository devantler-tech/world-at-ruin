#!/usr/bin/env bash
# Keep the independently required trusted workflow; this protects only the
# repository's parallel candidate proof and its stable, fail-closed routing.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$root/.github/workflows/ci.yaml}"
if ! yq -o=json '.' "$workflow" | jq -e '
  def checkout:
    .uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    and .with == {"fetch-depth":0,"persist-credentials":false};
  def worker($kind):
    keys == (if $kind == "ordinary" then ["defaults","name","outputs","runs-on","steps","timeout-minutes"]
      else ["name","outputs","runs-on","steps","timeout-minutes"] end)
    and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 75
    and .outputs == {complete:"${{ steps.proof.outputs.complete }}", "tested-sha":"${{ steps.proof.outputs.tested-sha }}"}
    and (.steps[0] | checkout)
    and ([.steps[] | select(has("continue-on-error"))] | length) == 0
    and .steps[1].run == ("printf '\''XDG_DATA_HOME=%s/war-client-" + $kind + "\\n'\'' \"$RUNNER_TEMP\" >> \"$GITHUB_ENV\"")
    and ([.steps[] | select(.run == "bash tools/install-ci-godot.sh")] | length) == 1
    and (.steps[-1] | .id == "proof" and .shell == "bash"
      and .run == ("bash tools/client-proof-completion.sh " + $kind) and (has("if") | not));
  def result($job):
    "${{ needs." + $job + ".result"
    + (if (["client-ordinary","client-sandbox","owned-child-native"] | index($job)) != null
      then " == '\''success'\'' && '\''success'\'' || '\''failure'\''" else "" end) + " }}";
  ["retired-repo-links","client-ordinary","client-sandbox","client-export-macos",
    "license-guard","lint","duplication-gate","gdscript-lint","go-vulnerability-scan",
    "server-ci","gameserver-commit-trial","zone-container","nakama-native","spire-native",
    "owned-child-native","detect-visual-changes","frame-capture","frame-capture-cloth","frame-capture-exported"] as $required
  | .on == {pull_request:null,merge_group:null}
  and .permissions == {contents:"read"}
  and (has("defaults") | not)
  and (.env | keys == ["GODOT_MACOS_SHA512","GODOT_SHA512","GODOT_TEMPLATES_SHA512","GODOT_VERSION"])
  and (.jobs | has("client-smoke") | not)
  and (.jobs["client-ordinary"] | worker("ordinary")
    and .name == "Ordinary client proof"
    and .defaults == {run:{shell:"bash --noprofile --norc tools/client-proof-step.sh {0}"}}
    and ([.steps[] | select(has("run") and .id != "proof" and has("shell"))] | length) == 0
    and ([.steps[] | select(has("if") and .if != "github.event_name == '\''pull_request'\'' || github.event_name == '\''merge_group'\''")] | length) == 0
    and ([.steps[].name] | contains([
      "Required regression control is candidate-independent and fail-closed",
      "Headless import + class-name scan", "Smoke boot (120 frames)",
      "Regression tests", "Parallel save-isolation guard"
    ]))
    and ([.steps[] | select(.name == "Real sandbox refuses escape and runs the full trusted suite")] | length) == 0)
  and (.jobs["client-sandbox"] | worker("sandbox")
    and .name == "Trusted sandbox client proof"
    and (.steps | length) == 6
    and .steps[2] == {name:"Runtime footprint reports require complete bounded observations", run:"go test tools/trusted-runtime-packages/main.go tools/trusted-runtime-packages/main_test.go\nbash tools/trusted-runtime-packages.test.sh\ngo test tools/trusted-runtime-bases/main.go tools/trusted-runtime-bases/main_test.go\nbash tools/trusted-runtime-bases.test.sh\ngo test tools/trusted-runtime-footprint/main.go tools/trusted-runtime-footprint/main_test.go\ngo test tools/trusted-runtime-inventory/main.go tools/trusted-runtime-inventory/main_test.go\ngo test tools/trusted-runtime-origin/main.go tools/trusted-runtime-origin/main_test.go\ngo test tools/trusted-runtime-archives/main.go tools/trusted-runtime-archives/main_test.go\nbash tools/trusted-runtime-inventory.test.sh\nbash tools/trusted-runtime-transaction.test.sh\nbash tools/propose-trusted-runtime-archives.test.sh\n"}
    and .steps[4] == {name:"Real sandbox refuses escape and runs the full trusted suite", "timeout-minutes":45, env:{WAR_TRUSTED_RUNTIME_FOOTPRINT:"1",WAR_TRUSTED_RUNTIME_INVENTORY_PROBE:"1"}, run:"bash tools/sandbox-godot-isolation.test.sh"})
  and (.jobs["ci-required-checks"] |
    keys == ["if","name","needs","runs-on","steps","timeout-minutes"]
    and .name == "CI - Required Checks" and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 5
    and .if == "${{ always() }}" and .needs == $required
    and (.steps | length) == 5
    and (.steps[0] | keys == ["uses","with"] and checkout)
    and (.steps[1] | keys == ["name","run"] and .run == "bash tools/client-proof-gate.test.sh")
    and (.steps[2] | keys == ["name","run"] and .run == "bash tools/client-proof-workflow-guard.test.sh")
    and (.steps[3] | keys == ["env","name","run"] and .run == "bash tools/client-proof-gate.sh")
    and .steps[3].env == {
      EXPECTED_SHA:"${{ github.sha }}", ORDINARY_RESULT:"${{ needs.client-ordinary.result }}",
      SANDBOX_RESULT:"${{ needs.client-sandbox.result }}",
      ORDINARY_COMPLETE:"${{ needs.client-ordinary.outputs.complete }}",
      SANDBOX_COMPLETE:"${{ needs.client-sandbox.outputs.complete }}",
      ORDINARY_SHA:"${{ needs.client-ordinary.outputs.tested-sha }}",
      SANDBOX_SHA:"${{ needs.client-sandbox.outputs.tested-sha }}"
    }
    and (.steps[4] | keys == ["uses","with"]
      and (.uses | test("^devantler-tech/\\.github/actions/aggregate-job-checks@[0-9a-f]{40}$"))
      and (.with | keys == ["job-results"])
      and .with["job-results"] == ($required | map(result(.)) | join(" "))))
' >/dev/null; then
  echo '::error::client CI must require both complete, independently cleaned proofs at the integration SHA' >&2
  exit 1
fi
