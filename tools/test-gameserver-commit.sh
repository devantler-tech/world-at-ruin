#!/usr/bin/env bash
# Prove one conditional GameServer mutation against disposable local storage.
set -euo pipefail
umask 077
test_timeout=2m
case "$#:${1:-}" in
  0:) ;;
  1:--cleanup-timeout-probe) test_timeout=1ns ;;
  *) echo 'Usage: test-gameserver-commit.sh [--cleanup-timeout-probe]' >&2; exit 1 ;;
esac
root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trial_pid=""
# A PID may be signalled only while it is this shell's live child.
trial_is_owned() {
  local candidate
  [ -n "${trial_pid}" ] || return 1
  for candidate in $(jobs -pr) $(jobs -ps); do
    [ "${candidate}" != "${trial_pid}" ] || return 0
  done
  return 1
}
# Rebind the process command immediately before every signal. The exact binary
# path is inside this invocation's private scratch directory.
controlplane_is_owned() {
  local command
  command="$(ps -ww -p "$1" -o command= 2>/dev/null)" || return 1
  case "${command}" in
    "${scratch}/controller-tools/envtest/kube-apiserver"|" ${scratch}/controller-tools/envtest/kube-apiserver") return 0 ;;
    "${scratch}/controller-tools/envtest/kube-apiserver "*|"${scratch}/controller-tools/envtest/etcd"|" ${scratch}/controller-tools/envtest/etcd"|"${scratch}/controller-tools/envtest/etcd "*) return 0 ;;
    *) return 1 ;;
  esac
}
owned_controlplane_pids() {
  local pid command
  ps -axww -o pid=,command= | while read -r pid command; do
    case "${command}" in
      "${scratch}/controller-tools/envtest/kube-apiserver "*|"${scratch}/controller-tools/envtest/etcd "*) printf '%s\n' "${pid}" ;;
    esac
  done
}
cleanup() {
  local pid owned_pids attempt
  trap '' INT TERM
  if trial_is_owned; then
    kill -TERM "${trial_pid}" 2>/dev/null || true
    for ((attempt=0; attempt<100; attempt++)); do
      trial_is_owned || break
      sleep 0.05
    done
    if trial_is_owned; then kill -KILL "${trial_pid}" 2>/dev/null || true; fi
  fi
  if [ -n "${trial_pid}" ]; then wait "${trial_pid}" 2>/dev/null || true; fi
  # Envtest starts its children in separate process groups. A panic or Go test
  # timeout cannot run TestMain's Stop, so retire only this invocation's binaries.
  owned_pids="$(owned_controlplane_pids)" || return 1
  for pid in ${owned_pids}; do
        if controlplane_is_owned "${pid}"; then
          kill -TERM "${pid}" 2>/dev/null || true
          for ((attempt=0; attempt<100; attempt++)); do
            controlplane_is_owned "${pid}" || break
            sleep 0.05
          done
          if controlplane_is_owned "${pid}"; then kill -KILL "${pid}" 2>/dev/null || true; fi
          for ((attempt=0; attempt<100; attempt++)); do
            controlplane_is_owned "${pid}" || break
            sleep 0.05
          done
          if controlplane_is_owned "${pid}"; then
            echo 'Owned control-plane cleanup failed; retaining private scratch' >&2
            return 1
          fi
          echo 'Trial cleanup: retired an owned control-plane process' >&2
        fi
  done
  owned_pids="$(owned_controlplane_pids)" || return 1
  [ -z "${owned_pids}" ] || { echo 'Owned control-plane processes remain; retaining private scratch' >&2; return 1; }
  rm -rf -- "${scratch}"
  [ ! -e "${scratch}" ] || return 1
  echo 'Trial cleanup: verified retirement and removed private state' >&2
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)
    platform=darwin-arm64
    archive_hash=fb38cfacdd71b5e97a4d4cceac861af5f55069cf783f0e49cf181bfc32eb3e557c2091a534dc5d38f1b92c5ba142bc1979f215a5385b3630ea6a661be6fa161b
    helm version --short | grep -q '^v4\.3\.0+' || { echo 'Helm v4.3.0 is required' >&2; exit 1; }
    ;;
  Linux/x86_64)
    platform=linux-amd64
    archive_hash=1d1c453633b72c161a5d5a886cde7ac850be1a2ac796a9e1d4ffacacc64868295bdd2d57aa66cd0c158f5ce510f5dfe3fbc61ac21bd3dcfb875bd70658aa663a
    curl --fail --silent --show-error --location --max-time 60 --retry 2 \
      https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz -o "${scratch}/helm.tar.gz"
    printf '%s  %s\n' 86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb "${scratch}/helm.tar.gz" | sha256sum --check --status
    tar -xzf "${scratch}/helm.tar.gz" -C "${scratch}"
    export PATH="${scratch}/linux-amd64:${PATH}"
    ;;
  *) echo 'Trial supports Darwin arm64 and Linux amd64 only' >&2; exit 1 ;;
esac
if [ -n "${WAR_ENVTEST_ARCHIVE:-}" ]; then
  cp -- "${WAR_ENVTEST_ARCHIVE}" "${scratch}/envtest.tar.gz"
else
  curl --fail --silent --show-error --location --max-time 60 --retry 2 \
    "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.37.0/envtest-v1.37.0-${platform}.tar.gz" \
    -o "${scratch}/envtest.tar.gz"
fi
actual="$(shasum -a 512 "${scratch}/envtest.tar.gz")"
[ "${actual%% *}" = "${archive_hash}" ] || { echo 'Control-plane archive digest mismatch' >&2; exit 1; }
tar -xzf "${scratch}/envtest.tar.gz" -C "${scratch}"
agones_version="$(go -C "${root}/server" list -m -f '{{.Version}}' agones.dev/agones)"
[ "${agones_version}" = v1.61.0 ] || { echo 'Review the trial CRD pin with the Agones upgrade' >&2; exit 1; }
agones_dir="$(go -C "${root}/server" list -m -f '{{.Dir}}' agones.dev/agones)"
[ -n "${agones_dir}" ] || { echo 'Download the pinned server modules first' >&2; exit 1; }
helm template commit-trial "${agones_dir}/install/helm/agones" \
  --show-only templates/crds/gameserver.yaml > "${scratch}/gameserver.yaml"
export KUBEBUILDER_ASSETS="${scratch}/controller-tools/envtest"
export WAR_GAMESERVER_CRD="${scratch}/gameserver.yaml"
go -C "${root}/tools/gameserver-commit-trial" vet ./...
go -C "${root}/tools/gameserver-commit-trial" test -race ./cmd/nativefixture
go -C "${root}/tools/gameserver-commit-trial" test -race -c -o "${scratch}/commit-trial.test" .
"${scratch}/commit-trial.test" -test.timeout="${test_timeout}" -test.v &
trial_pid=$!
wait "${trial_pid}"
