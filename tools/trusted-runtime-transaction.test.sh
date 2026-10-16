#!/usr/bin/env bash
# A real pre-install transaction observation must be selected in the owning recipe.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck disable=SC2016 # Match the literal Dockerfile variable.
if ! grep -Fq '&& bash /tmp/observe-runtime-transaction.sh "$WAR_RUNTIME_INVENTORY"' "$root/.github/containers/trusted-regressions.Dockerfile"; then
  echo "runtime does not collect the pre-install transaction" >&2
  exit 1
fi
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
mkdir "$state/bin" "$state/work" "$state/empty"
export TRANSACTION_TEST_STATE="$state"
printf 'good' > "$state/payload"
printf 'safe' > "$state/sentinel"
export TRANSACTION_TEST_HASH
TRANSACTION_TEST_HASH="$(shasum -a 256 "$state/payload")"
TRANSACTION_TEST_HASH=${TRANSACTION_TEST_HASH%% *}
export TRANSACTION_ORIGIN_INDEX="$state/origin_Packages"
export TRANSACTION_ORIGIN_RELEASE="$state/snapshot.ubuntu.com_dists_noble_InRelease"
export TRANSACTION_ORIGIN_INDEX_BASE="$state/origin_Packages.base"
printf 'Package: foo\nVersion: 1.0\nArchitecture: amd64\nFilename: test/foo.deb\nSize: 4\nSHA256: %s\n\n' "$TRANSACTION_TEST_HASH" > "$TRANSACTION_ORIGIN_INDEX_BASE"
cp "$TRANSACTION_ORIGIN_INDEX_BASE" "$TRANSACTION_ORIGIN_INDEX"
printf 'signed release\n' > "$TRANSACTION_ORIGIN_RELEASE"
GOTOOLCHAIN=local GOWORK=off go build -o "$state/origin-helper" "$root/tools/trusted-runtime-origin/main.go"
printf 'package\tapt\t2.8.3\tamd64\tinstalled\n' > "$state/before"
{ cat "$state/before"; printf 'package\tfoo\t1.0\tamd64\tinstalled\n'; } > "$state/expected"
sed -e "s|expected=/tmp/expected-packages.tsv|expected=$state/expected|" \
    -e "s|out=/usr/share/war-trusted-runtime/transaction.tsv|out=$state/report|" \
    -e "s|origin_helper=/tmp/trusted-runtime-origin|origin_helper=$state/origin-helper|" \
    "$root/tools/observe-runtime-transaction.sh" > "$state/observe.sh"
cat > "$state/bin/apt-get" <<'APT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRANSACTION_TEST_STATE/trace"
mode=${TRANSACTION_TEST_CASE:-good}
for argument in "$@"; do
  case "$argument" in Dir::Cache::archives=*) cache=${argument#*=};; esac
done
if [ "${1:-}" = indextargets ]; then
  rm -f "$TRANSACTION_ORIGIN_INDEX"
  cp "$TRANSACTION_ORIGIN_INDEX_BASE" "$TRANSACTION_ORIGIN_INDEX"
  release=$TRANSACTION_ORIGIN_RELEASE
  index=$TRANSACTION_ORIGIN_INDEX
  printf 'signed release\n' > "$release"
  trusted=yes
  repo=https://snapshot.ubuntu.com/
  case "$mode" in
    untrusted-target) trusted=no;;
    missing-inrelease) rm "$release";;
    linked-index) rm "$index"; ln -s "$TRANSACTION_ORIGIN_INDEX_BASE" "$index";;
    partial-stanza) sed '/^SHA256:/d' "$TRANSACTION_ORIGIN_INDEX_BASE" > "$index";;
    duplicate-field) sed "s/^SHA256:.*/&\nSHA256: $TRANSACTION_TEST_HASH/" "$TRANSACTION_ORIGIN_INDEX_BASE" > "$index";;
    origin-uri-mismatch) repo=https://snapshot.ubuntu.com/other/;;
    origin-tuple-mismatch) sed 's/^Version: 1.0$/Version: 2.0/' "$TRANSACTION_ORIGIN_INDEX_BASE" > "$index";;
    origin-digest-substitution) sed "s/^SHA256:.*/SHA256: $(printf '%064d' 2)/" "$TRANSACTION_ORIGIN_INDEX_BASE" > "$index";;
  esac
  row=$(printf '%s\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t%s\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\t%s\tnoble\tnoble\tUbuntu\tUbuntu' "$index" "$repo" "$trusted")
  printf '%s\n' "$row"
  if [ "$mode" = ambiguous-source ]; then printf '%s\n' "$row"; fi
  if [ "$mode" = conflicting-source ]; then
    other="$TRANSACTION_TEST_STATE/conflicting_Packages"
    sed "s/^SHA256:.*/SHA256: $(printf '%064d' 3)/" "$TRANSACTION_ORIGIN_INDEX_BASE" > "$other"
    printf '%s\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t%s\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tnoble\tnoble\tUbuntu\tUbuntu\n' "$other" "$repo"
  fi
  [ "$mode" != failed-target-reader ]
elif [[ "$*" = *--print-uris* ]]; then
  [[ "$*" = *'Acquire::ForceHash=sha256'* ]]
  case "$mode" in
    empty-plan) exit 0;; malformed-plan) echo 'unexpected progress'; exit 0;;
    oversized-plan) printf "'https://snapshot.ubuntu.com/test/foo.deb' foo.deb 67108865 SHA256:%s\n" "$TRANSACTION_TEST_HASH"; exit 0;;
    storage-budget)
      for n in 1 2 3 4 5; do printf "'https://snapshot.ubuntu.com/test/foo%s.deb' foo%s.deb 67108864 SHA256:%s\n" "$n" "$n" "$TRANSACTION_TEST_HASH"; done
      exit 0;;
  esac
  uri=https://snapshot.ubuntu.com/test/foo.deb
  if [ "$mode" = credential-uri ]; then uri=https://user@snapshot.ubuntu.com/test/foo.deb; fi
  row="'$uri' foo.deb 4 SHA256:$TRANSACTION_TEST_HASH"
  if [ "$mode" = unterminated-plan ]; then printf '%s' "$row"; else printf '%s\n' "$row"; fi
  if [ "$mode" = duplicate-plan ]; then printf '%s\n' "$row"; fi
  [ "$mode" != failed-plan ]
elif [[ "$*" = *--download-only* ]]; then
  mkdir "$cache/partial"
  : > "$cache/lock"
  cp "$TRANSACTION_TEST_STATE/payload" "$cache/foo.deb"
  case "$mode" in
    corrupt) printf evil > "$cache/foo.deb";;
    truncated) printf bad > "$cache/foo.deb";;
    missing) rm "$cache/foo.deb";;
    extra) cp "$cache/foo.deb" "$cache/other.deb";;
    linked) rm "$cache/foo.deb"; ln -s "$TRANSACTION_TEST_STATE/payload" "$cache/foo.deb";;
    hardlinked) ln "$cache/foo.deb" "$cache/other-link";;
    partial-cache) printf leftover > "$cache/partial/unfinished";;
    missing-lock) rm "$cache/lock";;
    linked-partial) rmdir "$cache/partial"; ln -s "$TRANSACTION_TEST_STATE/empty" "$cache/partial";;
  esac
  touch "$TRANSACTION_TEST_STATE/downloaded"
  [ "$mode" != failed-download ]
else
  touch "$TRANSACTION_TEST_STATE/install-attempted"
  if [ "$mode" = missing-offline ]; then
    [[ "$*" = *--no-download* ]]
    rm "$cache/foo.deb"
    exit 42
  fi
  if [ "$mode" = output-link ]; then
    ln -s "$TRANSACTION_TEST_STATE/sentinel" "$TRANSACTION_TEST_STATE/report"
  fi
  touch "$TRANSACTION_TEST_STATE/installed"
fi
APT
cat > "$state/bin/dpkg-query" <<'QUERY'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" = 3 ]; then printf '2.8.3\n'; exit 0; fi
cat "$TRANSACTION_TEST_STATE/before"
if [ "${TRANSACTION_TEST_CASE:-}" = changed-baseline ] && [ -e "$TRANSACTION_TEST_STATE/downloaded" ]; then printf 'package\tstray\t1\tamd64\tinstalled\n'; fi
[ "${TRANSACTION_TEST_CASE:-}" != failed-baseline ]
QUERY
cat > "$state/bin/dpkg-deb" <<'DEB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${TRANSACTION_TEST_CASE:-}" = wrong-tuple ]; then printf 'foo\t99\tamd64\n'; else printf 'foo\t1.0\tamd64\n'; fi
[ "${TRANSACTION_TEST_CASE:-}" != failed-metadata ]
DEB
cat > "$state/bin/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = '-c %h' ]
case "$(uname)" in Darwin) /usr/bin/stat -f %l "$3";; *) /usr/bin/stat "$@";; esac
STAT
cat > "$state/bin/sha256sum" <<'HASH'
#!/usr/bin/env bash
set -euo pipefail
shasum -a 256 "$@"
[ "${TRANSACTION_TEST_CASE:-}" != failed-hash ]
HASH
chmod +x "$state/bin/"*
export PATH="$state/bin:$PATH"
# Off selects exactly the original command and publishes no diagnostic.
bash "$state/observe.sh" 0 apt-get install -y --no-install-recommends foo=1.0
[ -f "$state/installed" ] && [ ! -f "$state/report" ]
[ "$(wc -l < "$state/trace")" -eq 1 ]
# The selected path must finish its observation before the no-download install.
rm "$state/installed" "$state/install-attempted" "$state/trace"
TMPDIR="$state/work" WAR_TRUSTED_RUNTIME_ORIGIN_TEST=1 WAR_APT_LISTS_DIR="$state" bash "$state/observe.sh" 1 apt-get install -y --no-install-recommends foo=1.0
[ -f "$state/installed" ]
[ "$(grep -c foo=1.0 "$state/trace")" -eq 3 ]
[ "$(grep -c -- --no-download "$state/trace")" -eq 1 ]
[ "$(grep -o 'Dir::Cache::archives=[^ ]*' "$state/trace" | sort -u | wc -l)" -eq 1 ]
grep -qx transaction-complete "$state/report"
# No private archive/cache state may survive the helper's successful exit.
[ -z "$(find "$state/work" -mindepth 1 -print)" ]
for refusal in empty-plan malformed-plan oversized-plan storage-budget credential-uri unterminated-plan duplicate-plan failed-plan failed-download corrupt truncated missing extra linked hardlinked partial-cache missing-lock linked-partial failed-baseline failed-metadata failed-hash wrong-tuple changed-baseline failed-target-reader untrusted-target missing-inrelease linked-index partial-stanza duplicate-field ambiguous-source conflicting-source origin-uri-mismatch origin-tuple-mismatch origin-digest-substitution missing-offline output-link; do
  rm -f "$state/installed" "$state/install-attempted" "$state/trace" "$state/downloaded" "$state/report"
  if TMPDIR="$state/work" WAR_TRUSTED_RUNTIME_ORIGIN_TEST=1 WAR_APT_LISTS_DIR="$state" TRANSACTION_TEST_CASE="$refusal" bash "$state/observe.sh" 1 apt-get install -y --no-install-recommends foo=1.0 > "$state/out" 2> "$state/error"; then
    echo "accepted $refusal transaction" >&2; exit 1
  fi
  if [ "$refusal" = output-link ]; then
    [ -f "$state/installed" ] && [ -L "$state/report" ] && [ "$(cat "$state/sentinel")" = safe ]
  else
    [ ! -f "$state/installed" ] && [ ! -f "$state/report" ]
  fi
  if [ "$refusal" != missing-offline ] && [ "$refusal" != output-link ]; then [ ! -f "$state/install-attempted" ]; fi
  case "$refusal" in
    empty-plan|malformed-plan|oversized-plan|storage-budget|credential-uri|unterminated-plan|duplicate-plan|failed-plan) [ ! -f "$state/downloaded" ];;
  esac
  [ -z "$(find "$state/work" -mindepth 1 -print)" ]
done
printf '%s\n' 'runtime transaction: original install, authenticated origin join and 36 refusal controls passed'
