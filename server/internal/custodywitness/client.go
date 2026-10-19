package custodywitness

import (
	"context"
	"errors"
	"reflect"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
)

// ErrConditionFailed is what a Table returns when a conditional write is
// definitively refused because the stored value is not the expected one.
var ErrConditionFailed = errors.New("custody witness: write condition refused")

// Table is the witness storage boundary. Every read is strongly consistent.
// Get and Put may address the table by a replaceable name, so the client reads
// Identity both before and after each of them: a call that reached a
// replacement table is never acknowledged and never verified.
type Table interface {
	// Identity reads the identity of the table the client is actually using.
	Identity(ctx context.Context) (TableIdentity, error)
	// Get reads the value stored under key, reporting whether one exists.
	Get(ctx context.Context, key string) (value string, found bool, err error)
	// Put stores value under key only when the stored value equals expected,
	// or, when expected is empty, only when no value exists. A refused
	// condition returns ErrConditionFailed; any other error is ambiguous: the
	// write may or may not have been committed.
	Put(ctx context.Context, key, expected, value string) error
}

// TableIdentity pins one table instance. A restored or recreated table has a
// different identity even under the same name, so a mismatch is never read.
type TableIdentity struct {
	ID        string
	CreatedAt time.Time
}

func (t TableIdentity) valid() bool {
	return handoffidentity.OpaqueUTF8(t.ID, 256) && !t.CreatedAt.IsZero()
}

// Config opts into the client. Identity is the table identity pinned at
// deployment; the client never learns it from the table it is checking.
type Config struct {
	Enabled  bool
	Table    Table
	Identity TableIdentity
}

// Client advances and compares witness records. It holds no record state and
// grants no launch, claim or completion authority: a write acknowledgement and
// a "verified" comparison are evidence a caller combines with its own pins.
type Client struct {
	table    Table
	identity TableIdentity
}

// operationTimeout bounds every write, read and comparison.
const operationTimeout = 30 * time.Second

// New refuses a disabled, incomplete or unpinned configuration.
func New(cfg Config) (*Client, error) {
	if !cfg.Enabled || nilTable(cfg.Table) || !cfg.Identity.valid() {
		return nil, ErrUnknown
	}
	return &Client{cfg.Table, cfg.Identity}, nil
}

// Write moves the witness record for next.LifetimeKey from previous to next in
// one conditional write. An enrolled record is created only when no record
// exists, so previous must be the zero Record; every later stage must follow
// previous exactly. The returned record is the acknowledgement and is returned
// only when this call's own write is known to be stored. A refused condition,
// a replaced table or an unresolved reply returns ErrUnknown, and nothing is
// ever retried into a different state.
func (c *Client) Write(ctx context.Context, previous, next Record) (Record, error) {
	expected := ""
	switch {
	case next.Stage == StageEnrolled && previous == (Record{}) && next.Valid():
	case next.Stage != StageEnrolled && next.Follows(previous):
		expected, _ = EncodeRecord(previous)
	default:
		return Record{}, ErrUnknown
	}
	value, err := EncodeRecord(next)
	if err != nil {
		return Record{}, ErrUnknown
	}
	writeCtx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	if !c.pinned(writeCtx) {
		return Record{}, ErrUnknown
	}
	err = c.table.Put(writeCtx, next.LifetimeKey, expected, value)
	if err == nil && writeCtx.Err() == nil {
		// A write that may have reached a replacement table is no
		// acknowledgement, even though that table accepted it.
		if !c.pinned(writeCtx) {
			return Record{}, ErrUnknown
		}
		return next, nil
	}
	if errors.Is(err, ErrConditionFailed) {
		return Record{}, ErrUnknown
	}
	// The reply was lost or arrived after cancellation. Exactly one strongly
	// consistent re-read decides: only the exact intended record is an
	// acknowledgement. The read is detached from the caller's cancellation so
	// an abandoned call can still learn what it committed, and is bounded.
	readCtx, cancelRead := context.WithTimeout(context.WithoutCancel(ctx), operationTimeout)
	defer cancelRead()
	if !c.pinned(readCtx) {
		return Record{}, ErrUnknown
	}
	stored, found, err := c.table.Get(readCtx, next.LifetimeKey)
	if err != nil || readCtx.Err() != nil || !found || stored != value || !c.pinned(readCtx) {
		return Record{}, ErrUnknown
	}
	return next, nil
}

// Verdict is the outcome of comparing an independently retained record with
// the witness. Only Verified is positive.
type Verdict string

// The seven comparison outcomes.
const (
	// Verified: the witness holds exactly the expected record.
	Verified Verdict = "verified"
	// WitnessAhead: the witness acknowledged a later stage of the same chain,
	// so the expected record comes from a rolled-back history.
	WitnessAhead Verdict = "witness-ahead"
	// WitnessBehind: the expected stage was never witnessed and does not count.
	WitnessBehind Verdict = "witness-behind"
	// Absent: no record exists. Absence never means a fresh lifetime.
	Absent Verdict = "absent"
	// Conflicting: the stored record disagrees with the expected chain or
	// cannot be read as exactly one valid record.
	Conflicting Verdict = "conflicting"
	// TableReplaced: the table is not the one pinned at deployment.
	TableReplaced Verdict = "table-replaced"
	// Unavailable: the witness could not be read; nothing is known.
	Unavailable Verdict = "unavailable"
)

// Compare reads the witness record for expected.LifetimeKey and classifies it
// against expected. It never writes and never rebuilds a record from what it
// reads: the result only says how the two agree.
func (c *Client) Compare(ctx context.Context, expected Record) Verdict {
	if !expected.Valid() {
		return Unavailable
	}
	ctx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	if verdict := c.identityVerdict(ctx); verdict != Verified {
		return verdict
	}
	value, found, err := c.table.Get(ctx, expected.LifetimeKey)
	// The read may have reached a table that replaced the pinned one after
	// the first check, so neither its result nor its error counts until the
	// pin holds again.
	if verdict := c.identityVerdict(ctx); verdict != Verified {
		return verdict
	}
	if err != nil || ctx.Err() != nil {
		return Unavailable
	}
	if !found {
		return Absent
	}
	stored, err := DecodeRecord(value)
	if err != nil || stored.LifetimeKey != expected.LifetimeKey {
		return Conflicting
	}
	switch storedRank, expectedRank := stored.Stage.rank(), expected.Stage.rank(); {
	case stored == expected:
		return Verified
	case storedRank > expectedRank && stored.truncate(expectedRank) == expected:
		return WitnessAhead
	case storedRank < expectedRank && expected.truncate(storedRank) == stored:
		return WitnessBehind
	default:
		return Conflicting
	}
}

// truncate returns the record as it stood when it reached the given stage.
func (r Record) truncate(rank int) Record {
	switch rank {
	case 1:
		return Record{LifetimeKey: r.LifetimeKey, Stage: StageEnrolled, EnrollmentPin: r.EnrollmentPin}
	case 2:
		return Record{LifetimeKey: r.LifetimeKey, Stage: StageCustody, EnrollmentPin: r.EnrollmentPin, CustodyPin: r.CustodyPin}
	default:
		return r
	}
}

// pinned reads the table identity and requires it to equal the pinned value.
func (c *Client) pinned(ctx context.Context) bool {
	return c.identityVerdict(ctx) == Verified
}

// identityVerdict reads the table identity: Verified when it equals the pinned
// value, TableReplaced when it differs and Unavailable when it cannot be read.
func (c *Client) identityVerdict(ctx context.Context) Verdict {
	identity, err := c.table.Identity(ctx)
	if err != nil || ctx.Err() != nil {
		return Unavailable
	}
	if !sameIdentity(identity, c.identity) {
		return TableReplaced
	}
	return Verified
}

// sameIdentity compares instants, so a location or monotonic reading cannot
// make the same table look replaced.
func sameIdentity(got, want TableIdentity) bool {
	return got.ID == want.ID && got.CreatedAt.Equal(want.CreatedAt)
}

// nilTable detects typed nil dependencies without restricting value tables.
func nilTable(value Table) bool {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	nilable := map[reflect.Kind]bool{reflect.Chan: true, reflect.Func: true, reflect.Interface: true, reflect.Map: true, reflect.Pointer: true, reflect.Slice: true}
	return nilable[v.Kind()] && v.IsNil()
}
