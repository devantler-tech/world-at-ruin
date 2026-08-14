#!/usr/bin/env bash
# Client test runner — the ONE place a client test scene is judged pass or fail.
#
# WHY THIS EXISTS (issue #305): `get_tree().quit(code)` does not halt the current
# frame. It requests a shutdown and execution continues to the end of the calling
# function and back up the stack. A test that reports failure through a `_fail()`
# helper therefore returns into `_ready()`, which runs on to its closing
# `print("TEST PASS …")` and `quit(0)` — the later quit wins the exit code, and
# BOTH markers land in the log. Measured on 4.7.1.stable.official.a13da4feb:
#
#     EXIT CODE: 0
#     TEST PASS lines: 1
#     TEST FAIL lines: 1
#
# The five call sites in ci.yaml previously judged a run by `grep -q "TEST PASS"`
# alone, so a test in that shape printed its own failure and passed CI anyway.
#
# THE FIX IS THE ABSENCE CHECK, NOT THE EXIT CODE. Every call site already ran
# under `set -o pipefail`, so a crashing or timing-out godot was always caught.
# What no site checked was `TEST FAIL` — and in this failure mode the process
# genuinely exits 0, so the exit status carries no signal at all. The absence
# check is the only thing that closes it.
#
# WHY A SHARED SCRIPT RATHER THAN SIX EDITED LINES: the pass criterion was
# duplicated five times (the generic auto-discovery loop plus the four
# product-law guards that run in their own named steps). Adding the missing
# check in five places would leave the next author free to write a sixth site
# without it — which is the same class of defect one level up. Judged here, a
# test file cannot regress the harness, and a new call site cannot skip a rule
# it never spells out.
#
# ORDER IS DELIBERATE: `TEST FAIL` is checked BEFORE `TEST PASS`. When a log
# carries both markers, the failure is the true diagnosis, and reporting the
# missing-PASS message instead would send a reader looking for a crash that
# never happened.
#
# Usage: tools/run-client-test.sh <test-name> [failure-message]
#   <test-name>        scene basename under client/tests (no .tscn suffix)
#   [failure-message]  optional context for the product-law guards, whose
#                      failures deserve a louder explanation than the default
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "::error::usage: tools/run-client-test.sh <test-name> [failure-message]" >&2
	exit 2
fi

name="$1"
context="${2:-}"
log="${name}.log"
# Test-only override for the watchdog regression. Production and CI use 180s.
timeout_seconds="${RUN_CLIENT_TEST_TIMEOUT_SECONDS:-180}"

case "${timeout_seconds}" in
	''|*[!0-9]*|0)
		echo "::error::${name} could not execute: RUN_CLIENT_TEST_TIMEOUT_SECONDS must be a positive integer"
		exit 2
		;;
esac

# A scene that does not exist would otherwise surface as a godot parse error
# buried in the log tail, and the reader would hunt a broken test rather than a
# typo'd call site.
if [ ! -f "client/tests/${name}.tscn" ]; then
	echo "::error::${name}: no such scene at client/tests/${name}.tscn"
	exit 1
fi

if ! command -v godot >/dev/null 2>&1; then
	echo "::error::${name} could not execute: godot was not found in PATH"
	exit 2
fi

# GNU timeout is absent from stock macOS, so supervise the real Godot PID with
# Bash and portable process primitives. A FIFO preserves the live tee output
# while keeping the child PID available for the watchdog; supervising a
# background pipeline would expose only tee's PID and leave a hung Godot alive.
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/run-client-test.XXXXXX")"
output_fifo="${run_dir}/output"
timeout_marker="${run_dir}/timed-out"
test_pid=""
tee_pid=""
watchdog_pid=""

cleanup() {
	if [ -n "${test_pid}" ]; then
		kill -TERM -- "-${test_pid}" 2>/dev/null || true
		kill -KILL -- "-${test_pid}" 2>/dev/null || true
	fi
	for pid in "${watchdog_pid}" "${test_pid}" "${tee_pid}"; do
		if [ -n "${pid}" ]; then
			kill "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
		fi
	done
	rm -rf "${run_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkfifo "${output_fifo}"
tee "${log}" <"${output_fifo}" &
tee_pid=$!
# Give Godot a dedicated process group. Tests may start descendants which
# inherit the FIFO writer, so supervising only Godot's direct PID can leave tee
# waiting forever after Godot exits. Job control is the portable Bash way to
# create that group on both Linux and macOS (where setsid is not available).
set -m
godot --headless --path client "res://tests/${name}.tscn" >"${output_fifo}" 2>&1 &
test_pid=$!
set +m

(
	watchdog_sleep_pid=""
	trap 'kill "${watchdog_sleep_pid}" 2>/dev/null || true
		wait "${watchdog_sleep_pid}" 2>/dev/null || true
		exit 0' INT TERM
	sleep "${timeout_seconds}" &
	watchdog_sleep_pid=$!
	if ! wait "${watchdog_sleep_pid}"; then
		exit 0
	fi
	watchdog_sleep_pid=""
	if kill -0 "${test_pid}" 2>/dev/null; then
		# Publish the verdict before TERM can wake the wait below. Otherwise
		# the waiter can cancel this watchdog before the marker is durable and
		# misclassify an elapsed timeout as the child's exit status.
		: >"${timeout_marker}"
		kill -TERM -- "-${test_pid}" 2>/dev/null || true
		sleep 2
		kill -KILL -- "-${test_pid}" 2>/dev/null || true
	fi
) &
watchdog_pid=$!

if wait "${test_pid}"; then
	test_status=0
else
	test_status=$?
fi
# A completed test does not own background work. Terminate its entire process
# group before waiting for tee so an inherited FIFO writer cannot outlive the
# per-test bound (or leak into later tests).
kill -TERM -- "-${test_pid}" 2>/dev/null || true
kill -KILL -- "-${test_pid}" 2>/dev/null || true
test_pid=""

kill "${watchdog_pid}" 2>/dev/null || true
wait "${watchdog_pid}" 2>/dev/null || true
watchdog_pid=""

if wait "${tee_pid}"; then
	tee_status=0
else
	tee_status=$?
fi
tee_pid=""

timed_out=false
if [ -f "${timeout_marker}" ]; then
	timed_out=true
fi

trap - EXIT INT TERM
rm -rf "${run_dir}"

if [ "${tee_status}" -ne 0 ]; then
	echo "::error::${name} could not execute: output capture failed (exit ${tee_status})"
	exit 2
fi

if [ "${timed_out}" = true ]; then
	echo "::error::${name} timed out (${timeout_seconds}s)${context:+ — ${context}}"
	tail -40 "${log}"
	exit 1
fi

if [ "${test_status}" -ne 0 ]; then
	echo "::error::${name} failed (exit ${test_status})${context:+ — ${context}}"
	tail -40 "${log}"
	exit 1
fi

if grep -q "TEST FAIL" "${log}"; then
	echo "::error::${name} reported TEST FAIL${context:+ — ${context}}"
	tail -40 "${log}"
	exit 1
fi

if ! grep -q "TEST PASS" "${log}"; then
	echo "::error::${name} exited 0 without reporting PASS${context:+ — ${context}}"
	tail -40 "${log}"
	exit 1
fi
