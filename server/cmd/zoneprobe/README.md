# Private zone-trial probe

`zoneprobe` checks the real TLS/WebSocket path of an operator-only development
trial. It sends no gameplay messages and writes no account, character, inventory,
mastery or handoff state. It is not a multiplayer readiness verdict.

Build with `go build -o zoneprobe ./cmd/zoneprobe` from `server/`. The zone image
also contains `/zoneprobe`.

Provide an unexpired trial admission token through `WAR_ZONE_TOKEN` in the
operator's process environment, then run:

```sh
zoneprobe -url 'wss://<verified-hostname>:<port>/zone' -timeout 10s
```

The token is never accepted as a command-line argument, echoed or included in an
error. Keep its minting and delivery in the private operator workflow and unset
the environment variable afterward. Never paste a token into a CI log, issue,
PR or shared terminal transcript.

For a fixture with an explicit PEM trust bundle, add `-ca-file /path/to/ca.pem`.
That file replaces the system roots for this probe and is limited to 1 MiB. For
an authenticated loopback port-forward, use the certificate's DNS identity:

```sh
zoneprobe -url 'wss://127.0.0.1:18443/zone' \
  -tls-server-name '<certificate-DNS-name>' -timeout 10s
```

The identity override is accepted only for `localhost` or loopback IP targets
and a valid DNS name containing at least two labels. TLS verification always
remains enabled. Redirects and environment-provided HTTP proxies are not used.
URLs with credentials, queries or fragments are refused. The timeout bounds
network work across the whole probe, including both protocol connections, and
must be positive and at most one minute.

The probe requires an **idle observer**. It first proves that absent and wrong
bearer credentials each receive HTTP 401 without a WebSocket upgrade. It then
connects with the supplied token twice, sequentially: the retained protocol with
no version header, followed by the newest protocol with its version header.
Each stream must begin with a binary snapshot and deliver a later tick whose
entity state actually changes. The decoder and continuity checks reject text,
malformed frames, wrong versions, stale ticks, observer changes, invalid entity
or cast references, and stalled streams. Frame and folded-state sizes are bounded
by the existing wire contract. A fresh snapshot can resynchronize the stream.

Each connection is closed before the next, with a short bounded grace for the
simulation's next-tick observer cleanup. A busy observer causes failure: the
probe never evicts, ends or releases an existing session. Do not run it while a
client uses the same token/observer. Success proves this demo's live replication;
a zone with no changing observable entities cannot produce that proof.

Successful stdout contains only:

```text
ZONEPROBE PASS denied=2 protocols=1,2 frames=4 state=advancing
```

The frame count can vary. Failures print only a fixed sanitized category to
stderr. No endpoint, certificate path, credential, entity identity, upstream
response body or raw frame appears in either output. Exit codes are `0` for a
verified trial stream, `1` for a failed proof/output, and `2` for invalid local
configuration. The probe does not invoke Agones, Nakama or Kubernetes APIs and
does not restart the trial. The trial's private operator workflow owns restart
and token renewal.

Run `go test -race ./cmd/zoneprobe` for verified TLS, retained/newest streams,
admission refusal, hostile/stalled frames, tunnel identity, and real-hub observer
ownership coverage. The container smoke additionally invokes this same CLI
against the built zone process.
