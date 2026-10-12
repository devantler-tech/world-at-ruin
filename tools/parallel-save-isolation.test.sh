#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
timeout_seconds=180
logs="$(mktemp -d)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
active=()
cleanup_uncertain=0
launching=false
cancel_pending=false
cleanup_started=false
cleanup_status=0
request_cancel() {
	cancel_pending=true
	if [ "$cleanup_started" = true ]; then return; fi
	if [ "$launching" != true ]; then exit 130; fi
}
cleanup() {
	trap ':' INT TERM
	local status=$cleanup_status pid
	trap - EXIT
	trap ':' INT TERM
	for pid in ${active[@]+"${active[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done
	for pid in ${active[@]+"${active[@]}"}; do
		local joined=0
		wait "$pid" 2>/dev/null || joined=$?
		case "$joined" in 2|137|143) cleanup_uncertain=1;; esac
	done
	if [ "$cleanup_uncertain" -ne 0 ]; then exit 2; fi
	rm -rf "$logs"
	exit "$status"
}
trap 'cleanup_status=$? cleanup_started=true; cleanup' EXIT
trap 'trap ":" INT TERM; request_cancel' INT TERM

if ! command -v "${godot_bin}" >/dev/null 2>&1; then
	echo "::error::Godot is unavailable at '${godot_bin}'"
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

	local test_name="${scene##*/}"
	test_name="${test_name%.tscn}"
	mkdir -p "$logs/$name-first" "$logs/$name-second"
	launching=true
	set -m
	RUN_CLIENT_TEST_LOG_DIR="$logs/$name-first" RUN_CLIENT_TEST_TIMEOUT_SECONDS="$timeout_seconds" GODOT_BIN="$godot_bin" \
		bash "$root/tools/run-client-test.sh" "$test_name" >"${first_log}" 2>&1 &
	local first_pid=$!
	active=("$first_pid")
	RUN_CLIENT_TEST_LOG_DIR="$logs/$name-second" RUN_CLIENT_TEST_TIMEOUT_SECONDS="$timeout_seconds" GODOT_BIN="$godot_bin" \
		bash "$root/tools/run-client-test.sh" "$test_name" >"${second_log}" 2>&1 &
	local second_pid=$!
	active+=("$second_pid")
	set +m
	launching=false
	if [ "$cancel_pending" = true ]; then exit 130; fi

	wait "${first_pid}" || first_status=$?
	if [ "$first_status" -eq 2 ] || [ "$first_status" -eq 137 ] || [ "$first_status" -eq 143 ]; then cleanup_uncertain=1; fi
	active=("$second_pid")
	wait "${second_pid}" || second_status=$?
	if [ "$second_status" -eq 2 ] || [ "$second_status" -eq 137 ] || [ "$second_status" -eq 143 ]; then cleanup_uncertain=1; fi
	active=()

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

check_failure_path() {
	local log="${logs}/vault-restore-failure-path.log"
	local status=0
	local expected="TEST FAIL — forced failure-path probe — AND the run touched the player's real save, vault or recovery ledger"

	mkdir -p "$logs/failure-path"
	launching=true
	set -m
	RUN_CLIENT_TEST_LOG_DIR="$logs/failure-path" RUN_CLIENT_TEST_TIMEOUT_SECONDS="$timeout_seconds" GODOT_BIN="$godot_bin" \
		bash "$root/tools/run-client-test.sh" vault_restore_failure_path_probe >"${log}" 2>&1 &
	active=("$!")
	set +m
	launching=false
	if [ "$cancel_pending" = true ]; then exit 130; fi
	wait "${active[0]}" || status=$?
	if [ "$status" -eq 2 ] || [ "$status" -eq 137 ] || [ "$status" -eq 143 ]; then cleanup_uncertain=1; fi
	active=()
	if [ "${status}" -ne 1 ] || ! grep -Fq "${expected}" "${log}" ||
		! grep -Eq '^::error::vault_restore_failure_path_probe (reported TEST FAIL|failed [(]exit 1[)])$' "$log" ||
		grep -Fq 'SCRIPT ERROR:' "$log"; then
		echo "::error::vault-restore failure path cleaned up without reporting the isolation breach"
		tail -80 "${log}"
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
check_failure_path

echo "TEST PASS — concurrent boot tests report independent save, vault, recovery and retry probes"
