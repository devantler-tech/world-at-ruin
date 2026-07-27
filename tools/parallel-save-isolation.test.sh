#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
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

check_run() {
	local log="$1"
	local status="$2"
	local name="$3"

	if [ "${status}" -ne 0 ] || grep -q "TEST FAIL" "${log}" || ! grep -q "TEST PASS" "${log}"; then
		echo "::error::parallel SaveIsolation run '${name}' failed"
		tail -80 "${log}"
		return 1
	fi
}

# A pair is isolated only when both real scenes pass and report different
# resolved probes. Distinct paths make the guard deterministic even if runner
# scheduling happens to serialize the destructive phases.
run_pair() {
	local name="$1"
	local scene="$2"
	local marker="$3"
	local first_log="${logs}/${name}-first.log"
	local second_log="${logs}/${name}-second.log"
	local first_status=0
	local second_status=0
	local first_probe
	local second_probe

	perl -e 'alarm shift; exec @ARGV' "${timeout_seconds}" \
		"${godot_bin}" --headless --path client "${scene}" >"${first_log}" 2>&1 &
	local first_pid=$!
	perl -e 'alarm shift; exec @ARGV' "${timeout_seconds}" \
		"${godot_bin}" --headless --path client "${scene}" >"${second_log}" 2>&1 &
	local second_pid=$!

	wait "${first_pid}" || first_status=$?
	wait "${second_pid}" || second_status=$?

	local failed=0
	check_run "${first_log}" "${first_status}" "${name}-first" || failed=1
	check_run "${second_log}" "${second_status}" "${name}-second" || failed=1
	if [ "${failed}" -ne 0 ]; then
		return 1
	fi

	first_probe="$(grep -F -m1 "${marker}" "${first_log}" | cut -d= -f2-)"
	second_probe="$(grep -F -m1 "${marker}" "${second_log}" | cut -d= -f2-)"
	if [ -z "${first_probe}" ] || [ -z "${second_probe}" ]; then
		echo "::error::parallel SaveIsolation run '${name}' did not report both resolved probes"
		return 1
	fi
	if [ "${first_probe}" = "${second_probe}" ]; then
		echo "::error::parallel SaveIsolation run '${name}' resolved the shared probe '${first_probe}'"
		return 1
	fi
}

run_pair \
	"boot-ledger" \
	"res://tests/boot_ledger_boot_test.tscn" \
	"SAVE_ISOLATION_PROBE="
run_pair \
	"vault-retry" \
	"res://tests/vault_restore_boot_test.tscn" \
	"SAVE_ISOLATION_RETRY_VAULT="

echo "TEST PASS — concurrent boot tests report independent save, vault, recovery and retry probes"
