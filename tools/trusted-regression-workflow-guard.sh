#!/usr/bin/env bash
# Admit only the additive base-owned controller workflow. The external
# ruleset gate remains independently required.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$root/.github/workflows/trusted-regressions.yaml}"
installer="$(
  cat <<'INSTALL'
curl --retry 4 --retry-delay 2 --retry-all-errors -fsSL -o godot.zip "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
echo "${GODOT_SHA512}  godot.zip" | sha512sum -c -
unzip -q godot.zip
sudo mv "Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot
INSTALL
)"
if ! yq -o=json '.' "$workflow" | jq -e --arg installer "$installer" '
  keys == ["env","jobs","name","on","permissions"]
  and .name == "World owned trusted regressions"
  and .on == {pull_request_target:{branches:["main"],types:["opened","synchronize","reopened","ready_for_review"]}}
  and .permissions == {}
  and .env == {GODOT_VERSION:"4.7.1",GODOT_SHA512:"4ccdab7a48eeccbe8819a2fc1f6262f8d72065d98601bcb3743fcbd7ebd39f373758a788ee3293a05ec5b2c48538266c437404312e372225cd2df273945a2de9"}
  and (.jobs | keys) == ["trusted-client-regressions"]
  and (.jobs["trusted-client-regressions"] |
    keys == ["name","permissions","runs-on","steps","timeout-minutes"]
    and .name == "World owned client regressions"
    and .permissions == {contents:"read"} and ."runs-on" == "ubuntu-latest"
    and ."timeout-minutes" == 90 and (.steps | length) == 8
    and (.steps[0]|keys) == ["name","uses","with"]
    and .steps[0].uses == "step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1"
    and .steps[0].with == {"egress-policy":"audit"}
    and (.steps[1]|keys) == ["name","uses","with"]
    and .steps[1].uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    and .steps[1].with == {repository:"devantler-tech/world-at-ruin",ref:"${{ github.workflow_sha }}",path:"workflow-source","persist-credentials":false}
    and (.steps[2]|keys) == ["id","name","run"]
    and .steps[2].id == "resolve"
    and .steps[2].run == "bash workflow-source/tools/resolve-trusted-regression-event.sh"
    and (.steps[3]|keys) == ["name","uses","with"]
    and (.steps[4]|keys) == ["name","uses","with"]
    and .steps[3].uses == .steps[1].uses and .steps[4].uses == .steps[1].uses
    and .steps[3].with == {repository:"devantler-tech/world-at-ruin",ref:"${{ steps.resolve.outputs.trusted-sha }}",path:"trusted","persist-credentials":false}
    and .steps[4].with == {repository:"devantler-tech/world-at-ruin",ref:"${{ steps.resolve.outputs.candidate-sha }}",path:"candidate","persist-credentials":false}
    and (.steps[5]|keys) == ["env","name","run"]
    and .steps[5].env == {TRUSTED_SHA:"${{ steps.resolve.outputs.trusted-sha }}",CANDIDATE_SHA:"${{ steps.resolve.outputs.candidate-sha }}"}
    and .steps[5].run == "bash workflow-source/tools/verify-trusted-regression-checkouts.sh workflow-source trusted candidate"
    and (.steps[6]|keys) == ["name","run"]
    and (.steps[6].run | rtrimstr("\n")) == $installer
    and (.steps[7]|keys) == ["name","run"]
    and .steps[7].run == "trusted/tools/required-regression-control.sh trusted candidate")
' >/dev/null; then
  echo '::error::restore the base-owned trusted regression workflow event, paths, pinned actions and read-only permissions' >&2
  exit 1
fi
