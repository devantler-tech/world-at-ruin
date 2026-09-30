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
  if [ "${TRIAL_TEST_MODE:-}" = ignore-term ]; then trap '' TERM; fi
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
case "${TRIAL_TEST_MODE:-}" in
  signal-int|signal-term|ignore-term)
    trap 'exit 0' TERM
    if [ "${TRIAL_TEST_MODE:-}" = ignore-term ]; then trap '' TERM; fi
    printf '%s\n' "$$" >"${TRIAL_TEST_ROOT}/client-pid"
    while :; do sleep 0.05; done
    ;;
esac
CLIENT
chmod +x "${trial_tmp}/bin/kubectl" "${trial_tmp}/bin/client"
export PATH="${trial_tmp}/bin:${PATH}"
launcher="${repo_root}/tools/try-zone-trial.sh"
# Run the actual launcher with fixture boundaries and optional extra arguments;
# return its exit status unchanged so normal client failure remains observable.
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

# Go starts the shell directly, rather than through Bash's asynchronous list:
# background Bash commands can inherit ignored SIGINT and make that control
# meaningless. The preflight proves this exact spawn path handles SIGINT.
cat >"${trial_tmp}/signal-check.go" <<'GO'
package main

import (
  "bufio"
  "fmt"
  "os"
  "os/exec"
  "path/filepath"
  "strconv"
  "strings"
  "syscall"
  "time"
)

func fail(reason string) {
  fmt.Fprintf(os.Stderr, "TEST FAIL — trial signal cleanup: %s\n", reason)
  os.Exit(1)
}

func waitFile(path string) bool {
  deadline := time.Now().Add(3 * time.Second)
  for time.Now().Before(deadline) {
    if _, err := os.Stat(path); err == nil { return true }
    time.Sleep(10 * time.Millisecond)
  }
  return false
}

func waitExit(done <-chan error, duration time.Duration) (int, bool) {
  select {
  case err := <-done:
    if err == nil { return 0, true }
    if exit, ok := err.(*exec.ExitError); ok { return exit.ExitCode(), true }
    return -1, true
  case <-time.After(duration):
    return 0, false
  }
}

func processAlive(path string) bool {
  raw, err := os.ReadFile(path)
  if err != nil { return false }
  pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
  return err == nil && pid > 0 && syscall.Kill(pid, 0) == nil
}

func run(root, launcher, mode string, signal syscall.Signal, expected int) error {
  for _, name := range []string{"client-pid", "tunnel-pid", "save-dir"} {
    _ = os.Remove(filepath.Join(root, name))
  }
  log, err := os.Create(filepath.Join(root, mode+".log"))
  if err != nil { return fmt.Errorf("could not create private fixture log") }
  defer log.Close()
  command := exec.Command("bash", launcher, "--client", filepath.Join(root, "bin/client"), "--tls-server-name", "trial.example.test")
  command.Env = append(os.Environ(), "TRIAL_TEST_MODE="+mode)
  command.Stdout, command.Stderr = log, log
  command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
  if err := command.Start(); err != nil { return fmt.Errorf("could not start launcher") }
  // This group was created by the helper and contains only its test fixtures.
  // Even a deliberately failing old launcher cannot strand those fixtures.
  defer syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
  done := make(chan error, 1)
  go func() { done <- command.Wait() }()
  if !waitFile(filepath.Join(root, "client-pid")) {
    return fmt.Errorf("the long-lived client never reached its launch boundary")
  }
  canary := exec.Command(os.Args[0], "--canary")
  canary.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: command.Process.Pid}
  canaryInput, err := canary.StdinPipe()
  if err != nil { return fmt.Errorf("could not create process-scope input") }
  canaryOutput, err := canary.StdoutPipe()
  if err != nil { return fmt.Errorf("could not create process-scope response") }
  if err := canary.Start(); err != nil { return fmt.Errorf("could not start process-scope control") }
  canaryDone := make(chan struct{})
  go func() { _ = canary.Wait(); close(canaryDone) }()
  defer func() { _ = canaryInput.Close(); _ = canary.Process.Kill(); <-canaryDone }()
  if err := command.Process.Signal(signal); err != nil { return fmt.Errorf("could not deliver signal to launcher") }
  status, exited := waitExit(done, 4*time.Second)
  if !exited { return fmt.Errorf("launcher deferred %s while its client remained alive", mode) }
  if status != expected { return fmt.Errorf("%s returned %d, expected %d", mode, status, expected) }
  if processAlive(filepath.Join(root, "client-pid")) || processAlive(filepath.Join(root, "tunnel-pid")) {
    return fmt.Errorf("%s left an owned client or tunnel alive", mode)
  }
  // Reap immediately: kill(pid, 0) can succeed for an unreaped dead child.
  select {
  case <-canaryDone:
    return fmt.Errorf("cleanup stopped a process it did not own")
  default:
  }
  // A response after cleanup proves the process still executes, even if its
  // Wait goroutine has not yet delivered an exit notification.
  if _, err := fmt.Fprintln(canaryInput, "alive"); err != nil {
    return fmt.Errorf("cleanup stopped a process it did not own")
  }
  response := make(chan string, 1)
  go func() { line, _ := bufio.NewReader(canaryOutput).ReadString('\n'); response <- line }()
  select {
  case <-canaryDone:
    return fmt.Errorf("cleanup stopped a process it did not own")
  case line := <-response:
    if line != "ALIVE\n" { return fmt.Errorf("cleanup stopped a process it did not own") }
  case <-time.After(time.Second):
    return fmt.Errorf("the unrelated process did not respond after cleanup")
  }
  profile, err := os.ReadFile(filepath.Join(root, "save-dir"))
  if err != nil { return fmt.Errorf("fixture profile location was not recorded") }
  if _, err := os.Stat(strings.TrimSpace(string(profile))); !os.IsNotExist(err) {
    return fmt.Errorf("%s retained the temporary profile", mode)
  }
  output, err := os.ReadFile(filepath.Join(root, mode+".log"))
  if err != nil || strings.Contains(string(output), "private-test-bearer") {
    return fmt.Errorf("%s did not keep the fixture bearer private", mode)
  }
  return nil
}

func probeSIGINT(root string) error {
  ready := filepath.Join(root, "signal-ready")
  _ = os.Remove(ready)
  command := exec.Command("bash", "-c", `trap 'exit 130' INT; : > "$1"; while :; do sleep 0.05; done`, "signal-probe", ready)
  command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
  if err := command.Start(); err != nil { return fmt.Errorf("could not start SIGINT disposition control") }
  defer syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
  done := make(chan error, 1)
  go func() { done <- command.Wait() }()
  if !waitFile(ready) { return fmt.Errorf("SIGINT disposition control did not become ready") }
  if err := command.Process.Signal(syscall.SIGINT); err != nil { return fmt.Errorf("could not send SIGINT disposition control") }
  status, exited := waitExit(done, time.Second)
  if !exited || status != 130 { return fmt.Errorf("spawn path inherited ignored SIGINT; the control would be invalid") }
  return nil
}

func main() {
  if len(os.Args) == 2 && os.Args[1] == "--canary" {
    input := bufio.NewScanner(os.Stdin)
    for input.Scan() {
      if input.Text() == "alive" { fmt.Println("ALIVE") }
    }
    return
  }
  if len(os.Args) != 3 { fail("invalid fixture arguments") }
  root, launcher := os.Args[1], os.Args[2]
  if err := probeSIGINT(root); err != nil { fail(err.Error()) }
  fmt.Println("SIGNAL CONTROL PASS — directly spawned Bash handles SIGINT")
  cases := []struct{mode string; signal syscall.Signal; expected int}{
    {"signal-int", syscall.SIGINT, 130},
    {"signal-term", syscall.SIGTERM, 143},
    {"ignore-term", syscall.SIGTERM, 143},
  }
  for _, control := range cases {
    if err := run(root, launcher, control.mode, control.signal, control.expected); err != nil { fail(err.Error()) }
    fmt.Printf("SIGNAL CLEANUP PASS — %s client+tunnel+profile cleaned, unrelated process retained\n", control.mode)
  }
}
GO
GOTOOLCHAIN=local GOCACHE="${GOCACHE:-${trial_tmp}/go-cache}" go build -o "${trial_tmp}/signal-check" "${trial_tmp}/signal-check.go"
"${trial_tmp}/signal-check" "${trial_tmp}" "${launcher}"

# Negative control: a private copy broadcasts TERM to its entire process group
# during cleanup. It must fail specifically because the unrelated canary died,
# while the real launcher above passes independently with identical fixtures.
awk '{ print } $0 == "  trap \047\047 INT TERM" { print "  kill -TERM -- -$$" }' \
  "${launcher}" >"${trial_tmp}/broad-cleanup-launcher.sh"
if "${trial_tmp}/signal-check" "${trial_tmp}" "${trial_tmp}/broad-cleanup-launcher.sh" \
  >"${trial_tmp}/scope-ablation.log" 2>&1; then
  printf '%s\n' 'TEST FAIL — broad process-group cleanup passed the unrelated-process control' >&2
  exit 1
fi
grep -q 'cleanup stopped a process it did not own' "${trial_tmp}/scope-ablation.log"
printf '%s\n' 'SCOPE ABLATION PASS — broad process-group cleanup is refused by the unrelated-process control'
printf '%s\n' 'TEST PASS — private trial launcher scopes credentials, isolates saves and cleans up'
