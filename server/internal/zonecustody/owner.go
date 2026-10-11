// Package zonecustody supplies inert private enrollment and receipt persistence.
// Correlation strings and process-local handles establish no workload identity,
// exclusive launch, rollback resistance or session-end authority.
package zonecustody

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"sync/atomic"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	// EnrollmentCollection retains immutable original-lifetime exclusion rows.
	EnrollmentCollection = "world_at_ruin_zone_enrollments"
	// CustodyCollection retains the complete original acknowledged claim.
	CustodyCollection = "world_at_ruin_zone_original_custody"
)

// ErrUnknown refuses authority when original acknowledgements are unavailable.
var ErrUnknown = errors.New("zone custody: original acknowledgement unavailable")

// Config opts into a source experiment. Owner and child strings are correlations,
// never credentials, attestation or proof that a process has been launched.
type Config struct {
	Enabled                   bool
	Storage                   Writer
	Binding                   agones.ClaimBinding
	OwnerID, ChildIncarnation string
}

// Writer has only the create surface needed by enrollment and custody. Readback
// is a separate diagnostic dependency and cannot restore an originating handle.
type Writer interface {
	StorageWrite(context.Context, []*runtime.StorageWrite) ([]*api.StorageObjectAck, error)
}

// Owner copies share one terminal enrollment attempt; construction is inert.
type Owner struct{ state *ownerState }
type ownerState struct {
	cfg       Config
	attempted atomic.Bool
}

// Enrollment requires the live originating enrollment acknowledgement. There
// is deliberately no constructor from diagnostics or persisted documents.
type Enrollment struct{ state *enrollmentState }
type enrollmentState struct {
	storage   Writer
	original  Observation
	version   string
	key       string
	attempted atomic.Bool
	accepted  atomic.Pointer[Pins]
}

// Pins are detached diagnostics of originating acknowledgements. Possession
// cannot recreate an Enrollment or authorize launch, recovery or completion.
type Pins struct {
	Enrollment                        Observation
	EnrollmentVersion, CustodyVersion string
	Receipt                           zoneclaim.Receipt
}

// NewOwner validates explicit opt-in and complete immutable correlations.
func NewOwner(cfg Config) (*Owner, error) {
	if !cfg.Enabled || nilStorage(cfg.Storage) || !validObservation(observation(cfg)) {
		return nil, ErrUnknown
	}
	return &Owner{state: &ownerState{cfg: cfg}}, nil
}

// LifetimeKey excludes owner, incarnation, storage version and watch revision
// so competing supervisors and replacement children contend for one lifetime.
func LifetimeKey(binding agones.ClaimBinding) string {
	raw, _ := json.Marshal(lifetime(binding))
	digest := sha256.Sum256(append([]byte("world-at-ruin/zone-enrollment-key/v1\n"), raw...))
	return hex.EncodeToString(digest[:])
}

// Reserve consumes one bounded create-only attempt before any storage I/O.
// Lost or canceled ACKs cannot be retried, even through a copied Owner.
func (o *Owner) Reserve(ctx context.Context) (Enrollment, error) {
	if o == nil || o.state == nil || !o.state.attempted.CompareAndSwap(false, true) {
		return Enrollment{}, ErrUnknown
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cfg := o.state.cfg
	original := observation(cfg)
	value, err := EncodeEnrollment(original)
	if err != nil || ctx.Err() != nil {
		return Enrollment{}, unknown(ctx, err)
	}
	key := LifetimeKey(cfg.Binding)
	version, err := create(ctx, cfg.Storage, EnrollmentCollection, key, value)
	if err != nil {
		return Enrollment{}, err
	}
	return Enrollment{state: &enrollmentState{storage: cfg.Storage, original: original, version: version, key: key}}, nil
}

// RetainOriginal implements zoneclaim.ReceiptCustodian using exactly one
// matching original receipt and create-only storage, never lease readback.
func (e Enrollment) RetainOriginal(ctx context.Context, r zoneclaim.Receipt) error {
	if e.state == nil || !e.state.attempted.CompareAndSwap(false, true) {
		return ErrUnknown
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	s := e.state
	if !r.Matches(s.original.Lifetime.binding(), r.Observer) || ctx.Err() != nil {
		return unknown(ctx, nil)
	}
	pins := Pins{Enrollment: s.original, EnrollmentVersion: s.version, Receipt: r}
	value, err := EncodeCustody(pins)
	if err != nil {
		return unknown(ctx, err)
	}
	pins.CustodyVersion, err = create(ctx, s.storage, CustodyCollection, s.key, value)
	if err != nil {
		return err
	}
	s.accepted.Store(&pins)
	return nil
}

// Pins exports only after the original custody ACK, without sharing mutable
// data. It provides no recovery constructor or independent protected custody.
func (e Enrollment) Pins() (Pins, bool) {
	if e.state == nil {
		return Pins{}, false
	}
	accepted := e.state.accepted.Load()
	if accepted == nil {
		return Pins{}, false
	}
	return *accepted, true
}

// create requires one private system-owned create and its exact original ACK.
func create(ctx context.Context, storage Writer, collection, key, value string) (string, error) {
	acks, err := storage.StorageWrite(ctx, []*runtime.StorageWrite{{Collection: collection, Key: key, UserID: "", Value: value, Version: "*", PermissionRead: 0, PermissionWrite: 0}})
	if err != nil || ctx.Err() != nil || len(acks) != 1 || !nakamastorage.ValidAcknowledgement(acks[0], collection, key, nakamastorage.SystemOwnerID) || !validVersion(acks[0].GetVersion()) {
		return "", unknown(ctx, err)
	}
	return acks[0].GetVersion(), nil
}

// unknown preserves cancellation while withholding backend details.
func unknown(ctx context.Context, err error) error {
	return nakamastorage.SanitizeError(ctx, err, ErrUnknown)
}

// validVersion excludes wildcard and malformed opaque ACK versions.
func validVersion(value string) bool { return value != "*" && handoffidentity.OpaqueUTF8(value, 1024) }

// nilStorage detects typed nil dependencies without restricting value clients.
func nilStorage(value any) bool {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	kind := v.Kind()
	return (kind == reflect.Chan || kind == reflect.Func || kind == reflect.Interface || kind == reflect.Map || kind == reflect.Pointer || kind == reflect.Slice) && v.IsNil()
}
