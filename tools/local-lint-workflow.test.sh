#!/usr/bin/env bash
# Test the actual job supplied to Actions, not catalogue self-test call counts.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Admit only the complete, unconditional, read-only native lint job declared in $1.
check() {
  # shellcheck disable=SC2016 # GitHub expressions are literal configuration data.
  yq -o=json '.' "$1" | jq -e '
    ([.jobs["client-ordinary"].steps[] | select(.run? == "bash tools/local-lint-workflow.test.sh")] |
      length == 1 and (.[0] |
        (has("if") or has("continue-on-error") or has("shell") | not))) and
    (.jobs["ci-required-checks"].needs | index("lint")) != null and
    (.jobs.lint |
      (has("uses") | not) and ."runs-on" == "ubuntu-latest" and
      .permissions == {contents:"read"} and (has("secrets") | not) and
      (has("if") or has("continue-on-error") | not) and
      .concurrency["cancel-in-progress"] == true and
      ([.steps[] | select(.uses? | strings | startswith("actions/checkout@"))] |
        length == 1 and .[0].with["persist-credentials"] == false) and
      ([.steps[] | select(.uses? | strings | startswith("oxsecurity/megalinter/flavors/go@"))] |
        length == 1 and (.[0] |
          .uses == "oxsecurity/megalinter/flavors/go@9949bad031045f366be2467e00e8371a7328a2e2" and
          (has("if") or has("continue-on-error") | not) and
          .env.DEFAULT_WORKSPACE == "." and .env.VALIDATE_ALL_CODEBASE == true and
          .env.MEGALINTER_CONFIG == "${{ github.workspace }}/.mega-linter.yml" and
          .env.ACTION_ACTIONLINT_ARGUMENTS == "-ignore code-quality -ignore unexpected.key..queue..for..concurrency..section" and
          .env.APPLY_FIXES == "none" and .env.GOTOOLCHAIN == "local")) and
      ([.steps[] | (.env // {}) | keys[] | select(test("TOKEN|SECRET|PRIVATE_KEY"))] | length) == 0)
  ' >/dev/null
}

check "$root/.github/workflows/ci.yaml" || {
  echo 'FAIL: local lint must cover the complete repository without fixes or write credentials' >&2
  exit 1
}
for mutation in \
  'del(.jobs.lint)' \
  '.jobs.lint.permissions.contents = "write"' \
  '.jobs.lint.secrets.APP_PRIVATE_KEY = "secret"' \
  '.jobs.lint.if = "false"' \
  '.jobs.lint["continue-on-error"] = true' \
  '(.jobs.lint.steps[] | select(.env.APPLY_FIXES)).env.APPLY_FIXES = "all"' \
  '(.jobs.lint.steps[] | select(.env.DEFAULT_WORKSPACE)).env.DEFAULT_WORKSPACE = "server"' \
  '(.jobs.lint.steps[] | select(.env.MEGALINTER_CONFIG)).env.MEGALINTER_CONFIG = "server/.mega-linter.yml"' \
  '(.jobs.lint.steps[] | select(.env.APPLY_FIXES))["continue-on-error"] = true' \
  '(.jobs.lint.steps[] | select(.env.APPLY_FIXES)).if = "false"' \
  '(.jobs.lint.steps[] | select(.env.APPLY_FIXES)).env.ACTION_ACTIONLINT_ARGUMENTS = "-ignore .*"' \
  '.jobs["client-ordinary"].steps |= map(select(.run != "bash tools/local-lint-workflow.test.sh"))' \
  '(.jobs["client-ordinary"].steps[] | select(.run == "bash tools/local-lint-workflow.test.sh")).if = "false"' \
  '(.jobs["client-ordinary"].steps[] | select(.run == "bash tools/local-lint-workflow.test.sh"))["continue-on-error"] = true' \
  '(.jobs["client-ordinary"].steps[] | select(.run == "bash tools/local-lint-workflow.test.sh")).shell = "true {0}"' \
  '.jobs["ci-required-checks"].needs |= map(select(. != "lint"))'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" >"$scratch/workflow.yaml"
  if check "$scratch/workflow.yaml"; then
    echo "FAIL: accepted lint boundary mutation: $mutation" >&2
    exit 1
  fi
done
echo 'TEST PASS -- local lint retains scope, read-only credentials and required routing'
