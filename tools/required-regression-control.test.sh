#!/usr/bin/env bash
# Pins the required-regression boundary to externally selected trusted bytes
# rather than to the pull-request checkout it evaluates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control_source="${repo_root}/tools/required-regression-control.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

workflow_source="${tmp_dir}/workflow-source"
control="${workflow_source}/tools/required-regression-control.sh"
trusted="${tmp_dir}/trusted"
candidate="${tmp_dir}/candidate"
empty_trusted="${tmp_dir}/empty-trusted"
bin_dir="${tmp_dir}/bin"
run_log="${tmp_dir}/runs.log"

mkdir -p \
	"${workflow_source}/tools" \
	"${trusted}/client/tests" \
	"${trusted}/tools" \
	"${candidate}/client/tests" \
	"${empty_trusted}/client/tests" \
	"${empty_trusted}/tools" \
	"${bin_dir}"

cp "${control_source}" "${control}"
cp "$repo_root/tools/trusted-regression-phase.sh" "$repo_root/tools/trusted-regression-lifecycle.sh" "$workflow_source/tools/"
printf '%s\n' 'trusted alpha harness' >"${trusted}/client/tests/alpha_test.tscn"
printf '%s\n' 'trusted beta harness' >"${trusted}/client/tests/beta_test.tscn"
printf '%s\n' 'candidate-weakened alpha harness' >"${candidate}/client/tests/alpha_test.tscn"
printf '%s\n' 'beta_test' >"${candidate}/client/tests/ci-skip.txt"
printf '%s\n' 'candidate product bytes' >"${candidate}/client/product.marker"
printf '%s\n' '[application]' >"${candidate}/client/project.godot"
printf '%s\n' '[application]' 'config/name="trusted suite"' >"${trusted}/client/project.godot"
cp "${trusted}/client/project.godot" "${empty_trusted}/client/project.godot"
mkdir -p "${trusted}/client/tests/data" "${candidate}/client/tests/data"
printf '# historical declaration\n1\n2\n3\n4\n5\n6\n' >"${trusted}/client/tests/data/shipped_save_capability.txt"
cp "${trusted}/client/tests/data/shipped_save_capability.txt" "${candidate}/client/tests/data/shipped_save_capability.txt"
printf '# recipe history\n1\n2\n3\n4\n' >"${trusted}/client/tests/data/shipped_recipe_versions.txt"
cp "${trusted}/client/tests/data/shipped_recipe_versions.txt" "${candidate}/client/tests/data/shipped_recipe_versions.txt"
printf '{"version":5,"joint_push":{"thigh":1.16,"calf":1.12}}\n' >"${trusted}/client/tests/data/planned_recipe_v5.json"
printf '%s\n' 'immutable golden player state' >"${trusted}/client/tests/data/golden_vault.json"
printf '%s\n' 'candidate weakened golden' >"${candidate}/client/tests/data/golden_vault.json"
# Candidate root files must not overwrite the controller's validated copy.
printf '8\n' >"${candidate}/validated-capability.txt"

cat >"${bin_dir}/godot" <<'GODOT'
#!/bin/bash
set -euo pipefail
printf '%s\n' imported >>"${REQUIRED_REGRESSION_RUN_LOG}.import"
printf '%s\n' 'trusted import completed'
GODOT
chmod +x "${bin_dir}/godot"
cp "${bin_dir}/godot" "${tmp_dir}/godot-import-stub"

cat >"${workflow_source}/tools/run-client-test.sh" <<'RUNNER'
#!/bin/bash
set -euo pipefail

name="${1:?test name required}"
: "${REQUIRED_REGRESSION_RUN_LOG:?run log required}"

if [ ! -f client/product.marker ]; then
	echo "candidate product was not evaluated" >&2
	exit 91
fi

if [ "$(cat client/project.godot)" != $'[application]\nconfig/name="trusted suite"' ]; then
	echo 'candidate selected protected-suite project settings' >&2
	exit 96
fi
expected="trusted ${name%_test} harness"
actual="$(cat "client/tests/${name}.tscn")"
if [ "${actual}" != "${expected}" ]; then
	echo "${name} used candidate-controlled harness bytes: ${actual}" >&2
	exit 92
fi

if [ "$(cat client/tests/data/golden_vault.json)" != 'immutable golden player state' ]; then
	echo "candidate substituted historical player-state fixture" >&2
	exit 94
fi
if [ "$(tail -n 1 client/tests/data/shipped_save_capability.txt)" != "${REQUIRED_REGRESSION_CAPABILITY:-6}" ]; then
	echo "validated candidate capability declaration was not evaluated" >&2
	exit 95
fi
if [ "$(tail -n 1 client/tests/data/shipped_recipe_versions.txt)" != "${REQUIRED_REGRESSION_RECIPE_VERSION:-4}" ]; then
	echo "validated recipe declaration was not evaluated" >&2
	exit 97
fi
if [ "${REQUIRED_REGRESSION_RECIPE_VERSION:-4}" = 5 ] && ! cmp -s client/tests/data/golden_recipe_v5.json client/tests/data/planned_recipe_v5.json; then
	echo "planned golden did not come from trusted fixture bytes" >&2
	exit 98
fi
printf '%s\n' "${name}" >>"${REQUIRED_REGRESSION_RUN_LOG}"
if [ "${REQUIRED_REGRESSION_FAIL_TEST:-}" = "${name}" ]; then
	echo "deliberate ${name} failure" >&2
	exit 93
fi

printf '%s\n' "TEST PASS -- ${name}"
RUNNER
chmod +x "${workflow_source}/tools/run-client-test.sh"
cp "${workflow_source}/tools/run-client-test.sh" "${empty_trusted}/tools/run-client-test.sh"

# Historical base helpers are inert sentinels, never host control inputs.
export REQUIRED_REGRESSION_LEGACY_LOG="${tmp_dir}/historical-host.log"
for helper in required-regression-control run-client-test; do
  cat >"${trusted}/tools/${helper}.sh" <<'HISTORICAL'
#!/bin/bash
printf '%s\n' 'historical helper executed' >>"${REQUIRED_REGRESSION_LEGACY_LOG}"
exit 0
HISTORICAL
  chmod +x "${trusted}/tools/${helper}.sh"
done

failures=0

# Accumulate every independently observed control failure before reporting.
fail() {
	printf 'required-regression-control regression: FAIL -- %s\n' "$1" >&2
	failures=$((failures + 1))
}

# Locate every local workflow caller, including renamed definitions.
find_local_controller_workflows() {
	local workflows_dir="$1"
	local workflow_file
	for workflow_file in "${workflows_dir}"/*.yaml "${workflows_dir}"/*.yml; do
		[ -f "${workflow_file}" ] || continue
		if grep -Eq 'tools/(required-regression-control|run-sandboxed-trusted-regressions)[.]sh' "${workflow_file}"; then
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

# Candidate log links must never redirect host capture into unrelated files.
cp "${workflow_source}/tools/run-client-test.sh" "${tmp_dir}/fixture-runner"
cp "${repo_root}/tools/run-client-test.sh" "${workflow_source}/tools/run-client-test.sh"
cat >"${bin_dir}/godot" <<'GODOT'
#!/bin/bash
set -euo pipefail
if [[ " $* " == *" --editor "* ]]; then
  printf '%s\n' 'benign fixture import'
else
  printf '%s\n' 'TEST PASS -- benign fixture scene'
fi
GODOT
for sink in trusted-import alpha_test beta_test; do
  printf 'unchanged inert sentinel\n' >"${tmp_dir}/${sink}.sentinel"
  ln -s "${tmp_dir}/${sink}.sentinel" "${candidate}/${sink}.log"
done
if ! PATH="${bin_dir}:${PATH}" /bin/bash "${control}" "${trusted}" "${candidate}" >"${control_output}" 2>&1; then
  fail "real verdict runner did not accept benign scenes with candidate log links: $(<"${control_output}")"
fi
for sink in trusted-import alpha_test beta_test; do
  if [ "$(cat "${tmp_dir}/${sink}.sentinel")" != 'unchanged inert sentinel' ]; then
    fail "candidate ${sink}.log redirected host output"
  fi
  rm "${candidate}/${sink}.log"
done
[ "$(grep -c 'TEST PASS -- benign fixture scene' "${control_output}")" -eq 2 ] ||
  fail 'real verdict runner did not capture both benign scene outcomes'
cp "${tmp_dir}/fixture-runner" "${workflow_source}/tools/run-client-test.sh"
cp "${tmp_dir}/godot-import-stub" "${bin_dir}/godot"

# Execute the real launcher/controller with a divergent event-base helper pair.
# Only the external compiler/container runtime are stubs in this ownership test.
cp "${repo_root}/tools/run-client-test.sh" "${workflow_source}/tools/run-client-test.sh"
for helper in run-sandboxed-trusted-regressions build-trusted-regression-runtime sandbox-godot; do
  cp "${repo_root}/tools/${helper}.sh" "${workflow_source}/tools/${helper}.sh"
done
cp "${repo_root}/tools/trusted-regression-cache.go" "${workflow_source}/tools/"
mkdir -p "${workflow_source}/.github/containers" "${trusted}/docs/phase-0" \
  "${candidate}/server/wire" "${candidate}/.github/workflows"
cp "${repo_root}/.github/containers/trusted-regressions.Dockerfile" "${workflow_source}/.github/containers/"
printf 'historical frame fixture\n' >"${trusted}/docs/phase-0/cave-chamber.png"
printf 'candidate source data\n' >"${candidate}/server/wire/wire.go"
printf 'candidate source data\n' >"${candidate}/.github/workflows/ci.yaml"
cat >"${bin_dir}/go" <<'COMPILER'
#!/bin/bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    printf '#!/bin/bash\nexit 0\n' >"$2"
    chmod +x "$2"
    exit 0
  fi
  shift
done
exit 2
COMPILER
cat >"${bin_dir}/docker" <<'CONTAINER'
#!/bin/bash
set -euo pipefail
case "$1" in
  rm|ps) exit 0 ;;
  build) exit 0 ;;
  image) printf 'sha256:%064d\n' 0 ;;
  run)
    for arg in "$@"; do
      case "$arg" in
        res://tests/*_test.tscn)
          name="${arg##*/}"
          printf '%s\n' "${name%.tscn}" >>"${REQUIRED_REGRESSION_RUN_LOG}"
          ;;
      esac
    done
    printf 'TEST PASS -- benign contained fixture\n'
    ;;

  *) exit 2 ;;
esac
CONTAINER
chmod +x "${bin_dir}/go" "${bin_dir}/docker"
: >"${run_log}"
: >"${REQUIRED_REGRESSION_LEGACY_LOG}"
if ! PATH="${bin_dir}:${PATH}" REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
  /bin/bash "${workflow_source}/tools/run-sandboxed-trusted-regressions.sh" "${trusted}" "${candidate}" \
  >"${control_output}" 2>&1; then
  fail "workflow-source launcher did not evaluate base-owned data: $(<"${control_output}")"
fi
if [ "$(<"${run_log}")" != $'alpha_test\nbeta_test' ]; then
  fail 'launcher did not execute both scenes through workflow-source host helpers'
fi
if [ -s "${REQUIRED_REGRESSION_LEGACY_LOG}" ]; then
  fail 'launcher executed a historical base host helper'
fi
rm "${bin_dir}/go" "${bin_dir}/docker"
cp "${tmp_dir}/fixture-runner" "${workflow_source}/tools/run-client-test.sh"

# Missing inputs and import failures refuse before any trusted scene can run.
for broken in project trusted_project trusted_project_link runner import; do
	: >"${run_log}"
	case "$broken" in
	project) mv "${candidate}/client/project.godot" "${tmp_dir}/project.godot" ;;
	trusted_project) mv "${trusted}/client/project.godot" "${tmp_dir}/trusted-project.godot" ;;
	trusted_project_link) mv "${trusted}/client/project.godot" "${tmp_dir}/trusted-project.godot"; ln -s "${tmp_dir}/trusted-project.godot" "${trusted}/client/project.godot" ;;
	runner) chmod -x "${workflow_source}/tools/run-client-test.sh" ;;
	import) printf '#!/bin/bash\necho "ERROR: deliberate import failure"\nexit 1\n' >"${bin_dir}/godot" ;;
	esac
	if PATH="${bin_dir}:${PATH}" REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		/bin/bash "${control}" "${trusted}" "${candidate}" >"${control_output}" 2>&1; then
		fail "missing $broken input or failed import was accepted"
	fi
	[ ! -s "${run_log}" ] || fail "$broken refusal executed a regression scene"
	case "$broken" in
	project) mv "${tmp_dir}/project.godot" "${candidate}/client/project.godot" ;;
	trusted_project) mv "${tmp_dir}/trusted-project.godot" "${trusted}/client/project.godot" ;;
	trusted_project_link) rm "${trusted}/client/project.godot"; mv "${tmp_dir}/trusted-project.godot" "${trusted}/client/project.godot" ;;
	runner) chmod +x "${workflow_source}/tools/run-client-test.sh" ;;
	import) cp "${tmp_dir}/godot-import-stub" "${bin_dir}/godot" ;;
	esac
done

# Unsupported startup configuration is refused before importing candidate code.
for setting in autoload editor_plugins override symlink binary binary_link; do
  cp "${candidate}/client/project.godot" "${tmp_dir}/clean-project"
  case "$setting" in
    autoload) printf '\n[autoload]\n' >>"${candidate}/client/project.godot" ;;
    editor_plugins) printf '\n[editor_plugins]\n' >>"${candidate}/client/project.godot" ;;
    override) printf '[application]\n' >"${candidate}/client/override.cfg" ;;
    symlink) rm "${candidate}/client/project.godot"; ln -s "${tmp_dir}/clean-project" "${candidate}/client/project.godot" ;;
    binary) printf 'unsupported binary configuration\n' >"${candidate}/client/project.binary" ;;
    binary_link) ln -s nonexistent "${candidate}/client/project.binary" ;;
  esac
  : >"${run_log}.import"
  if PATH="${bin_dir}:${PATH}" REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
    /bin/bash "${control}" "${trusted}" "${candidate}" >"${control_output}" 2>&1; then
    fail "accepted unsupported startup configuration: $setting"
  elif ! grep -q 'startup configuration' "${control_output}"; then
    fail "startup refusal was not explicit: $setting"
  fi
  [ ! -s "${run_log}.import" ] || fail "imported unsupported configuration: $setting"
  rm -f "${candidate}/client/project.godot" "${candidate}/client/override.cfg" "${candidate}/client/project.binary"
  cp "${tmp_dir}/clean-project" "${candidate}/client/project.godot"
done

# Only the planned capability declaration is candidate input. A candidate
# cannot change trusted history or hide that its writer has advanced.
ledger="${candidate}/client/tests/data/shipped_save_capability.txt"
base_ledger="${trusted}/client/tests/data/shipped_save_capability.txt"
# Check declaration acceptance, the installed capability, and refusal before import.
run_capability_case() {
	local label="$1" want="$2" capability="$3"
	: >"${run_log}"
	: >"${run_log}.import"
	if PATH="${bin_dir}:${PATH}" REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		REQUIRED_REGRESSION_CAPABILITY="${capability}" \
		/bin/bash "${control}" "${trusted}" "${candidate}" >"${control_output}" 2>&1; then
		[ "${want}" = pass ] || fail "${label}: invalid capability history passed"
	else
		if [ "${want}" = pass ]; then
			fail "${label}: valid declaration refused: $(<"${control_output}")"
		elif ! grep -q 'save-capability declaration' "${control_output}"; then
			fail "${label}: refused for an unrelated reason: $(<"${control_output}")"
		fi
	fi
	if [ "${want}" = pass ] && [ ! -s "${run_log}.import" ]; then
		fail "${label}: passing candidate did not record its import"
	fi
	if [ "${want}" = fail ] && { [ -s "${run_log}" ] || [ -s "${run_log}.import" ]; }; then
		fail "${label}: candidate ran before declaration validation"
	fi
}

printf '7\n' >>"${ledger}"
run_capability_case 'single planned append' pass 7
printf '8\n' >>"${ledger}"
run_capability_case 'unreviewed capability 8' fail 8
cp "${base_ledger}" "${ledger}"
printf '8\n' >>"${ledger}"
run_capability_case 'missing capability 7' fail 8
cp "${base_ledger}" "${ledger}"
printf '7\n7\n' >>"${ledger}"
run_capability_case 'duplicate append' fail 7
cp "${base_ledger}" "${ledger}"
printf '# unreviewed suffix\n7\n' >>"${ledger}"
run_capability_case 'unexpected declaration bytes' fail 7
sed 's/historical/rewritten/' "${base_ledger}" >"${ledger}"
run_capability_case 'edited historical comment' fail 6
sed '/^3$/d' "${base_ledger}" >"${ledger}"
run_capability_case 'deleted historical capability' fail 6
cp "${base_ledger}" "${ledger}"
printf '7' >>"${ledger}"
run_capability_case 'unterminated append' fail 7
rm "${ledger}"
run_capability_case 'missing declaration' fail 6
ln -s "${base_ledger}" "${ledger}"
run_capability_case 'symlinked declaration' fail 6
rm "${ledger}"
cp "${base_ledger}" "${ledger}"
mv "${candidate}/client/tests/data" "${candidate}/candidate-data"
ln -s "${candidate}/candidate-data" "${candidate}/client/tests/data"
run_capability_case 'symlinked declaration directory' fail 6
rm "${candidate}/client/tests/data"
mv "${candidate}/candidate-data" "${candidate}/client/tests/data"
run_capability_case 'unchanged reader stage' pass 6
printf '7\n' >>"${base_ledger}"
cp "${base_ledger}" "${ledger}"
run_capability_case 'unchanged future writer stage' pass 7
sed '/^7$/d' "${base_ledger}" >"${ledger}"
run_capability_case 'rollback after capability 7 ships' fail 6
cp "${base_ledger}" "${ledger}"
printf '8\n' >>"${ledger}"
run_capability_case 'new append after capability 7 ships' fail 8
cp "${base_ledger}" "${ledger}"
mv "${base_ledger}" "${tmp_dir}/trusted-ledger"
run_capability_case 'missing trusted declaration' fail 7
ln -s "${tmp_dir}/trusted-ledger" "${base_ledger}"
run_capability_case 'symlinked trusted declaration' fail 7
rm "${base_ledger}"
cp "${tmp_dir}/trusted-ledger" "${base_ledger}"
printf '8\n' >>"${base_ledger}"
cp "${base_ledger}" "${ledger}"
run_capability_case 'unsupported trusted ceiling' fail 8
sed '/^3$/d' "${tmp_dir}/trusted-ledger" >"${base_ledger}"
cp "${base_ledger}" "${ledger}"
run_capability_case 'malformed trusted history' fail 7
printf '# historical declaration\n1\n2\n3\n4\n5\n6' >"${base_ledger}"
cp "${base_ledger}" "${ledger}"
run_capability_case 'unterminated trusted history' fail 6

# Only the exact reviewed recipe plan may accompany the next reader.
recipe_ledger="${candidate}/client/tests/data/shipped_recipe_versions.txt"
base_recipe_ledger="${trusted}/client/tests/data/shipped_recipe_versions.txt"
planned_recipe="${trusted}/client/tests/data/planned_recipe_v5.json"
golden_recipe="${candidate}/client/tests/data/golden_recipe_v5.json"
run_recipe_case() {
	local label="$1" want="$2" version="$3"
	: >"${run_log}"
	: >"${run_log}.import"
	if PATH="${bin_dir}:${PATH}" REQUIRED_REGRESSION_RUN_LOG="${run_log}" \
		REQUIRED_REGRESSION_CAPABILITY=7 REQUIRED_REGRESSION_RECIPE_VERSION="${version}" \
		/bin/bash "${control}" "${trusted}" "${candidate}" >"${control_output}" 2>&1; then
		[ "${want}" = pass ] || fail "${label}: invalid recipe declaration passed"
	else
		if [ "${want}" = pass ]; then
			fail "${label}: approved recipe declaration refused: $(<"${control_output}")"
		elif ! grep -q 'recipe declaration' "${control_output}"; then
			fail "${label}: refused for an unrelated reason: $(<"${control_output}")"
		fi
	fi
	if [ "${want}" = pass ]; then
		[ -s "${run_log}.import" ] || fail "${label}: passing candidate did not record its import"
		[ "$(<"${run_log}")" = "${expected_runs}" ] || fail "${label}: passing candidate did not execute the exact trusted scenes"
	fi
	if [ "${want}" = fail ] && { [ -s "${run_log}" ] || [ -s "${run_log}.import" ]; }; then
		fail "${label}: candidate ran before recipe validation"
	fi
}
cp "${tmp_dir}/trusted-ledger" "${base_ledger}"
cp "${base_ledger}" "${ledger}"
run_recipe_case 'unchanged recipe4' pass 4
printf '5\n' >>"${recipe_ledger}"
cp "${planned_recipe}" "${golden_recipe}"
run_recipe_case 'exact planned recipe5' pass 5
printf '6\n' >>"${recipe_ledger}"
run_recipe_case 'unplanned recipe6' fail 6
cp "${base_recipe_ledger}" "${recipe_ledger}"
printf '5\n' >>"${recipe_ledger}"
printf '{"version":5,"joint_push":{"thigh":1.99}}\n' >"${golden_recipe}"
run_recipe_case 'changed planned fixture' fail 5
rm "${golden_recipe}"
run_recipe_case 'missing planned fixture' fail 5
ln -s "${planned_recipe}" "${golden_recipe}"
run_recipe_case 'symlinked planned fixture' fail 5
rm "${golden_recipe}"
cp "${planned_recipe}" "${golden_recipe}"
sed 's/history/rewritten/' "${base_recipe_ledger}" >"${recipe_ledger}"
printf '5\n' >>"${recipe_ledger}"
run_recipe_case 'rewritten recipe history' fail 5
cp "${base_recipe_ledger}" "${recipe_ledger}"
run_recipe_case 'fixture5 without declaration' fail 4
rm "${golden_recipe}"
rm "${recipe_ledger}"
run_recipe_case 'missing recipe declaration' fail 4
ln -s "${base_recipe_ledger}" "${recipe_ledger}"
run_recipe_case 'symlinked recipe declaration' fail 4
rm "${recipe_ledger}"
cp "${base_recipe_ledger}" "${recipe_ledger}"
printf '5\n' >>"${base_recipe_ledger}"
cp "${planned_recipe}" "${trusted}/client/tests/data/golden_recipe_v5.json"
cp "${base_recipe_ledger}" "${recipe_ledger}"
cp "${planned_recipe}" "${golden_recipe}"
run_recipe_case 'unchanged shipped recipe5' pass 5
sed '/^5$/d' "${base_recipe_ledger}" >"${recipe_ledger}"
run_recipe_case 'recipe rollback after5 ships' fail 4
cp "${base_recipe_ledger}" "${recipe_ledger}"
printf '6\n' >>"${recipe_ledger}"
run_recipe_case 'append after recipe5 ships' fail 6

workflow_fixture_dir="${tmp_dir}/workflow-fixture"
mkdir -p "${workflow_fixture_dir}"
printf '%s\n' 'run: trusted/tools/required-regression-control.sh trusted candidate' \
	>"${workflow_fixture_dir}/renamed-gate.yaml"
if ! find_local_controller_workflows "${workflow_fixture_dir}" |
	grep -Fq 'renamed-gate.yaml'; then
	fail "a renamed candidate-repository workflow can evade the source guard"
fi

local_workflows="$(find_local_controller_workflows "${repo_root}/.github/workflows")"
if [ "${local_workflows}" != $'repository-trusted-regressions.yaml\ntrusted-regressions.yaml' ]; then
	fail "only the base-owned product workflow may invoke the controller: ${local_workflows}"
elif ! bash "${repo_root}/tools/trusted-regression-workflow-guard.sh"; then
	fail "the product workflow does not preserve the base-owned controller boundary"
elif ! bash "${repo_root}/tools/repository-trusted-gate-workflow-guard.sh"; then
	fail "the repository publisher workflow does not preserve the independent credential boundary"
fi

external_workflow='.github/workflows/world-at-ruin-required-regressions.yaml'
for contract in "${repo_root}/AGENTS.md" \
	"${repo_root}/docs/adr/0003-pin-required-regressions-outside-candidate-control.md"; do
	if ! grep -Fq 'devantler-tech/.github/.github/workflows/world-at-ruin-required-regressions.yaml' "${contract}" ||
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
