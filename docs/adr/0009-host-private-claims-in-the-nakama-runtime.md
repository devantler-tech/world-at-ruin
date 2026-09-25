# Host private claims in the Nakama runtime

Status: proposed for #888, part of #569.

## Decision

The enabled handoff runtime can independently opt into a private HTTPS listener
through `WAR_HANDOFF_CLAIMS_ENABLED=true` in Nakama `runtime.env`. Disabled mode
does not read private listener credentials or bind a socket. The listener uses
separate server credentials and dedicated workload trust roots, requires verified
client certificates, and composes the existing claim handler with the same lease
store and pinned Agones resource resolver as allocation. No claim RPC is public.

Initialization validates bounded credential material and reserves the explicit
bind address before registering public handoff admission. Serving starts only
after all runtime registrations succeed; every startup failure releases the
socket and dependency transports. Connections, headers, reads, writes and idle
time are bounded independently of the claim handler's body and storage deadline.

The module lifetime owns both private and public admission. Shutdown closes new
admission, cancels active claims and drains handlers before retiring dependencies,
within the caller's deadline and a fixed upper bound. Unexpected private serving
failure cancels the module lifetime so public handoffs cannot keep allocating
places whose claim service has stopped. Request and startup errors expose no
credential values, material paths or durable lease contents.

## Activation boundary

This is a default-off composition surface, not a platform deployment. Private
network exposure, attested workload identity issuance and rotation, trusted
session-end production, restart recovery and the complete cluster smoke remain
under #567/#569. Allocator-generation fencing remains #793. Socket closure is not
proof of zone death, and this listener never releases a claimed lease.

Credential rotation requires controlled runtime replacement. Existing zone tokens,
wire messages and persisted records keep their formats.

Issue #881 tracks retiring both temporary claim opt-ins after the complete
sealed handoff passes its production activation gates.
