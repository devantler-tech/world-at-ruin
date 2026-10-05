# 0026: Keep client ground prediction explicit and independent of input ownership

Status: accepted

`GroundStep` and `PredictedMovement` are latent, nonvisual libraries. They have
no player-controller, boot or production connection caller. The native acceptance
fixture explicitly constructs them; ordinary launches retain their local physics.
Full player composition and its motion evidence remain #812.

The predictor accepts one immutable explicit isolated-flat specification:
server-authored maximum speed, six bounds within ±1,000,000 mm and an intent hold
of 1–300 ticks. Unknown configuration and collision modes refuse. The client
cannot obtain these facts from wire v3, so fixture configuration is not evidence
of production configuration distribution. Separation, swept collision, terrain,
gravity and jumping are outside this one-actor reference.

Ground arithmetic uses signed 64-bit integers: planar intent is sanitized to
±1,000,000,000 mm/s; the integer square root and directional speed clamp match
the server; displacement truncates toward zero at 30 Hz. Direction thousandths
produce half-cap walking and full-cap sprinting. No floating vector stores
authority state. A generated corpus records every position from actual
`World.SetIntent` and `World.Step`, independently checked by Go and Godot;
the production socket conversion is also checked against its direction vectors.

Successfully sent sequence ownership and speculative tick history are separate.
The caller invokes `record_sent` only after a successful transport write.
The latest sample is speculatively held for the configured duration; every
`step_tick` records the actual effective velocity. A sequence can therefore
appear in multiple tick entries. A cumulative ACK retires pending transmission
ownership while preserving later held tick entries carrying that same sequence.

Reconciliation validates the complete ACK, reanchors to its completed tick and
position, and replays retained future tick entries through the same integer step.
It returns integer correction components. Identical ACKs are idempotent; a newer
authoritative tick can catch up beyond local speculation without fabricating
past ticks. Catch-up clears the unknown remaining hold phase until fresh input
is recorded. Regressed, inconsistent, malformed or unsent-sequence ACKs, missing
replay history, counter exhaustion and overflow latch a refusal before partial
movement mutation. An explicit reset clears all connection state and preserves
only the validated configuration.

History is bounded to 120 ticks and pending ownership to 64 samples; callers may
choose smaller bounds. Neither overflow evicts required replay information.
State and history reads are independent copies.

The v3 server selects the newest input at its mailbox boundary. It does not
report receipt-to-tick mapping, remaining hold phase, speed, bounds or collision
geometry. The retained history is therefore speculative timing, not an attested
reconstruction of network receipt. Equal one-actor arithmetic does not establish
collision parity, synchronized transport phase, smooth rendering or a latency
budget. Interpolation, correction presentation, player controls and production
configuration require their own integration and evaluation under #812/#813.

Validation from the repository root:

```sh
go -C server run ./cmd/groundgoldens > client/tests/data/ground_step_goldens.json
go -C server test -race -count=1 ./sim ./zonesock ./internal/groundgoldens
bash tools/run-client-test.sh ground_step_test
bash tools/run-client-test.sh ground_step_golden_test
bash tools/run-client-test.sh predicted_movement_test
WAR_GODOT_ZONE_PROOF=1 go -C server test -count=1 -timeout 90s -v ./cmd/zone -run '^TestNativeGodotMovement$'
```

The existing required native entrypoint includes the prediction scenario against
the built zone and real Godot WebSocketPeer over verified ephemeral TLS. It
records ownership only after the native write succeeds, consumes live ACK
anchors, exercises speculative movement, reconciliation, silence and reconnect,
and retains the ordinary v2, server-off, wrong-identity and wrong-trust controls.
Missing prerequisites fail the explicitly enabled proof. This disposable
acceptance does not authorize production activation under #569.
