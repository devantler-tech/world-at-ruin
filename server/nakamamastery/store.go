package nakamamastery

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
)

// Collection contains private, system-owned schema-1 mastery records.
const Collection = "world_at_ruin_mastery"

var (
	ErrNotFound = errors.New("mastery: record not found")
	ErrStorage  = errors.New("mastery: invalid or unavailable record")
)

// Store owns mastery transitions and routes every write through the shared
// conditional player-record-plus-audit transaction. It has no direct writer.
type Store struct {
	storage   nakamastorage.Client
	mutations *playerstate.Store
	authority *authorityState
}

// NewStore binds this owner to one private process-local event authority.
func NewStore(storage nakamastorage.Client, authority Authority) (*Store, error) {
	mutations, err := playerstate.NewStore(storage)
	if err != nil {
		return nil, err
	}
	return &Store{storage: storage, mutations: mutations, authority: authority.state}, nil
}

// Load reads only the authenticated account's private system-owned record.
func (s *Store) Load(ctx context.Context, requested string) (State, string, error) {
	if s.authority == nil {
		return State{}, "", ErrDisabled
	}
	subject, ok := nakamastorage.AuthenticatedSubjectID(ctx, requested)
	if !ok {
		return State{}, "", ErrInvalid
	}
	object, err := nakamastorage.ReadSystemOwned(ctx, s.storage, Collection, recordKey(subject))
	if err != nil {
		return State{}, "", nakamastorage.ReadError(err, ErrNotFound, ErrStorage)
	}
	state, err := decodeMasteryDocument(object.GetValue())
	if err != nil {
		return State{}, "", ErrStorage
	}
	return state, object.GetVersion(), nil
}

// Apply resolves replay before reading current state. A valid no-op still
// commits a conditional unchanged record and create-only audit, preventing a
// later replay from applying that old event to newly earned value.
func (s *Store) Apply(ctx context.Context, event Event) (Outcome, error) {
	if err := s.validate(ctx, event); err != nil {
		return Outcome{}, err
	}
	result, found, err := s.mutations.Lookup(ctx, lookup(event))
	if err != nil {
		return Outcome{}, err
	}
	if found {
		return historical(result, event)
	}
	state, version, err := s.Load(ctx, event.subject)
	if errors.Is(err, ErrNotFound) {
		state = emptyState()
		version = "*"
	} else if err != nil {
		return Outcome{}, err
	}
	next, out, err := transition(state, event.payload, event.identity)
	if err != nil {
		return Outcome{}, err
	}
	value, err := json.Marshal(next)
	if err != nil {
		return Outcome{}, ErrInvalid
	}
	outcome, err := json.Marshal(out)
	if err != nil {
		return Outcome{}, ErrInvalid
	}
	result, err = s.mutations.Apply(ctx, playerstate.Mutation{
		SubjectID: event.subject, IdempotencyKey: event.identity, Operation: "mastery_" + event.payload.Kind, Payload: event.binding,
		Record: playerstate.RecordWrite{Collection: Collection, Key: recordKey(event.subject), ExpectedVersion: version, Value: value, SystemOwned: true}, Outcome: outcome,
	})
	if err != nil {
		return Outcome{}, err
	}
	return historical(result, event)
}

// Resolve performs one read-only lookup after an uncertain dispatch. Missing
// evidence or a failed read remains indeterminate; it never retries a write.
func (s *Store) Resolve(ctx context.Context, event Event) (Outcome, error) {
	if err := s.validate(ctx, event); err != nil {
		return Outcome{}, err
	}
	result, found, err := s.mutations.Lookup(ctx, lookup(event))
	if err != nil {
		if errors.Is(err, playerstate.ErrKeyConflict) {
			return Outcome{}, err
		}
		return Outcome{}, errors.Join(playerstate.ErrIndeterminate, err)
	}
	if !found {
		return Outcome{}, playerstate.ErrIndeterminate
	}
	return historical(result, event)
}

func (s *Store) validate(ctx context.Context, event Event) error {
	if s.authority == nil {
		return ErrDisabled
	}
	if event.owner == nil || event.owner != s.authority || event.identity == "" || len(event.binding) == 0 {
		return ErrInvalid
	}
	if _, ok := nakamastorage.AuthenticatedSubjectID(ctx, event.subject); !ok {
		return ErrInvalid
	}
	return nil
}

func recordKey(subject string) string { return "mastery:" + subject }

func lookup(event Event) playerstate.LookupRequest {
	return playerstate.LookupRequest{SubjectID: event.subject, IdempotencyKey: event.identity, Operation: "mastery_" + event.payload.Kind, Payload: event.binding, RecordCollection: Collection, RecordKey: recordKey(event.subject)}
}

func historical(result playerstate.Result, event Event) (Outcome, error) {
	out, err := decodeOutcome(string(result.Outcome))
	if err != nil || out.Kind != event.payload.Kind || (out.Kind == "award" && out.Credited != event.payload.Amount) {
		return Outcome{}, ErrStorage
	}
	return out, nil
}
