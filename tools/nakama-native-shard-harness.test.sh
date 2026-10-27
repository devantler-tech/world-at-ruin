#!/usr/bin/env bash
# The real parent and worker reducer, with only the Docker boundary doubled.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
finished=0
cleanup() {
	local rc=$?
	trap - EXIT
	rm -rf -- "$scratch"
	if [[ $finished != 1 && $rc == 0 ]]; then rc=1; fi
	exit "$rc"
}
trap cleanup EXIT
mkdir "$scratch/bin"
export SHARD_FIXTURE=$scratch SHARD_FAILURE='' SHARD_PROFILE=native
# Independently discover the test declarations admitted by each native build tag.
for source_file in "$root"/server/internal/nakamatrial/*_test.go; do
	tag=$(head -n 1 "$source_file")
	case "$tag" in
	'//go:build war_native_trial') target=native ;;
	'//go:build war_native_trial && war_issued_trial') target=issued ;;
	*) continue ;;
	esac
	sed -nE '/^func TestMain\(/d; s/^func (Test[A-Za-z0-9_]+)\(.*/\1/p' "$source_file" >>"$scratch/$target"
done
[[ $(wc -l <"$scratch/native") -eq 41 && $(wc -l <"$scratch/issued") -eq 2 ]]
cat >"$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SHARD_FIXTURE/commands"
image=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$1 $2" in
  'image inspect')
    case "$4" in '{{.Id}}') echo "$image" ;; '{{.Config.User}}') echo 10001:10001 ;; *) exit 91 ;; esac ;;
  'network create') printf '%064d\n' 9 ;;
  'network rm') [[ $SHARD_FAILURE != network-remove ]] ;;
  'network ls')
    [[ $SHARD_FAILURE != network-unreadable ]]
    if [[ $SHARD_FAILURE == network-retained ]]; then echo retained; fi ;;
  'exec postgres-id') ;;
  'run -d') echo postgres-id ;;
  'run --rm')
    if [[ $* != *'-test.list=^Test'* ]]; then
      echo 'native trial requires Linux, explicit opt-in'; exit 2
    fi
    [[ $* == *"$image"* && $* == *'--network none --read-only --cap-drop ALL'* ]]
    if [[ $SHARD_FAILURE == inventory-missing ]]; then sed '1d' "$SHARD_FIXTURE/native"; else cat "$SHARD_FIXTURE/native"; fi
    if [[ $SHARD_PROFILE == issued ]]; then cat "$SHARD_FIXTURE/issued"; fi
    case "$SHARD_FAILURE" in
      inventory-extra) echo TestUnexpected ;;
      inventory-duplicate) head -n 1 "$SHARD_FIXTURE/native" ;;
      inventory-malformed) echo 'not a compiled test' ;;
      inventory-producer) exit 23 ;;
    esac ;;
  'create --network')
    [[ $* == *"$image"* && $* == *'--read-only --cap-drop ALL'* && $* == *'--security-opt no-new-privileges:true'* ]]
    [[ $* == *'--pids-limit 256 --memory 2g --cpus 2'* && $* == *'-test.timeout=16m'* ]]
    [[ $* != *'--cap-add'* && $* != *'--user 0:0'* ]]
		[[ $* == *'--cgroupns private'* ]] || { echo 'worker counters must use a private cgroup namespace' >&2; exit 93; }
    [[ $* == *'--entrypoint /bin/bash'* && $* == *'native_worker_run /out/native-trial.test "$@"'* ]]
    count=$(wc -l <"$SHARD_FIXTURE/created")
    id=$(printf '%064d' "$((count + 1))")
    if [[ $SHARD_FAILURE == duplicate-id && $count -gt 0 ]]; then id=$(head -n 1 "$SHARD_FIXTURE/created"); fi
    printf '%s\n' "$id" >>"$SHARD_FIXTURE/created"
    for arg in "$@"; do
      case "$arg" in -test.run=*)
        pattern=${arg#'-test.run=^('}; pattern=${pattern%')$'}
        printf '%s\n' "$pattern" | tr '|' '\n' >"$SHARD_FIXTURE/$id.expected" ;;
      esac
    done
    echo "$id" ;;
  'start -a')
    id=$3
    printf '%s\n' "$$" >"$SHARD_FIXTURE/$id.pid"
    touch "$SHARD_FIXTURE/$id.started"
    # A serial launcher times out: four real launchers must be concurrent.
    ready=false
    for ((n=0; n<100; n++)); do
      started=("$SHARD_FIXTURE/"*.started)
      if [[ ${#started[@]} == 4 ]]; then ready=true; break; fi
      sleep 0.02
    done
    [[ $ready == true ]]
    if [[ $SHARD_FAILURE == cancel ]]; then sleep 2; exit 23; fi
    [[ $SHARD_FAILURE != worker-start ]]
    while IFS= read -r name; do
      if [[ $SHARD_FAILURE == worker-missing && $name == TestNativeOriginalClaimCustody ]]; then continue; fi
      printf '%s\n' "--- PASS: $name (0.1s)"
      case "$name" in
        TestNativeIssuedSDKStartupBoundary)
          if [[ $SHARD_FAILURE != sdk-marker ]]; then echo 'ISSUED SDK NATIVE PASS: loaded plugin; default off; actual WorkloadAPI unavailable; zero provider effects; no serving authority'; fi ;;
        TestNativeIssuedClaimsPlugin)
          if [[ $SHARD_FAILURE != claims-marker ]]; then echo 'ISSUED CLAIMS NATIVE PASS: synthetic WorkloadAPI; loaded plugin; one fetch and closed stream; fixed verified TLS; native receipt and replay; refusal storage unchanged; owned shutdown'; fi ;;
      esac
    done <"$SHARD_FIXTURE/$id.expected"
    case "$SHARD_FAILURE" in
      worker-extra) echo '--- PASS: TestUnexpected (0.1s)' ;;
      worker-duplicate) name=$(head -n 1 "$SHARD_FIXTURE/$id.expected"); echo "--- PASS: $name (0.1s)" ;;
      worker-skipped) echo '    --- SKIP: TestUnexpected/subcase (0.1s)' ;;
      worker-failed) echo '--- FAIL: TestUnexpected (0.1s)' ;;
    esac
    if [[ $SHARD_FAILURE != worker-no-pass ]]; then echo PASS; fi
    if [[ $SHARD_FAILURE == worker-two-pass ]]; then echo PASS; fi
    if [[ $SHARD_FAILURE == resource-invalid ]]; then
      echo 'NATIVE WORKER RESOURCES: {"memoryPeakBytes":0,"cpuUsageUsec":"unknown","complete":true}'
    elif [[ $SHARD_FAILURE != resource-missing ]]; then
      echo 'NATIVE WORKER RESOURCES: {"memoryPeakBytes":104857600,"cpuUsageUsec":2500000,"complete":true}'
    fi
    if [[ $SHARD_FAILURE == resource-duplicate ]]; then
      echo 'NATIVE WORKER RESOURCES: {"memoryPeakBytes":104857600,"cpuUsageUsec":2500000,"complete":true}'
    fi
    [[ $SHARD_FAILURE != worker-producer ]] ;;
  'inspect --format') if [[ $SHARD_FAILURE == worker-exit ]]; then echo 23; else echo 0; fi ;;
  'rm -f') [[ $SHARD_FAILURE != remove ]] ;;
  'container ls')
    [[ $SHARD_FAILURE != unreadable ]]
    if [[ $SHARD_FAILURE == retained ]]; then echo retained; fi ;;
  *) exit 92 ;;
esac
DOCKER
chmod +x "$scratch/bin/docker"
export PATH="$scratch/bin:$PATH" TMPDIR="$scratch" WAR_NATIVE_WORKERS=4
unset GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
reset_observation() {
	rm -f "$scratch/"*.started "$scratch/"*.expected
	: >"$scratch/commands"
	: >"$scratch/created"
}
run_wrapper() {
	args=()
	if [[ $SHARD_PROFILE == issued ]]; then args+=(--issued); fi
	bash "$root/tools/smoke-nakama-native.sh" fixture --experimental ${args[@]+"${args[@]}"} >"$scratch/result" 2>&1
}
for profile in native issued; do
	export SHARD_PROFILE=$profile SHARD_FAILURE=''
	reset_observation
	if ! run_wrapper; then
		cat "$scratch/result"
		exit 1
	fi
	[[ $(grep -c '^create --network' "$scratch/commands") == 4 ]]
	[[ $(grep -c '^rm -f ' "$scratch/commands") == 5 ]]
	grep -Fq 'NAKAMA NATIVE PASS:' "$scratch/result"
	sed -n 's/^NATIVE WORKER RECEIPT: //p' "$scratch/result" | jq -e --arg sha "$(git -C "$root" rev-parse HEAD)" \
		'.complete==true and .workers==4 and .source==$sha and .run=="local" and .attempt=="local" and (.seconds|length)==4 and
      (.resources | length)==4 and all(.resources[]; .complete==true and .memoryPeakBytes==104857600 and .cpuUsageUsec==2500000)' >/dev/null || {
		echo 'FAIL: complete native receipts must retain each worker resource observation' >&2
		exit 1
	}
	for failure in inventory-missing inventory-extra inventory-duplicate inventory-malformed inventory-producer duplicate-id worker-start worker-missing worker-extra worker-duplicate worker-skipped worker-failed worker-no-pass worker-two-pass worker-producer worker-exit remove unreadable retained network-remove network-unreadable network-retained; do
		export SHARD_FAILURE=$failure
		reset_observation
		if run_wrapper; then
			echo "FAIL: $profile accepted $failure" >&2
			exit 1
		fi
		if grep -Eq '^NATIVE WORKER RECEIPT:|^NAKAMA NATIVE PASS:' "$scratch/result"; then
			echo "FAIL: $profile emitted completion for $failure" >&2
			exit 1
		fi
		case "$failure" in inventory-*) [[ ! -s $scratch/created ]] ;; esac
	done
done
for uncertainty in resource-missing resource-invalid resource-duplicate; do
	export SHARD_PROFILE=native SHARD_FAILURE=$uncertainty
	reset_observation
	if ! run_wrapper; then
		cat "$scratch/result"
		exit 1
	fi
	sed -n 's/^NATIVE WORKER RECEIPT: //p' "$scratch/result" | jq -e \
		'.complete==true and (.resources|length)==4 and
      all(.resources[]; .memoryPeakBytes==null and .cpuUsageUsec==null and .complete==false)' >/dev/null || {
		echo "FAIL: $uncertainty became a measured value or altered native acceptance" >&2
		exit 1
	}
done
export SHARD_PROFILE=issued
for failure in sdk-marker claims-marker; do
	export SHARD_FAILURE=$failure
	reset_observation
	if run_wrapper; then
		echo "FAIL: issued accepted $failure" >&2
		exit 1
	fi
	if grep -q '^NATIVE WORKER RECEIPT:' "$scratch/result"; then exit 1; fi
done
export SHARD_FAILURE=''
for workers in '' 0 2 3 04 '4 4'; do
	reset_observation
	if WAR_NATIVE_WORKERS=$workers run_wrapper; then
		echo 'FAIL: invalid worker count accepted' >&2
		exit 1
	fi
	[[ ! -s $scratch/commands ]]
done
reset_observation
if bash "$root/tools/smoke-nakama-native.sh" fixture --experimental --spire >"$scratch/result" 2>&1; then exit 1; fi
[[ ! -s $scratch/commands ]]
for identity in wrong-sha bad-run bad-attempt; do
	reset_observation
	export GITHUB_SHA GITHUB_RUN_ID=77 GITHUB_RUN_ATTEMPT=2
	GITHUB_SHA=$(git -C "$root" rev-parse HEAD)
	case "$identity" in wrong-sha) GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; bad-run) GITHUB_RUN_ID=01 ;; bad-attempt) GITHUB_RUN_ATTEMPT=0 ;; esac
	if run_wrapper; then
		echo "FAIL: accepted $identity" >&2
		exit 1
	fi
	[[ ! -s $scratch/created ]]
done
unset GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
export SHARD_FAILURE=cancel
reset_observation
bash "$root/tools/smoke-nakama-native.sh" fixture --experimental --issued >"$scratch/result" 2>&1 &
parent=$!
ready=false
for ((n = 0; n < 200; n++)); do
	started=("$scratch/"*.started)
	if [[ ${#started[@]} == 4 ]]; then
		ready=true
		break
	fi
	sleep 0.02
done
[[ $ready == true ]]
kill -TERM "$parent"
if wait "$parent"; then
	echo 'FAIL: cancelled parent reported success' >&2
	exit 1
fi
[[ $(grep -c '^rm -f ' "$scratch/commands") == 5 ]]
for pid_file in "$scratch/"*.pid; do
	pid=$(<"$pid_file")
	[[ $pid =~ ^[1-9][0-9]*$ ]]
	if kill -0 "$pid" 2>/dev/null; then
		echo 'FAIL: cancellation left an unjoined launcher' >&2
		exit 1
	fi
done
if grep -Eq '^NATIVE WORKER RECEIPT:|^NAKAMA NATIVE PASS:' "$scratch/result"; then exit 1; fi
export SHARD_FAILURE=''
reset_observation
state=$scratch/reused
mkdir -p "$state/shards"
source "$root/tools/nakama-native-scenarios.sh"
native_scenarios --issued
printf '%s\n' "${scenarios[@]}" >"$state/expected"
if bash "$root/tools/run-nakama-native-shards.sh" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa fixture "$state" --issued >"$scratch/result" 2>&1; then
	echo 'FAIL: accepted reused shard evidence' >&2
	exit 1
fi
[[ ! -s $scratch/commands ]]
finished=1
echo 'TEST PASS: complete four-worker union, concurrent launch, producer failures, cleanup and run identity are fail-closed'
