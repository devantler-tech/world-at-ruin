#!/usr/bin/env bash
# Preserve the narrow manual measurement and its complete execution boundary.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
workflow=${1:-$root/.github/workflows/issued-native-stability.yaml}
definition=$(yq -o=json '.' "$workflow")
# Pin the inline pre-checkout admission without maintaining a second copy of it.
# The behavioral tests separately exercise its successful and refusing paths.
admission=$(jq -er '.jobs.admit.steps[0].run' <<< "$definition")
identity=$(printf '%s' "$admission" | shasum -a 256)
[[ ${identity%% *} == 7a4dc249411191784621d8f8a70f6f0e0ef7224b8a6617b2828cb4c364f08bdb ]]
jq -e '
  keys == ["concurrency","jobs","name","on","permissions"]
  and .name == "Issued native startup stability"
  and .on == {workflow_dispatch:{inputs:{confirmation:{description:"Measure ten fresh issued-SPIRE trials per architecture",required:true,type:"choice",options:["measure-issued-startup"]}}}}
  and .permissions == {contents:"read"}
  and .concurrency == {group:"issued-native-stability-main","cancel-in-progress":false}
  and (.jobs|keys) == ["admit","trials"]
  and (.jobs.admit |
    keys == ["name","outputs","runs-on","steps","timeout-minutes"]
    and .name == "Bind the reviewed main source" and ."runs-on" == "ubuntu-latest"
    and ."timeout-minutes" == 2 and .outputs == {source:"${{ steps.identity.outputs.source }}"}
    and (.steps|length) == 1
    and (.steps[0]|keys) == ["env","id","name","run"]
    and .steps[0].name == "Refuse an unauthorized measurement before checkout"
    and .steps[0].id == "identity" and .steps[0].env == {CONFIRMATION:"${{ inputs.confirmation }}"})
  and (.jobs.trials |
    keys == ["name","needs","runs-on","steps","strategy","timeout-minutes"]
    and .name == "Repeat issued startup (${{ matrix.arch }})" and .needs == "admit"
    and ."runs-on" == "${{ matrix.runner }}" and ."timeout-minutes" == 25
    and .strategy == {"fail-fast":false,matrix:{include:[{arch:"amd64",runner:"ubuntu-latest"},{arch:"arm64",runner:"ubuntu-24.04-arm"}]}}
    and (.steps|length) == 4
    and .steps[0] == {uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",with:{ref:"${{ needs.admit.outputs.source }}","persist-credentials":false}}
    and .steps[1] == {name:"Prove measurement and workflow refusals",run:"bash tools/issued-native-stability.test.sh\nbash tools/issued-native-stability-workflow.test.sh\n"}
    and .steps[2] == {name:"Build one existing issued-SPIRE image",id:"native-image",uses:"docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc",env:{DOCKER_BUILD_RECORD_UPLOAD:false},with:{context:".",file:"server/Dockerfile.nakama-native","build-args":"EXPERIMENTAL=true\nRUNTIME_PROFILE=issued-spire\n",load:true,tags:"world-at-ruin-issued-stability:measurement"}}
    and .steps[3] == {name:"Run ten complete fresh trials","timeout-minutes":15,env:{IMAGE_ID:"${{ steps.native-image.outputs.imageid }}",SOURCE_SHA:"${{ needs.admit.outputs.source }}",ARCHITECTURE:"${{ matrix.arch }}"},run:"bash tools/issued-native-stability.sh \"$IMAGE_ID\" \"$SOURCE_SHA\" \"$ARCHITECTURE\""})
' <<< "$definition" >/dev/null
