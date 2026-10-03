# ADR 0011 — Private zone integration trial

Status: accepted for the opt-in operator trial; production multiplayer remains gated.

The owner needs to observe the developing realtime server on the existing platform.
The current zone seeds three scripted walkers and streams their deterministic state;
it does not accept player movement, create accounts or persist progression.

The zone ships as a signed, immutable Linux container for amd64 and arm64. Its
default command runs the finite deterministic scenario without a listener. The
runtime contains static zone and read-only probe executables, public CA roots,
and no shell. It runs as UID/GID 65532 and supports a read-only filesystem.
Certificates and admission material are mounted or injected at runtime, never
baked into the image. Release tags identify versions; deployment pins digests.

The integration trial has one private zone process, no public route and no
player storage. Access requires an authenticated operator tunnel, verified TLS,
and a short-lived observer token. The developer admission path serves this
limited integration exercise only. It does not replace Agones allocation,
Nakama identity, durable claims or their pending acceptance gates.

The probe refuses insecure transport and redirects, checks rejected credentials,
and requires advancing, decodable state through both retained wire v1 and v2.
Container CI exercises the actual runtime on both architectures. Publishing
checks the immutable image before signing it and verifies the signature.

Restarting the trial resets its scripted demonstration only. It owns no player
state, and its existence grants no clearance to reset players or activate online
economic mutations. Production activation separately requires allocator fencing,
claimed-session recovery, workload identities and the real handoff proof in #569.
