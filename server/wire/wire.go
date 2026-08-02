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

// LegacyVersion is the retained entity-only protocol. Version is the newest
// protocol this build speaks. Decode accepts the inclusive range so the zone
// can expand before it contracts; outbound connections select one version at
// handshake and keep it for their lifetime.
const LegacyVersion uint16 = 1
const Version uint16 = 2

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

// MaxCasts is independently enforced for every cast list. One authoritative
// entity can own at most one active cast, so the entity ceiling is also the
// natural cast ceiling.
const MaxCasts = MaxEntities

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
	activeCastSize  = idSize + 1 + 3*8 + 3*8 + 4*8 + 2*8

	maxWireWorldExtentMM     = 1_000_000
	maxWireTelegraphExtentMM = 4 * maxWireWorldExtentMM
)

// Decode failures wrap exactly one of these sentinel errors, so a transport
// can classify a bad frame without string-matching.
var (
	ErrTruncated  = errors.New("wire: truncated message")
	ErrTrailing   = errors.New("wire: trailing bytes after message")
	ErrVersion    = errors.New("wire: unsupported protocol version")
	ErrKind       = errors.New("wire: unknown message kind")
	ErrCount      = errors.New("wire: list length exceeds MaxEntities")
	ErrOrder      = errors.New("wire: list not in strictly ascending EntityID order")
	ErrOverlap    = errors.New("wire: delta lists share an EntityID")
	ErrRadius     = errors.New("wire: entity radius is negative")
	ErrCastShape  = errors.New("wire: invalid cast shape")
	ErrCastTiming = errors.New("wire: invalid cast timing")
	ErrCastCaster = errors.New("wire: cast caster is not replicated")
)

// Message is one decoded frame: the kind tag plus the one payload field that
// kind selects (the other stays zero). A tagged value rather than an interface
// keeps the transport's receive loop allocation-light and switch-friendly.
type Message struct {
	Version  uint16
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
	return EncodeSnapshotVersion(s, Version)
}

// EncodeSnapshotVersion encodes s for a negotiated protocol version. Version
// 1 deliberately omits casts and remains byte-identical to the retained
// entity-only contract; version 2 carries the authoritative active-cast set.
func EncodeSnapshotVersion(s sim.Snapshot, version uint16) ([]byte, error) {
	if err := validateSnapshotVersion(s, version); err != nil {
		return nil, err
	}
	capacity := headerSize + tickSize + observerSize + countSize + len(s.Entities)*entityStateSize
	if version >= 2 {
		capacity += countSize + len(s.Casts)*activeCastSize
	}
	b := make([]byte, 0, capacity)
	b = appendHeader(b, version, KindSnapshot)
	b = binary.LittleEndian.AppendUint64(b, s.Tick)
	b = binary.LittleEndian.AppendUint64(b, uint64(s.Observer))
	b = appendStates(b, s.Entities)
	if version >= 2 {
		b = appendCasts(b, s.Casts)
	}
	return b, nil
}

// EncodeSnapshotDelta encodes a per-tick delta as one wire message, under the
// same refuse-don't-repair rule as EncodeSnapshot. An empty delta encodes fine
// (a transport may choose to skip sending it — sim.SnapshotDelta.Empty is the
// test — but the codec does not decide transport policy).
func EncodeSnapshotDelta(d sim.SnapshotDelta) ([]byte, error) {
	return EncodeSnapshotDeltaVersion(d, Version)
}

// EncodeSnapshotDeltaVersion is the delta counterpart to
// EncodeSnapshotVersion. Version 2 appends started and ended cast lists.
func EncodeSnapshotDeltaVersion(d sim.SnapshotDelta, version uint16) ([]byte, error) {
	if err := validateDeltaVersion(d, version); err != nil {
		return nil, err
	}
	capacity := headerSize + tickSize +
		countSize + len(d.Entered)*entityStateSize +
		countSize + len(d.Moved)*entityStateSize +
		countSize + len(d.Left)*idSize
	if version >= 2 {
		capacity += countSize + len(d.StartedCasts)*activeCastSize + countSize + len(d.EndedCasts)*idSize
	}
	b := make([]byte, 0, capacity)
	b = appendHeader(b, version, KindSnapshotDelta)
	b = binary.LittleEndian.AppendUint64(b, d.Tick)
	b = appendStates(b, d.Entered)
	b = appendStates(b, d.Moved)
	b = appendCount(b, len(d.Left))
	for _, id := range d.Left {
		b = binary.LittleEndian.AppendUint64(b, uint64(id))
	}
	if version >= 2 {
		b = appendCasts(b, d.StartedCasts)
		b = appendIDs(b, d.EndedCasts)
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
	if version < LegacyVersion || version > Version {
		return Message{}, fmt.Errorf("%w: message speaks %d, this build speaks %d-%d", ErrVersion, version, LegacyVersion, Version)
	}
	kind, err := r.u8()
	if err != nil {
		return Message{}, err
	}
	m := Message{Version: version, Kind: kind}
	switch kind {
	case KindSnapshot:
		if m.Snapshot, err = r.snapshot(version); err != nil {
			return Message{}, err
		}
		if err := validateSnapshotVersion(m.Snapshot, version); err != nil {
			return Message{}, err
		}
	case KindSnapshotDelta:
		if m.Delta, err = r.delta(version); err != nil {
			return Message{}, err
		}
		if err := validateDeltaVersion(m.Delta, version); err != nil {
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

func validateSnapshotVersion(s sim.Snapshot, version uint16) error {
	if err := validateVersion(version); err != nil {
		return err
	}
	if err := validateStates("entities", s.Entities); err != nil {
		return err
	}
	if version == LegacyVersion {
		return nil
	}
	if err := validateCasts("casts", s.Tick, s.Casts); err != nil {
		return err
	}
	entity := 0
	for _, cast := range s.Casts {
		for entity < len(s.Entities) && s.Entities[entity].ID < cast.Caster {
			entity++
		}
		if entity == len(s.Entities) || s.Entities[entity].ID != cast.Caster {
			return fmt.Errorf("%w: caster %d", ErrCastCaster, cast.Caster)
		}
	}
	return nil
}

func validateDeltaVersion(d sim.SnapshotDelta, version uint16) error {
	if err := validateVersion(version); err != nil {
		return err
	}
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
	if version >= 2 {
		if err := validateCasts("started casts", d.Tick, d.StartedCasts); err != nil {
			return err
		}
		if err := validateIDs("ended casts", d.EndedCasts); err != nil {
			return err
		}
	}
	return nil
}

func validateVersion(version uint16) error {
	if version < LegacyVersion || version > Version {
		return fmt.Errorf("%w: %d", ErrVersion, version)
	}
	return nil
}

func validateCasts(list string, tick uint64, casts []sim.ActiveCast) error {
	if len(casts) > MaxCasts {
		return fmt.Errorf("%w: %s has %d entries", ErrCount, list, len(casts))
	}
	for i, cast := range casts {
		if i > 0 && cast.Caster <= casts[i-1].Caster {
			return fmt.Errorf("%w: %s at index %d", ErrOrder, list, i)
		}
		if cast.StartTick >= cast.ResolveTick || cast.StartTick >= tick || cast.ResolveTick < tick {
			return fmt.Errorf("%w: %s at index %d is [%d,%d] at tick %d", ErrCastTiming, list, i, cast.StartTick, cast.ResolveTick, tick)
		}
		if err := validateCastShape(cast.Shape); err != nil {
			return fmt.Errorf("%w: %s at index %d: %w", ErrCastShape, list, i, err)
		}
	}
	return nil
}

func validateCastShape(shape sim.Telegraph) error {
	if shape.Origin.X < -maxWireWorldExtentMM || shape.Origin.X > maxWireWorldExtentMM ||
		shape.Origin.Z < -maxWireWorldExtentMM || shape.Origin.Z > maxWireWorldExtentMM {
		return errors.New("origin outside world bounds")
	}
	if shape.Facing.Y != 0 {
		return errors.New("facing is not planar")
	}
	extent := func(v int64) bool { return v >= -maxWireTelegraphExtentMM && v <= maxWireTelegraphExtentMM }
	zeroFacing := shape.Facing.X == 0 && shape.Facing.Z == 0
	switch shape.Kind {
	case sim.ShapeCircle:
		if !zeroFacing || !extent(shape.Outer) || shape.Inner != 0 || shape.HalfWidth != 0 || shape.CosHalf != 0 {
			return errors.New("non-canonical circle")
		}
	case sim.ShapeRing:
		invertedPositiveRing := shape.Outer >= 0 && shape.Inner > shape.Outer
		noncanonicalDegenerateRing := shape.Outer < 0 && shape.Inner != 0
		if !zeroFacing || !extent(shape.Outer) || shape.Inner < 0 || shape.Inner > maxWireTelegraphExtentMM || invertedPositiveRing || noncanonicalDegenerateRing || shape.HalfWidth != 0 || shape.CosHalf != 0 {
			return errors.New("non-canonical ring")
		}
	case sim.ShapeCone:
		if !extent(shape.Outer) || shape.Inner != 0 || shape.HalfWidth != 0 || shape.CosHalf < -sim.CosScale || shape.CosHalf > sim.CosScale {
			return errors.New("non-canonical cone")
		}
	case sim.ShapeRect:
		if !extent(shape.Outer) || shape.Inner != 0 || !extent(shape.HalfWidth) || shape.CosHalf != 0 {
			return errors.New("non-canonical rect")
		}
	default:
		return fmt.Errorf("unknown kind %d", shape.Kind)
	}
	return nil
}

// validateStates enforces the replicated-state contract: at most MaxEntities
// entries, non-negative radii, and strictly ascending EntityIDs (which also
// forbids duplicates).
func validateStates(list string, es []sim.EntityState) error {
	if len(es) > MaxEntities {
		return fmt.Errorf("%w: %s has %d entries", ErrCount, list, len(es))
	}
	for i, state := range es {
		if state.Radius < 0 {
			return fmt.Errorf("%w: %s at index %d", ErrRadius, list, i)
		}
		if i > 0 && state.ID <= es[i-1].ID {
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

func appendHeader(b []byte, version uint16, kind uint8) []byte {
	b = binary.LittleEndian.AppendUint16(b, version)
	return append(b, kind)
}

// appendStates appends a uint32 count followed by each state's fixed-width
// fields. Callers validate the list first, so the count always fits uint32.
func appendStates(b []byte, es []sim.EntityState) []byte {
	b = appendCount(b, len(es))
	for _, s := range es {
		b = binary.LittleEndian.AppendUint64(b, uint64(s.ID))
		b = appendSigned64(b, s.Pos.X)
		b = appendSigned64(b, s.Pos.Y)
		b = appendSigned64(b, s.Pos.Z)
		b = appendSigned64(b, s.Radius)
	}
	return b
}

func appendCasts(b []byte, casts []sim.ActiveCast) []byte {
	b = appendCount(b, len(casts))
	for _, cast := range casts {
		b = binary.LittleEndian.AppendUint64(b, uint64(cast.Caster))
		b = append(b, uint8(cast.Shape.Kind))
		b = appendVec3(b, cast.Shape.Origin)
		b = appendVec3(b, cast.Shape.Facing)
		b = appendSigned64(b, cast.Shape.Outer)
		b = appendSigned64(b, cast.Shape.Inner)
		b = appendSigned64(b, cast.Shape.HalfWidth)
		b = appendSigned64(b, cast.Shape.CosHalf)
		b = binary.LittleEndian.AppendUint64(b, cast.StartTick)
		b = binary.LittleEndian.AppendUint64(b, cast.ResolveTick)
	}
	return b
}

func appendVec3(b []byte, v sim.Vec3) []byte {
	b = appendSigned64(b, v.X)
	b = appendSigned64(b, v.Y)
	return appendSigned64(b, v.Z)
}

func appendIDs(b []byte, ids []sim.EntityID) []byte {
	b = appendCount(b, len(ids))
	for _, id := range ids {
		b = binary.LittleEndian.AppendUint64(b, uint64(id))
	}
	return b
}

// appendCount records a validated list length. Every caller runs the shared
// validity predicate first, so n is non-negative and at most MaxEntities,
// which is strictly smaller than the uint32 wire field's ceiling.
func appendCount(b []byte, n int) []byte {
	return binary.LittleEndian.AppendUint32(b, uint32(n))
}

// appendSigned64 preserves an int64's two's-complement bits in the protocol's
// uint64 storage word. This is an equal-width representation, not arithmetic
// narrowing; signed64 performs the exact inverse after decoding.
func appendSigned64(b []byte, v int64) []byte {
	return binary.LittleEndian.AppendUint64(b, uint64(v))
}

func signed64(v uint64) int64 {
	return int64(v)
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

func (r *reader) snapshot(version uint16) (sim.Snapshot, error) {
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
	if version >= 2 {
		if s.Casts, err = r.casts("casts"); err != nil {
			return sim.Snapshot{}, err
		}
	}
	return s, nil
}

func (r *reader) delta(version uint16) (sim.SnapshotDelta, error) {
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
	if version >= 2 {
		if d.StartedCasts, err = r.casts("started casts"); err != nil {
			return sim.SnapshotDelta{}, err
		}
		if d.EndedCasts, err = r.ids("ended casts"); err != nil {
			return sim.SnapshotDelta{}, err
		}
	}
	return d, nil
}

func (r *reader) casts(list string) ([]sim.ActiveCast, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	if n > MaxCasts {
		return nil, fmt.Errorf("%w: %s claims %d entries", ErrCount, list, n)
	}
	if err := r.need(int(n) * activeCastSize); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	casts := make([]sim.ActiveCast, n)
	for i := range casts {
		caster, _ := r.u64()
		kind, _ := r.u8()
		origin := r.vec3Unchecked()
		facing := r.vec3Unchecked()
		outer, _ := r.u64()
		inner, _ := r.u64()
		halfWidth, _ := r.u64()
		cosHalf, _ := r.u64()
		startTick, _ := r.u64()
		resolveTick, _ := r.u64()
		casts[i] = sim.ActiveCast{
			Caster: sim.EntityID(caster),
			Shape: sim.Telegraph{
				Kind: sim.ShapeKind(kind), Origin: origin, Facing: facing,
				Outer: signed64(outer), Inner: signed64(inner), HalfWidth: signed64(halfWidth), CosHalf: signed64(cosHalf),
			},
			StartTick: startTick, ResolveTick: resolveTick,
		}
	}
	return casts, nil
}

func (r *reader) vec3Unchecked() sim.Vec3 {
	x, _ := r.u64()
	y, _ := r.u64()
	z, _ := r.u64()
	return sim.Vec3{X: signed64(x), Y: signed64(y), Z: signed64(z)}
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
			Pos:    sim.Vec3{X: signed64(x), Y: signed64(y), Z: signed64(z)},
			Radius: signed64(radius),
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
