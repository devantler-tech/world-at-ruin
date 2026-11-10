#!/usr/bin/env bash
# Controls for tools/server-dependents-tidy.sh and the workflow that runs it (#1654).
# `go` and `gh` are stubbed: the controls check which modules are tidied, what is committed,
# and that the workflow only hands its write token to trusted Dependabot server updates.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/tools/server-dependents-tidy.sh"
workflow=${1:-$root/.github/workflows/dependabot-server-tidy.yaml}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Stub go: `go -C DIR mod tidy` appends a marker to DIR/go.mod, or fails when DIR is listed
# in STUB_GO_FAIL. Every call is logged.
mkdir -p "$work/bin"
cat >"$work/bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -C ] && [ "$3" = mod ] && [ "$4" = tidy ] || { echo "unexpected go call: $*" >&2; exit 2; }
echo "$2" >>"$STUB_LOG/go.calls"
if [ "${STUB_GO_FAIL:-}" = "$2" ]; then exit 1; fi
if [ "${STUB_GO_NOOP:-}" != 1 ]; then printf '// tidied\n' >>"$2/go.mod"; printf 'sum\n' >>"$2/go.sum"; fi
STUB
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat >"$STUB_LOG/gh.request"
echo "$*" >"$STUB_LOG/gh.args"
echo 0123456789abcdef0123456789abcdef01234567
STUB
chmod +x "$work/bin/go" "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_LOG="$work"

fixture() {
  local repo=$work/repo
  rm -rf "$repo" "$work/go.calls" "$work/gh.request" "$work/gh.args"
  mkdir -p "$repo/server/issued" "$repo/tools/trial" "$repo/tools/other" "$repo/server/testdata/x"
  printf 'module github.com/devantler-tech/world-at-ruin/server\n\ngo 1.27.3\n' >"$repo/server/go.mod"
  printf 'module issued\n\ngo 1.27.3\n\nreplace github.com/devantler-tech/world-at-ruin/server => ..\n' >"$repo/server/issued/go.mod"
  printf 'module trial\n\ngo 1.27.3\n\nreplace (\n\tgithub.com/devantler-tech/world-at-ruin/server v0.0.0 => ../../server\n)\n' >"$repo/tools/trial/go.mod"
  printf 'module other\n\ngo 1.27.3\n\nreplace github.com/devantler-tech/world-at-ruin/server => github.com/example/fork v1.0.0\n' >"$repo/tools/other/go.mod"
  printf 'module fixture\n\nreplace github.com/devantler-tech/world-at-ruin/server => ../..\n' >"$repo/server/testdata/x/go.mod"
  touch "$repo/server/issued/go.sum" "$repo/tools/trial/go.sum"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm fixture
  cd "$repo"
}

# 1. Discovery finds exactly the local-path replacements, in both directive shapes.
fixture
[ "$("$script" list)" = "$(printf 'server/issued\ntools/trial')" ] || fail "list did not find exactly the two local-path dependents"

# 2. Tidy runs in each dependent and reports only their locks.
out=$("$script" tidy)
[ "$(cat "$work/go.calls")" = "$(printf 'server/issued\ntools/trial')" ] || fail "tidy did not run in exactly the dependents"
[ "$out" = "$(printf 'server/issued/go.mod\nserver/issued/go.sum\ntools/trial/go.mod\ntools/trial/go.sum')" ] || fail "tidy reported the wrong files: $out"

# 3. Commit sends one signed-by-GitHub commit with the tidied locks, pinned to the expected head.
GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin dependabot/go_modules/server/x 0123456789abcdef0123456789abcdef01234567 >/dev/null
[ "$(cat "$work/gh.args")" = "api graphql --input - --jq .data.createCommitOnBranch.commit.oid" ] || fail "commit did not call the GraphQL mutation"
jq -e '.variables.input.expectedHeadOid == "0123456789abcdef0123456789abcdef01234567"
  and .variables.input.branch.branchName == "dependabot/go_modules/server/x"
  and .variables.input.branch.repositoryNameWithOwner == "devantler-tech/world-at-ruin"
  and ([.variables.input.fileChanges.additions[].path] == ["server/issued/go.mod","server/issued/go.sum","tools/trial/go.mod","tools/trial/go.sum"])
  and (.variables.input.fileChanges.deletions == null)
  and (.query | test("createCommitOnBranch"))' "$work/gh.request" >/dev/null || fail "commit request is wrong"
[ "$(jq -r '.variables.input.fileChanges.additions[0].contents | @base64d' "$work/gh.request")" = "$(cat server/issued/go.mod)" ] || fail "commit contents do not match the tidied file"

# 4. Nothing changed: no commit request at all.
fixture
STUB_GO_NOOP=1 "$script" tidy >/dev/null
GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 2>/dev/null
[ ! -e "$work/gh.request" ] || fail "commit called GitHub with nothing to commit"

# 5. Fail closed.
fixture
if STUB_GO_FAIL=tools/trial "$script" tidy >/dev/null 2>&1; then fail "a failed tidy was accepted"; fi
fixture
echo changed >>server/go.mod
if "$script" tidy >/dev/null 2>&1; then fail "tidy ran on a dirty work tree"; fi
git checkout -q -- server/go.mod
"$script" tidy >/dev/null
echo changed >>server/go.mod
if GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  fail "a change outside the dependents' locks was committed"
fi
[ ! -e "$work/gh.request" ] || fail "an unexpected change reached GitHub"
git checkout -q -- server/go.mod
if GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b deadbeef >/dev/null 2>&1; then fail "a short expected head was accepted"; fi
if "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then fail "commit ran without a token"; fi
rm -rf server/issued tools/trial
if "$script" list >/dev/null 2>&1; then fail "no dependents was accepted"; fi

# 6. The workflow hands the write token only to a same-repository Dependabot server update,
# never to the step that runs go, and never persists a checkout credential.
cd "$root"
command -v yq >/dev/null || fail "yq is required"
[ "$(yq '.permissions | length' "$workflow")" = 0 ] || fail "workflow-level permissions must be empty"
[ "$(yq '.on | keys | join(",")' "$workflow")" = pull_request_target ] || fail "the only trigger must be pull_request_target"
[ "$(yq '.on.pull_request_target.paths | join(",")' "$workflow")" = server/go.mod ] || fail "the trigger must be limited to server/go.mod"
condition=$(yq '.jobs.tidy.if' "$workflow")
for clause in \
  "github.actor == 'dependabot[bot]'" \
  "github.event.pull_request.user.login == 'dependabot[bot]'" \
  "github.event.pull_request.head.repo.full_name == github.repository" \
  "startsWith(github.event.pull_request.head.ref, 'dependabot/go_modules/server/')"; do
  case "$condition" in *"$clause"*) ;; *) fail "the job condition lacks: $clause" ;; esac
done
case "$condition" in *'||'*) fail "the job condition must not contain an alternative" ;; esac
[ "$(yq -o=json -I=0 '.jobs.tidy.permissions' "$workflow")" = '{"contents":"read"}' ] || fail "the job's GITHUB_TOKEN must only read contents"
checkouts='[.jobs.tidy.steps[] | select(.uses == "actions/checkout@*")]'
[ "$(yq "$checkouts | length" "$workflow")" = 2 ] || fail "expected exactly the base and head checkouts"
[ "$(yq "$checkouts | map(.with.\"persist-credentials\" == false) | all" "$workflow")" = true ] || fail "no checkout may persist credentials"
[ "$(yq "$checkouts | map(select(.with.path == \"base\")) | .[0].with.ref" "$workflow")" = null ] || fail "the script must come from the base commit"
[ "$(yq "$checkouts | map(select(.with.path == \"base\")) | .[0].with.\"sparse-checkout\"" "$workflow")" = tools/server-dependents-tidy.sh ] || fail "the base checkout must hold only the tidy script"
[ "$(yq "$checkouts | map(select(.with.path == \"pr\")) | .[0].with.ref" "$workflow")" = "\${{ github.event.pull_request.head.sha }}" ] || fail "the head checkout must pin the head SHA"
[ "$(yq '[.jobs.tidy.steps[] | select(has("run")) | .run | test("^bash \.\./base/tools/server-dependents-tidy\.sh ")] | all' "$workflow")" = true ] || fail "every run step must use the base copy of the script"
[ "$(yq '[.jobs.tidy.steps[] | select(.uses == "actions/setup-go@*")] | .[0].with.cache' "$workflow")" = false ] || fail "the job must not use the shared Go cache"
token_users=$(yq '[.jobs.tidy.steps[] | select(to_yaml | test("steps\.app-token\.outputs\.token")) | .name] | join(",")' "$workflow")
[ "$token_users" = "Commit the tidied locks" ] || fail "only the commit step may see the App token (saw: $token_users)"
[ "$(yq '.jobs.tidy.steps[] | select(.name == "Commit the tidied locks") | .run' "$workflow")" = "bash ../base/tools/server-dependents-tidy.sh commit \"\$REPOSITORY\" \"\$BRANCH\" \"\$HEAD_SHA\"" ] || fail "the commit step must only commit"
token_index=$(yq '.jobs.tidy.steps | to_entries | map(select(.value.id == "app-token")) | .[0].key' "$workflow")
tidy_index=$(yq '.jobs.tidy.steps | to_entries | map(select(.value.run // "" | test(" tidy$"))) | .[0].key' "$workflow")
[ "$token_index" != null ] && [ "$tidy_index" != null ] && [ "$tidy_index" -lt "$token_index" ] || fail "the App token must be minted after go has run"

echo "server-dependents-tidy: PASS"
