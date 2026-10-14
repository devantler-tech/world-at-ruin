#!/usr/bin/env bash
# Exercise profile verdict refusal through the actual disposable wrapper.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export HARNESS_RECORD="$scratch/commands" HARNESS_SCENARIOS="$scratch/scenarios"
export HARNESS_PROFILE=native HARNESS_FAILURE=''
# Declaration discovery is independent of the wrapper's required-name list.
for file in "$root"/server/internal/nakamatrial/*_test.go; do
  if head -1 "$file" | grep -qx '//go:build war_native_trial'; then
    sed -nE '/^func TestMain\(/d; s/^func (Test[A-Za-z0-9_]+)\(.*/\1/p' "$file"
  fi
done > "$HARNESS_SCENARIOS"
[[ $(wc -l < "$HARNESS_SCENARIOS" | tr -d ' ') == 41 ]]
cat > "$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HARNESS_RECORD"
case "$1 $2" in
  'image inspect') echo 10001:10001 ;;
  'run --rm') echo 'native trial requires Linux, explicit opt-in'; exit 2 ;;
  'network create'|'network rm'|'rm -f'|'exec postgres-id') ;;
  'run -d') echo postgres-id ;;
  'create --network')
    [[ $* == *'--read-only --cap-drop ALL'* ]]
    [[ $* == *'--security-opt no-new-privileges:true'* ]]
    [[ $* == *'-test.timeout=16m'* ]]
    echo trial-id ;;
  'start -a')
    if [[ $HARNESS_FAILURE == start ]]; then exit 1; fi
    while IFS= read -r name; do
      if [[ $HARNESS_FAILURE != missing-base || $name != TestNativeOriginalClaimCustody ]]; then
        printf '%s\n' "--- PASS: $name (0.1s)"
      fi
    done < "$HARNESS_SCENARIOS"
    if [[ $HARNESS_PROFILE == issued ]]; then
      if [[ $HARNESS_FAILURE != missing-sdk ]]; then echo '--- PASS: TestNativeIssuedSDKStartupBoundary (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-verdict ]]; then echo 'ISSUED SDK NATIVE PASS: loaded plugin; default off; actual WorkloadAPI unavailable; zero provider effects; no serving authority'; fi
      if [[ $HARNESS_FAILURE != missing-claims ]]; then echo '--- PASS: TestNativeIssuedClaimsPlugin (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-claims-verdict ]]; then echo 'ISSUED CLAIMS NATIVE PASS: synthetic WorkloadAPI; loaded plugin; one fetch and closed stream; fixed verified TLS; native receipt and replay; refusal storage unchanged; owned shutdown'; fi
    fi
    echo PASS ;;
  'inspect --format') echo 0 ;;
  *) exit 92 ;;
esac
DOCKER
chmod +x "$scratch/bin/docker"
export PATH="$scratch/bin:$PATH" TMPDIR="$scratch"
for profile in native issued; do
  export HARNESS_PROFILE=$profile HARNESS_FAILURE=''
  args=()
  if [[ $profile == issued ]]; then args+=(--issued); fi
  if ! bash "$root/tools/smoke-nakama-native.sh" fixture --experimental ${args[@]+"${args[@]}"} > "$scratch/result" 2>&1; then
    cat "$scratch/result"; exit 1
  fi
  grep -Fq 'rm -f trial-id' "$HARNESS_RECORD"
  failures=(start missing-base)
  if [[ $profile == issued ]]; then failures+=(missing-sdk missing-verdict missing-claims missing-claims-verdict); fi
  for failure in "${failures[@]}"; do
    export HARNESS_FAILURE=$failure
    if bash "$root/tools/smoke-nakama-native.sh" fixture --experimental ${args[@]+"${args[@]}"} > "$scratch/result" 2>&1; then
      echo "TEST FAIL: $profile accepted $failure" >&2; exit 1
    fi
  done
done
: > "$HARNESS_RECORD"
if bash "$root/tools/smoke-nakama-native.sh" fixture --experimental --arbitrary > "$scratch/result" 2>&1; then
  echo 'TEST FAIL: arbitrary profile accepted' >&2; exit 1
fi
[[ ! -s $HARNESS_RECORD ]]
echo 'TEST PASS: both native profiles refuse partial or failed acceptance'
