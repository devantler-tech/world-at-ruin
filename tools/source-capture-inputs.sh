#!/usr/bin/env bash
# Validate the source/flag boundary before installation, import or capture.
set -euo pipefail
fail() {
  echo "::error::source capture: $*" >&2
  exit 1
}
case ${CAPTURE_GROUP:-} in world | activity) ;; *) fail 'unknown capture group' ;; esac
case ${FIRST_RUN:-} in true | false) ;; *) fail 'invalid first-run decision' ;; esac
case ${GPU_GATED:-} in true | false) ;; *) fail 'invalid GPU decision' ;; esac
[[ ${VISUAL:-} == true ]] || fail 'source capture requires a selected visual change'
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'invalid integration source'
actual=$(git --no-replace-objects rev-parse --verify HEAD) || fail 'checkout unavailable'
[[ $actual == "$GITHUB_SHA" ]] || fail 'checkout differs from the integration source'
loaded="${GITHUB_ACTION_PATH:-}/action.yaml"
candidate=.github/actions/capture-source/action.yaml
[[ -n ${GITHUB_ACTION_PATH:-} && -f $loaded && ! -L $loaded && -f $candidate && ! -L $candidate ]] || fail 'loaded action metadata unavailable'
cmp -s "$loaded" "$candidate" || fail 'pinned action differs from the candidate action'
[[ ${RUNNER_TEMP:-} == /* && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP ]] || fail 'runner temporary directory unavailable'
shots="$RUNNER_TEMP/shots"
[[ ! -e $shots && ! -L $shots ]] || fail 'evidence directory already exists'
mkdir "$shots"
