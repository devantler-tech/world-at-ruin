package allocatorpeer

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/netip"
	"reflect"
	"slices"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/allocatordiscovery"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	corev1 "k8s.io/api/core/v1"
)

// nilSource also rejects typed nil readers before any operation can call them.
func nilSource(value any) bool {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	kind := v.Kind()
	if kind == reflect.Chan || kind == reflect.Func || kind == reflect.Interface || kind == reflect.Map || kind == reflect.Pointer || kind == reflect.Slice {
		return v.IsNil()
	}
	return false
}

// validConfig requires a complete distinct peer map and bounded transport and allocation inputs.
func validConfig(cfg Config) bool {
	if !validGeneration(cfg.Record) || !handoffidentity.DNSLabel(cfg.AllocatorNamespace) || cfg.Timeout < 0 || cfg.Timeout > 30*time.Second || len(cfg.Peers) != len(cfg.Record.MemberPodUIDs) {
		return false
	}
	keys := make(map[[32]byte]bool)
	for _, uid := range cfg.Record.MemberPodUIDs {
		peer, ok := cfg.Peers[uid]
		_, numericName := netip.ParseAddr(peer.ServerName)
		if !ok || numericName == nil || !handoffidentity.DNSSubdomain(peer.ServerName) || peer.SPKI == [32]byte{} || keys[peer.SPKI] {
			return false
		}
		keys[peer.SPKI] = true
	}
	_, selected := cfg.Peers[cfg.ActorUID]
	a := cfg.Allocation
	return selected && handoffidentity.DNSLabel(a.Namespace) && len(a.Fleet) <= 63 && handoffidentity.DNSSubdomain(a.Fleet) && handoffidentity.DNSLabel(a.TLSPortName) && handoffidentity.Fingerprint(a.WrappingKeyFingerprint)
}

// validGeneration checks canonical membership and the store's domain-separated digest.
func validGeneration(record nakamageneration.Record) bool {
	if record.ReaderOnly() || !handoffidentity.OpaqueUTF8(record.GenerationID, 128) || !handoffidentity.OpaqueUTF8(record.Version, 1024) || record.Version == "*" || record.State != "open" || len(record.MemberPodUIDs) == 0 || len(record.MemberPodUIDs) > 256 {
		return false
	}
	for i, uid := range record.MemberPodUIDs {
		if !handoffidentity.OpaqueUTF8(uid, 128) || (i > 0 && record.MemberPodUIDs[i-1] >= uid) {
			return false
		}
	}
	encoded, err := json.Marshal(record.MemberPodUIDs)
	if err != nil {
		return false
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-generation-members/v1\n"), encoded...))
	return record.MemberSetDigest == hex.EncodeToString(digest[:])
}

// sameGeneration binds the complete open record to its exact private storage version.
func sameGeneration(got, want nakamageneration.Record) bool {
	return validGeneration(got) && got.GenerationID == want.GenerationID && got.Version == want.Version && got.State == want.State && got.MemberSetDigest == want.MemberSetDigest && slices.Equal(got.MemberPodUIDs, want.MemberPodUIDs)
}

// selectBinding validates the complete join and deterministically chooses the selected actor's socket.
func selectBinding(cfg Config, snapshot allocatordiscovery.Snapshot) (Binding, error) {
	if !handoffidentity.OpaqueUTF8(snapshot.PodResourceVersion, 1024) || !handoffidentity.OpaqueUTF8(snapshot.EndpointSliceResourceVersion, 1024) || len(snapshot.Members) != len(cfg.Record.MemberPodUIDs) {
		return Binding{}, ErrObservation
	}
	seen := make(map[string]bool)
	names := make(map[string]bool)
	sockets := make(map[netip.AddrPort]string)
	var selected allocatordiscovery.Member
	total := 0
	for _, member := range snapshot.Members {
		id := member.Identity
		if _, ok := cfg.Peers[id.UID]; !ok || seen[id.UID] || names[id.Name] || id.Namespace != cfg.AllocatorNamespace || !handoffidentity.DNSSubdomain(id.Name) || !handoffidentity.OpaqueUTF8(member.ResourceVersion, 1024) || !condition(member.Ready) {
			return Binding{}, ErrObservation
		}
		seen[id.UID] = true
		names[id.Name] = true
		for _, endpoint := range member.Endpoints {
			total++
			a := endpoint.Address
			if total > 10000 || !a.IsValid() || a.Zone() != "" || a.Is4In6() || a.IsUnspecified() || a.IsMulticast() || a.IsLoopback() || a.IsLinkLocalUnicast() || endpoint.Port == 0 || !condition(endpoint.Ready) || !condition(endpoint.Serving) || !condition(endpoint.Terminating) {
				return Binding{}, ErrObservation
			}
			socket := netip.AddrPortFrom(a, endpoint.Port)
			if _, exists := sockets[socket]; exists {
				return Binding{}, ErrObservation
			}
			sockets[socket] = id.UID
		}
		if id.UID == cfg.ActorUID {
			selected = member
		}
	}
	endpoints := selected.EligibleEndpoints()
	if len(endpoints) == 0 {
		return Binding{}, ErrObservation
	}
	slices.SortFunc(endpoints, func(a, b allocatordiscovery.Endpoint) int {
		if order := a.Address.Compare(b.Address); order != 0 {
			return order
		}
		if a.Port < b.Port {
			return -1
		}
		if a.Port > b.Port {
			return 1
		}
		return 0
	})
	return Binding{GenerationID: cfg.Record.GenerationID, SourceVersion: cfg.Record.Version, MemberSetDigest: cfg.Record.MemberSetDigest, ActorUID: cfg.ActorUID, PodName: selected.Identity.Name, PodResourceVersion: selected.ResourceVersion, PodListResourceVersion: snapshot.PodResourceVersion, EndpointSliceResourceVersion: snapshot.EndpointSliceResourceVersion, Address: netip.AddrPortFrom(endpoints[0].Address, endpoints[0].Port), ServerName: cfg.Peers[cfg.ActorUID].ServerName}, nil
}

// condition refuses values outside Kubernetes's three-valued condition vocabulary.
func condition(value corev1.ConditionStatus) bool {
	return value == corev1.ConditionTrue || value == corev1.ConditionFalse || value == corev1.ConditionUnknown
}
