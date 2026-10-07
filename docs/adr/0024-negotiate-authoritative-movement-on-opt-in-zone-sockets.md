# 0024: Negotiate authoritative movement on opt-in zone sockets

Status: accepted

Movement is an explicit, default-off zone capability. The command enables it
with `-movement-intents`; peers additionally request wire version 3 during the
authenticated WebSocket upgrade. Admission precedes movement authority; the sealed
native trial additionally requires its durable private claim before upgrade.
Retained version 1 and 2 peers keep their existing replication
frames and refuse client data, even when the operator enables movement.

Version 3 retains the version 2 snapshot and delta layout. Its client intent kind
is a fixed 17-byte frame: the ordinary three-byte header, a nonzero uint64
sequence, two signed int16 ground-direction components in thousandths, a canonical
boolean sprint byte and a mode byte. The squared direction length cannot exceed
1,000,000. Ground mode is zero; mode one reserves swimming without enabling it.
The input contains no actor identity, position, speed or client clock.

Each admitted connection controls only its observer. Walking uses half the
actor's server-owned maximum speed and sprint uses that maximum. Integer conversion
feeds the existing deterministic step, which retains its speed, navmesh and capsule
constraints. These experimental ratios are not the final gait or latency budget.
Cast locks, stun enforcement and client prediction remain separate work.

Socket readers keep one latest valid intent, accept only increasing sequence
numbers and process at most 64 input frames between owner phases. Malformed,
replayed and excess intents cannot refresh movement. Text and server-only message
kinds disconnect the peer even after its budget is exhausted. The simulation
owner consumes the mailbox after AI/demo intent and before `World.Step`; input
cannot mutate the world from a socket worker. A bounded hold of 1–300 ticks
(default three) expires to zero. Disconnect and shutdown clear control, while
previously controlled actors stay stopped instead of resuming scripted demo input.
A fresh connection starts with no inherited sequence or movement.

Replication excludes the observer itself, so its delta stream cannot acknowledge
the player's own position. A separate fixed 43-byte acknowledgement kind carries
the cumulative applied sequence, completed authoritative tick and three int64
position coordinates. Receipt does not count as application. A single coalesced
acknowledgement slot remains independent of delta-queue overflow and snapshot
resynchronization. The first outbound frame is always the join snapshot; subsequent
acknowledgements use the ordinary write and idle deadlines.

Literal wire goldens, real TLS ownership/refusal tests, bounded queue controls and
the built command exercise the capability in both flag states. The mandatory
disposable native Nakama trial authenticates, consumes a real sealed handoff,
reads back its durable claim and observes movement through the built zone's TLS
socket. The launcher requires this scenario with the other 21 on Linux amd64 and
arm64. The nonvisual Godot networking API and its native TLS proof are described
in ADR 0025; player input, prediction and reconciliation remain under #812.
These checks do not activate production. Platform serving and irreversible
session-end authority remain independent gates under #569 and #1177.
