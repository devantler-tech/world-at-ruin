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
timeout_seconds=180

# A scene that does not exist would otherwise surface as a godot parse error
# buried in the log tail, and the reader would hunt a broken test rather than a
# typo'd call site.
if [ ! -f "client/tests/${name}.tscn" ]; then
	echo "::error::${name}: no such scene at client/tests/${name}.tscn"
	exit 1
fi

if ! timeout "${timeout_seconds}" godot --headless --path client "res://tests/${name}.tscn" 2>&1 | tee "${log}"; then
	echo "::error::${name} failed or timed out (${timeout_seconds}s)${context:+ — ${context}}"
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
