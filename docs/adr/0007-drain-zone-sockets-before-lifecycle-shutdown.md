# Drain zone sockets before lifecycle shutdown

Status: accepted for the existing opt-in zone server (#878, part of #569).

## Context

An upgraded WebSocket is a hijacked connection, outside HTTP server shutdown.
The zone owns its admission handlers, transport workers and observer state, so
successful teardown must cover all three before announcing lifecycle shutdown.
A canceled private claim may already have committed durable ownership.

## Decision

`Hub.Shutdown` is terminal and runs on the simulation owner after its tick loop
stops. Under the admission lock it closes registration and discards pending
attachments. It cancels admitted requests, removes attached observer interest
on that owner, and forcibly closes every registered WebSocket, including one
whose close handshake is stalled. All registered handlers and transport workers
must exit before the drain reports success. A racing upgrade is either included
in that drain or closed by its still-registered handler without attachment.

The caller supplies a deadline. Expiry reports incomplete shutdown and never
reopens admission; another call may await the same drain. No mutex is held
across transport I/O. No network goroutine accesses the simulation world.

The serving command closes HTTP ingress, drains the hub with a five-second
budget, then invokes Agones lifecycle shutdown. Every serving exit runs this
cleanup, including failed readiness. Errors remain visible in the command's
result, and an error in one cleanup step does not skip the others.

## Boundaries and verification

Transport completion is not authority to release a durable claimed lease.
There is no compensating release for a canceled or uncertain claim, no private
session-end endpoint, and no process-death inference. Those remain separately
authenticated and fenced lifecycle work under #567/#569. Existing serving flags
retain their defaults; no save, wire format or gameplay feature changes.

Real TLS socket tests reproduce surviving hijacked connections, pending and
late admission, canceled claims and bounded drain waits. A command regression
exercises the actual serving function against the real SDK transport and checks
that new admission is unavailable at the sidecar's shutdown boundary. The full
command suite also covers deadline, signal, readiness failure and flag-off exits.
