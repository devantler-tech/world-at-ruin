#!/usr/bin/env bash
# Four same-image workers; no imported verdicts or caller-selected test regexes.
set -euo pipefail
[[ $# == 4 ]] || exit 2
image=$1 network=$2 state=$3 issued=$4
[[ $image =~ ^sha256:[a-f0-9]{64}$ && ($issued == '' || $issued == --issued) ]] || exit 2
[[ -d $state && ! -L $state && -f $state/expected && ! -L $state/expected ]] || exit 2
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$root/tools/nakama-native-scenarios.sh"
source "$root/tools/native-worker-resources.sh"
native_scenarios "$issued"
command -v jq >/dev/null
mkdir "$state/shards"
cpu_count=''
if ! cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null); then cpu_count=''; fi
native_runner_resources /proc/meminfo "$cpu_count" >"$state/shards/runner-resources.json"
worker_script=$(cat "$root/tools/native-worker-resources.sh")
worker_script+=$'\nnative_worker_run /out/native-trial.test "$@"'
printf '%s\n' "${scenarios[@]}" >"$state/shards/required"
cmp "$state/expected" "$state/shards/required"
source_sha=$(git -C "$root" rev-parse --verify HEAD)
[[ $source_sha =~ ^[a-f0-9]{40}$ ]]
run=${GITHUB_RUN_ID-local} attempt=${GITHUB_RUN_ATTEMPT-local}
if [[ -n ${GITHUB_SHA+x}${GITHUB_RUN_ID+x}${GITHUB_RUN_ATTEMPT+x} ]]; then
	[[ ${GITHUB_SHA:-} == "$source_sha" && $run =~ ^[1-9][0-9]{0,19}$ && $attempt =~ ^[1-9][0-9]{0,19}$ ]]
fi
ids=() pids=()
worker_execution_complete=0
# Preserve the producer's failure and join/retire only this invocation's children.
cleanup() {
	local rc=$? remaining owned pid
	trap - EXIT INT TERM
	for owned in ${ids[@]+"${ids[@]}"}; do
		if ! docker rm -f "$owned" >/dev/null 2>&1; then
			rc=1
		elif ! remaining=$(docker container ls --all --filter "id=$owned" --format '{{.ID}}') || [[ -n $remaining ]]; then
			rc=1
		fi
	done
	for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
	if [[ $rc == 0 && $worker_execution_complete != 1 ]]; then rc=1; fi
	if [[ $rc != 0 ]]; then echo 'native worker execution or owned retirement is incomplete' >&2; fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The opt-in binary lists its real compiled inventory without starting any scenario.
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
	--pids-limit 64 --memory 512m -e WAR_NATIVE_DB_PASSWORD "$image" \
	-war-experimental -war-bundle=/out/bundle -war-postgres=postgres:5432 -war-zone=/out/zone \
	'-test.list=^Test' >"$state/shards/compiled"
LC_ALL=C sort "$state/shards/required" >"$state/shards/required-sorted"
LC_ALL=C sort "$state/shards/compiled" >"$state/shards/compiled-sorted"
cmp "$state/shards/required-sorted" "$state/shards/compiled-sorted" || {
	echo 'compiled native inventory differs from the complete required profile' >&2
	exit 1
}
for shard in 0 1 2 3; do
	selected=()
	for ((index = shard; index < ${#scenarios[@]}; index += 4)); do selected+=("${scenarios[index]}"); done
	printf '%s\n' "${selected[@]}" >"$state/shards/expected-$shard"
	pattern=$(
		IFS='|'
		printf '%s' "${selected[*]}"
	)
	id=$(docker create --network "$network" --read-only --cap-drop ALL \
		--security-opt no-new-privileges:true --pids-limit 256 --memory 2g --cpus 2 \
		--cgroupns private \
		--tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777 \
		--tmpfs /var/run/secrets/kubernetes.io/serviceaccount:rw,nosuid,nodev,size=1m,uid=10001,gid=10001,mode=0700 \
		--entrypoint /bin/bash -e WAR_NATIVE_DB_PASSWORD "$image" -c "$worker_script" native-worker \
		-war-experimental -war-bundle=/out/bundle \
		-war-postgres=postgres:5432 -war-zone=/out/zone -test.v "-test.run=^($pattern)$" -test.timeout=16m)
	[[ $id =~ ^[a-f0-9]{64}$ ]]
	for owned in ${ids[@]+"${ids[@]}"}; do [[ $owned != "$id" ]] || exit 1; done
	ids+=("$id")
done
# Every launcher is started before any wait; separate containers isolate global env and ports.
for shard in 0 1 2 3; do
	(
		started=$SECONDS
		docker start -a "${ids[shard]}" | tee "$state/shards/worker-$shard.log" >/dev/null
		printf '%s\n' "$((SECONDS - started))" >"$state/shards/seconds-$shard"
	) &
	pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=1; fi; done
[[ $failed == 0 ]] || exit 1
for shard in 0 1 2 3; do
	log="$state/shards/worker-$shard.log"
	[[ $(docker inspect --format '{{.State.ExitCode}}' "${ids[shard]}") == 0 ]]
	[[ $(grep -c '^PASS$' "$log") == 1 ]]
	if grep -E '^[[:space:]]*--- (FAIL|SKIP): Test|^FAIL($|[[:space:]])' "$log"; then
		exit 1
	else
		grep_result=$?
		[[ $grep_result == 1 ]] || exit 1
	fi
	sed -nE 's/^--- PASS: (Test[A-Za-z0-9_]+) \([0-9]+(\.[0-9]+)?s\)$/\1/p' "$log" |
		LC_ALL=C sort >"$state/shards/actual-$shard"
	LC_ALL=C sort "$state/shards/expected-$shard" >"$state/shards/expected-sorted-$shard"
	cmp "$state/shards/expected-sorted-$shard" "$state/shards/actual-$shard"
	[[ $(grep -c '^--- PASS: Test' "$log") == $(wc -l <"$state/shards/expected-$shard" | tr -d ' ') ]]
	# A measurement failure is explicit diagnostic uncertainty, never zero or a new passing verdict.
	sed -n 's/^NATIVE WORKER RESOURCES: //p' "$log" >"$state/shards/raw-resources-$shard"
	# shellcheck disable=SC2016 # Literal jq schema, with no shell expansion.
	if ! observation=$(jq -sce '
    def counter: . == null or (type == "number" and . > 0 and . < 1e15 and floor == .);
    select(length == 1) | .[0] |
    select(keys == ["complete","cpuUsageUsec","memoryPeakBytes"]) |
    select((.memoryPeakBytes | counter) and (.cpuUsageUsec | counter)) |
    select(.complete == (.memoryPeakBytes != null and .cpuUsageUsec != null))
  ' "$state/shards/raw-resources-$shard" 2>/dev/null); then
		observation='{"memoryPeakBytes":null,"cpuUsageUsec":null,"complete":false}'
	fi
	printf '%s\n' "$observation" >"$state/shards/resources-$shard.json"
done
# Keep all native diagnostic markers for the unchanged profile checks in the parent.
for shard in 0 1 2 3; do cat "$state/shards/worker-$shard.log"; done >"$state/trial.log"
profile=native
if [[ $issued == --issued ]]; then profile=issued; fi
# shellcheck disable=SC2016 # jq binds the exact invocation identity, not shell expansion.
jq -n --arg source "$source_sha" --arg run "$run" --arg attempt "$attempt" --arg image "$image" \
	--arg profile "$profile" --argjson scenarios "${#scenarios[@]}" \
	--slurpfile runnerResources "$state/shards/runner-resources.json" \
	--argjson resources "$(jq -s '.' "$state/shards/resources-0.json" "$state/shards/resources-1.json" "$state/shards/resources-2.json" "$state/shards/resources-3.json")" \
	--argjson seconds "$(jq -s '.' "$state/shards/seconds-0" "$state/shards/seconds-1" "$state/shards/seconds-2" "$state/shards/seconds-3")" \
	'{source:$source,run:$run,attempt:$attempt,image:$image,profile:$profile,workers:4,scenarios:$scenarios,seconds:$seconds,runnerResources:$runnerResources[0],resources:$resources,complete:true}' \
	>"$state/parallel-pending.json"
worker_execution_complete=1
