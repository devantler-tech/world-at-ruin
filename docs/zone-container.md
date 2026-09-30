# Zone server container

`ghcr.io/devantler-tech/world-at-ruin/zone:vX.Y.Z` contains the exact released
zone source for Linux amd64 and arm64. The **Zone server CD** workflow signs the
multiarchitecture digest and records it in its summary. Pin that digest when
deploying; there is deliberately no mutable `latest` deployment channel.

The default invocation performs 600 deterministic ticks, prints the committed
state hash and exits. No socket opens. A listening trial explicitly supplies
`-listen`, `-allocation-id`, `-tls-cert` and `-tls-key`, with a hex admission
secret of at least 32 decoded bytes supplied through `WAR_ZONE_ADMISSION_SECRET`.
Mount certificates read-only. Keep the root filesystem read-only, all Linux
capabilities dropped and privilege escalation disabled. The process runs as
65532:65532, so mounted files must be readable by that identity.

This developer admission configuration is for the **owner-only integration
trial**, not production player allocation. The running scenario contains three
scripted walkers. The released client can receive their replicas; its movement
still remains local. There are no server accounts or persisted player rewards.
Agones and Nakama production activation remain subject to #566, #567 and #569.

`/zoneprobe` is a read-only connection check (see its
[instructions](../server/cmd/zoneprobe/README.md)). CI tests the actual container
on both architectures. A deployment readback must additionally exercise the
real running service and released client; image tests alone do not prove a
platform trial is reachable.

The signed `zone-manifests` artifact contains the private trial's restricted
Deployment, service and tenant-owned admission-secret seed/readback. The trial
restarts its scripted process hourly to reload mounted TLS material. Token
minting remains short-lived, and a restart never affects player saves.

The server publisher is independent of the client asset release. A failed server
publication is a delivery failure requiring repair; it does not silently change
or remove an already published client asset. The server is not deployed merely
because its image exists. Trial registration, access and live verification are
tracked in #927.
