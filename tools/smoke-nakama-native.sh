#!/usr/bin/env bash
# Own only the disposable containers/network created by this explicit trial.
set -euo pipefail
if [[ $# != 2 || $2 != --experimental || -z $1 ]]; then
  echo 'usage: smoke-nakama-native.sh <local-image> --experimental' >&2
  exit 2
fi
image=$1
state=$(mktemp -d)
network="war-nakama-native-$$-$(basename "$state")"
postgres_id=""
trial_id=""
cleanup() {
  if [[ -n "$trial_id" ]]; then docker rm -f "$trial_id" >/dev/null 2>&1 || true; fi
  if [[ -n "$postgres_id" ]]; then docker rm -f "$postgres_id" >/dev/null 2>&1 || true; fi
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$state"
}
trap cleanup EXIT
user=$(docker image inspect --format '{{.Config.User}}' "$image")
if [[ "$user" != 10001:10001 ]]; then echo 'native trial image must use its non-root identity' >&2; exit 1; fi
set +e
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --pids-limit 64 --memory 512m "$image" > "$state/default.log" 2>&1
refused=$?
set -e
if [[ "$refused" != 2 ]] || ! grep -q 'native trial requires Linux, explicit opt-in' "$state/default.log"; then
  echo 'native trial default invocation did not refuse missing opt-in' >&2; exit 1
fi
docker network create --internal "$network" >/dev/null
# These credentials exist only inside this unpublished, disposable fixture.
export WAR_NATIVE_DB_PASSWORD=native-trial-disposable-password
postgres_id=$(docker run -d --network "$network" --network-alias postgres \
  --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 128 --memory 1g --cpus 2 \
  ghcr.io/cloudnative-pg/postgresql@sha256:78c4fdf165e8ffb1b5b7a7fc6b22b3cf37890a338b4c1c8c4d913896129a86da \
  bash -ec 'printf "%s" native-trial-disposable-password > /tmp/pw; initdb -D /tmp/war-native-pg -U war_native_trial --encoding=UTF8 --pwfile=/tmp/pw --auth-host=scram-sha-256 >/dev/null; printf "host all all all scram-sha-256\n" >> /tmp/war-native-pg/pg_hba.conf; exec postgres -D /tmp/war-native-pg -c listen_addresses=*')
ready=false
for ((attempt=1;attempt<=30;attempt++)); do
  if docker exec "$postgres_id" pg_isready -U war_native_trial >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
if [[ "$ready" != true ]]; then echo 'disposable native database did not become ready' >&2; exit 1; fi
trial_id=$(docker create --network "$network" --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --pids-limit 256 --memory 2g --cpus 2 \
  --tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777 \
  --tmpfs /var/run/secrets/kubernetes.io/serviceaccount:rw,nosuid,nodev,size=1m,uid=10001,gid=10001,mode=0700 \
  -e WAR_NATIVE_DB_PASSWORD "$image" -war-experimental -war-bundle=/out/bundle \
  -war-postgres=postgres:5432 -test.v -test.timeout=6m)
docker start -a "$trial_id" | tee "$state/trial.log"
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$trial_id")
if [[ "$exit_code" != 0 ]] || ! grep -q '^PASS$' "$state/trial.log"; then
  echo 'native Nakama acceptance did not produce a complete passing verdict' >&2; exit 1
fi
if [[ $(grep -c '^--- PASS: Test' "$state/trial.log") != 11 ]]; then
  echo 'native Nakama acceptance did not execute all eleven scenarios' >&2; exit 1
fi
echo 'NAKAMA NATIVE PASS: eleven scenarios; native plugin; disposable PostgreSQL; non-root'
