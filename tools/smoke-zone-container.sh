#!/usr/bin/env bash
# Check the packaged entrypoint, default-off socket and deterministic scenario.
set -euo pipefail
if [[ $# != 1 || -z "$1" ]]; then
  echo 'usage: smoke-zone-container.sh <local-image>' >&2
  exit 2
fi
image="$1"
output="$(docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 32 --memory 128m --cpus 1 "$image")"
if [[ "$output" != 'zone: entities=3 tick=600 hash=99cf0bbe914e3ecc' ]]; then
  echo 'zone container did not match the committed deterministic scenario' >&2
  exit 1
fi
user="$(docker image inspect --format '{{.Config.User}}' "$image")"
if [[ "$user" != '65532:65532' ]]; then
  echo 'zone container must run as the declared non-root identity' >&2
  exit 1
fi
echo 'ZONE CONTAINER PASS: non-root; no network; deterministic 600-tick scenario'

# Exercise the image's TLS listener and probe together. No credential or URL is
# emitted; fixture material is ephemeral and never enters the image build.
credentials="$(mktemp -d)"
server_id=""
cleanup() {
  if [[ -n "$server_id" ]]; then
    docker rm -f "$server_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$credentials"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -keyout "$credentials/key.pem" -out "$credentials/cert.pem" \
  -subj /CN=zoneprobe.example \
  -addext subjectAltName=DNS:zoneprobe.example,IP:127.0.0.1 >/dev/null 2>&1
# UID 65532 must be able to read the bind mount. These are test-only credentials.
chmod 755 "$credentials"
chmod 644 "$credentials/key.pem" "$credentials/cert.pem"
WAR_ZONE_ADMISSION_SECRET="$(openssl rand -hex 32)"
export WAR_ZONE_ADMISSION_SECRET
WAR_ZONE_TOKEN="$(docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true -e WAR_ZONE_ADMISSION_SECRET "$image" \
  -allocation-id container-smoke -mint-token 1 -mint-ttl 2m)"
export WAR_ZONE_TOKEN
server_id="$(docker run -d --rm --network host --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --pids-limit 32 --memory 128m --cpus 1 \
  -v "$credentials:/credentials:ro" -e WAR_ZONE_ADMISSION_SECRET "$image" \
  -listen 127.0.0.1:18443 -allocation-id container-smoke \
  -tls-cert /credentials/cert.pem -tls-key /credentials/key.pem -duration 90s)"
passed=false
for ((attempt=1; attempt<=10; attempt++)); do
  # The kubelet mode receives no admission token and must not enter HTTP.
  if docker run --rm --network host --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --pids-limit 32 --memory 128m --cpus 1 \
    -v "$credentials:/credentials:ro" --entrypoint /zoneprobe \
    "$image" -tls-only -url wss://127.0.0.1:18443/zone \
    -tls-server-name-file /credentials/cert.pem -ca-file /credentials/cert.pem \
    -timeout 1500ms > "$credentials/health.log" 2>&1; then
    passed=true
    break
  fi
  sleep 1
done
if [[ "$passed" != true ]] || [[ "$(cat "$credentials/health.log")" != 'ZONEPROBE TLS PASS' ]]; then
  echo 'zone container verified TLS-only health smoke failed' >&2
  exit 1
fi
for ((attempt=1; attempt<=20; attempt++)); do
  docker run --rm --network host --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --pids-limit 32 --memory 128m --cpus 1 \
    -v "$credentials:/credentials:ro" --entrypoint /zoneprobe \
    "$image" -tls-only -url wss://127.0.0.1:18443/zone \
    -tls-server-name-file /credentials/cert.pem -ca-file /credentials/cert.pem \
    -timeout 1500ms > "$credentials/health.log" 2>&1
  if [[ "$(cat "$credentials/health.log")" != 'ZONEPROBE TLS PASS' ]]; then
    echo 'zone container repeated health check lacked a verdict' >&2
    exit 1
  fi
done
docker logs "$server_id" > "$credentials/server.log" 2>&1
if grep -q 'TLS handshake error' "$credentials/server.log"; then
  echo 'zone container health checks caused TLS handshake errors' >&2
  exit 1
fi
cat "$credentials/health.log"
passed=false
for ((attempt=1; attempt<=10; attempt++)); do
  if docker run --rm --network host --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --pids-limit 32 --memory 128m --cpus 1 \
    -v "$credentials:/credentials:ro" -e WAR_ZONE_TOKEN --entrypoint /zoneprobe \
    "$image" -url wss://127.0.0.1:18443/zone -ca-file /credentials/cert.pem \
    -timeout 3s > "$credentials/probe.log" 2>&1; then
    passed=true
    break
  fi
  sleep 1
done
if [[ "$passed" != true ]]; then
  echo 'zone container TLS/admission/stream smoke failed' >&2
  exit 1
fi
if ! grep -q '^ZONEPROBE PASS' "$credentials/probe.log"; then
  echo 'zone container probe returned without an affirmative verdict' >&2
  exit 1
fi
cat "$credentials/probe.log"
