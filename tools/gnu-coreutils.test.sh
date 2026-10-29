#!/usr/bin/env bash
# Exercise actual supervision with Rust defaults and explicitly qualified GNU tools.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
REAL_GNU_TIMEOUT="$(command -v gtimeout || command -v gnutimeout || command -v timeout)"
REAL_GNU_ENV="$(command -v genv || command -v gnuenv || command -v env)"
export REAL_GNU_TIMEOUT REAL_GNU_ENV
"$REAL_GNU_TIMEOUT" --version >"$scratch/timeout-version"
"$REAL_GNU_ENV" --version >"$scratch/env-version"
grep 'GNU coreutils' "$scratch/timeout-version" >/dev/null
grep 'GNU coreutils' "$scratch/env-version" >/dev/null
mkdir "$scratch/bin" "$scratch/records"
export GNU_PROVIDER_TRACE="$scratch/trace"
: >"$GNU_PROVIDER_TRACE"
# Qualify the whole invocation-private tool path; system fallbacks cannot mask a refusal.
for tool in timeout gnutimeout gtimeout env gnuenv genv; do
  cat >"$scratch/bin/$tool" <<'NON_GNU'
#!/bin/bash
if [ "$1" = --version ]; then printf 'uutils coreutils\n'; exit 0; fi
exit 91
NON_GNU
  chmod +x "$scratch/bin/$tool"
done
cat >"$scratch/gnu-timeout" <<'GNU_TIMEOUT'
#!/bin/bash
if [ "$1" = --version ]; then exec "$REAL_GNU_TIMEOUT" "$@"; fi
printf 'timeout %s\n' "$*" >>"$GNU_PROVIDER_TRACE"
exec "$REAL_GNU_TIMEOUT" "$@"
GNU_TIMEOUT
cat >"$scratch/gnu-env" <<'GNU_ENV'
#!/bin/bash
if [ "$1" = --version ]; then exec "$REAL_GNU_ENV" "$@"; fi
printf 'env %s\n' "$*" >>"$GNU_PROVIDER_TRACE"
exec "$REAL_GNU_ENV" "$@"
GNU_ENV
chmod +x "$scratch/gnu-timeout" "$scratch/gnu-env"
cp "$scratch/gnu-timeout" "$scratch/bin/gnutimeout"
cp "$scratch/gnu-env" "$scratch/bin/gnuenv"
status=0
PATH="$scratch/bin:$PATH" bash "$root/tools/trusted-regression-phase.sh" 'ordinary client step' bash -c 'exit 37' >"$scratch/log" 2>&1 || status=$?
if [ "$status" != 37 ]; then cat "$scratch/log" >&2; echo 'GNU-provider control: qualified Ubuntu tools did not preserve the child status' >&2; exit 1; fi
grep 'timeout --kill-after=' "$GNU_PROVIDER_TRACE" >/dev/null
grep 'env --default-signal=INT,TERM' "$GNU_PROVIDER_TRACE" >/dev/null
# The same qualified timeout owns cleanup; no Docker daemon is contacted.
cat >"$scratch/bin/docker" <<'DOCKER'
#!/bin/bash
case "$1" in rm|ps) exit 0;; *) exit 92;; esac
DOCKER
chmod +x "$scratch/bin/docker"
record="$scratch/records/war-trusted-0123456789abcdef0123456789abcdef"
printf owned >"$record"
PATH="$scratch/bin:$PATH" bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$scratch/records"
[ ! -e "$record" ]
grep 'timeout --kill-after=2s 5s docker ps' "$GNU_PROVIDER_TRACE" >/dev/null
# A GNU-looking banner is insufficient when the executable itself fails.
for tool in timeout gnutimeout gtimeout env gnuenv genv; do
  printf '#!/bin/bash\nprintf "GNU coreutils\\n"\nexit 7\n' >"$scratch/bin/$tool"
done
status=0
PATH="$scratch/bin:$PATH" bash "$root/tools/trusted-regression-phase.sh" 'ordinary client step' bash -c 'exit 0' >"$scratch/refusal" 2>&1 || status=$?
[ "$status" = 2 ]
grep 'GNU coreutils timeout is required' "$scratch/refusal" >/dev/null
status=0
PATH="$scratch/bin:$PATH" bash "$root/tools/trusted-phase-command.sh" "$scratch/verdict" bash -c 'exit 0' >"$scratch/env-refusal" 2>&1 || status=$?
[ "$status" = 2 ] && [ ! -e "$scratch/verdict" ]
grep 'requires GNU coreutils env' "$scratch/env-refusal" >/dev/null
printf 'TEST PASS -- GNU Ubuntu providers preserve status, signals and cleanup; failed probes refuse\n'
