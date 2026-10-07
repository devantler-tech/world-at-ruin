# 0025: Bound opt-in client movement networking

Status: accepted

`ZoneConnection` selects movement only when `WAR_ZONE_MOVEMENT=1` at connect
time. The selection remains fixed for that socket. Ordinary connections request
wire v2, retain their receive-only transport contract, and keep the original
v1/v2 decoder. The movement connection requests v3 and uses an explicit decoder
for v3 replication and own-state acknowledgements; versions cannot mix within
that connection. A join snapshot is required before sending or accepting an ACK.

Movement is a nonvisual networking API, not player prediction. A producer calls
`queue_movement(Vector2, sprint)` with fresh planar input. Finite vectors are
clamped to the unit circle and truncated toward zero into integer thousandths;
invalid samples leave the previous valid sample untouched. The canonical
17-byte binary intent includes only sequence, direction, sprint and ground mode.
The server owns speed, position, tick and observer identity.

`poll()` uses native monotonic time and sends at most one newest sample every
33,334 microseconds. It never emits a catch-up burst or automatically resends the
last input. Producer silence therefore lets the server's tick hold expire. One
unsent sample, 64 unacknowledged sequences and 1,088 outbound bytes bound memory.
Backpressure retains the newest unsent sample without consuming a sequence.
A failed write, invalid buffer report, two-second unacknowledged/blocked deadline,
or signed-64 sequence exhaustion closes the connection with a classified error.

The 43-byte own-state ACK is independent of replication. Its sequence is
cumulative and may jump, but cannot exceed successfully sent input or regress.
Its completed tick cannot regress; the same tick may only repeat identical state.
The same sequence at a later tick can update position during held movement.
Consumers receive a copied authoritative state, and ACKs never enter
`ReplicaStore` or change its tick. Snapshot resynchronization preserves the own
stream. Close, hangup, failure and reconnect discard movement state; a new join
begins sequence ownership afresh.

Literal movement fixtures are checked by Go and Godot. Required client CI also
executes a fixed native Godot probe against the built zone over verified TLS,
using test-only ephemeral trust. It proves retained v2, movement application,
silence stop, reconnect, operator-off refusal and incorrect TLS identity/trust refusal.
Missing native prerequisites fail the explicitly enabled proof. Production TLS
continues to use system trust; no insecure option is added.

Player input wiring, integer prediction, reconciliation and rendering remain
under #812. Real-platform correction and latency measurement remain under #813;
production activation remains under #569. The networking flag is retained until
those acceptance gates support activation and retirement; a passed disposable
trial does not authorize production serving.
