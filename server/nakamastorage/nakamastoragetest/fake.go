// Package nakamastoragetest is the in-memory Nakama storage fake the store
// tests share. It keeps the version-conflict semantics the real runtime
// enforces — a batch with one rejected version changes nothing — so a store's
// conditional-write behaviour can be proven without a Nakama instance.
package nakamastoragetest

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sync"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
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
	WriteCalls [][]*runtime.StorageWrite
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

// StorageRead returns the objects that exist among reads, in request order.
func (f *Fake) StorageRead(
	_ context.Context,
	reads []*runtime.StorageRead,
) ([]*api.StorageObject, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ReadCalls++
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
	_ context.Context,
	writes []*runtime.StorageWrite,
) ([]*api.StorageObjectAck, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	call := make([]*runtime.StorageWrite, len(writes))
	copy(call, writes)
	f.WriteCalls = append(f.WriteCalls, call)
	if f.WriteErr != nil {
		return nil, f.WriteErr
	}
	for _, write := range writes {
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
	}
	acks := make([]*api.StorageObjectAck, 0, len(writes))
	for _, write := range writes {
		ownerID := owner(write.UserID)
		version := fmt.Sprintf("v%d", f.next)
		f.next++
		f.objects[id(write.Collection, write.Key, ownerID)] = Object{
			Collection:      write.Collection,
			Key:             write.Key,
			UserID:          ownerID,
			Value:           write.Value,
			Version:         version,
			PermissionRead:  int32(write.PermissionRead),
			PermissionWrite: int32(write.PermissionWrite),
		}
		acks = append(acks, &api.StorageObjectAck{
			Collection: write.Collection,
			Key:        write.Key,
			UserId:     ownerID,
			Version:    version,
		})
	}
	return acks, nil
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
	return userID
}

func id(collection, key, userID string) string {
	return collection + "\x00" + key + "\x00" + userID
}
