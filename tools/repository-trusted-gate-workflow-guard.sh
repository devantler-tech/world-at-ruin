#!/usr/bin/env bash
# Parse the real workflow; only the reviewed controller may consume credentials.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$root/.github/workflows/repository-trusted-regressions.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [[ ! -f "$workflow" ]] ||
  [[ "$(grep -cF 'zizmor: ignore[' "$workflow")" != 1 ]] ||
  ! grep -Eq '^  workflow_run: +# zizmor: ignore\[dangerous-triggers\]$' "$workflow" ||
  ! grep -Fq '# Candidate data runs only in containment; the writer checks out reviewed main' "$workflow" ||
  ! grep -Fq '# and consumes resolver identity rather than candidate workflow artifacts.' "$workflow"; then
  echo '::error::keep the single audited workflow-run exception and its containment rationale' >&2
  exit 1
fi
evaluate="vars.WAR_REPOSITORY_TRUSTED_GATE_ENABLED == 'true' && github.event.action == 'completed' && github.ref == 'refs/heads/main' && github.workflow_ref == 'devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main'"
publish="always() && $evaluate && needs.evaluate.outputs.identity-json != ''"
verdict="\${{ needs.evaluate.result == 'success' && 'success' || 'failure' }}"
installer="$(cat <<'INSTALL'
curl --retry 4 --retry-delay 2 --retry-all-errors -fsSL -o godot.zip "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
echo "${GODOT_SHA512}  godot.zip" | sha512sum -c -
unzip -q godot.zip
sudo mv "Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot
INSTALL
)"
if ! yq -o=json '.' "$workflow" >"$work/documents.json"; then
  echo '::error::repository trusted gate workflow is missing or malformed' >&2
  exit 1
fi
if ! jq -s -e 'if length == 1 then .[0] else error("one workflow document required") end' \
  "$work/documents.json" >"$work/workflow.json"; then
  echo '::error::repository trusted gate requires exactly one workflow document' >&2
  exit 1
fi
if ! jq -e --arg evaluate "$evaluate" --arg publish "$publish" --arg verdict "$verdict" --arg installer "$installer" '
  def harden:
    keys == ["name","uses","with"]
    and .uses == "step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1"
    and .with == {"egress-policy":"audit"};
  def source_checkout:
    keys == ["name","uses","with"]
    and .uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    and .with == {repository:"devantler-tech/world-at-ruin",ref:"${{ github.workflow_sha }}",path:"workflow-source","persist-credentials":false};
  def admission:
    keys == ["env","name","run"]
    and .env == {
      WAR_REPOSITORY_TRUSTED_GATE_ENABLED:"${{ vars.WAR_REPOSITORY_TRUSTED_GATE_ENABLED }}",
      WAR_TRUSTED_GATE_APP_ID:"${{ vars.APP_ID }}",
      WAR_TRUSTED_GATE_PUBLISHER_ENVIRONMENT:"world-trusted-gate-publisher",
      GITHUB_WORKFLOW_SHA:"${{ github.workflow_sha }}"}
    and .run == "bash workflow-source/tools/repository-trusted-gate-admission.sh";
  def go_toolchain:
    keys == ["name","uses","with"]
    and .uses == "actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e"
    and .with == {"go-version":"1.27.2",cache:false};
  keys == ["concurrency","jobs","name","on","permissions"]
  and .name == "Repository trusted regressions"
  and .on == {workflow_run:{workflows:["CI"],types:["completed"]}}
  and .permissions == {}
  and .concurrency == {group:"repository-trusted-regressions-${{ github.event.workflow_run.id }}","cancel-in-progress":false}
  and (.jobs | keys) == ["evaluate","publish"]
  and (.jobs.evaluate |
    keys == ["if","name","outputs","permissions","runs-on","steps","timeout-minutes"]
    and .name == "Evaluate repository trusted regressions"
    and .if == $evaluate
    and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 90
    and .permissions == {actions:"read",contents:"read","pull-requests":"read"}
    and .outputs == {
      "trusted-sha":"${{ steps.resolve.outputs.trusted-sha }}",
      "candidate-sha":"${{ steps.resolve.outputs.candidate-sha }}",
      "head-sha":"${{ steps.resolve.outputs.head-sha }}",
      "run-id":"${{ steps.resolve.outputs.run-id }}",
      "identity-json":"${{ steps.resolve.outputs.identity-json }}"}
    and (.steps | length) == 10
    and (.steps[0] | harden)
    and (.steps[1] | source_checkout)
    and (.steps[2] | admission)
    and (.steps[3] | go_toolchain)
    and (.steps[4] |
      keys == ["env","id","name","run","working-directory"]
      and .id == "resolve" and ."working-directory" == "workflow-source/tools/trusted-gate"
      and .env == {GITHUB_TOKEN:"${{ github.token }}",WAR_REPOSITORY_TRUSTED_GATE_ENABLED:"${{ vars.WAR_REPOSITORY_TRUSTED_GATE_ENABLED }}",
        GITHUB_WORKFLOW_SHA:"${{ github.workflow_sha }}",
        UPSTREAM_RUN_ID:"${{ github.event.workflow_run.id }}",GOTOOLCHAIN:"local",GOWORK:"off",GOFLAGS:""}
      and .run == "go run . resolve --run-id \"$UPSTREAM_RUN_ID\" --output \"$GITHUB_OUTPUT\"")
    and (.steps[5] |
      keys == ["env","name","run"]
      and .env == {DATA_SHA:"${{ steps.resolve.outputs.trusted-sha }}"}
      and .run == "bash workflow-source/tools/fetch-trusted-regression-data.sh trusted \"$DATA_SHA\"")
    and (.steps[6] |
      keys == ["env","name","run"]
      and .env == {DATA_SHA:"${{ steps.resolve.outputs.candidate-sha }}"}
      and .run == "bash workflow-source/tools/fetch-trusted-regression-data.sh candidate \"$DATA_SHA\"")
    and (.steps[7] |
      keys == ["env","name","run"]
      and .env == {GITHUB_WORKFLOW_SHA:"${{ github.workflow_sha }}",
        TRUSTED_SHA:"${{ steps.resolve.outputs.trusted-sha }}",CANDIDATE_SHA:"${{ steps.resolve.outputs.candidate-sha }}"}
      and .run == "bash workflow-source/tools/verify-trusted-regression-checkouts.sh workflow-source trusted candidate")
    and (.steps[8] |
      keys == ["env","name","run"]
      and .env == {GODOT_VERSION:"4.7.1",GODOT_SHA512:"4ccdab7a48eeccbe8819a2fc1f6262f8d72065d98601bcb3743fcbd7ebd39f373758a788ee3293a05ec5b2c48538266c437404312e372225cd2df273945a2de9"}
      and (.run | rtrimstr("\n")) == $installer)
    and (.steps[9] |
      keys == ["name","run"]
      and .run == "bash workflow-source/tools/run-sandboxed-trusted-regressions.sh trusted candidate"))
  and (.jobs.publish |
    keys == ["environment","if","name","needs","permissions","runs-on","steps","timeout-minutes"]
    and .name == "Publish repository trusted verdict"
    and .if == $publish and .needs == "evaluate"
    and .environment == "world-trusted-gate-publisher"
    and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 10
    and .permissions == {contents:"read"}
    and (.steps | length) == 6
    and (.steps[0] | harden)
    and (.steps[1] | source_checkout)
    and (.steps[2] | admission)
    and (.steps[3] | go_toolchain)
    and (.steps[4] |
      keys == ["id","name","uses","with"]
      and .id == "publisher-token"
      and .uses == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
      and .with == {"client-id":"${{ vars.APP_CLIENT_ID }}","private-key":"${{ secrets.APP_PRIVATE_KEY }}",
        owner:"devantler-tech",repositories:"world-at-ruin","permission-actions":"read","permission-checks":"write",
        "permission-contents":"read","permission-pull-requests":"read"})
    and (.steps[5] |
      keys == ["env","name","run","working-directory"]
      and ."working-directory" == "workflow-source/tools/trusted-gate"
      and .env == {GITHUB_TOKEN:"${{ steps.publisher-token.outputs.token }}",WAR_REPOSITORY_TRUSTED_GATE_ENABLED:"${{ vars.WAR_REPOSITORY_TRUSTED_GATE_ENABLED }}",
        GITHUB_WORKFLOW_SHA:"${{ github.workflow_sha }}",
        TRUSTED_GATE_APP_ID:"${{ vars.APP_ID }}",IDENTITY_JSON:"${{ needs.evaluate.outputs.identity-json }}",
        VERDICT:$verdict,GOTOOLCHAIN:"local",GOWORK:"off",GOFLAGS:""}
      and .run == "go run . publish --identity \"$IDENTITY_JSON\" --verdict \"$VERDICT\""))
' "$work/workflow.json" >/dev/null; then
  echo '::error::restore the repository trusted gate source, admission, credential and current-head verdict boundaries' >&2
  exit 1
fi
