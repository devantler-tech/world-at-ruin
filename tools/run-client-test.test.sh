#!/usr/bin/env bash
# Pins the client-test runner's three distinct outcomes: executed failure,
# elapsed timeout, and an infrastructure failure before Godot can start.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${repo_root}/tools/run-client-test.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

bin_dir="${tmp_dir}/bin"
fixture_root="${tmp_dir}/fixture"
mkdir -p "${bin_dir}" "${fixture_root}/client/tests"
: >"${fixture_root}/client/tests/ability_registry_test.tscn"

# Use a deliberately curated PATH so GNU timeout/gtimeout are absent even on
# Linux CI. The runner must supervise Godot itself rather than accidentally
# succeeding because the host happens to carry coreutils.
for utility in grep mkfifo mktemp rm sed sleep tail tee; do
	utility_path="$(command -v "${utility}")"
	ln -s "${utility_path}" "${bin_dir}/${utility}"
done

cat >"${bin_dir}/godot" <<'GODOT'
#!/bin/bash
set -euo pipefail

case "${FAKE_GODOT_MODE:-success}" in
success)
	printf '%s\n' "TEST PASS — fake Godot completed"
	;;
workflow-log)
	printf '%s\n' '::notice::benign fixture data' '##[notice]benign fixture data' '::::notice::::benign repeated-colon fixture' 'TEST FAIL -- benign fixture failure'
	;;
fail)
	printf '%s\n' "fake Godot assertion failed"
	exit 7
	;;
script-error)
	printf '%s\n' 'SCRIPT ERROR: Invalid access on a null instance' >&2
	printf '%s\n' 'TEST PASS — caller continued after the exception'
	;;
script-error-after-pass)
	printf '%s\n' 'TEST PASS — caller reported success before the exception'
	printf '%s\n' 'SCRIPT ERROR: Invalid access on a null instance' >&2
	;;
warning)
	printf '%s\n' 'WARNING: deliberately refused invalid admission' >&2
	printf '%s\n' 'TEST PASS — the refusal was expected'
	;;
hang)
	trap 'exit 143' TERM
	while :; do
		sleep 1
	done
	;;
descendant)
	/bin/bash -c '
		trap "" TERM
		printf "%s\n" "$$" >"${FAKE_GODOT_CHILD_PID_FILE}"
		while :; do sleep 1; done
	' &
	while [ ! -s "${FAKE_GODOT_CHILD_PID_FILE}" ]; do sleep 0.01; done
	printf '%s\n' "TEST PASS — fake Godot completed with a descendant"
	;;
term-pass)
	trap 'printf "%s\n" "TEST PASS — fake Godot handled TERM"; exit 0' TERM
	while :; do
		:
	done
	;;
*)
	printf 'unknown fake mode: %s\n' "${FAKE_GODOT_MODE}" >&2
	exit 64
	;;
esac
GODOT
chmod +x "${bin_dir}/godot"

failures=0
case_status=0
case_output=""

fail() {
	printf 'run-client-test regression: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

# The timeout marker is the verdict hand-off from the watchdog to the waiter.
# It must exist before TERM can wake the waiter, otherwise the waiter can cancel
# the watchdog and misclassify the elapsed timeout as a process result.
marker_line="$(grep -n ": >\"\${timeout_marker}\"" "${runner}")"
marker_line="${marker_line%%:*}"
term_line=""
while IFS=: read -r candidate _; do
	if [ "${candidate}" -gt "${marker_line:-0}" ]; then
		term_line="${candidate}"
		break
	fi
done < <(grep -n "kill -TERM -- \"-\${test_pid}\"" "${runner}")
if [ -z "${marker_line}" ] || [ -z "${term_line}" ]; then
	fail "the timeout verdict publication or TERM signal is missing"
elif [ "${marker_line}" -ge "${term_line}" ]; then
	fail "the timeout verdict is not published before TERM can wake the waiter"
fi

run_case() {
	local label="$1"
	local mode="$2"
	local timeout_seconds="$3"
	local output="${tmp_dir}/${label}.log"

	if (
		cd "${fixture_root}"
		PATH="${bin_dir}" \
			FAKE_GODOT_MODE="${mode}" \
			RUN_CLIENT_TEST_TIMEOUT_SECONDS="${timeout_seconds}" \
			/bin/bash "${runner}" ability_registry_test
	) >"${output}" 2>&1; then
		case_status=0
	else
		case_status=$?
	fi
	case_output="$(<"${output}")"
}

run_case success success 2
if [ "${case_status}" -ne 0 ]; then
	fail "a passing scene could not run without GNU timeout: ${case_output}"
elif [[ "${case_output}" == *"failed or timed out"* ]]; then
	fail "the no-coreutils path was misreported as a test verdict"
fi

run_case failure fail 2
if [ "${case_status}" -eq 0 ]; then
	fail "a genuine Godot failure was accepted"
elif [[ "${case_output}" != *"failed (exit 7)"* ]]; then
	fail "a genuine failure did not preserve its exit status: ${case_output}"
elif [[ "${case_output}" == *"could not execute"* ]]; then
	fail "a genuine test failure was misreported as an infrastructure failure"
fi

for mode in script-error script-error-after-pass; do
	run_case "${mode}" "${mode}" 2
	if [ "${case_status}" -eq 0 ]; then
		fail "${mode} was hidden by a zero exit and PASS marker"
	elif [[ "${case_output}" != *"reported SCRIPT ERROR"* ]]; then
		fail "${mode} did not name its engine failure: ${case_output}"
	fi
done
run_case warning warning 2
if [ "${case_status}" -ne 0 ]; then
	fail "an expected warning was confused with a script exception: ${case_output}"
fi

# A failure excerpt remains data after the contained process restores commands.
run_case workflow-log workflow-log 2
if [ "${case_status}" -eq 0 ] || [[ "${case_output}" != *'reported TEST FAIL'* ]]; then
  fail 'workflow-like log fixture did not preserve its failing verdict'
fi
excerpt="$(printf '%s\n' "${case_output}" | awk '/^::error::ability_registry_test reported TEST FAIL/ {seen=1;next} seen {print}')"
if [[ "${excerpt}" == *'::'* || "${excerpt}" == *'##[notice]'* ]]; then
  fail 'failure excerpt replayed workflow command delimiters'
fi
if [[ "${excerpt}" != *': : notice: : benign fixture data'* || "${excerpt}" != *'# #[notice]benign fixture data'* ]]; then
  fail 'failure excerpt lost its safely displayed diagnostic'
fi
if ! grep -Fq '::notice::benign fixture data' "${fixture_root}/ability_registry_test.log" ||
  ! grep -Fq '##[notice]benign fixture data' "${fixture_root}/ability_registry_test.log" ||
  ! grep -Fq '::::notice::::benign repeated-colon fixture' "${fixture_root}/ability_registry_test.log"; then
  fail 'display escaping changed the original verdict log'
fi

run_case timeout hang 1
if [ "${case_status}" -eq 0 ]; then
	fail "a hung Godot process was accepted"
elif [[ "${case_output}" != *"timed out (1s)"* ]]; then
	fail "the portable watchdog did not report its timeout distinctly: ${case_output}"
elif [[ "${case_output}" == *"failed (exit"* ]]; then
	fail "a timeout was misreported as an ordinary process failure"
fi

run_case timeout-term-pass term-pass 1
if [ "${case_status}" -eq 0 ]; then
	fail "a scene that printed PASS while handling the timeout signal was accepted"
elif [[ "${case_output}" != *"timed out (1s)"* ]]; then
	fail "the timeout verdict was not published before signalling Godot: ${case_output}"
elif [[ "${case_output}" == *"failed (exit"* ]]; then
	fail "a signal-responsive timeout was misreported as an ordinary process failure"
fi

child_pid_file="${tmp_dir}/descendant.pid"
export FAKE_GODOT_CHILD_PID_FILE="${child_pid_file}"
run_case descendant descendant 2
if [ "${case_status}" -ne 0 ]; then
	fail "a completed scene with a descendant did not finish cleanly: ${case_output}"
elif [ ! -s "${child_pid_file}" ]; then
	fail "the descendant fixture did not publish its PID"
else
	child_pid="$(<"${child_pid_file}")"
	if [[ ! "${child_pid}" =~ ^[1-9][0-9]*$ ]]; then
		fail "the descendant fixture published a PID that is not a process id: ${child_pid}"
	elif kill -0 -- "${child_pid}" 2>/dev/null; then
		child_state="$(ps -o stat= -p "${child_pid}" 2>/dev/null || true)"
		if [[ "${child_state}" != Z* ]]; then
			fail "a descendant that inherited the output FIFO survived its test"
			kill -KILL -- "${child_pid}" 2>/dev/null || true
		fi
	fi
fi
unset FAKE_GODOT_CHILD_PID_FILE

# The protected controller selects a fresh host-owned log directory.
private_logs="${tmp_dir}/private-logs"
mkdir "${private_logs}"
sentinel="${tmp_dir}/log-sentinel"
printf 'unchanged inert sentinel\n' >"${sentinel}"
rm "${fixture_root}/ability_registry_test.log"
ln -s "${sentinel}" "${fixture_root}/ability_registry_test.log"
export RUN_CLIENT_TEST_LOG_DIR="${private_logs}"
run_case private-log success 2
unset RUN_CLIENT_TEST_LOG_DIR
if [ "${case_status}" -ne 0 ]; then
  fail "private host capture did not accept a passing scene: ${case_output}"
fi
if [ "$(cat "${sentinel}")" != 'unchanged inert sentinel' ]; then
  fail 'candidate log symlink redirected the real verdict runner output'
fi
if [ ! -f "${private_logs}/ability_registry_test.log" ] ||
  ! grep -q 'TEST PASS' "${private_logs}/ability_registry_test.log"; then
  fail 'passing scene output was not captured in the host-owned directory'
fi
rm "${fixture_root}/ability_registry_test.log"

mv "${bin_dir}/godot" "${tmp_dir}/godot-disabled"
run_case missing-godot success 2
if [ "${case_status}" -eq 0 ]; then
	fail "the runner accepted a PATH with no Godot executable"
elif [[ "${case_output}" != *"could not execute: godot was not found"* ]]; then
	fail "a missing runtime did not name the infrastructure failure: ${case_output}"
elif [[ "${case_output}" == *"failed or timed out"* ]] \
		|| [[ "${case_output}" == *"failed (exit"* ]] \
		|| [[ "${case_output}" == *"timed out ("* ]]; then
	fail "a run that never launched emitted a test verdict: ${case_output}"
fi

if [ "${failures}" -ne 0 ]; then
	printf 'run-client-test regression: %d failure(s)\n' "${failures}" >&2
	exit 1
fi

printf '%s\n' \
	"TEST PASS — client-test runner separates launch failure, process failure, and timeout without GNU timeout"
