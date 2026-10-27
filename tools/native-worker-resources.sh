#!/usr/bin/env bash
# Diagnostic observations only; missing counters never become zero or a test verdict.
native_worker_resources() {
	local directory=$1 memory=null cpu=null text line matches=0 complete=false
	if text=$(cat "$directory/memory.peak" 2>/dev/null) && [[ $text =~ ^[1-9][0-9]{0,14}$ ]]; then
		memory=$text
	fi
	if text=$(cat "$directory/cpu.stat" 2>/dev/null); then
		while IFS= read -r line; do
			if [[ $line == usage_usec* ]]; then
				matches=$((matches + 1))
				if [[ $line =~ ^usage_usec[[:space:]]([1-9][0-9]{0,14})$ ]]; then cpu=${BASH_REMATCH[1]}; fi
			fi
		done <<<"$text"
	fi
	if [[ $matches != 1 ]]; then cpu=null; fi
	if [[ $memory != null && $cpu != null ]]; then complete=true; fi
	printf '{"memoryPeakBytes":%s,"cpuUsageUsec":%s,"complete":%s}\n' "$memory" "$cpu" "$complete"
}

native_runner_resources() {
	local file=$1 cpus=$2 memory=null text line matches=0 complete=false
	if [[ ! $cpus =~ ^[1-9][0-9]{0,5}$ ]]; then cpus=null; fi
	if text=$(cat "$file" 2>/dev/null); then
		while IFS= read -r line; do
			if [[ $line == MemTotal:* ]]; then
				matches=$((matches + 1))
				if [[ $line =~ ^MemTotal:[[:space:]]+([1-9][0-9]{0,11})[[:space:]]+kB$ ]]; then
					memory=$((BASH_REMATCH[1] * 1024))
				fi
			fi
		done <<<"$text"
	fi
	if [[ $matches != 1 ]]; then memory=null; fi
	if [[ $cpus != null && $memory != null ]]; then complete=true; fi
	printf '{"logicalCPUs":%s,"memoryTotalBytes":%s,"complete":%s}\n' "$cpus" "$memory" "$complete"
}

native_worker_run() {
	local result=0 observation
	"$@" || result=$?
	observation=$(native_worker_resources /sys/fs/cgroup)
	printf 'NATIVE WORKER RESOURCES: %s\n' "$observation"
	return "$result"
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then native_worker_run /out/native-trial.test "$@"; fi
