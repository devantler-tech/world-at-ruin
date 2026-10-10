# ADR 0037 — Register frozen capabilities before exposure

Status: accepted for the default-off capability composition experiment (#1314). Production allocator authority remains #793.

## Decision

`NewDurableGeneration` privately owns a generation-wide admission writer, its latest acknowledged snapshot, and every registered frozen GameServer grant. Configuration supplies explicit enablement, storage, one observed generation, an incarnation and scoped Kubernetes credentials. It cannot supply a replacement journal, snapshot or grant inventory. The existing `NewGeneration` constructor remains a process-local reference; neither constructor is a production authority.

Preparation freezes exactly one GameServer through the private commit client. Registration derives the original actor and attempt plus name, UID and resourceVersion from that private frozen grant. A separate context-aware gate serializes registration and drain against the acknowledged admission version. The local admission mutex is never held across storage networking. An acknowledged registration enters the conservative private set before the gate is released, even when local closure prevents its capability from being exported.

Closure sets local admission closed before waiting for the durable gate. Every already exported capability immediately refuses new commit admission. After pending registration accounting settles, closure drains the latest admission root and barriers the complete registered set, including registered-but-unexposed entries. A preparation still freezing or queued behind closure exports nothing and writes no registration. The operation has one bounded deadline; no background retry or refreshed target is permitted.

Unknown create, registration or drain acknowledgments permanently close the owner. A plausible partial response is still unknown. Cancellation after dispatch, a committed write with a lost reply, and a crashed process cannot reconstruct a capability, restore a writer snapshot or authorize a receipt. A durable entry survives a crash after registration conservatively. A different incarnation cannot create another root for the same generation. An acknowledged durable drain remains separate from the real GameServer barriers required for a complete process-local receipt.

## Validation and activation boundaries

Behavioral tests hold successful registration replies across closure, serialize concurrent preparation, freeze original identities through intervening resource changes, and lose acknowledgments only after committed storage writes. Empty and complete inventories, copied handles, cancellation, failed barriers and restart controls remain explicit.

The disposable native trial joins actual packaged Nakama storage writes with held mutations at real kube-apiserver/etcd. It independently observes the private PostgreSQL admission row and the resulting GameServer state. Separate successful storage suites do not prove this ordering. The ordinary plugin import guard excludes this composition; the native trial additionally requires explicit default-off enablement.

This experiment does not authenticate exclusive production allocation authority, reopen a generation on restart, adopt serving or retained readers, release quarantine, or deploy a server. Independent recovery remains #1315; production and retained-artifact gates remain #793 and ADRs 0012, 0031, 0032, 0035 and 0036.

## Alternatives

A network call under the local admission mutex would delay closure behind an unavailable dependency. Taking the complete-set snapshot before pending registration accounting would omit a committed grant whose reply was held. Reading the newest version after an uncertain write would restore authority from diagnostic observations. A separate service adds another lifetime without solving the two-storage ordering. One private serialized coordinator preserves immediate local closure and conservative durable accounting with fewer states.
