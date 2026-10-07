#!/usr/bin/env bash
# Fetch public source data without sending workflow credentials to its transport.
set -euo pipefail
if [ "$#" -ne 2 ] || [[ ! "$2" =~ ^[0-9a-f]{40}$ ]]; then
  echo '::error::public data checkout needs a fixed target and exact commit' >&2
  exit 1
fi
target="$1"
identity="$2"
case "$target" in trusted|candidate) ;; *)
  echo '::error::public data checkout target is not admitted' >&2; exit 1 ;;
esac
if [ -e "$target" ] || [ -L "$target" ]; then
  echo '::error::public data checkout refuses an existing target' >&2
  exit 1
fi
# Run Git with only the reviewed path and explicit safe configuration inputs.
git_clean() {
  env -i PATH="$PATH" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false GIT_NO_REPLACE_OBJECTS=1 git "$@"
}
git_clean -c core.hooksPath=/dev/null init --quiet --template= "$target"
git_clean -C "$target" -c credential.helper= -c http.extraHeader= \
  -c protocol.allow=never -c protocol.https.allow=always \
  -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
  fetch --quiet --no-tags --depth=1 https://github.com/devantler-tech/world-at-ruin.git \
  "+$identity:refs/heads/verified-data"
git_clean -C "$target" -c core.hooksPath=/dev/null checkout --quiet --detach "$identity"
actual="$(git_clean -C "$target" rev-parse --verify HEAD)"
if [ "$actual" != "$identity" ]; then
  echo '::error::public data checkout identity does not match the event' >&2
  exit 1
fi
printf 'Verified anonymous %s checkout at %s\n' "$target" "$identity"
