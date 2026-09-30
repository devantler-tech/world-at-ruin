# Try the private zone server

The owner-only trial lets the released client observe the developing zone server
through an authenticated operator tunnel. The server currently runs three scripted
walkers. The client draws their nearby replicas as pale blue capsules; your own
movement remains local. Accounts, shared player control, online combat and server
progression are still in development. This trial has no player-state storage.

Use a client release containing the secure tunnel option, installed through the
Homebrew cask described in the [README](../README.md#play-it). Keep the app closed
before starting the trial. You also need `kubectl`, your existing platform operator
login, and the DNS name covered by the trial's mounted TLS certificate. The
platform's private operator instructions supply that name; do not publish it or
the admission credential in an issue, PR or shared log.

From this repository, run:

```sh
bash tools/try-zone-trial.sh \
  --client '/Applications/World at Ruin.app/Contents/MacOS/World at Ruin' \
  --tls-server-name '<certificate-DNS-name>' \
  --context '<authenticated-platform-context>'
```

The launcher waits for the private workload, mints a five-minute observer token,
and binds a tunnel to `127.0.0.1` only. It passes the token in the client's process
environment without printing it. The certificate must still prove its configured
DNS identity against the client's normal trusted certificate roots. No certificate
verification bypass or system DNS change is needed. Use `--port <port>` if the
default local port `18443` is already occupied.

The launcher creates a private temporary directory and redirects all three game
state files there: the character, progression vault and boot-recovery ledger. This
trial starts with a separate character and leaves your usual saves in place. Make
a character in the first-run screen. Closing the client or stopping the launcher
closes both processes, clears the launcher's credential and removes the trial's
temporary files. Relaunch the script for a fresh token and trial character. The
trial character is deliberately temporary; it is not an online player account.

A small status below the build number says whether the trial is connecting,
waiting for world data, or live with its last applied tick and nearby entity
count. An open socket alone does not show live: that state requires an applied
world snapshot. A stopped connection asks you to relaunch the trial. The ordinary
client has no trial status. For private operator evaluation, the client writes
one `ZONE_TRIAL_LIVE` log line after its first applied snapshot; it contains only
frame, tick and entity counts, with no address, certificate name or credential.

To see the live scripted actors, follow the lit passage out of the starting cave
and head toward the Wardens' Shrine in the center of the Reach. The cave begins
west of that center; the server's demo actors move within roughly twenty metres
of the shrine. Look for moving pale blue capsules nearby. The demo has a flat
ground plane, so its provisional markers can intersect the client's generated
terrain. They are development markers, not finished remote characters. Press
`L` or `F1` to follow the client development log.

Only one connection may use observer 1 at a time. Finish any `/zoneprobe` check
before launching the app, and close an earlier trial client before starting
another. A lost tunnel or server restart stops replication for that session;
the local world remains available. Close and relaunch the operator script to
reconnect. A trial restart resets its scripted demonstration only and grants no
permission to reset real characters or progression.

The ordinary client remains offline unless `WAR_ZONE_URL` names a zone. The new
`WAR_ZONE_TLS_SERVER_NAME` setting defaults to empty, preserving the URL's normal
TLS identity and transport call. A nonempty setting is accepted only for an
explicit `localhost`, canonical IPv4 loopback address, or bracketed IPv6 loopback
URL. It must name a valid DNS identity with at least two labels. Numeric names,
wildcards, credentials, queries, fragments, escaped authorities, backslashes and
non-loopback destinations are refused before transport configuration. Both the
CA chain and expected DNS identity remain verified.

The `replication` frame-capture scenario injects a committed fixture for visual
regressions. It does not prove connection to the platform trial. Live acceptance
must use the real running server and client connection instead.
