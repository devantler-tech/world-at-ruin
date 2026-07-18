// Package wire is the versioned, transport-agnostic binary codec for the
// replication payload: the full sim.Snapshot an observer receives when it
// joins a zone, and the per-tick sim.SnapshotDelta stream that follows. It is
// the first networking child of the server-foundation epic — the byte layout a
// transport (and, on the other end, the client's delta-apply) will carry, kept
// deliberately free of any socket so the format exists as a pinned contract
// before transport selection is made.
//
// Design constraints:
//
//   - Born versioned. Product law requires backward-compatible protocols, so
//     every message opens with an explicit protocol version and the decoder
//     refuses anything it does not speak — a version bump is a visible,
//     reviewed act, never a silent re-interpretation of old bytes.
//   - Canonical and deterministic. One message value has exactly one byte
//     encoding: fixed-width little-endian integers, fixed field order, list
//     lengths up front, and the sim's documented ascending-EntityID list order
//     enforced — never repaired — on BOTH encode and decode. The same predicate
//     (validateSnapshot / validateDelta) guards both directions, so encoder and
//     decoder cannot drift apart on what "well-formed" means.
//   - Fail closed on untrusted bytes. Decode never panics and never trusts a
//     length: counts are capped (MaxEntities) before any allocation, every read
//     is bounds-checked, and trailing bytes are refused. A malformed or hostile
//     frame yields an error, not a crash of the single authoritative zone loop.
//
// The codec is read-only over sim types: it imports sim's replication values
// and never touches world state, so it cannot move any committed sim golden.
package wire

import (
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// Version is the wire-protocol version this build speaks, and the decoder's
// ceiling: Decode refuses any other version, loudly. It starts at 1 and only
// ever grows; bumping it is a deliberate, reviewed act (the protocol is
// forward-only, like every other versioned surface in this product).
const Version uint16 = 1

// Message kinds. Values are part of the wire contract — never renumber one.
const (
	// KindSnapshot frames a full sim.Snapshot: the whole replicated state an
	// observer holds after a tick. Sent when an observer joins (or must resync).
	KindSnapshot uint8 = 1
	// KindSnapshotDelta frames a sim.SnapshotDelta: the minimal per-tick
	// spawn/update/despawn update for one observer.
	KindSnapshotDelta uint8 = 2
)

// MaxEntities caps every entity/ID list in a single message. It exists so a
// hostile or corrupt length prefix can neither force a giant allocation nor
// overflow any size arithmetic: 65 536 is far above any real per-observer
// interest set (area-of-interest bounds what one observer is told about) while
// keeping the largest possible list under ~2.7 MB. Enforced on encode and
// decode alike.
const MaxEntities = 1 << 16

// Fixed byte widths of the layout. These are contract, not implementation
// detail: the committed hex golden in wire_test.go pins them for the future
// client-side decoder.
const (
	headerSize      = 3                // version uint16 + kind uint8
	tickSize        = 8                // uint64
	observerSize    = 8                // uint64 EntityID
	countSize       = 4                // uint32 list length
	idSize          = 8                // uint64 EntityID
	entityStateSize = idSize + 3*8 + 8 // id + pos.{x,y,z} + radius
)

// Decode failures wrap exactly one of these sentinel errors, so a transport
// can classify a bad frame without string-matching.
var (
	ErrTruncated = errors.New("wire: truncated message")
	ErrTrailing  = errors.New("wire: trailing bytes after message")
	ErrVersion   = errors.New("wire: unsupported protocol version")
	ErrKind      = errors.New("wire: unknown message kind")
	ErrCount     = errors.New("wire: list length exceeds MaxEntities")
	ErrOrder     = errors.New("wire: list not in strictly ascending EntityID order")
	ErrOverlap   = errors.New("wire: delta lists share an EntityID")
)

// Message is one decoded frame: the kind tag plus the one payload field that
// kind selects (the other stays zero). A tagged value rather than an interface
// keeps the transport's receive loop allocation-light and switch-friendly.
type Message struct {
	Kind     uint8
	Snapshot sim.Snapshot      // set when Kind == KindSnapshot
	Delta    sim.SnapshotDelta // set when Kind == KindSnapshotDelta
}

// EncodeSnapshot encodes a full snapshot as one wire message. It refuses a
// non-canonical value (list too long, or not strictly ascending by ID) rather
// than repairing it: the sim's snapshot layer guarantees ascending order, so a
// violation here is an upstream determinism bug that must fail loudly, not be
// sorted into silence.
func EncodeSnapshot(s sim.Snapshot) ([]byte, error) {
	if err := validateSnapshot(s); err != nil {
		return nil, err
	}
	b := make([]byte, 0, headerSize+tickSize+observerSize+countSize+len(s.Entities)*entityStateSize)
	b = appendHeader(b, KindSnapshot)
	b = binary.LittleEndian.AppendUint64(b, s.Tick)
	b = binary.LittleEndian.AppendUint64(b, uint64(s.Observer))
	b = appendStates(b, s.Entities)
	return b, nil
}

// EncodeSnapshotDelta encodes a per-tick delta as one wire message, under the
// same refuse-don't-repair rule as EncodeSnapshot. An empty delta encodes fine
// (a transport may choose to skip sending it — sim.SnapshotDelta.Empty is the
// test — but the codec does not decide transport policy).
func EncodeSnapshotDelta(d sim.SnapshotDelta) ([]byte, error) {
	if err := validateDelta(d); err != nil {
		return nil, err
	}
	b := make([]byte, 0, headerSize+tickSize+
		countSize+len(d.Entered)*entityStateSize+
		countSize+len(d.Moved)*entityStateSize+
		countSize+len(d.Left)*idSize)
	b = appendHeader(b, KindSnapshotDelta)
	b = binary.LittleEndian.AppendUint64(b, d.Tick)
	b = appendStates(b, d.Entered)
	b = appendStates(b, d.Moved)
	b = binary.LittleEndian.AppendUint32(b, uint32(len(d.Left)))
	for _, id := range d.Left {
		b = binary.LittleEndian.AppendUint64(b, uint64(id))
	}
	return b, nil
}

// Decode parses one wire message. It fails closed: unknown version or kind,
// truncation at any offset, an over-cap count, out-of-order or overlapping
// lists, and trailing bytes are all errors — and a decoded message satisfies
// exactly the same validity predicate an encoder enforces, so
// decode(encode(m)) == m and encode(decode(b)) == b for every valid m and b.
func Decode(b []byte) (Message, error) {
	r := reader{buf: b}
	version, err := r.u16()
	if err != nil {
		return Message{}, err
	}
	if version != Version {
		return Message{}, fmt.Errorf("%w: message speaks %d, this build speaks %d", ErrVersion, version, Version)
	}
	kind, err := r.u8()
	if err != nil {
		return Message{}, err
	}
	m := Message{Kind: kind}
	switch kind {
	case KindSnapshot:
		if m.Snapshot, err = r.snapshot(); err != nil {
			return Message{}, err
		}
		if err := validateSnapshot(m.Snapshot); err != nil {
			return Message{}, err
		}
	case KindSnapshotDelta:
		if m.Delta, err = r.delta(); err != nil {
			return Message{}, err
		}
		if err := validateDelta(m.Delta); err != nil {
			return Message{}, err
		}
	default:
		return Message{}, fmt.Errorf("%w: %d", ErrKind, kind)
	}
	if r.off != len(r.buf) {
		return Message{}, fmt.Errorf("%w: %d byte(s)", ErrTrailing, len(r.buf)-r.off)
	}
	return m, nil
}

// --- shared validity predicate (one source for both directions) ------------

func validateSnapshot(s sim.Snapshot) error {
	return validateStates("entities", s.Entities)
}

func validateDelta(d sim.SnapshotDelta) error {
	if err := validateStates("entered", d.Entered); err != nil {
		return err
	}
	if err := validateStates("moved", d.Moved); err != nil {
		return err
	}
	if err := validateIDs("left", d.Left); err != nil {
		return err
	}
	// The tracker's single pass makes entered/moved/left pairwise disjoint (an
	// entity is in `next` xor in `prev`-only); a frame violating that would
	// make the client's spawn/update/despawn apply ambiguous, so it is invalid.
	seen := make(map[sim.EntityID]string, len(d.Entered)+len(d.Moved)+len(d.Left))
	claim := func(list string, id sim.EntityID) error {
		if prev, dup := seen[id]; dup {
			return fmt.Errorf("%w: entity %d in both %s and %s", ErrOverlap, id, prev, list)
		}
		seen[id] = list
		return nil
	}
	for _, es := range d.Entered {
		if err := claim("entered", es.ID); err != nil {
			return err
		}
	}
	for _, es := range d.Moved {
		if err := claim("moved", es.ID); err != nil {
			return err
		}
	}
	for _, id := range d.Left {
		if err := claim("left", id); err != nil {
			return err
		}
	}
	return nil
}

// validateStates enforces the list contract sim documents: at most MaxEntities
// entries, strictly ascending by EntityID (which also forbids duplicates).
func validateStates(list string, es []sim.EntityState) error {
	if len(es) > MaxEntities {
		return fmt.Errorf("%w: %s has %d entries", ErrCount, list, len(es))
	}
	for i := 1; i < len(es); i++ {
		if es[i].ID <= es[i-1].ID {
			return fmt.Errorf("%w: %s at index %d", ErrOrder, list, i)
		}
	}
	return nil
}

// validateIDs is validateStates for a bare ID list.
func validateIDs(list string, ids []sim.EntityID) error {
	if len(ids) > MaxEntities {
		return fmt.Errorf("%w: %s has %d entries", ErrCount, list, len(ids))
	}
	for i := 1; i < len(ids); i++ {
		if ids[i] <= ids[i-1] {
			return fmt.Errorf("%w: %s at index %d", ErrOrder, list, i)
		}
	}
	return nil
}

// --- encoding helpers -------------------------------------------------------

func appendHeader(b []byte, kind uint8) []byte {
	b = binary.LittleEndian.AppendUint16(b, Version)
	return append(b, kind)
}

// appendStates appends a uint32 count followed by each state's fixed-width
// fields. Callers validate the list first, so the count always fits uint32.
func appendStates(b []byte, es []sim.EntityState) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(len(es)))
	for _, s := range es {
		b = binary.LittleEndian.AppendUint64(b, uint64(s.ID))
		b = binary.LittleEndian.AppendUint64(b, uint64(s.Pos.X))
		b = binary.LittleEndian.AppendUint64(b, uint64(s.Pos.Y))
		b = binary.LittleEndian.AppendUint64(b, uint64(s.Pos.Z))
		b = binary.LittleEndian.AppendUint64(b, uint64(s.Radius))
	}
	return b
}

// --- decoding helpers -------------------------------------------------------

// reader is a bounds-checked cursor over one frame. Every read either returns
// a value or ErrTruncated; nothing indexes the buffer unchecked.
type reader struct {
	buf []byte
	off int
}

func (r *reader) need(n int) error {
	if len(r.buf)-r.off < n {
		return fmt.Errorf("%w: need %d byte(s) at offset %d, have %d", ErrTruncated, n, r.off, len(r.buf)-r.off)
	}
	return nil
}

func (r *reader) u8() (uint8, error) {
	if err := r.need(1); err != nil {
		return 0, err
	}
	v := r.buf[r.off]
	r.off++
	return v, nil
}

func (r *reader) u16() (uint16, error) {
	if err := r.need(2); err != nil {
		return 0, err
	}
	v := binary.LittleEndian.Uint16(r.buf[r.off:])
	r.off += 2
	return v, nil
}

func (r *reader) u32() (uint32, error) {
	if err := r.need(4); err != nil {
		return 0, err
	}
	v := binary.LittleEndian.Uint32(r.buf[r.off:])
	r.off += 4
	return v, nil
}

func (r *reader) u64() (uint64, error) {
	if err := r.need(8); err != nil {
		return 0, err
	}
	v := binary.LittleEndian.Uint64(r.buf[r.off:])
	r.off += 8
	return v, nil
}

func (r *reader) snapshot() (sim.Snapshot, error) {
	var s sim.Snapshot
	tick, err := r.u64()
	if err != nil {
		return s, err
	}
	observer, err := r.u64()
	if err != nil {
		return s, err
	}
	s.Tick = tick
	s.Observer = sim.EntityID(observer)
	if s.Entities, err = r.states("entities"); err != nil {
		return sim.Snapshot{}, err
	}
	return s, nil
}

func (r *reader) delta() (sim.SnapshotDelta, error) {
	var d sim.SnapshotDelta
	tick, err := r.u64()
	if err != nil {
		return d, err
	}
	d.Tick = tick
	if d.Entered, err = r.states("entered"); err != nil {
		return sim.SnapshotDelta{}, err
	}
	if d.Moved, err = r.states("moved"); err != nil {
		return sim.SnapshotDelta{}, err
	}
	if d.Left, err = r.ids("left"); err != nil {
		return sim.SnapshotDelta{}, err
	}
	return d, nil
}

// states reads a count-prefixed EntityState list. The cap check runs BEFORE
// the length check and BEFORE any allocation, so a hostile count is reported
// as ErrCount and can never size a buffer.
func (r *reader) states(list string) ([]sim.EntityState, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	if n > MaxEntities {
		return nil, fmt.Errorf("%w: %s claims %d entries", ErrCount, list, n)
	}
	if err := r.need(int(n) * entityStateSize); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	es := make([]sim.EntityState, n)
	for i := range es {
		id, _ := r.u64()
		x, _ := r.u64()
		y, _ := r.u64()
		z, _ := r.u64()
		radius, _ := r.u64()
		es[i] = sim.EntityState{
			ID:     sim.EntityID(id),
			Pos:    sim.Vec3{X: int64(x), Y: int64(y), Z: int64(z)},
			Radius: int64(radius),
		}
	}
	return es, nil
}

// ids reads a count-prefixed EntityID list, under the same cap-first rule.
func (r *reader) ids(list string) ([]sim.EntityID, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	if n > MaxEntities {
		return nil, fmt.Errorf("%w: %s claims %d entries", ErrCount, list, n)
	}
	if err := r.need(int(n) * idSize); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	ids := make([]sim.EntityID, n)
	for i := range ids {
		v, _ := r.u64()
		ids[i] = sim.EntityID(v)
	}
	return ids, nil
}
