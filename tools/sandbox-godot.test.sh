#!/usr/bin/env bash
# Pin containment arguments and propagate a failed candidate execution.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/client/tests"
mkdir -p "$tmp/work/server/wire" "$tmp/work/.github/workflows"
printf 'source data\n' >"$tmp/work/server/wire/wire.go"
printf 'source data\n' >"$tmp/work/.github/workflows/ci.yaml"
printf 'immutable trusted harness\n' >"$tmp/work/client/tests/alpha_test.gd"
cat >"$tmp/bin/docker" <<'DOCKER'
#!/bin/bash
printf '%s\n' "$@" > "$SANDBOX_ARGS"
exit "$SANDBOX_EXIT"
DOCKER
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/cache-guard"
chmod +x "$tmp/bin/docker" "$tmp/bin/cache-guard"
export GODOT_SANDBOX_CACHE_GUARD="$tmp/bin/cache-guard"
mkdir "$tmp/import-metadata"
export GODOT_SANDBOX_METADATA="$tmp/import-metadata"
printf 'source data\n' >"$tmp/frozen-frame.png"
export GODOT_SANDBOX_FRAME="$tmp/frozen-frame.png"
printf 'asset bytes\n' >"$tmp/work/client/icon.svg"
image="sha256:$(printf 'image identity' | sha256sum | cut -d' ' -f1)"
cd "$tmp/work"
export SANDBOX_ARGS="$tmp/args" SANDBOX_EXIT=0
export GODOT_SANDBOX_IMAGE="$image"
PATH="$tmp/bin:$PATH" bash "$root/tools/sandbox-godot.sh" --headless --editor --quit --path client >"$tmp/log"
for flag in --rm --network none --cap-drop ALL --security-opt no-new-privileges \
  --read-only --user --pids-limit 256 --memory 4g --cpus 2 --tmpfs \
  /tmp:rw,exec,nosuid,nodev,size=2g,mode=1777 --env HOME=/tmp XDG_CACHE_HOME=/tmp/cache \
  --workdir /project "$image" --headless --editor --quit --path client; do
  grep -Fxq -- "$flag" "$tmp/args"
done
grep -Fxq "type=bind,source=$PWD/client,target=/project/client,readonly" "$tmp/args"
grep -Fxq "type=bind,source=$PWD/server/wire/wire.go,target=/project/server/wire/wire.go,readonly" "$tmp/args"
grep -Fxq "type=bind,source=$PWD/.github/workflows/ci.yaml,target=/project/.github/workflows/ci.yaml,readonly" "$tmp/args"
test "$(grep -Fxc -- '--mount' "$tmp/args")" -eq 6
grep -Fxq "type=bind,source=$PWD/client/.godot,target=/project/client/.godot" "$tmp/args"
grep -Fxq "type=bind,source=$tmp/import-metadata/icon.svg.import,target=/project/client/icon.svg.import" "$tmp/args"
grep -Fxq "type=bind,source=$tmp/frozen-frame.png,target=/project/docs/phase-0/cave-chamber.png,readonly" "$tmp/args"
test "$(cat client/tests/alpha_test.gd)" = 'immutable trusted harness'
grep -Eq '^::stop-commands::[0-9a-f-]+$' "$tmp/log"
PATH="$tmp/bin:$PATH" bash "$root/tools/sandbox-godot.sh" --headless --path client >"$tmp/log"
grep -Fxq "type=bind,source=$PWD/client/.godot,target=/project/client/.godot,readonly" "$tmp/args"
grep -Fxq "type=bind,source=$tmp/import-metadata/icon.svg.import,target=/project/client/icon.svg.import,readonly" "$tmp/args"
export SANDBOX_EXIT=17
set +e
PATH="$tmp/bin:$PATH" bash "$root/tools/sandbox-godot.sh" --headless --path client >"$tmp/log"
status=$?
set -e
test "$status" -eq 17
grep -Eq '^::[0-9a-f-]+::$' "$tmp/log"
export SANDBOX_EXIT=0
rm -rf client/.godot
ln -s tests client/.godot
if PATH="$tmp/bin:$PATH" bash "$root/tools/sandbox-godot.sh" --headless --editor --quit --path client >"$tmp/log" 2>&1; then
  echo 'TEST FAIL -- a cache symlink escaped the read-only harness' >&2
  exit 1
fi
export GODOT_SANDBOX_IMAGE=latest
if PATH="$tmp/bin:$PATH" bash "$root/tools/sandbox-godot.sh" --headless --path client >"$tmp/log" 2>&1; then
  echo 'TEST FAIL -- a mutable runtime identity was accepted' >&2
  exit 1
fi
echo 'TEST PASS -- candidate execution is isolated and its failure is preserved'
