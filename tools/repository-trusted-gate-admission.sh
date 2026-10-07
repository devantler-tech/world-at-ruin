#!/usr/bin/env bash
# Validate reviewed invocation/configuration before evaluating or minting a token.
# Naming an environment is not live proof of its deployment branch protection.
set -euo pipefail
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
case "${WAR_REPOSITORY_TRUSTED_GATE_ENABLED:-}" in
  ''|false)
    printf '%s\n' 'admitted=false' >>"$GITHUB_OUTPUT"
    exit 0
    ;;
  true) ;;
  *) echo '::error::repository trusted gate flag must be true, false or unset' >&2; exit 1 ;;
esac
source='devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main'
# The shared Actions App can also publish candidate-owned checks.
if [[ ! "${WAR_TRUSTED_GATE_APP_ID:-}" =~ ^[1-9][0-9]*$ ]] ||
  [[ "${WAR_TRUSTED_GATE_APP_ID:-}" == 15368 ]] ||
  [[ "${WAR_TRUSTED_GATE_PUBLISHER_ENVIRONMENT:-}" != world-trusted-gate-publisher ]] ||
  [[ "${GITHUB_REPOSITORY:-}" != devantler-tech/world-at-ruin ]] ||
  [[ "${GITHUB_EVENT_NAME:-}" != workflow_run ]] ||
  [[ "${GITHUB_REF:-}" != refs/heads/main ]] ||
  [[ "${GITHUB_WORKFLOW_REF:-}" != "$source" ]] ||
  [[ ! "${GITHUB_WORKFLOW_SHA:-}" =~ ^[0-9a-f]{40}$ ]] ||
  [[ ! -f "${GITHUB_EVENT_PATH:-}" ]]; then
  echo '::error::enabled repository trusted gate requires reviewed main and canonical publisher configuration' >&2
  exit 1
fi
if ! jq -e '
  .action == "completed"
  and .repository.full_name == "devantler-tech/world-at-ruin"
  and .repository.default_branch == "main"
  and .workflow_run.name == "CI"
  and .workflow_run.path == ".github/workflows/ci.yaml"
  and .workflow_run.status == "completed"
  and (.workflow_run.event == "pull_request" or .workflow_run.event == "merge_group")
  and (.workflow_run.id | type == "number" and . > 0 and floor == .)
  and .workflow_run.repository.full_name == "devantler-tech/world-at-ruin"
' "$GITHUB_EVENT_PATH" >/dev/null; then
  echo '::error::repository trusted gate requires a canonical completed CI event' >&2
  exit 1
fi
printf '%s\n' 'admitted=true' >>"$GITHUB_OUTPUT"
