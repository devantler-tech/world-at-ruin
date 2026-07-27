#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
scene="res://tests/boot_ledger_boot_test.tscn"
timeout_seconds=180
logs="$(mktemp -d)"
trap 'rm -rf "${logs}"' EXIT

if ! command -v "${godot_bin}" >/dev/null 2>&1; then
	echo "::error::Godot is unavailable at '${godot_bin}'"
	exit 2
fi
if ! command -v perl >/dev/null 2>&1; then
	echo "::error::Perl is required for the portable test timeout"
	exit 2
fi

perl -e 'alarm shift; exec @ARGV' "${timeout_seconds}" \
	"${godot_bin}" --headless --path client "${scene}" >"${logs}/first.log" 2>&1 &
first_pid=$!
perl -e 'alarm shift; exec @ARGV' "${timeout_seconds}" \
	"${godot_bin}" --headless --path client "${scene}" >"${logs}/second.log" 2>&1 &
second_pid=$!

first_status=0
second_status=0
wait "${first_pid}" || first_status=$?
wait "${second_pid}" || second_status=$?

check_run() {
	local name="$1"
	local status="$2"
	local log="${logs}/${name}.log"

	if [ "${status}" -ne 0 ] || grep -q "TEST FAIL" "${log}" || ! grep -q "TEST PASS" "${log}"; then
		echo "::error::parallel SaveIsolation run '${name}' failed"
		tail -80 "${log}"
		return 1
	fi
}

failed=0
check_run "first" "${first_status}" || failed=1
check_run "second" "${second_status}" || failed=1
if [ "${failed}" -ne 0 ]; then
	exit 1
fi

echo "TEST PASS — concurrent boot tests keep independent save, vault and recovery probes"
