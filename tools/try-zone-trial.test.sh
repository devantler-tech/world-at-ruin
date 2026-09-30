#!/usr/bin/env bash
# Exercise the real launcher with an isolated Kubernetes/client boundary.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trial_tmp="$(mktemp -d)"
trap 'rm -rf "${trial_tmp}"' EXIT
mkdir -p "${trial_tmp}/bin"
export TRIAL_TEST_ROOT="${trial_tmp}"
cat >"${trial_tmp}/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TRIAL_TEST_ROOT}/calls"
case " $* " in
*" rollout status "*) exit 0 ;;
*" exec "*)
  [ "${TRIAL_TEST_MODE:-}" != mint-failure ] || exit 1
  printf '%s\n' 'private-test-bearer'
  ;;
*" port-forward "*)
  [ "${TRIAL_TEST_MODE:-}" != tunnel-failure ] || exit 1
  printf '%s\n' "$$" >"${TRIAL_TEST_ROOT}/tunnel-pid"
  trap 'exit 0' TERM
  printf '%s\n' 'Forwarding from 127.0.0.1:18443 -> 8443'
  while :; do sleep 0.05; done
  ;;
*) exit 2 ;;
esac
KUBE
cat >"${trial_tmp}/bin/client" <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
[ "${WAR_ZONE_TOKEN}" = private-test-bearer ]
[ "${WAR_ZONE_URL}" = wss://127.0.0.1:18443/zone ]
[ "${WAR_ZONE_TLS_SERVER_NAME}" = trial.example.test ]
for trial_path in "${WAR_SAVE_PATH}" "${WAR_VAULT_PATH}" "${WAR_BOOT_RECOVERY_PATH}"; do
  [ "${trial_path%/*}" = "${WAR_SAVE_PATH%/*}" ]
  [ -d "${trial_path%/*}" ]
done
printf '%s\n' "${WAR_SAVE_PATH%/*}" >"${TRIAL_TEST_ROOT}/save-dir"
printf '%s\n' client-started
[ "${TRIAL_TEST_MODE:-}" != client-failure ] || exit 7
CLIENT
chmod +x "${trial_tmp}/bin/kubectl" "${trial_tmp}/bin/client"
export PATH="${trial_tmp}/bin:${PATH}"
launcher="${repo_root}/tools/try-zone-trial.sh"
run_trial() {
  bash "${launcher}" --client "${trial_tmp}/bin/client" --tls-server-name trial.example.test "$@"
}
run_trial >"${trial_tmp}/success.log" 2>&1
grep -q client-started "${trial_tmp}/success.log"
if grep -q private-test-bearer "${trial_tmp}/success.log"; then exit 1; fi
grep -q -- '--address 127.0.0.1' "${trial_tmp}/calls"
grep -q -- '-mint-ttl 5m' "${trial_tmp}/calls"
if grep -Eq ' get secret| apply | create ' "${trial_tmp}/calls"; then exit 1; fi
[ ! -d "$(cat "${trial_tmp}/save-dir")" ]
if kill -0 "$(cat "${trial_tmp}/tunnel-pid")" 2>/dev/null; then exit 1; fi
for mode in mint-failure tunnel-failure client-failure; do
  set +e
  TRIAL_TEST_MODE="${mode}" run_trial >"${trial_tmp}/${mode}.log" 2>&1
  trial_status=$?
  set -e
  [ "${trial_status}" -ne 0 ]
  if grep -q private-test-bearer "${trial_tmp}/${mode}.log"; then exit 1; fi
  if kill -0 "$(cat "${trial_tmp}/tunnel-pid")" 2>/dev/null; then exit 1; fi
  if [ "${mode}" = client-failure ]; then [ "${trial_status}" = 7 ]; fi
done
for server_name in localhost 127.0.0.1 '--bad.test' 'evil/path.test' 'name..test'; do
  if run_trial --tls-server-name "${server_name}" >"${trial_tmp}/invalid.log" 2>&1; then
    printf 'launcher accepted invalid server name: %s\n' "${server_name}" >&2
    exit 1
  fi
done
for trial_port in 0 1023 65536 12x; do
  if run_trial --port "${trial_port}" >"${trial_tmp}/invalid.log" 2>&1; then exit 1; fi
done
mkdir "${trial_tmp}/selected"
cp "${trial_tmp}/bin/client" "${trial_tmp}/selected/selected-client"
cat >"${trial_tmp}/bin/selected-client" <<'DECOY'
#!/usr/bin/env bash
printf '%s\n' path-decoy >"${TRIAL_TEST_ROOT}/decoy-started"
exit 66
DECOY
chmod +x "${trial_tmp}/bin/selected-client"
(
  cd "${trial_tmp}/selected"
  bash "${launcher}" --client selected-client --tls-server-name trial.example.test
) >"${trial_tmp}/selected.log" 2>&1
grep -q client-started "${trial_tmp}/selected.log"
[ ! -f "${trial_tmp}/decoy-started" ]
if kill -0 "$(cat "${trial_tmp}/tunnel-pid")" 2>/dev/null; then exit 1; fi
(
  cd "${trial_tmp}"
  export CDPATH="${trial_tmp}"
  bash "${launcher}" --client selected/selected-client --tls-server-name trial.example.test
) >"${trial_tmp}/cdpath.log" 2>&1
grep -q client-started "${trial_tmp}/cdpath.log"
if kill -0 "$(cat "${trial_tmp}/tunnel-pid")" 2>/dev/null; then exit 1; fi
printf '%s\n' 'TEST PASS — private trial launcher scopes credentials, isolates saves and cleans up'
