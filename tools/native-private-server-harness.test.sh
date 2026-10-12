#!/usr/bin/env bash
# Exercise the real containment wrapper against complete and failed observations.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export HARNESS_RECORD="$scratch/commands" HARNESS_KIND=spire HARNESS_FAILURE=''
cat >"$scratch/bin/docker" <<'DOCKER'
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
    if [[ $* == *'-war-orphan-scenario'* ]]; then touch "$HARNESS_RECORD.orphan"; fi
    printf '%s\n' 'fixture-owned-id' ;;
  'start -a')
    if [[ $HARNESS_FAILURE == start ]]; then exit 1; fi
    if [[ -f $HARNESS_RECORD.orphan ]]; then
      if [[ $HARNESS_FAILURE != orphan-output ]]; then echo 'EXPECTED FORK REFUSAL: original joined; descendant join unproved; containment retained'; fi
      exit 1
    fi
    if [[ $HARNESS_KIND == spire ]]; then
      echo '--- PASS: TestNativeSPIREAttestedRoles (0.1s)'; echo 'SPIRE NATIVE PASS: fixture'
      if [[ $HARNESS_FAILURE != missing-claim ]]; then echo '--- PASS: TestNativeSPIREPrivateClaim (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-claim-verdict ]]; then echo 'SPIRE CLAIM NATIVE PASS: fixture'; fi
    else
      echo '--- PASS: TestNativeOwnedChild (0.1s)'; echo 'OWNED CHILD NATIVE PASS: fixture'
      if [[ $HARNESS_FAILURE != missing ]]; then echo '--- PASS: TestNativeOwnedRetirement (0.1s)'; fi
      echo '--- PASS: TestNativeOwnedCleanupFaults (0.1s)'
      if [[ $HARNESS_FAILURE != missing-exec ]]; then echo '--- PASS: TestNativeExecSeal (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-arch ]]; then echo '--- PASS: TestNativeExecSealArchitectureMismatch (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-abi ]]; then echo '--- PASS: TestNativeExecSealABIReports (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-table ]]; then echo '--- PASS: TestExecSealFilterTable (0.1s)'; fi
      if [[ $HARNESS_FAILURE != missing-fork ]]; then echo '--- PASS: TestNativeForkSender (0.1s)'; fi
      echo '--- PASS: TestNativeForkFaults (0.1s)'
      echo '--- PASS: TestNativeForkOwnershipFaults (0.1s)'
      echo '--- PASS: TestForkAssemblyLayout (0.1s)'
    fi
    echo PASS ;;
  'inspect --format')
    if [[ -f $HARNESS_RECORD.orphan && $HARNESS_FAILURE != orphan-zero ]]; then printf '1\n'; else printf '0\n'; fi ;;
  'rm -f') [[ $HARNESS_FAILURE != remove ]]; rm -f "$HARNESS_RECORD.orphan" ;;
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
  : >"$HARNESS_RECORD"
  if ! bash "$root/tools/smoke-native-private-server.sh" "$kind" fixture --experimental >"$scratch/result" 2>&1; then
    cat "$scratch/result"
    exit 1
  fi
  grep -Fq 'rm -f fixture-owned-id' "$HARNESS_RECORD"
  grep -Fq 'container ls --all --filter id=fixture-owned-id' "$HARNESS_RECORD"
done
export HARNESS_KIND=spire
for failure in missing-claim missing-claim-verdict; do
  export HARNESS_FAILURE=$failure
  if bash "$root/tools/smoke-native-private-server.sh" spire fixture --experimental >"$scratch/result" 2>&1; then
    echo "TEST FAIL -- SPIRE wrapper accepted $failure" >&2
    exit 1
  fi
done
export HARNESS_KIND=owned-child
for failure in start missing missing-exec missing-arch missing-abi missing-table missing-fork orphan-output orphan-zero remove unreadable retained; do
  export HARNESS_FAILURE=$failure
  if bash "$root/tools/smoke-native-private-server.sh" owned-child fixture --experimental >"$scratch/result" 2>&1; then
    echo "TEST FAIL -- native wrapper accepted $failure" >&2
    exit 1
  fi
done
: >"$HARNESS_RECORD"
if bash "$root/tools/smoke-owned-child-native.sh" fixture >"$scratch/result" 2>&1; then
  echo 'TEST FAIL -- missing opt-in accepted' >&2
  exit 1
fi
[[ ! -s "$HARNESS_RECORD" ]]
echo 'TEST PASS -- both native fixtures preserve containment and reject incomplete verdict or cleanup'
