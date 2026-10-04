#!/usr/bin/env bash
# Check that public data checkout never uses ambient credentials or unsafe paths.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/tools/fetch-trusted-regression-data.sh"
[ -x "$helper" ] || { echo 'TEST FAIL -- anonymous data checkout helper is missing' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_git="$(command -v git)"
mkdir -p "$tmp/origin" "$tmp/bin" "$tmp/work"
git -C "$tmp/origin" init -q
git -C "$tmp/origin" config user.name fixture
git -C "$tmp/origin" config user.email fixture@example.invalid
printf 'public fixture bytes\n' > "$tmp/origin/product"
git -C "$tmp/origin" add product
git -C "$tmp/origin" -c commit.gpgsign=false commit -qm fixture
sha="$(git -C "$tmp/origin" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nREAL_GIT=%q\nFIXTURE_ORIGIN=%q\nFETCH_OBSERVATION=%q\nFETCH_REFUSE_FILE=%q\n' "$real_git" "$tmp/origin" "$tmp/fetches" "$tmp/refuse-fetch" > "$tmp/bin/git"
cat >> "$tmp/bin/git" <<'TRANSPORT'
set -euo pipefail
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[i]}" = fetch ]; then
    [ "${GITHUB_TOKEN+x}" != x ] && [ "${GH_TOKEN+x}" != x ] ||
      { echo 'credential environment reached public transport' >&2; exit 81; }
    [ "${GIT_CONFIG_COUNT+x}" != x ] && [ "${GIT_CONFIG_PARAMETERS+x}" != x ] ||
      { echo 'injected Git configuration reached public transport' >&2; exit 82; }
    [ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] && [ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ] ||
      { echo 'ambient Git configuration reached public transport' >&2; exit 83; }
    [ "${GIT_SSL_CERT+x}" != x ] && [ "${GIT_SSL_KEY+x}" != x ] && [ "${GIT_SSL_NO_VERIFY+x}" != x ] ||
      { echo 'ambient TLS input reached public transport' >&2; exit 86; }
    printf 'fetch\n' >> "$FETCH_OBSERVATION"
    [ ! -f "$FETCH_REFUSE_FILE" ] || exit 84
    found=no
    for ((j=i+1; j<${#args[@]}; j++)); do
      if [ "${args[j]}" = 'https://github.com/devantler-tech/world-at-ruin.git' ]; then
        args[j]="$FIXTURE_ORIGIN"
        found=yes
      fi
    done
    [ "$found" = yes ] || { echo 'noncanonical public repository requested' >&2; exit 85; }
    exec "$REAL_GIT" -c protocol.file.allow=always "${args[@]}"
  fi
done
exec "$REAL_GIT" "${args[@]}"
TRANSPORT
chmod +x "$tmp/bin/git"
FETCH_OBSERVATION="$tmp/fetches"
export PATH="$tmp/bin:$PATH"
export GITHUB_TOKEN=nonsecret-fixture GH_TOKEN=nonsecret-fixture
export GIT_SSL_CERT=not-a-certificate GIT_SSL_KEY=not-a-key GIT_SSL_NO_VERIFY=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=false
mkdir "$tmp/template"
printf 'ambient template bytes\n' > "$tmp/template/ambient-marker"
export GIT_TEMPLATE_DIR="$tmp/template"
cd "$tmp/work"
# Require refusal before any directory or transport side effect.
refuse() {
  local path="$1" identity="$2"
  : > "$FETCH_OBSERVATION"
  if bash "$helper" "$path" "$identity" > "$tmp/log" 2>&1; then
    echo "TEST FAIL -- unsafe checkout accepted: $path" >&2; exit 1
  fi
  [ ! -s "$FETCH_OBSERVATION" ] ||
    { echo 'TEST FAIL -- invalid checkout reached transport' >&2; exit 1; }
}
refuse candidate main
refuse candidate "$(printf '%040d' 0 | tr 0 A)"
refuse ../outside "$sha"
refuse workflow-source "$sha"
[ ! -e candidate ] && [ ! -e "$tmp/outside" ]
mkdir trusted
printf 'preserve\n' > trusted/existing
refuse trusted "$sha"
[ "$(cat trusted/existing)" = preserve ]
rm trusted/existing
rmdir trusted
ln -s "$tmp/origin" candidate
refuse candidate "$sha"
rm candidate
: > "$FETCH_OBSERVATION"
bash "$helper" candidate "$sha"
[ "$(git --no-replace-objects -C candidate rev-parse HEAD)" = "$sha" ]
[ "$(cat candidate/product)" = 'public fixture bytes' ]
[ ! -e candidate/.git/ambient-marker ] || { echo 'TEST FAIL -- ambient Git template was installed' >&2; exit 1; }
[ "$(cat "$FETCH_OBSERVATION")" = fetch ]
# A failed public fetch never yields a successful checkout or changes another tree.
: > "$tmp/refuse-fetch"
if bash "$helper" trusted "$sha" > "$tmp/log" 2>&1; then
  echo 'TEST FAIL -- failed public fetch passed' >&2; exit 1
fi
[ "$(cat candidate/product)" = 'public fixture bytes' ]
echo 'TEST PASS -- public checkout binds exact bytes and refuses credentials, paths and failed transport'
