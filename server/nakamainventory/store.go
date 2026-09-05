// Package nakamainventory persists what a player carries: one private,
// versioned, conflict-checked container per account, stored under Nakama's
// system owner and written only through the playerstate mutation boundary so
// the record and its replay evidence commit atomically. The container is the
// whole of this package's scope — a stack is an opaque item id and a count —
// and the durability it promises is the one docs/design/server-state-durability.md
// states for player-owned records: a write either commits with its audit
// evidence or leaves the previous container untouched, a stale observation is
// refused rather than merged, and a replayed mutation has one effect.
package nakamainventory

import (
	"context"
	"encoding/json"
	"errors"
	"sort"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
)

const (
	// Collection is the private Nakama collection for inventory containers.
	Collection = "world_at_ruin_inventories"
	// RecordKey is the prefix for account-bound system-owned inventory documents.
	RecordKey = "inventory"
	// MaxStacks bounds how many distinct stacks one container holds.
	MaxStacks = 256
	// MaxStackCount bounds one stack. With MaxStacks it caps what one document
	// can claim, so no write — replayed, raced or malformed — mints an unbounded
	// amount of anything (product law 3).
	MaxStackCount = 1_000_000

	schemaVersion = 1
)

var (
	// ErrNotFound means the verified account has no container yet.
	ErrNotFound = errors.New("nakama inventory: not found")
	// ErrConflict means the container changed since the caller observed it.
	ErrConflict = playerstate.ErrConflict
	// ErrKeyConflict means an idempotency key names a different container.
	ErrKeyConflict = playerstate.ErrKeyConflict
	// ErrStorage means Nakama returned an invalid record or a storage failure.
	ErrStorage = playerstate.ErrStorage
)

// Stack is one kind of item and how many of it the container holds. The id is
// opaque here: what an item is belongs to the item model, not the container.
type Stack struct {
	ItemID string
	Count  int64
}

// Inventory is the container. It is stored and returned with its stacks sorted
// by item id and no id twice; Save normalises the caller's order.
type Inventory struct {
	Stacks []Stack
}

// Record pairs one container with the exact Nakama version that observed it.
type Record struct {
	Inventory Inventory
	Version   string
}

// SaveRequest conditionally creates or replaces one account's container.
// ExpectedVersion is the version the caller observed, or "*" to create.
type SaveRequest struct {
	SubjectID       string
	IdempotencyKey  string
	ExpectedVersion string
	Inventory       Inventory
}

// Store owns system-owned inventory containers through Nakama storage. Writes
// go through playerstate.Store so the container and its system-owned audit
// evidence commit atomically.
type Store struct {
	storage   nakamastorage.Client
	mutations *playerstate.Store
}

// NewStore builds an inventory store over Nakama's runtime storage surface.
func NewStore(storage nakamastorage.Client) (*Store, error) {
	if storage == nil {
		return nil, errors.New("nakama inventory: storage is required")
	}
	mutations, err := playerstate.NewStore(storage)
	if err != nil {
		return nil, err
	}
	return &Store{storage: storage, mutations: mutations}, nil
}

// Load reads the private container belonging to one verified Nakama subject.
func (s *Store) Load(ctx context.Context, subjectID string) (Record, error) {
	subjectID, err := authenticatedSubjectID(ctx, subjectID)
	if err != nil {
		return Record{}, err
	}
	object, err := nakamastorage.ReadSystemOwned(ctx, s.storage, Collection, recordKey(subjectID))
	switch {
	case errors.Is(err, nakamastorage.ErrObjectMissing):
		return Record{}, ErrNotFound
	case errors.Is(err, nakamastorage.ErrObjectInvalid):
		return Record{}, ErrStorage
	case err != nil:
		return Record{}, err
	}
	inventory, err := decodeDocument(object.GetValue())
	if err != nil {
		return Record{}, ErrStorage
	}
	return Record{Inventory: inventory, Version: object.GetVersion()}, nil
}

// Save atomically commits one conditional container replacement and its
// append-only mutation evidence. A malformed durable container is never
// overwritten by quoting its version: the observed record has to load first.
func (s *Store) Save(ctx context.Context, request SaveRequest) error {
	subjectID, err := authenticatedSubjectID(ctx, request.SubjectID)
	if err != nil {
		return err
	}
	if request.ExpectedVersion == "" {
		return errors.New("nakama inventory: observed version is required")
	}
	if request.ExpectedVersion != "*" {
		if _, err := s.Load(ctx, subjectID); err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
	}
	value, err := encodeDocument(request.Inventory)
	if err != nil {
		return err
	}
	outcome, err := json.Marshal(struct {
		Schema int `json:"schema"`
		Stacks int `json:"stacks"`
	}{
		Schema: schemaVersion,
		Stacks: len(request.Inventory.Stacks),
	})
	if err != nil {
		return errors.New("nakama inventory: encode mutation outcome")
	}
	_, err = s.mutations.Apply(ctx, playerstate.Mutation{
		SubjectID:      subjectID,
		IdempotencyKey: request.IdempotencyKey,
		Operation:      "save_inventory",
		Payload:        value,
		Record: playerstate.RecordWrite{
			Collection:      Collection,
			Key:             recordKey(subjectID),
			ExpectedVersion: request.ExpectedVersion,
			Value:           value,
			SystemOwned:     true,
		},
		Outcome: outcome,
	})
	return err
}

func recordKey(subjectID string) string {
	return RecordKey + ":" + subjectID
}

func authenticatedSubjectID(ctx context.Context, requestedSubjectID string) (string, error) {
	subjectID, ok := nakamastorage.AuthenticatedSubjectID(ctx, requestedSubjectID)
	if !ok {
		return "", errors.New("nakama inventory: authenticated subject must own the container")
	}
	return subjectID, nil
}

// normalize validates a container and returns its stacks in canonical order.
func normalize(inventory Inventory) ([]Stack, error) {
	if len(inventory.Stacks) > MaxStacks {
		return nil, errors.New("nakama inventory: too many stacks")
	}
	stacks := make([]Stack, 0, len(inventory.Stacks))
	seen := make(map[string]struct{}, len(inventory.Stacks))
	for _, stack := range inventory.Stacks {
		if nakamastorage.InvalidIdentityPart(stack.ItemID) {
			return nil, errors.New("nakama inventory: valid item id is required")
		}
		if stack.Count < 1 || stack.Count > MaxStackCount {
			return nil, errors.New("nakama inventory: stack count out of range")
		}
		if _, duplicate := seen[stack.ItemID]; duplicate {
			return nil, errors.New("nakama inventory: item id repeated")
		}
		seen[stack.ItemID] = struct{}{}
		stacks = append(stacks, stack)
	}
	sort.Slice(stacks, func(i, j int) bool { return stacks[i].ItemID < stacks[j].ItemID })
	return stacks, nil
}

type stackDocument struct {
	ItemID string `json:"item_id"`
	Count  int64  `json:"count"`
}

func encodeDocument(inventory Inventory) (json.RawMessage, error) {
	stacks, err := normalize(inventory)
	if err != nil {
		return nil, err
	}
	documents := make([]stackDocument, len(stacks))
	for index, stack := range stacks {
		documents[index] = stackDocument(stack)
	}
	value, err := json.Marshal(struct {
		Schema int             `json:"schema"`
		Stacks []stackDocument `json:"stacks"`
	}{
		Schema: schemaVersion,
		Stacks: documents,
	})
	if err != nil {
		return nil, errors.New("nakama inventory: encode container")
	}
	return value, nil
}

// decodeDocument reads a stored container strictly: every member exactly once,
// no member this schema does not know, and a container that normalize accepts.
// Stack order in the stored bytes is not content — the result is canonical
// either way — but a count that is not a whole number in range, or an id that
// repeats, is a document this client cannot render and is refused.
func decodeDocument(value string) (Inventory, error) {
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return Inventory{}, err
	}
	var schema int
	var stacks []json.RawMessage
	seen := make(map[string]struct{}, 2)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return Inventory{}, err
		}
		key, ok := token.(string)
		if !ok {
			return Inventory{}, errors.New("invalid inventory field")
		}
		if _, duplicate := seen[key]; duplicate {
			return Inventory{}, errors.New("duplicate inventory field")
		}
		seen[key] = struct{}{}
		switch key {
		case "schema":
			err = decoder.Decode(&schema)
		case "stacks":
			err = decoder.Decode(&stacks)
		default:
			return Inventory{}, errors.New("unknown inventory field")
		}
		if err != nil {
			return Inventory{}, err
		}
	}
	if err := nakamastorage.EndObject(decoder); err != nil {
		return Inventory{}, err
	}
	if _, ok := seen["schema"]; !ok {
		return Inventory{}, errors.New("missing inventory schema")
	}
	if _, ok := seen["stacks"]; !ok || stacks == nil {
		return Inventory{}, errors.New("missing inventory stacks")
	}
	if schema != schemaVersion {
		return Inventory{}, errors.New("unknown inventory schema")
	}
	inventory := Inventory{Stacks: make([]Stack, 0, len(stacks))}
	for _, raw := range stacks {
		stack, err := decodeStack(string(raw))
		if err != nil {
			return Inventory{}, err
		}
		inventory.Stacks = append(inventory.Stacks, stack)
	}
	normalized, err := normalize(inventory)
	if err != nil {
		return Inventory{}, err
	}
	return Inventory{Stacks: normalized}, nil
}

func decodeStack(value string) (Stack, error) {
	decoder, err := nakamastorage.BeginObject(value)
	if err != nil {
		return Stack{}, err
	}
	var stack Stack
	seen := make(map[string]struct{}, 2)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return Stack{}, err
		}
		key, ok := token.(string)
		if !ok {
			return Stack{}, errors.New("invalid stack field")
		}
		if _, duplicate := seen[key]; duplicate {
			return Stack{}, errors.New("duplicate stack field")
		}
		seen[key] = struct{}{}
		switch key {
		case "item_id":
			err = decoder.Decode(&stack.ItemID)
		case "count":
			err = decoder.Decode(&stack.Count)
		default:
			return Stack{}, errors.New("unknown stack field")
		}
		if err != nil {
			return Stack{}, err
		}
	}
	if err := nakamastorage.EndObject(decoder); err != nil {
		return Stack{}, err
	}
	if len(seen) != 2 {
		return Stack{}, errors.New("missing stack field")
	}
	return stack, nil
}
