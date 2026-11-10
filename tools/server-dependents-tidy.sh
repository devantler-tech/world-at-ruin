#!/usr/bin/env bash
# Keeps the Go modules that replace the server module with the local tree in step with a
# Dependabot update to server/go.mod (#1654).
#
# Dependabot rewrites only server/go.mod and server/go.sum. Every module that points at the
# local server tree with a `replace` directive keeps its own locks, so its -mod=readonly
# builds and tests fail with "updates to go.mod needed" until `go mod tidy` runs there.
#
#   server-dependents-tidy.sh list
#       Print every module directory whose go.mod replaces the server module with a local path.
#   server-dependents-tidy.sh tidy
#       Run `go mod tidy` in each of those modules and print the go.mod/go.sum files it changed.
#   server-dependents-tidy.sh commit REPOSITORY BRANCH EXPECTED_HEAD_SHA
#       Commit the changed go.mod/go.sum files to BRANCH through the GraphQL
#       createCommitOnBranch mutation (GH_TOKEN), so GitHub signs the commit. The mutation
#       refuses if BRANCH moved past EXPECTED_HEAD_SHA. Nothing is committed when nothing changed.
#
# Every mode runs from the repository root and fails closed: no dependent module, a failed
# tidy, or a change outside the dependents' go.mod/go.sum is an error.
set -euo pipefail

readonly server_module='github.com/devantler-tech/world-at-ruin/server'
readonly headline='ci: tidy the modules that replace the server module'

die() {
  echo "server-dependents-tidy: $*" >&2
  exit 1
}

dependents() {
  local mod dir found=0
  while IFS= read -r mod; do
    dir=${mod%/go.mod}
    dir=${dir#./}
    # A local-path replace of the server module, written either as a single directive or
    # inside a replace block.
    if grep -Eq "^[[:space:]]*(replace[[:space:]]+)?${server_module//./\\.}([[:space:]]+v[^[:space:]]+)?[[:space:]]+=>[[:space:]]+\.\.?(/|[[:space:]]|$)" "$mod"; then
      printf '%s\n' "$dir"
      found=1
    fi
  done < <(find . -name go.mod -not -path './.git/*' -not -path '*/testdata/*' | LC_ALL=C sort)
  [ "$found" -eq 1 ] || die "no module replaces $server_module with a local path"
}

changed_files() {
  local allowed=$1 path dir ok
  git diff --name-only -- . | LC_ALL=C sort | while IFS= read -r path; do
    ok=0
    while IFS= read -r dir; do
      if [ "$path" = "$dir/go.mod" ] || [ "$path" = "$dir/go.sum" ]; then
        ok=1
      fi
    done <<<"$allowed"
    [ "$ok" -eq 1 ] || die "unexpected change outside the dependents' locks: $path"
    printf '%s\n' "$path"
  done
}

cmd_list() {
  dependents
}

cmd_tidy() {
  local list dir
  list=$(dependents)
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the work tree must be clean before tidying"
  while IFS= read -r dir; do
    echo "server-dependents-tidy: go mod tidy in $dir" >&2
    go -C "$dir" mod tidy || die "go mod tidy failed in $dir"
  done <<<"$list"
  changed_files "$list"
}

cmd_commit() {
  [ "$#" -eq 3 ] || die "usage: commit REPOSITORY BRANCH EXPECTED_HEAD_SHA"
  local repository=$1 branch=$2 head=$3 list files additions query
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $repository"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "expected head must be a full commit SHA"
  [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required to commit"

  list=$(dependents)
  files=$(changed_files "$list")
  if [ -z "$files" ]; then
    echo "server-dependents-tidy: the dependent modules are already tidy; nothing to commit" >&2
    return 0
  fi

  additions=$(while IFS= read -r path; do
    jq -n --arg path "$path" --rawfile contents "$path" '{path: $path, contents: ($contents | @base64)}'
  done <<<"$files" | jq -s .)

  query="mutation(\$input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: \$input) { commit { oid } } }"
  jq -n \
    --arg query "$query" \
    --arg repository "$repository" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg headline "$headline" \
    --arg body "Ran go mod tidy in every module that replaces the server module with the local tree, so their read-only builds accept this server update (#1654)." \
    --argjson additions "$additions" \
    '{query: $query, variables: {input: {
        branch: {repositoryNameWithOwner: $repository, branchName: $branch},
        expectedHeadOid: $head,
        message: {headline: $headline, body: $body},
        fileChanges: {additions: $additions}
      }}}' |
    gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'
}

[ "$#" -ge 1 ] || die "usage: server-dependents-tidy.sh list|tidy|commit REPOSITORY BRANCH EXPECTED_HEAD_SHA"
mode=$1
shift
case "$mode" in
  list) cmd_list "$@" ;;
  tidy) cmd_tidy "$@" ;;
  commit) cmd_commit "$@" ;;
  *) die "unknown mode: $mode" ;;
esac
