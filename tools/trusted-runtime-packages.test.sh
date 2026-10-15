#!/usr/bin/env bash
# Exercise the container verifier with complete and failed dpkg observations.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
mkdir "$state/bin"
printf 'package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\npackage\tlibgl1\t1.7.0-1build1\tamd64\tinstalled\n' > "$state/expected"
cp "$state/expected" "$state/observed"
cat > "$state/bin/dpkg-query" <<'QUERY'
#!/usr/bin/env bash
cat "$OBSERVED"
test "${FAILED:-0}" = 0
QUERY
cat > "$state/bin/dpkg" <<'DPKG'
#!/usr/bin/env bash
printf '%s\n' "${ARCHITECTURE:-amd64}"
test "${ARCH_FAILED:-0}" = 0
DPKG
chmod +x "$state/bin/"*
export PATH="$state/bin:$PATH" OBSERVED="$state/observed"
verify="$root/tools/verify-trusted-runtime-packages.sh"
bash "$verify" "$state/expected" > "$state/result"
grep -qx 'TRUSTED_RUNTIME_PACKAGES verified=2 architecture=amd64' "$state/result"
refuse() {
  if bash "$verify" "$1" > "$state/result" 2>&1; then echo "accepted $2" >&2; exit 1; fi
  if grep -q '^TRUSTED_RUNTIME_PACKAGES verified=' "$state/result"; then echo 'emitted false success' >&2; exit 1; fi
}
for change in missing extra version architecture status duplicate; do
  case "$change" in
    missing) head -1 "$state/expected" > "$OBSERVED";;
    extra) cat "$state/expected" > "$OBSERVED"; printf 'package\tzlib1g\t1\tamd64\tinstalled\n' >> "$OBSERVED";;
    version) sed 's/13ubuntu10.3/99/' "$state/expected" > "$OBSERVED";;
    architecture) sed 's/amd64/arm64/g' "$state/expected" > "$OBSERVED";;
    status) sed 's/installed/unpacked/g' "$state/expected" > "$OBSERVED";;
    duplicate) cat "$state/expected" "$state/expected" > "$OBSERVED";;
  esac
  refuse "$state/expected" "$change"
done
cp "$state/expected" "$OBSERVED"
cat > "$state/bin/cmp" <<'COMPARE'
#!/usr/bin/env bash
echo 'fixture comparison could not complete' >&2
exit 2
COMPARE
chmod +x "$state/bin/cmp"
comparison_status=0
bash "$verify" "$state/expected" > "$state/result" 2>&1 || comparison_status=$?
test "$comparison_status" -eq 2
grep -qx 'trusted runtime package comparison could not complete' "$state/result"
if grep -Eq 'identities differ|^TRUSTED_RUNTIME_PACKAGES verified=' "$state/result"; then
  echo 'comparison error masqueraded as a completed comparison' >&2; exit 1
fi
rm "$state/bin/cmp"
export FAILED=1; refuse "$state/expected" 'plausible output followed by failure'; unset FAILED
export ARCH_FAILED=1; refuse "$state/expected" 'architecture output followed by failure'; unset ARCH_FAILED
export ARCHITECTURE=arm64; refuse "$state/expected" 'foreign architecture'; unset ARCHITECTURE
ln -s "$state/expected" "$state/linked"
refuse "$state/linked" 'linked lock'
: > "$state/empty"; refuse "$state/empty" 'empty lock'
refuse "$state/missing" 'missing lock'
echo 'TEST PASS -- complete package equality and failed-observation refusals'

# Drive the real native-probe wrapper and cleanup-name validation with a Docker fixture.
cat > "$state/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  run)
    echo 'trusted runtime installed package identities differ from the reviewed lock'
    exit "${DOCKER_STATUS:-1}";;
  rm|ps) exit 0;;
  *) exit 92;;
esac
DOCKER
chmod +x "$state/bin/docker"
mkdir -p "$state/native/containers"
bash "$root/tools/probe-trusted-runtime-package-refusal.sh" "sha256:$(printf '%064d' 1)" "$state/native" > "$state/native-result"
grep -q '^TEST PASS -- real runtime refuses changed package expectation' "$state/native-result"
test -z "$(ls -A "$state/native/containers")"
for status in 0 2 125; do
  mkdir -p "$state/native-$status/containers"
  if DOCKER_STATUS="$status" bash "$root/tools/probe-trusted-runtime-package-refusal.sh" "sha256:$(printf '%064d' 1)" "$state/native-$status" > "$state/native-result" 2>&1; then
    echo "native probe accepted Docker status $status" >&2; exit 1
  fi
done
echo 'TEST PASS -- native refusal requires exact failure and owned cleanup'
