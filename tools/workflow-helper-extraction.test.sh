#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/workflow-helper-extraction.sh
source "$root/tools/workflow-helper-extraction.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
workflow="$scratch/workflow"
cat > "$workflow" <<'BLOCKS'
outside must not be extracted
    # BEGIN first-helper
    first() { printf 'first\n'; }
    # END first-helper
unrelated bytes
    # BEGIN second-helper
    second() { printf 'second\n'; }
    # END second-helper
BLOCKS
cat > "$scratch/expected" <<'BLOCKS'
    # BEGIN second-helper
    second() { printf 'second\n'; }
    # END second-helper
    # BEGIN first-helper
    first() { printf 'first\n'; }
    # END first-helper
BLOCKS
output="$scratch/output"
extract_marked_workflow_helpers "$workflow" "$output" second-helper first-helper
cmp "$scratch/expected" "$output"
# Source at the caller scope, exactly as the real regression harnesses do.
# shellcheck source=/dev/null
source "$output"
[ "$(first)" = first ] && [ "$(second)" = second ]
if extract_marked_workflow_helpers "$workflow" "$output" absent; then
 echo 'workflow extraction: FAIL — missing block accepted' >&2; exit 1
fi
printf '# BEGIN broken\nbroken() {\n# END broken\n' > "$scratch/broken"
if extract_marked_workflow_helpers "$scratch/broken" "$output" broken; then
 echo 'workflow extraction: FAIL — invalid shell accepted' >&2; exit 1
fi
printf '# BEGIN truncated\ntrue\n' > "$scratch/truncated"
if extract_marked_workflow_helpers "$scratch/truncated" "$output" truncated; then
 echo 'workflow extraction: FAIL — unterminated block accepted' >&2; exit 1
fi
if extract_marked_workflow_helpers "$scratch/absent" "$output" first-helper; then
 echo 'workflow extraction: FAIL — unreadable workflow accepted' >&2; exit 1
fi
printf '# BEGIN duplicate\ntrue\n# END duplicate\n# BEGIN duplicate\nfalse\n# END duplicate\n' > "$scratch/duplicate"
if extract_marked_workflow_helpers "$scratch/duplicate" "$output" duplicate; then
 echo 'workflow extraction: FAIL — ambiguous blocks accepted' >&2; exit 1
fi
printf 'workflow extraction: PASS — exact bytes, requested order and refusal controls\n'
