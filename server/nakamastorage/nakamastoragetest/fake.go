// Package nakamastoragetest is the in-memory Nakama storage fake the store
// tests share. It keeps the version-conflict semantics the real runtime
// enforces — a batch with one rejected version changes nothing — so a store's
// conditional-write behaviour can be proven without a Nakama instance.
package nakamastoragetest

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"sync"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/gofrs/uuid/v5"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Object is one stored record as the fake holds it. An empty UserID means the
// system owner, exactly as it does on a runtime write.
type Object struct {
	Collection      string
	Key             string
	UserID          string
	Value           string
	Version         string
	PermissionRead  int32
	PermissionWrite int32
}

// Fake is an in-memory nakamastorage.Client.
//
// ReadErr and WriteErr, when set, are returned from every read or write after
// the call has been recorded, so a test can prove how a store sanitises a
// storage failure. WriteCalls records every batch a store dispatched.
type Fake struct {
	mu         sync.Mutex
	objects    map[string]Object
	next       int
	ReadCalls  int
	ReadErr    error
	WriteErr   error
	ListErr    error
	DeleteErr  error
	WriteCalls [][]*runtime.StorageWrite
	// Hooks inject failures before mutation or after a committed write. Their
	// argument is the first version number in the batch; they run under the
	// fake's mutex and must not call back into the fake.
	BeforeWrite func(int) error
	AfterWrite  func(int) error
}

var _ nakamastorage.Client = (*Fake)(nil)

// New returns an empty fake whose first written version is "v1".
func New() *Fake {
	return &Fake{
		objects: make(map[string]Object),
		next:    1,
	}
}

// Seed stores object as durable state without going through a write.
func (f *Fake) Seed(object Object) {
	f.mu.Lock()
	defer f.mu.Unlock()
	object.UserID = owner(object.UserID)
	f.objects[id(object.Collection, object.Key, object.UserID)] = object
}

// Get returns the durable object at collection/key for userID ("" for the
// system owner) and whether one exists.
func (f *Fake) Get(collection, key, userID string) (Object, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	object, ok := f.objects[id(collection, key, owner(userID))]
	return object, ok
}

// Objects returns an independent snapshot for assertions about durable state.
func (f *Fake) Objects() []Object {
	f.mu.Lock()
	defer f.mu.Unlock()
	objects := make([]Object, 0, len(f.objects))
	for _, object := range f.objects {
		objects = append(objects, object)
	}
	return objects
}

// StorageRead returns the objects that exist among reads, in request order.
func (f *Fake) StorageRead(
	ctx context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ReadCalls++
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if f.ReadErr != nil {
		return nil, f.ReadErr
	}
	objects := make([]*api.StorageObject, 0, len(reads))
	for _, read := range reads {
		object, ok := f.objects[id(read.Collection, read.Key, owner(read.UserID))]
		if !ok {
			continue
		}
		objects = append(objects, &api.StorageObject{
			Collection:      object.Collection,
			Key:             object.Key,
			UserId:          object.UserID,
			Value:           object.Value,
			Version:         object.Version,
			PermissionRead:  object.PermissionRead,
			PermissionWrite: object.PermissionWrite,
		})
	}
	return objects, nil
}

// StorageWrite applies the whole batch or none of it: a create ("*") of an
// existing object, or a version that is not the current one, rejects the batch
// with runtime.ErrStorageRejectedVersion before any object changes.
func (f *Fake) StorageWrite(
	ctx context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	call := make([]*runtime.StorageWrite, len(writes))
	copy(call, writes)
	f.WriteCalls = append(f.WriteCalls, call)
	firstVersion := f.next
	if f.BeforeWrite != nil {
		if err := f.BeforeWrite(firstVersion); err != nil {
			return nil, err
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if f.WriteErr != nil {
		return nil, f.WriteErr
	}
	type permissions struct{ read, write int32 }
	validated := make([]permissions, len(writes))
	for index, write := range writes {
		current, exists := f.objects[id(write.Collection, write.Key, owner(write.UserID))]
		switch {
		case write.Version == "*" && exists:
			return nil, runtime.ErrStorageRejectedVersion
		case write.Version != "" && write.Version != "*" &&
			(!exists || write.Version != current.Version):
			return nil, runtime.ErrStorageRejectedVersion
		}
		if write.PermissionRead < math.MinInt32 || write.PermissionRead > math.MaxInt32 ||
			write.PermissionWrite < math.MinInt32 || write.PermissionWrite > math.MaxInt32 {
			return nil, errors.New("nakamastoragetest: permission out of range")
		}
		validated[index] = permissions{int32(write.PermissionRead), int32(write.PermissionWrite)}
	}
	acks := make([]*api.StorageObjectAck, 0, len(writes))
	for index, write := range writes {
		ownerID := owner(write.UserID)
		version := fmt.Sprintf("v%d", f.next)
		f.next++
		f.objects[id(write.Collection, write.Key, ownerID)] = Object{
			Collection:      write.Collection,
			Key:             write.Key,
			UserID:          ownerID,
			Value:           write.Value,
			Version:         version,
			PermissionRead:  validated[index].read,
			PermissionWrite: validated[index].write,
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     ownerID,
			Version:    version,
		})
	}
	if f.AfterWrite != nil {
		if err := f.AfterWrite(firstVersion); err != nil {
			return nil, err
		}
	}
	return acks, nil
}

type listCursor struct {
	After string
}

// StorageList implements owner/permission filtering and keyset pagination.
// A cursor remains usable when an expiry sweep deletes a preceding page. It
// uses a test-only encoding, not a Nakama wire cursor. Callers must treat it
// as opaque; it carries no query identity or query-binding guarantee.
func (f *Fake) StorageList(
	ctx context.Context, callerID, userID, collection string, limit int, cursor string,
) ([]*api.StorageObject, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	if f.ListErr != nil {
		return nil, "", f.ListErr
	}
	if limit < 1 || limit > 100 {
		return nil, "", errors.New("nakamastoragetest: invalid list limit")
	}
	for _, user := range []*string{&callerID, &userID} {
		if *user == "" {
			continue
		}
		parsed, err := uuid.FromString(*user)
		if err != nil {
			return nil, "", errors.New("nakamastoragetest: invalid list UUID")
		}
		*user = parsed.String()
	}
	query := listCursor{}
	if cursor != "" {
		raw, err := base64.RawURLEncoding.DecodeString(cursor)
		var previous listCursor
		if err != nil || json.Unmarshal(raw, &previous) != nil || previous.After == "" {
			return nil, "", errors.New("nakamastoragetest: invalid list cursor")
		}
		query.After = previous.After
	}
	authoritative := callerID == "" || callerID == nakamastorage.SystemOwnerID
	keys := make([]string, 0, len(f.objects))
	for key, object := range f.objects {
		if object.Collection != collection || listKey(object) <= query.After {
			continue
		}
		if userID != "" && object.UserID != userID {
			continue
		}
		if !authoritative && userID == "" && object.PermissionRead != 2 {
			continue
		}
		if !authoritative && object.PermissionRead != 2 &&
			(object.UserID != callerID || object.PermissionRead != 1) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	next := ""
	if len(keys) > limit {
		keys = keys[:limit]
		query.After = listKey(f.objects[keys[len(keys)-1]])
		raw, err := json.Marshal(query)
		if err != nil {
			return nil, "", err
		}
		next = base64.RawURLEncoding.EncodeToString(raw)
	}
	objects := make([]*api.StorageObject, 0, len(keys))
	for _, key := range keys {
		object := f.objects[key]
		objects = append(objects, &api.StorageObject{
			Collection: object.Collection, Key: object.Key, UserId: object.UserID,
			Value: object.Value, Version: object.Version,
			PermissionRead: object.PermissionRead, PermissionWrite: object.PermissionWrite,
		})
	}
	return objects, next, nil
}

// StorageDelete applies a complete conditional batch or leaves all objects
// intact. An empty version is an unconditional, idempotent server-side delete.
func (f *Fake) StorageDelete(ctx context.Context, deletes []*runtime.StorageDelete) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if f.DeleteErr != nil {
		return f.DeleteErr
	}
	for _, deletion := range deletes {
		current, exists := f.objects[id(deletion.Collection, deletion.Key, owner(deletion.UserID))]
		if deletion.Version != "" && (!exists || current.Version != deletion.Version) {
			return errors.New("nakamastoragetest: storage delete rejected")
		}
	}
	for _, deletion := range deletes {
		delete(f.objects, id(deletion.Collection, deletion.Key, owner(deletion.UserID)))
	}
	return nil
}

// AuthenticatedContext is a context the Nakama runtime would hand a handler
// invoked by userID.
func AuthenticatedContext(userID string) context.Context {
	return sessionContext{Context: context.Background(), userID: userID}
}

type sessionContext struct {
	context.Context
	userID string
}

func (c sessionContext) Value(key any) any {
	if key == runtime.RUNTIME_CTX_USER_ID {
		return c.userID
	}
	return c.Context.Value(key)
}

func owner(userID string) string {
	if userID == "" {
		return nakamastorage.SystemOwnerID
	}
	if parsed, err := uuid.FromString(userID); err == nil {
		return parsed.String()
	}
	// Seed may deliberately contain malformed durable data for refusal tests.
	return userID
}

func id(collection, key, userID string) string {
	return collection + "\x00" + key + "\x00" + userID
}

func listKey(object Object) string {
	return object.Key + "\x00" + object.UserID
}
