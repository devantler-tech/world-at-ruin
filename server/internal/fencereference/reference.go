// Package fencereference implements an inactive allocator commit-authority
// reference. Its owned in-memory ledger is the ONLY mutation it can fence.
// It cannot authorize native Agones writes, durable recovery or quarantine release.
package fencereference

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"sync"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
)

var (
	ErrDisabled = errors.New("fence reference: disabled")
	ErrInvalid  = errors.New("fence reference: invalid configuration or identity")
	ErrIdentity = errors.New("fence reference: actor identity refused")
	ErrTicket   = errors.New("fence reference: dispatch ticket refused")
	ErrBudget   = errors.New("fence reference: admission budget exhausted")
	ErrConflict = errors.New("fence reference: conflicting operation")
	ErrClosed   = errors.New("fence reference: generation closed")
	ErrProof    = errors.New("fence reference: proof unavailable or mismatched")
)

// Config must explicitly enable the reference. No runtime consumes this flag.
// ActorSPKI is operator-trusted exact allocator UID to server SPKI SHA-256.
type Config struct {
	Enabled     bool
	Record      nakamageneration.Record
	ActorSPKI   map[string][32]byte
	MaxAttempts int
}

// Binding identifies an exact immutable durable source observation. It is
// identity data, never authority or a fence on its own.
type Binding struct {
	GenerationID    string
	MemberSetDigest string
	SourceVersion   string
}

// Allocation is a structured record OWNED by the reference authority.
type Allocation struct {
	ActorUID    string
	AttemptID   string
	ResourceUID string
}

// Ticket is an opaque, process-local capability for one admitted attempt.
type Ticket struct {
	owner *authority
	id    uint64
}

// Receipt is an opaque, process-local proof from one terminal authority.
// It has no serialized representation and cannot survive a restart.
type Receipt struct {
	owner    *authority
	binding  Binding
	revision uint64
	members  []string
}

// Members returns a detached view of the complete set fenced by this receipt.
func (r Receipt) Members() []string { return slices.Clone(r.members) }

// Resolution concerns only the owned reference ledger, never Kubernetes.
type Resolution struct {
	Allocation  Allocation
	Unallocated bool
}

type admitted struct {
	ticket  Ticket
	actor   string
	attempt string
}

// Reference serializes admission, close and every ledger mutation. There is no
// callback, network forwarding, deletion, persistence or background worker.
type Reference struct {
	*authority
}

// Copies of the public handle share the same private authority, including its
// mutex and terminal state; they cannot keep a separate open commit boundary.
type authority struct {
	mu          sync.Mutex
	binding     Binding
	members     []string
	actorKeys   map[string][32]byte
	maxAttempts int
	revision    uint64
	state       string
	attempts    map[string]admitted
	tickets     map[uint64]admitted
	allocations map[string]Allocation
	resources   map[string]string
}

// New refuses the zero/default flag before constructing any authority.
func New(cfg Config) (*Reference, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	rec := cfg.Record
	if !opaque(rec.GenerationID) || !handoffidentity.OpaqueUTF8(rec.Version, 1024) || rec.Version == "*" ||
		rec.State != "open" || len(rec.MemberPodUIDs) < 1 || len(rec.MemberPodUIDs) > 256 ||
		!slices.IsSorted(rec.MemberPodUIDs) || len(cfg.ActorSPKI) != len(rec.MemberPodUIDs) ||
		cfg.MaxAttempts < 0 || cfg.MaxAttempts > 4096 {
		return nil, ErrInvalid
	}
	keys := make(map[string][32]byte, len(cfg.ActorSPKI))
	seenKeys := make(map[[32]byte]bool, len(cfg.ActorSPKI))
	for index, uid := range rec.MemberPodUIDs {
		key, exists := cfg.ActorSPKI[uid]
		if !opaque(uid) || (index > 0 && uid == rec.MemberPodUIDs[index-1]) ||
			!exists || key == [32]byte{} || seenKeys[key] {
			return nil, ErrInvalid
		}
		keys[uid] = key
		seenKeys[key] = true
	}
	encoded, err := json.Marshal(rec.MemberPodUIDs)
	if err != nil {
		return nil, ErrInvalid
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-generation-members/v1\n"), encoded...))
	if rec.MemberSetDigest != hex.EncodeToString(digest[:]) {
		return nil, ErrInvalid
	}
	budget := cfg.MaxAttempts
	if budget == 0 {
		budget = 256
	}
	return &Reference{authority: &authority{
		binding: Binding{GenerationID: rec.GenerationID, MemberSetDigest: rec.MemberSetDigest, SourceVersion: rec.Version},
		members: slices.Clone(rec.MemberPodUIDs), actorKeys: keys, maxAttempts: budget,
		revision: 1, state: "open", attempts: make(map[string]admitted), tickets: make(map[uint64]admitted),
		allocations: make(map[string]Allocation), resources: make(map[string]string),
	}}, nil
}

func opaque(value string) bool { return handoffidentity.OpaqueUTF8(value, 128) }

// Binding returns identity data detached from the caller's original config.
func (r *Reference) Binding() Binding { return r.binding }

// Admit is the single atomic dispatch-admission decision. A repeated attempt
// never receives another ticket, including after an uncertain RPC result.
func (r *Reference) Admit(actorUID, attemptID string) (Ticket, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state != "open" {
		return Ticket{}, ErrClosed
	}
	if _, ok := r.actorKeys[actorUID]; !ok {
		return Ticket{}, ErrIdentity
	}
	if !opaque(attemptID) {
		return Ticket{}, ErrInvalid
	}
	if _, exists := r.attempts[attemptID]; exists {
		return Ticket{}, ErrConflict
	}
	if len(r.attempts) >= r.maxAttempts {
		return Ticket{}, ErrBudget
	}
	r.revision++
	ticket := Ticket{owner: r.authority, id: r.revision}
	admitted := admitted{ticket: ticket, actor: actorUID, attempt: attemptID}
	r.attempts[attemptID] = admitted
	r.tickets[ticket.id] = admitted
	return ticket, nil
}

func (r *Reference) admittedLocked(ticket Ticket) (admitted, error) {
	operation, exists := r.tickets[ticket.id]
	if ticket.owner != r.authority || !exists || operation.ticket != ticket {
		return admitted{}, ErrTicket
	}
	return operation, nil
}

// Commit checks generation authority and writes the owned ledger in ONE atomic
// operation. It cannot call an external API or defer a mutation beyond this lock.
func (r *Reference) Commit(ticket Ticket, actorUID, resourceUID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	operation, err := r.admittedLocked(ticket)
	if err != nil {
		return err
	}
	if operation.actor != actorUID {
		return ErrIdentity
	}
	if !opaque(resourceUID) {
		return ErrInvalid
	}
	if r.state != "open" {
		return ErrClosed
	}
	want := Allocation{ActorUID: actorUID, AttemptID: operation.attempt, ResourceUID: resourceUID}
	if prior, exists := r.allocations[operation.attempt]; exists {
		if prior != want {
			return ErrConflict
		}
		return nil
	}
	if _, exists := r.resources[resourceUID]; exists {
		return ErrConflict
	}
	r.allocations[operation.attempt] = want
	r.resources[resourceUID] = operation.attempt
	r.revision++
	return nil
}

// Drain atomically revokes both future admission and all uncommitted tickets.
// Requests already in transit cannot bypass the same Commit state check.
func (r *Reference) Drain() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state == "open" {
		r.state = "draining"
		r.revision++
	}
	return nil
}

// Fence returns a complete terminal receipt only after the closing boundary.
// Because the ledger is owned here, every member uses this same commit guard.
func (r *Reference) Fence() (Receipt, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state == "open" {
		return Receipt{}, ErrProof
	}
	if r.state == "draining" {
		r.state = "fenced"
		r.revision++
	}
	return Receipt{owner: r.authority, binding: r.binding, revision: r.revision, members: slices.Clone(r.members)}, nil
}

func (r *Reference) acceptLocked(receipt Receipt, pinned Binding) error {
	if r.state != "fenced" || receipt.owner != r.authority || receipt.binding != r.binding || pinned != r.binding ||
		receipt.revision != r.revision || !slices.Equal(receipt.members, r.members) {
		return ErrProof
	}
	return nil
}

// Accept refuses data-only, foreign, stale and incomplete receipts.
func (r *Reference) Accept(receipt Receipt, pinned Binding) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.acceptLocked(receipt, pinned)
}

// Resolve requires the actual originating fence even after a failed RPC.
// A zero match without that proof never becomes definitively unallocated.
func (r *Reference) Resolve(ticket Ticket, receipt Receipt) (Resolution, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.acceptLocked(receipt, r.binding); err != nil {
		return Resolution{}, err
	}
	operation, err := r.admittedLocked(ticket)
	if err != nil {
		return Resolution{}, err
	}
	allocation, exists := r.allocations[operation.attempt]
	return Resolution{Allocation: allocation, Unallocated: !exists}, nil
}

// Snapshot returns a stable sorted copy for observing the actual reference effect.
func (r *Reference) Snapshot() []Allocation {
	r.mu.Lock()
	defer r.mu.Unlock()
	result := make([]Allocation, 0, len(r.allocations))
	for _, allocation := range r.allocations {
		result = append(result, allocation)
	}
	slices.SortFunc(result, func(a, b Allocation) int {
		if a.AttemptID < b.AttemptID {
			return -1
		}
		if a.AttemptID > b.AttemptID {
			return 1
		}
		return 0
	})
	return result
}

// TLSConfig retains normal chain/hostname checks and additionally pins the
// allocator SERVER public key. The coordinator's client cert is a separate
// identity. Bindings must come from a trusted issuer, never Pod/address metadata.
func (r *Reference) TLSConfig(actorUID string, base *tls.Config) (*tls.Config, error) {
	key, exists := r.actorKeys[actorUID]
	if !exists || base == nil || base.InsecureSkipVerify || base.ServerName == "" {
		return nil, ErrIdentity
	}
	config := base.Clone()
	if config.MinVersion < tls.VersionTLS13 {
		config.MinVersion = tls.VersionTLS13
	}
	prior := config.VerifyConnection
	config.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 ||
			len(state.VerifiedChains[0]) == 0 ||
			!state.PeerCertificates[0].Equal(state.VerifiedChains[0][0]) ||
			sha256.Sum256(state.PeerCertificates[0].RawSubjectPublicKeyInfo) != key {
			return ErrIdentity
		}
		if prior != nil {
			return prior(state)
		}
		return nil
	}
	return config, nil
}
