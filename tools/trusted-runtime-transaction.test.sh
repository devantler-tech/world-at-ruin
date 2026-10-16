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
printf 'package\tapt\t2.8.3\tamd64\tinstalled\n' > "$state/before"
{ cat "$state/before"; printf 'package\tfoo\t1.0\tamd64\tinstalled\n'; } > "$state/expected"
sed -e "s|expected=/tmp/expected-packages.tsv|expected=$state/expected|" \
    -e "s|out=/usr/share/war-trusted-runtime/transaction.tsv|out=$state/report|" \
    "$root/tools/observe-runtime-transaction.sh" > "$state/observe.sh"
cat > "$state/bin/apt-get" <<'APT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRANSACTION_TEST_STATE/trace"
mode=${TRANSACTION_TEST_CASE:-good}
for argument in "$@"; do
  case "$argument" in Dir::Cache::archives=*) cache=${argument#*=};; esac
done
if [[ "$*" = *--print-uris* ]]; then
  [[ "$*" = *'Acquire::ForceHash=sha256'* ]]
  case "$mode" in
    empty-plan) exit 0;; malformed-plan) echo 'unexpected progress'; exit 0;;
    oversized-plan) printf "'https://snapshot.ubuntu.com/test/foo.deb' foo.deb 67108865 SHA256:%s\n" "$TRANSACTION_TEST_HASH"; exit 0;;
    storage-budget)
      for n in 1 2 3 4 5; do printf "'https://snapshot.ubuntu.com/test/foo%s.deb' foo%s.deb 67108864 SHA256:%s\n" "$n" "$n" "$TRANSACTION_TEST_HASH"; done
      exit 0;;
  esac
  row="'https://snapshot.ubuntu.com/test/foo.deb' foo.deb 4 SHA256:$TRANSACTION_TEST_HASH"
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
TMPDIR="$state/work" bash "$state/observe.sh" 1 apt-get install -y --no-install-recommends foo=1.0
[ -f "$state/installed" ]
[ "$(grep -c foo=1.0 "$state/trace")" -eq 3 ]
[ "$(grep -c -- --no-download "$state/trace")" -eq 1 ]
[ "$(grep -o 'Dir::Cache::archives=[^ ]*' "$state/trace" | sort -u | wc -l)" -eq 1 ]
grep -qx transaction-complete "$state/report"
# No private archive/cache state may survive the helper's successful exit.
[ -z "$(find "$state/work" -mindepth 1 -print)" ]
for refusal in empty-plan malformed-plan oversized-plan storage-budget unterminated-plan duplicate-plan failed-plan failed-download corrupt truncated missing extra linked hardlinked partial-cache missing-lock linked-partial failed-baseline failed-metadata failed-hash wrong-tuple changed-baseline missing-offline output-link; do
  rm -f "$state/installed" "$state/install-attempted" "$state/trace" "$state/downloaded" "$state/report"
  if TMPDIR="$state/work" TRANSACTION_TEST_CASE="$refusal" bash "$state/observe.sh" 1 apt-get install -y --no-install-recommends foo=1.0 > "$state/out" 2> "$state/error"; then
    echo "accepted $refusal transaction" >&2; exit 1
  fi
  if [ "$refusal" = output-link ]; then
    [ -f "$state/installed" ] && [ -L "$state/report" ] && [ "$(cat "$state/sentinel")" = safe ]
  else
    [ ! -f "$state/installed" ] && [ ! -f "$state/report" ]
  fi
  if [ "$refusal" != missing-offline ] && [ "$refusal" != output-link ]; then [ ! -f "$state/install-attempted" ]; fi
  [ -z "$(find "$state/work" -mindepth 1 -print)" ]
done
printf '%s\n' 'runtime transaction: original install, private-cache/no-download path and 24 refusal controls passed'
