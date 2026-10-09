#!/usr/bin/env bash
# Execute the regression suite from a trusted workflow snapshot against a
# candidate checkout. The candidate supplies product code; it never supplies
# the selector, test harness, historical fixtures, or verdict runner. The
# candidate declarations are reconstructed from reviewed capability/recipe history.
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "::error::usage: tools/required-regression-control.sh <trusted-root> <candidate-root>" >&2
	exit 2
fi

trusted_root="$(cd "$1" 2>/dev/null && pwd -P)" || {
	echo "::error::trusted workflow snapshot is not a readable directory" >&2
	exit 2
}
candidate_root="$(cd "$2" 2>/dev/null && pwd -P)" || {
	echo "::error::candidate checkout is not a readable directory" >&2
	exit 2
}
trusted_tests="${trusted_root}/client/tests"
# Host helpers belong to this reviewed controller snapshot; the base owns data.
control_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_runner="${control_dir}/run-client-test.sh"
trusted_project="${trusted_root}/client/project.godot"
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$control_dir/trusted-regression-lifecycle.sh"

if [ ! -d "${trusted_tests}" ] || [ -L "${trusted_tests}" ]; then
	echo "::error::trusted regression directory is missing or symlinked: ${trusted_tests}" >&2
	exit 2
fi
if [ ! -x "${trusted_runner}" ] || [ -L "${trusted_runner}" ]; then
	echo "::error::trusted client-test runner is missing, non-executable, or symlinked" >&2
	exit 2
fi
if [ ! -d "${trusted_root}/client" ] || [ -L "${trusted_root}/client" ] ||
	[ ! -f "${trusted_project}" ] || [ ! -r "${trusted_project}" ] || [ -L "${trusted_project}" ]; then
	echo '::error::trusted project configuration is missing, unreadable, or symlinked' >&2
	exit 2
fi
if [ ! -d "${candidate_root}/client" ] || [ -L "${candidate_root}/client" ]; then
	echo "::error::candidate client project is missing or symlinked" >&2
	exit 2
fi
if [ ! -f "${candidate_root}/client/project.godot" ]; then
	echo "::error::candidate client/project.godot is missing" >&2
	exit 2
fi
# Tests run as explicit scenes; candidate startup hooks cannot select that surface.
if [ -L "${candidate_root}/client/project.godot" ] ||
  [ -e "${candidate_root}/client/override.cfg" ] || [ -L "${candidate_root}/client/override.cfg" ] ||
  [ -e "${candidate_root}/client/project.binary" ] || [ -L "${candidate_root}/client/project.binary" ] ||
  grep -Eq '^[[:space:]]*\[(autoload|editor_plugins)\][[:space:]]*(;.*)?$' "${candidate_root}/client/project.godot"; then
  echo '::error::unsupported candidate startup configuration for explicit trusted scenes' >&2
  exit 1
fi
if ! command -v godot >/dev/null 2>&1; then
	echo "::error::trusted regressions could not execute: godot was not found in PATH" >&2
	exit 2
fi

LC_ALL=C
export LC_ALL
shopt -s nullglob
trusted_scenes=("${trusted_tests}"/*_test.tscn)
if [ "${#trusted_scenes[@]}" -eq 0 ]; then
	echo "::error::no trusted regression test scenes found under client/tests/*_test.tscn" >&2
	exit 1
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/required-regression-control.XXXXXX")"
evaluation_root="${scratch_root}/candidate"
host_logs="${scratch_root}/logs"
# Remove only this invocation's private evaluation tree and reconstructed ledger.
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  result=$?
  trap - EXIT INT TERM
  trusted_stop_child
  if [ -n "${GODOT_SANDBOX_CONTAINERS:-}" ] && ! bash "$control_dir/trusted-regression-phase.sh" "sandbox cleanup" bash "$control_dir/trusted-regression-phase.sh" --cleanup-containers "$GODOT_SANDBOX_CONTAINERS"; then
    result=1
  fi
  rm -rf "$scratch_root"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Host output never follows a path supplied by the copied candidate.
mkdir "${evaluation_root}" "${host_logs}"

# Accept only the already shipped declaration or the one planned mastery
# activation. Construct the permitted bytes ourselves: candidate comments,
# rewritten history and future capabilities cannot redefine the contract.
ledger_path='client/tests/data/shipped_save_capability.txt'
for root in "${trusted_root}" "${candidate_root}"; do
	for path in client/tests client/tests/data "${ledger_path}"; do
		if [ -L "${root}/${path}" ]; then
			echo "::error::save-capability declaration has a symlinked path" >&2
			exit 1
		fi
	done
	if [ ! -f "${root}/${ledger_path}" ]; then
		echo "::error::save-capability declaration is missing" >&2
		exit 1
	fi
done
# A later append must start a new record, never concatenate onto the old ceiling.
if [ "$(tail -c 1 "${trusted_root}/${ledger_path}" | wc -l)" -ne 1 ]; then
	echo "::error::trusted save-capability declaration lacks its final newline" >&2
	exit 1
fi
trusted_capability="$(awk '
	/^#/ || /^$/ { next }
	!/^[1-9][0-9]*$/ || $0 != ++capability { invalid = 1; exit }
	END {
		if (invalid || (capability != 6 && capability != 7)) exit 1
		print capability
	}
' "${trusted_root}/${ledger_path}")" || {
	echo "::error::trusted save-capability declaration is malformed or unsupported" >&2
	exit 1
}
validated_ledger="${scratch_root}/validated-capability.txt"
cp "${trusted_root}/${ledger_path}" "${validated_ledger}"
if ! cmp -s "${candidate_root}/${ledger_path}" "${validated_ledger}"; then
	if [ "${trusted_capability}" != 6 ]; then
		echo "::error::save-capability declaration differs from shipped history" >&2
		exit 1
	fi
	printf '7\n' >>"${validated_ledger}"
	if ! cmp -s "${candidate_root}/${ledger_path}" "${validated_ledger}"; then
		echo "::error::save-capability declaration must preserve history and append only capability 7" >&2
		exit 1
	fi
fi

# The stature expansion is one reviewed schema declaration, never arbitrary
# candidate test data. Future golden bytes come exclusively from the base plan.
recipe_ledger_path='client/tests/data/shipped_recipe_versions.txt'
recipe_fixture_path='client/tests/data/golden_recipe_v5.json'
planned_fixture_path='client/tests/data/planned_recipe_v5.json'
for root in "${trusted_root}" "${candidate_root}"; do
	if [ -L "${root}/${recipe_ledger_path}" ] || [ ! -f "${root}/${recipe_ledger_path}" ]; then
		echo '::error::recipe declaration is missing or symlinked' >&2
		exit 1
	fi
done
if [ "$(tail -c 1 "${trusted_root}/${recipe_ledger_path}" | wc -l)" -ne 1 ]; then
	echo '::error::trusted recipe declaration lacks its final newline' >&2
	exit 1
fi
trusted_recipe="$(awk '
	/^#/ || /^$/ { next }
	!/^[1-9][0-9]*$/ || $0 != ++version { invalid = 1; exit }
	END {
		if (invalid || (version != 4 && version != 5)) exit 1
		print version
	}
' "${trusted_root}/${recipe_ledger_path}")" || {
	echo '::error::trusted recipe declaration is malformed or unsupported' >&2
	exit 1
}
validated_recipe="${scratch_root}/validated-recipe.txt"
validated_fixture="${scratch_root}/validated-recipe-v5.json"
cp "${trusted_root}/${recipe_ledger_path}" "${validated_recipe}"
candidate_recipe="${trusted_recipe}"
if ! cmp -s "${candidate_root}/${recipe_ledger_path}" "${validated_recipe}"; then
	if [ "${trusted_recipe}" != 4 ]; then
		echo '::error::recipe declaration differs from shipped history' >&2
		exit 1
	fi
	printf '5\n' >>"${validated_recipe}"
	if ! cmp -s "${candidate_root}/${recipe_ledger_path}" "${validated_recipe}"; then
		echo '::error::recipe declaration must preserve history and append only recipe5' >&2
		exit 1
	fi
	candidate_recipe=5
fi
if [ "${candidate_recipe}" = 5 ]; then
	fixture_source="${trusted_root}/${recipe_fixture_path}"
	if [ "${trusted_recipe}" = 4 ]; then
		fixture_source="${trusted_root}/${planned_fixture_path}"
	fi
	if [ -L "${fixture_source}" ] || [ ! -f "${fixture_source}" ] ||
		[ -L "${candidate_root}/${recipe_fixture_path}" ] ||
		[ ! -f "${candidate_root}/${recipe_fixture_path}" ] ||
		! cmp -s "${fixture_source}" "${candidate_root}/${recipe_fixture_path}"; then
		echo '::error::recipe declaration needs the exact trusted recipe5 fixture' >&2
		exit 1
	fi
	cp "${fixture_source}" "${validated_fixture}"
elif [ -e "${candidate_root}/${recipe_fixture_path}" ] || [ -L "${candidate_root}/${recipe_fixture_path}" ]; then
	echo '::error::recipe declaration does not permit a recipe5 fixture' >&2
	exit 1
fi

# Do not mutate the checkout Actions produced. Copy only tracked-worktree
# content (never its .git directory), then replace the candidate-controlled
# harness wholesale with the snapshot that contains this workflow.
if ! (
	cd "${candidate_root}"
	tar --exclude='./.git' --exclude='.git' -cf - .
) | (
	cd "${evaluation_root}"
	tar -xf -
); then
	echo "::error::candidate checkout could not be copied into the isolated evaluation root" >&2
	exit 2
fi

rm -rf -- "${evaluation_root}/client/tests"
cp -R "${trusted_tests}" "${evaluation_root}/client/tests"
# Frozen scenes also require base-owned engine settings. Candidate startup
# settings remain covered by ordinary CI, not this protected baseline suite.
cp "${trusted_project}" "${evaluation_root}/client/project.godot"
cp "${validated_ledger}" "${evaluation_root}/${ledger_path}"
rm "${validated_ledger}"
cp "${validated_recipe}" "${evaluation_root}/${recipe_ledger_path}"
if [ "${candidate_recipe}" = 5 ]; then
	cp "${validated_fixture}" "${evaluation_root}/${recipe_fixture_path}"
fi

cd "$evaluation_root"
if ! trusted_wait bash "$control_dir/trusted-regression-phase.sh" "editor import" godot --headless --editor --quit --path client >"$host_logs/import.log" 2>&1; then
  cat "$host_logs/import.log"
	echo "::error::candidate client failed the trusted headless import" >&2
	exit 1
fi
cat "$host_logs/import.log"
if grep -qE 'SCRIPT ERROR|^ERROR' "${host_logs}/import.log"; then
	echo "::error::candidate client reported errors during the trusted headless import" >&2
	exit 1
fi

ran=0
for scene in "${trusted_scenes[@]}"; do
	name="$(basename "${scene}" .tscn)"
	RUN_CLIENT_TEST_LOG_DIR="$host_logs" trusted_wait "$trusted_runner" "$name" "trusted required regression failed"
	ran=$((ran + 1))
done

printf 'Ran %d trusted regression test scene(s) from workflow snapshot %s.\n' \
	"${ran}" "${trusted_root}"
