#!/usr/bin/env bash
# Exercise the real containment wrapper against complete and failed observations.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export HARNESS_RECORD="$scratch/commands" HARNESS_KIND=spire HARNESS_FAILURE=''
cat > "$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HARNESS_RECORD"
case "$1 $2" in
  'image inspect') printf '%s\n' 10001:10001 ;;
  'run --rm')
    if [[ $HARNESS_KIND == spire ]]; then echo 'SPIRE trial requires explicit opt-in before any state or process'; else echo 'owned child trial requires explicit opt-in before any process'; fi
    exit 2 ;;
  'create --user')
    [[ $* == *'--cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add KILL'* ]]
    [[ $* == *'--security-opt no-new-privileges:true'* ]]
    [[ $* == *'--network none --read-only'* ]]
    printf '%s\n' 'fixture-owned-id' ;;
  'start -a')
    if [[ $HARNESS_FAILURE == start ]]; then exit 1; fi
    if [[ $HARNESS_KIND == spire ]]; then
      echo '--- PASS: TestNativeSPIREAttestedRoles (0.1s)'; echo 'SPIRE NATIVE PASS: fixture'
    else
      echo '--- PASS: TestNativeOwnedChild (0.1s)'; echo 'OWNED CHILD NATIVE PASS: fixture'
      if [[ $HARNESS_FAILURE != missing ]]; then echo '--- PASS: TestNativeOwnedRetirement (0.1s)'; fi
      echo '--- PASS: TestNativeOwnedCleanupFaults (0.1s)'
    fi
    echo PASS ;;
  'inspect --format') printf '0\n' ;;
  'rm -f') [[ $HARNESS_FAILURE != remove ]] ;;
  'container ls')
    [[ $HARNESS_FAILURE != unreadable ]]
    if [[ $HARNESS_FAILURE == retained ]]; then echo fixture-owned-id; fi ;;
  *) exit 92 ;;
esac
DOCKER
chmod +x "$scratch/bin/docker"
export PATH="$scratch/bin:$PATH"
export TMPDIR="$scratch"
for kind in spire owned-child; do
  export HARNESS_KIND=$kind
  : > "$HARNESS_RECORD"
  if ! bash "$root/tools/smoke-native-private-server.sh" "$kind" fixture --experimental > "$scratch/result" 2>&1; then cat "$scratch/result"; exit 1; fi
  grep -Fq 'rm -f fixture-owned-id' "$HARNESS_RECORD"
  grep -Fq 'container ls --all --filter id=fixture-owned-id' "$HARNESS_RECORD"
done
export HARNESS_KIND=owned-child
for failure in start missing remove unreadable retained; do
  export HARNESS_FAILURE=$failure
  if bash "$root/tools/smoke-native-private-server.sh" owned-child fixture --experimental > "$scratch/result" 2>&1; then echo "TEST FAIL -- native wrapper accepted $failure" >&2; exit 1; fi
done
: > "$HARNESS_RECORD"
if bash "$root/tools/smoke-owned-child-native.sh" fixture > "$scratch/result" 2>&1; then echo 'TEST FAIL -- missing opt-in accepted' >&2; exit 1; fi
[[ ! -s "$HARNESS_RECORD" ]]
echo 'TEST PASS -- both native fixtures preserve containment and reject incomplete verdict or cleanup'
