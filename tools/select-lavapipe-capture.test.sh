#!/usr/bin/env bash
# Exercise the shipped selector over real PR merge histories and failed reads.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="$root/tools/select-lavapipe-capture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "TEST FAIL -- $*" >&2; exit 1; }
[[ -f $selector ]] || fail 'the independent capture has no executable source selector'
real_git="$(command -v git)"

commit_fixture() {
  git -C "$scratch/repo" -c commit.gpgsign=false commit -qm "$1"
}

fixture() {
  local changed=$1 advance=client/scripts/hollow_fog.gd
  [[ $changed != "$advance" ]] || advance=client/scripts/main.gd
  rm -rf "$scratch/repo"
  mkdir -p "$scratch/repo/tools" "$scratch/repo/docs"
  git -C "$scratch/repo" init -q -b main
  git -C "$scratch/repo" config user.name fixture
  git -C "$scratch/repo" config user.email fixture@example.invalid
  cp "$selector" "$root/tools/pr-diff-base.sh" "$scratch/repo/tools/"
  echo base > "$scratch/repo/docs/base.md"
  git -C "$scratch/repo" add -- tools/select-lavapipe-capture.sh tools/pr-diff-base.sh docs/base.md
  commit_fixture base
  base=$(git -C "$scratch/repo" rev-parse HEAD)
  git -C "$scratch/repo" switch -qc pr
  mkdir -p "$scratch/repo/$(dirname "$changed")"
  echo '# fixture change' >> "$scratch/repo/$changed"
  git -C "$scratch/repo" add -- "$changed"
  commit_fixture candidate
  head=$(git -C "$scratch/repo" rev-parse HEAD)
  git -C "$scratch/repo" switch -q main
  mkdir -p "$scratch/repo/$(dirname "$advance")"
  echo advanced > "$scratch/repo/$advance"
  git -C "$scratch/repo" add -- "$advance"
  commit_fixture advanced
  git -C "$scratch/repo" -c commit.gpgsign=false merge -q --no-ff pr -m integration
  integration=$(git -C "$scratch/repo" rev-parse HEAD)
}

select_capture() {
  (cd "$scratch/repo" && GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$integration" HEAD_SHA="$head" BASE_SHA="$base" \
    bash tools/select-lavapipe-capture.sh select)
}

for changed in docs/readme.md client/scripts/main.gd client/scripts/volumetrics.gd \
  client/scripts/hollow_fog.gd .github/workflows/ci.yaml \
  .github/workflows/lavapipe-capture.yaml tools/select-lavapipe-capture.sh \
  tools/lavapipe-capture-guard.sh tools/install-ci-godot.sh; do
  fixture "$changed"
  expected=true
  [[ $changed != docs/readme.md ]] || expected=false
  result=$(select_capture) || fail "selector refused valid $changed history"
  [[ $result == "$expected" ]] || fail "$changed selected $result; expected $expected"
done

fixture docs/readme.md
for invalid in missing-integration wrong-integration missing-head wrong-head missing-base wrong-event; do
  status=0
  (
    cd "$scratch/repo"
    export GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$integration" HEAD_SHA="$head" BASE_SHA="$base"
    case "$invalid" in
      missing-integration) unset GITHUB_SHA ;;
      wrong-integration) GITHUB_SHA=$base ;;
      missing-head) unset HEAD_SHA ;;
      wrong-head) HEAD_SHA=$base ;;
      missing-base) unset BASE_SHA ;;
      wrong-event) GITHUB_EVENT_NAME=merge_group ;;
    esac
    bash tools/select-lavapipe-capture.sh select
  ) > "$scratch/refused" 2> "$scratch/refusal" || status=$?
  [[ $status != 0 && ! -s $scratch/refused ]] || fail "$invalid emitted a usable selection"
done

# Missing or failed diff observations add capture work; plausible partial paths
# never justify false. Identity verification above remains a separate refusal.
missing_base=$(printf '%040d' 0)
result=$(cd "$scratch/repo" && GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$integration" \
  HEAD_SHA="$head" BASE_SHA="$missing_base" bash tools/select-lavapipe-capture.sh select)
[[ $result == true ]] || fail 'unavailable frozen base silently skipped capture'
mkdir "$scratch/bin"
cat > "$scratch/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == diff ]]; then
  printf '%s\n' docs/plausible-partial.md
  exit 7
fi
exec "$SELECTOR_TEST_GIT" "$@"
SH
chmod +x "$scratch/bin/git"
result=$(PATH="$scratch/bin:$PATH" SELECTOR_TEST_GIT="$real_git" select_capture)
[[ $result == true ]] || fail 'failed partial diff silently skipped capture'

cat > "$scratch/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == diff && ${3:-} == "$SELECTOR_TEST_DIFF_BASE" ]]; then
  printf '%s\n' docs/plausible-partial.md
  exit 7
fi
exec "$SELECTOR_TEST_GIT" "$@"
SH
resolved_base=$(git -C "$scratch/repo" rev-parse 'HEAD^1')
result=$(PATH="$scratch/bin:$PATH" SELECTOR_TEST_GIT="$real_git" SELECTOR_TEST_DIFF_BASE="$resolved_base" select_capture)
[[ $result == true ]] || fail 'failed resolved diff silently skipped capture'
cat > "$scratch/repo/tools/pr-diff-base.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$BASE_SHA"
exit 7
SH
result=$(select_capture)
[[ $result == true ]] || fail 'failed resolver with plausible output silently skipped capture'

fixture tools/pr-diff-base.sh
# A changed resolver must not execute, even if it could forge a quiet decision.
{ printf '#!/usr/bin/env bash\ntouch resolver-executed\nexit 7\n'; } > "$scratch/repo/tools/pr-diff-base.sh"
result=$(select_capture)
[[ $result == true && ! -e $scratch/repo/resolver-executed ]] || fail 'changed resolver executed or skipped itself'

(cd "$scratch/repo" && GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$integration" \
  HEAD_SHA="$head" BASE_SHA="$base" bash tools/select-lavapipe-capture.sh verify) \
  > "$scratch/verified"
[[ ! -s $scratch/verified ]] || fail 'identity verification emitted a selection'
echo 'Lavapipe source identity, real-history selection and partial-read controls passed'
