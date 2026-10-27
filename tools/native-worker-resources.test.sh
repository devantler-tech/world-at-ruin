#!/usr/bin/env bash
# Real file readers must retain unknown counters and preserve the test process's result.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
source "$root/tools/native-worker-resources.sh"
mkdir "$scratch/cgroup"
printf '104857600\n' >"$scratch/cgroup/memory.peak"
printf 'usage_usec 2500000\nuser_usec 2400000\nsystem_usec 100000\n' >"$scratch/cgroup/cpu.stat"
native_worker_resources "$scratch/cgroup" | jq -e \
	'.memoryPeakBytes==104857600 and .cpuUsageUsec==2500000 and .complete==true' >/dev/null
for invalid in '' 0 -1 01 '12 garbage' 9999999999999999; do
	printf '%s\n' "$invalid" >"$scratch/cgroup/memory.peak"
	native_worker_resources "$scratch/cgroup" | jq -e \
		'.memoryPeakBytes==null and .cpuUsageUsec==2500000 and .complete==false' >/dev/null
done
printf '104857600\n' >"$scratch/cgroup/memory.peak"
for invalid in 'usage_usec 0' 'usage_usec -1' 'usage_usec 1 extra' 'user_usec 5' $'usage_usec 1\nusage_usec 2'; do
	printf '%s\n' "$invalid" >"$scratch/cgroup/cpu.stat"
	native_worker_resources "$scratch/cgroup" | jq -e \
		'.memoryPeakBytes==104857600 and .cpuUsageUsec==null and .complete==false' >/dev/null
done
rm "$scratch/cgroup/cpu.stat"
native_worker_resources "$scratch/cgroup" | jq -e \
	'.memoryPeakBytes==104857600 and .cpuUsageUsec==null and .complete==false' >/dev/null
# An errored read that already produced a plausible number must remain unknown.
cat() {
	printf '12345\n'
	return 42
}
native_worker_resources "$scratch/cgroup" | jq -e \
	'.memoryPeakBytes==null and .cpuUsageUsec==null and .complete==false' >/dev/null
unset -f cat
printf 'MemTotal:       16384000 kB\nMemFree: 1024 kB\n' >"$scratch/meminfo"
native_runner_resources "$scratch/meminfo" 4 | jq -e \
	'.logicalCPUs==4 and .memoryTotalBytes==16777216000 and .complete==true' >/dev/null
native_runner_resources "$scratch/absent" 4 | jq -e \
	'.logicalCPUs==4 and .memoryTotalBytes==null and .complete==false' >/dev/null
native_runner_resources "$scratch/meminfo" '' | jq -e \
	'.logicalCPUs==null and .memoryTotalBytes==16777216000 and .complete==false' >/dev/null
printf 'MemTotal: 1024 kB\nMemTotal: 2048 kB\n' >"$scratch/meminfo"
native_runner_resources "$scratch/meminfo" 4 | jq -e \
	'.logicalCPUs==4 and .memoryTotalBytes==null and .complete==false' >/dev/null
cat >"$scratch/exit-worker" <<'EXIT_WORKER'
#!/usr/bin/env bash
exit "$1"
EXIT_WORKER
for result in 0 23; do
	set +e
	native_worker_run bash "$scratch/exit-worker" "$result" >"$scratch/result"
	actual=$?
	set -e
	[[ $actual == "$result" ]] || {
		echo 'FAIL: resource observation changed worker exit status' >&2
		exit 1
	}
	[[ $(grep -c '^NATIVE WORKER RESOURCES: ' "$scratch/result") == 1 ]]
	sed -n 's/^NATIVE WORKER RESOURCES: //p' "$scratch/result" | jq -e \
		'has("memoryPeakBytes") and has("cpuUsageUsec") and (.complete | type)=="boolean"' >/dev/null
done
echo 'TEST PASS: actual resource readers preserve measured values, unknown reads and worker exit status'
