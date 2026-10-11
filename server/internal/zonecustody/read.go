package zonecustody

import (
	"context"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Reader has no mutation surface. Readback cannot reserve a lifetime or retain
// a receipt, and its caller must independently retain complete original pins.
type Reader interface {
	StorageRead(context.Context, []*runtime.StorageRead) ([]*api.StorageObject, error)
}

// ReadConfig opts into diagnostic comparison against complete original pins.
type ReadConfig struct {
	Enabled bool
	Storage Reader
	Pins    Pins
}

// Read returns exact private diagnostics under one bounded read. It grants no
// authority to launch, restore custody or complete a session after restart.
func Read(ctx context.Context, cfg ReadConfig) (Pins, error) {
	p := cfg.Pins
	if !cfg.Enabled || nilStorage(cfg.Storage) || !validObservation(p.Enrollment) || !validVersion(p.EnrollmentVersion) || !validVersion(p.CustodyVersion) || !p.Receipt.Matches(p.Enrollment.Lifetime.binding(), p.Receipt.Observer) {
		return Pins{}, ErrUnknown
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	key := LifetimeKey(p.Enrollment.Lifetime.binding())
	objects, err := cfg.Storage.StorageRead(ctx, []*runtime.StorageRead{{Collection: EnrollmentCollection, Key: key, UserID: ""}, {Collection: CustodyCollection, Key: key, UserID: ""}})
	if err != nil || ctx.Err() != nil || len(objects) != 2 {
		return Pins{}, unknown(ctx, err)
	}
	var enrollment, custody *api.StorageObject
	for _, o := range objects {
		if o == nil || o.GetKey() != key || o.GetUserId() != nakamastorage.SystemOwnerID || o.GetPermissionRead() != 0 || o.GetPermissionWrite() != 0 {
			return Pins{}, ErrUnknown
		}
		switch o.GetCollection() {
		case EnrollmentCollection:
			if enrollment != nil {
				return Pins{}, ErrUnknown
			}
			enrollment = o
		case CustodyCollection:
			if custody != nil {
				return Pins{}, ErrUnknown
			}
			custody = o
		default:
			return Pins{}, ErrUnknown
		}
	}
	if enrollment == nil || custody == nil || enrollment.GetVersion() != p.EnrollmentVersion || custody.GetVersion() != p.CustodyVersion {
		return Pins{}, ErrUnknown
	}
	e, err := DecodeEnrollment(enrollment.GetValue())
	if err != nil || e != p.Enrollment {
		return Pins{}, ErrUnknown
	}
	got, err := DecodeCustody(custody.GetValue())
	if err != nil || got.Enrollment != p.Enrollment || got.EnrollmentVersion != p.EnrollmentVersion || !got.Receipt.Equal(p.Receipt) {
		return Pins{}, ErrUnknown
	}
	got.CustodyVersion = p.CustodyVersion
	if ctx.Err() != nil {
		return Pins{}, unknown(ctx, nil)
	}
	return got, nil
}
