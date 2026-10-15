#!/usr/bin/env bash
# Exercise the actual builder's offline proof boundary before any Docker call.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
fixture="$state/recipe"
mkdir -p "$fixture/.github/containers" "$fixture/tools/trusted-runtime-bases" "$state/bin"
for file in build-trusted-regression-runtime.sh build-locked-trusted-runtime.sh \
  capture-trusted-runtime-inventory.sh trusted-regression-lifecycle.sh \
  trusted-regression-phase.sh trusted-phase-command.sh process-group-lifecycle.sh; do
  cp "$root/tools/$file" "$fixture/tools/$file"
done
cp "$root/tools/trusted-runtime-bases/main.go" "$fixture/tools/trusted-runtime-bases/main.go"
cp "$root/.github/containers/"trusted-runtime-bases.*.json "$fixture/.github/containers/"
cp "$root/.github/containers/trusted-regressions.Dockerfile" "$fixture/.github/containers/"
cat > "$state/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRACE"
case "$1 $2" in
  'build --pull')
    [[ "$*" = *'--platform linux/amd64'* ]]
    [[ "$*" = *'--build-arg WAR_RUNTIME_INVENTORY=0'* ]];;
  'image inspect') printf 'sha256:%064d\n' 1;;
  *) exit 91;;
esac
DOCKER
printf '#!/bin/sh\nexit 0\n' > "$state/bin/godot"
chmod +x "$state/bin/docker" "$state/bin/godot"
export PATH="$state/bin:$PATH" TRACE="$state/trace"
bash "$fixture/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"
grep -qx 'sha256:0000000000000000000000000000000000000000000000000000000000000001' "$state/out"
test "$(wc -l < "$TRACE" | tr -d ' ')" = 2
test "$(grep -c '^TRUSTED_RUNTIME_BASE .* linux/amd64 manifest=sha256:' "$state/report")" = 2
for refusal in missing-lock partial-lock altered-index stale-dockerfile; do
  cp "$root/.github/containers/trusted-runtime-bases.lock.json" "$fixture/.github/containers/"
  cp "$root/.github/containers/trusted-regressions.Dockerfile" "$fixture/.github/containers/"
  lock="$fixture/.github/containers/trusted-runtime-bases.lock.json"
  case "$refusal" in
    missing-lock) rm "$lock";;
    partial-lock) printf '{"schema":1,"proofs":[' > "$lock";;
    altered-index)
      jq '.proofs[0].index="e30="' "$lock" > "$state/changed"
      mv "$state/changed" "$lock";;
    stale-dockerfile) printf '\nFROM ubuntu:24.04\n' >> "$fixture/.github/containers/trusted-regressions.Dockerfile";;
  esac
  : > "$TRACE"
  if bash "$fixture/tools/build-trusted-regression-runtime.sh" > "$state/out" 2> "$state/report"; then
    echo "accepted $refusal before Docker" >&2; exit 1
  fi
  test ! -s "$TRACE"
  test ! -s "$state/out"
  grep -q 'trusted runtime bases:' "$state/report"
done
echo 'trusted runtime base proof, platform selection and pre-Docker refusal controls passed'
