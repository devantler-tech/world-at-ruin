#!/usr/bin/env bash
# Pins the required-regression boundary to externally selected trusted bytes
# rather than to the pull-request checkout it evaluates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control="${repo_root}/tools/required-regression-control.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

trusted="${tmp_dir}/trusted"
candidate="${tmp_dir}/candidate"
empty_trusted="${tmp_dir}/empty-trusted"
bin_dir="${tmp_dir}/bin"
run_log="${tmp_dir}/runs.log"

mkdir -p \
	"${trusted}/client/tests" \
	"${trusted}/tools" \
	"${candidate}/client/tests" \
	"${empty_trusted}/client/tests" \
	"${empty_trusted}/tools" \
	"${bin_dir}"

printf '%s\n' 'trusted alpha harness' >"${trusted}/client/tests/alpha_test.tscn"
printf '%s\n' 'trusted beta harness' >"${trusted}/client/tests/beta_test.tscn"
printf '%s\n' 'candidate-weakened alpha harness' >"${candidate}/client/tests/alpha_test.tscn"
printf '%s\n' 'beta_test' >"${candidate}/client/tests/ci-skip.txt"
printf '%s\n' 'candidate product bytes' >"${candidate}/client/product.marker"
printf '%s\n' '[application]' >"${candidate}/client/project.godot"

cat >"${bin_dir}/godot" <<'GODOT'
#!/bin/bash
set -euo pipefail
printf '%s\n' 'trusted import completed'
GODOT
chmod +x "${bin_dir}/godot"

cat >"${trusted}/tools/run-client-test.sh" <<'RUNNER'
#!/bin/bash
set -euo pipefail

name="${1:?test name required}"
: "${REQUIRED_REGRESSION_RUN_LOG:?run log required}"

if [ ! -f client/product.marker ]; then
	echo "candidate product was not evaluated" >&2
	exit 91
fi

expected="trusted ${name%_test} harness"
actual="$(cat "client/tests/${name}.tscn")"
if [ "${actual}" != "${expected}" ]; then
	echo "${name} used candidate-controlled harness bytes: ${actual}" >&2
	exit 92
fi

printf '%s\n' "${name}" >>"${REQUIRED_REGRESSION_RUN_LOG}"
if [ "${REQUIRED_REGRESSION_FAIL_TEST:-}" = "${name}" ]; then
	echo "deliberate ${name} failure" >&2
	exit 93
fi

printf '%s\n' "TEST PASS -- ${name}"
RUNNER
chmod +x "${trusted}/tools/run-client-test.sh"
cp "${trusted}/tools/run-client-test.sh" "${empty_trusted}/tools/run-client-test.sh"

failures=0

fail() {
	printf 'required-regression-control regression: FAIL -- %s\n' "$1" >&2
	failures=$((failures + 1))
}

find_local_controller_workflows() {
	local workflows_dir="$1"
	local workflow_file
	for workflow_file in "${workflows_dir}"/*.yaml "${workflows_dir}"/*.yml; do
		[ -f "${workflow_file}" ] || continue
		if grep -Fq 'tools/required-regression-control.sh' "${workflow_file}"; then
			basename "${workflow_file}"
		fi
	done
}

if [ ! -x "${control}" ]; then
	fail "the required-regression control is missing or not executable"
else
	control_output="${tmp_dir}/control.log"
	if ! PATH="${bin_dir}:${PATH}" \
		REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		/bin/bash "${control}" "${trusted}" "${candidate}" \
		>"${control_output}" 2>&1; then
		fail "the trusted suite did not accept a passing candidate: $(<"${control_output}")"
	fi

	if [ ! -f "${run_log}" ]; then
		fail "no trusted regression scene was executed"
	else
		expected_runs=$'alpha_test\nbeta_test'
		actual_runs="$(<"${run_log}")"
		if [ "${actual_runs}" != "${expected_runs}" ]; then
			fail "candidate deletion or ci-skip changed the trusted selection: ${actual_runs}"
		fi
	fi

	: >"${run_log}"
	if PATH="${bin_dir}:${PATH}" \
		REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		REQUIRED_REGRESSION_FAIL_TEST="beta_test" \
		/bin/bash "${control}" "${trusted}" "${candidate}" \
		>"${control_output}" 2>&1; then
		fail "the aggregate accepted a failing trusted regression"
	elif ! grep -q 'deliberate beta_test failure' "${control_output}"; then
		fail "the aggregate did not preserve the trusted runner failure: $(<"${control_output}")"
	fi

	if PATH="${bin_dir}:${PATH}" \
		REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		/bin/bash "${control}" "${empty_trusted}" "${candidate}" \
		>"${control_output}" 2>&1; then
		fail "an empty trusted regression selection passed vacuously"
	elif ! grep -q 'no trusted regression test scenes' "${control_output}"; then
		fail "the empty-selection refusal was not explicit: $(<"${control_output}")"
	fi
fi

workflow_fixture_dir="${tmp_dir}/workflow-fixture"
mkdir -p "${workflow_fixture_dir}"
printf '%s\n' 'run: trusted/tools/required-regression-control.sh trusted candidate' \
	>"${workflow_fixture_dir}/renamed-gate.yaml"
if ! find_local_controller_workflows "${workflow_fixture_dir}" |
	grep -Fq 'renamed-gate.yaml'; then
	fail "a renamed candidate-repository workflow can evade the source guard"
fi

local_workflows="$(find_local_controller_workflows "${repo_root}/.github/workflows")"
if [ -n "${local_workflows}" ]; then
	fail "candidate-repository workflows invoke the required-regression controller: ${local_workflows}"
fi

external_workflow='.github/workflows/world-at-ruin-required-regressions.yaml'
for contract in "${repo_root}/AGENTS.md" \
	"${repo_root}/docs/adr/0003-pin-required-regressions-outside-candidate-control.md"; do
	if ! grep -Fq 'devantler-tech/actions' "${contract}" ||
		! grep -Fq "${external_workflow}" "${contract}" ||
		! grep -Fq 'refs/heads/main' "${contract}"; then
		fail "$(basename "${contract}") does not name the live external workflow source contract"
	fi
done

if [ "${failures}" -ne 0 ]; then
	printf 'required-regression-control regression: %d failure(s)\n' "${failures}" >&2
	exit 1
fi

printf '%s\n' \
	'TEST PASS -- required regressions use trusted selection and harness bytes and fail closed as one aggregate'
