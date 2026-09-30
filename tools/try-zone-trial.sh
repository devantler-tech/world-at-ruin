#!/usr/bin/env bash
# Launch the private scripted trial without exposing credentials or touching saves.
set -euo pipefail
umask 077
client_path=""
server_name=""
trial_context="oidc@prod"
trial_port=18443
# Print the supported arguments to stdout; take no parameters and return zero.
usage() {
  printf '%s\n' 'Usage: try-zone-trial.sh --client <released executable> --tls-server-name <certificate DNS name> [--context <context>] [--port <1024..65535>]'
}
# Print the supplied sanitized operator message to stderr and exit with status 1.
die() { printf 'Private zone trial: %s\n' "$1" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --client|--tls-server-name|--context|--port)
      [ "$#" -ge 2 ] || die 'a named option is missing its value'
      case "$1" in
        --client) client_path="$2" ;;
        --tls-server-name) server_name="$2" ;;
        --context) trial_context="$2" ;;
        --port) trial_port="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die 'unknown option' ;;
  esac
done
[ -f "${client_path}" ] && [ -x "${client_path}" ] || die 'supply an executable from the released client app'
client_dir="$(CDPATH='' cd -- "$(dirname -- "${client_path}")" && pwd -P)" || die 'the selected client directory is unavailable'
client_path="${client_dir}/$(basename -- "${client_path}")"
[ -n "${trial_context}" ] || die 'the Kubernetes context must not be empty'
[[ "${trial_port}" =~ ^[0-9]{4,5}$ ]] || die 'choose a port from 1024 through 65535'
trial_port=$((10#${trial_port}))
[ "${trial_port}" -ge 1024 ] && [ "${trial_port}" -le 65535 ] || die 'choose a port from 1024 through 65535'
[[ "${server_name}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z][A-Za-z0-9-]*$ ]] || die 'supply the certificate fully qualified DNS name'
[ "${#server_name}" -le 253 ] || die 'the certificate DNS name is too long'
IFS='.' read -r -a dns_labels <<<"${server_name}"
for dns_label in "${dns_labels[@]}"; do
  [[ "${dns_label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && [ "${#dns_label}" -le 63 ] || die 'the certificate DNS name is invalid'
done
command -v kubectl >/dev/null || die 'kubectl and the platform OIDC login are required'
trial_dir="$(mktemp -d)"
tunnel_pid=""
client_pid=""

# Return zero only when $1 is a running or stopped job owned by this shell.
# Completed/reaped PIDs must not be signalled if the OS has since reused them.
is_owned_child() {
  local child_pid="$1" candidate
  for candidate in $(jobs -pr) $(jobs -ps); do
    [ "${candidate}" != "${child_pid}" ] || return 0
  done
  return 1
}

# Stop and reap the owned child PID in $1; return zero even after a signal exit.
# Allow at most one second for TERM, then KILL so an ignored TERM cannot hang
# cleanup. A finished child is only waited, never signalled by its stale PID.
stop_owned_child() {
  local child_pid="$1" attempt
  [ -n "${child_pid}" ] || return 0
  if is_owned_child "${child_pid}"; then
    kill -TERM "${child_pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
      is_owned_child "${child_pid}" || break
      sleep 0.05
    done
    if is_owned_child "${child_pid}"; then kill -KILL "${child_pid}" 2>/dev/null || true; fi
  fi
  wait "${child_pid}" 2>/dev/null || true
}

# EXIT trap with no parameters: retire this launcher's children and private
# profile, clear its bearer, and retain the original normal or signal exit code.
cleanup() {
  trap '' INT TERM
  stop_owned_child "${client_pid}"
  stop_owned_child "${tunnel_pid}"
  unset WAR_ZONE_TOKEN
  rm -rf "${trial_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kube_args=(--context "${trial_context}" -n world-at-ruin)
kubectl "${kube_args[@]}" rollout status deployment/world-at-ruin-zone --timeout=60s >"${trial_dir}/rollout.log" 2>&1 || die 'the zone deployment is not ready; check its platform workload status'
WAR_ZONE_TOKEN="$(kubectl "${kube_args[@]}" exec deployment/world-at-ruin-zone -c world-at-ruin -- /zone -allocation-id operator-trial -mint-token 1 -mint-ttl 5m 2>"${trial_dir}/mint.log")" || die 'could not mint the trial token; check your namespace operator access'
[ -n "${WAR_ZONE_TOKEN}" ] || die 'the token mint returned no credential'
kubectl "${kube_args[@]}" port-forward --address 127.0.0.1 service/world-at-ruin-zone "${trial_port}:8443" >"${trial_dir}/tunnel.log" 2>&1 &
tunnel_pid=$!
tunnel_ready=false
for ((attempt = 0; attempt < 40; attempt++)); do
  kill -0 "${tunnel_pid}" 2>/dev/null || die 'the localhost tunnel could not start; check the port and namespace operator access'
  if grep -q "Forwarding from 127.0.0.1:${trial_port} " "${trial_dir}/tunnel.log"; then
    tunnel_ready=true
    break
  fi
  sleep 0.1
done
[ "${tunnel_ready}" = true ] || die 'the localhost tunnel did not become ready'
printf '%s\n' 'Starting the private scripted zone trial with a separate temporary character. Close the client to close the tunnel.'
export WAR_ZONE_TOKEN

# Launch the configured client with private environment settings; no arguments.
# Wait in a Bash builtin so INT/TERM traps run promptly (130/143), while a normal
# client exit is returned unchanged and a reaped client PID is never signalled.
run_trial() {
  local client_status=0
  WAR_ZONE_URL="wss://127.0.0.1:${trial_port}/zone" \
    WAR_ZONE_TLS_SERVER_NAME="${server_name}" \
    WAR_SAVE_PATH="${trial_dir}/character.json" \
    WAR_VAULT_PATH="${trial_dir}/vault.json" \
    WAR_BOOT_RECOVERY_PATH="${trial_dir}/recovery.json" \
    "${client_path}" &
  client_pid=$!
  wait "${client_pid}" || client_status=$?
  client_pid=""
  return "${client_status}"
}
run_trial
