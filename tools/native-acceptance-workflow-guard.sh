#!/usr/bin/env bash
# Preserve fresh native builds, every architecture/profile and the actual worker invocation.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
workflow=${1:-$root/.github/workflows/ci.yaml}
# shellcheck disable=SC2016 # These are literal GitHub expressions and jq variables.
yq -o=json '.' "$workflow" | jq -e '
  .on == {pull_request:null,merge_group:null}
  and (.jobs["ci-required-checks"].needs|index("nakama-native")) != null
  and .jobs["nakama-native"] == {
    name:"Nakama native (${{ matrix.arch }}, ${{ matrix.profile }})",
    "timeout-minutes":25,
    strategy:{"fail-fast":false,matrix:{arch:["amd64","arm64"],profile:["native","issued","issued-spire"],include:[{arch:"amd64",runner:"ubuntu-latest"},{arch:"arm64",runner:"ubuntu-24.04-arm"}]}},
    "runs-on":"${{ matrix.runner }}",
    steps:[
      {uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",with:{"persist-credentials":false}},
      {name:"Prove native profile acceptance refuses partial observations",run:"bash tools/nakama-native-harness.test.sh\nbash tools/native-acceptance-workflow.test.sh\nbash tools/issued-native-stability.test.sh\nbash tools/issued-native-stability-workflow.test.sh\n"},
      {name:"Build the explicitly experimental native bundle and acceptance image",id:"native-image",uses:"docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc",with:{context:".",file:"server/Dockerfile.nakama-native","build-args":"EXPERIMENTAL=true\nRUNTIME_PROFILE=${{ matrix.profile }}\n",load:true,tags:"world-at-ruin-nakama-native:ci"}},
      {name:"Exercise the actual packaged runtime against disposable PostgreSQL",env:{NATIVE_PROFILE:"${{ matrix.profile }}",IMAGE_ID:"${{ steps.native-image.outputs.imageid }}",WAR_NATIVE_WORKERS:"${{ matrix.profile == '\''issued-spire'\'' && '\''1'\'' || '\''4'\'' }}"},run:"args=()\nif [[ $NATIVE_PROFILE == issued ]]; then args+=(--issued); fi\nif [[ $NATIVE_PROFILE == issued-spire ]]; then args+=(--spire); fi\nbash tools/smoke-nakama-native.sh \"$IMAGE_ID\" --experimental \"${args[@]}\"\n"}
    ]
  }
' >/dev/null
