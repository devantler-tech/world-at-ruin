package nakamastorage

import (
	"context"
	"errors"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

var (
	// ErrObjectMissing reports that no object exists at the requested key.
	ErrObjectMissing = errors.New("nakama storage: object missing")
	// ErrObjectInvalid reports that storage returned something other than
	// exactly one private, versioned, system-owned object at the requested key,
	// or did not complete the read.
	ErrObjectInvalid = errors.New("nakama storage: object invalid")
)

// ReadSystemOwned reads the one private object at collection/key under the
// system owner and validates its identity, ownership, version and permissions
// before returning it. A client-owned object at the same key is never returned:
// the read asks for the system owner, so a player cannot preseed an
// authoritative record from their own namespace. A failed read is sanitised
// against ctx with ErrObjectInvalid as the fallback.
func ReadSystemOwned(
	ctx context.Context,
	client Client,
	collection string,
	key string,
) (*api.StorageObject, error) {
	objects, err := client.StorageRead(ctx, []*runtime.StorageRead{
		{
			Collection: collection,
			Key:        key,
			UserID:     "",
		},
	})
	if err != nil {
		return nil, SanitizeError(ctx, err, ErrObjectInvalid)
	}
	if len(objects) == 0 {
		return nil, ErrObjectMissing
	}
	if len(objects) != 1 {
		return nil, ErrObjectInvalid
	}
	object := objects[0]
	if object == nil ||
		object.GetCollection() != collection ||
		object.GetKey() != key ||
		object.GetUserId() != SystemOwnerID ||
		object.GetVersion() == "" ||
		object.GetPermissionRead() != 0 ||
		object.GetPermissionWrite() != 0 {
		return nil, ErrObjectInvalid
	}
	return object, nil
}
