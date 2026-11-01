#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
guard=$root/tools/native-acceptance-workflow-guard.sh
bash "$guard"
# The fixture's test and executable share one cold compilation graph. A test
# without the executable's path flags recompiles its large Kubernetes graph.
if ! grep -Fxq "    && go -C /source/tools/gameserver-commit-trial test -mod=readonly -trimpath -buildvcs=false ./cmd/nativefixture \\" "$root/server/Dockerfile.nakama-native" ||
  ! grep -Fxq '    && go -C /source/tools/gameserver-commit-trial build -mod=readonly -trimpath -buildvcs=false -o /out/gameserver-fixture ./cmd/nativefixture' "$root/server/Dockerfile.nakama-native"; then
  echo 'FAIL: native fixture test and build must share their reproducible compilation flags' >&2
  exit 1
fi
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$scratch/base.json"
# shellcheck disable=SC2016 # Mutation expressions, not shell interpolation.
mutations=(
  'del(.jobs["nakama-native"])'
  '.jobs["ci-required-checks"].needs |= map(select(. != "nakama-native"))'
  '.jobs["nakama-native"].strategy.matrix.arch=["amd64"]'
  '.jobs["nakama-native"].strategy.matrix.profile=["native","issued-spire"]'
  '.jobs["nakama-native"].strategy.matrix.profile=["native","issued"]'
  '.jobs["nakama-native"].strategy["fail-fast"]=true'
  '.jobs["nakama-native"].if="false"'
  '.jobs["nakama-native"]["continue-on-error"]=true'
  '.jobs["nakama-native"].steps[1].run="true"'
  '.jobs["nakama-native"].steps[2].if="false"'
  '.jobs["nakama-native"].steps[2].with["cache-from"]="type=gha"'
  '.jobs["nakama-native"].steps[2].with["build-args"]="EXPERIMENTAL=false"'
  '.jobs["nakama-native"].steps[2].with.context="server"'
  '.jobs["nakama-native"].steps[3].env.IMAGE_ID="stale:latest"'
  '.jobs["nakama-native"].steps[3].env.WAR_NATIVE_WORKERS="1"'
  '.jobs["nakama-native"].steps[3].env.NATIVE_PROFILE="native"'
  '.jobs["nakama-native"].steps[3].if="always()"'
  '.jobs["nakama-native"].steps[3]["continue-on-error"]=true'
  '.jobs["nakama-native"].steps[3].run += " || true"'
  '.jobs["nakama-native"].steps[3].shell="true {0}"'
)
for mutation in "${mutations[@]}"; do
  jq "$mutation" "$scratch/base.json" >"$scratch/mutated.json"
  if cmp -s "$scratch/base.json" "$scratch/mutated.json"; then
    echo 'FAIL: no-op native workflow mutation' >&2
    exit 1
  fi
  if bash "$guard" "$scratch/mutated.json"; then
    echo "FAIL: accepted native workflow mutation $mutation" >&2
    exit 1
  fi
done
echo "TEST PASS: complete native workflow rejects ${#mutations[@]} omissions, stale images and masked execution"
