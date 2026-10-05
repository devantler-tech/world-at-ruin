package wire

import (
	"encoding/binary"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// MovementIntent contains direction in integer thousandths, never velocity,
// position, entity identity or a client clock. Ground mode is 0; mode 1 is
// reserved for future swimming and is currently refused.
type MovementIntent struct {
	Sequence uint64
	X, Z     int16
	Sprint   bool
	Mode     uint8
}

// MovementAck reports the completed authoritative step for this connection's
// own observer. AppliedSequence is cumulative; zero means no input applied.
type MovementAck struct {
	AppliedSequence uint64
	Tick            uint64
	Pos             sim.Vec3
}

const IntentFrameSize = 17

var ErrMovement = errors.New("wire: invalid movement")

func validIntent(i MovementIntent) error {
	x, z := int64(i.X), int64(i.Z)
	if i.Sequence == 0 || i.Mode != 0 || x*x+z*z > 1_000_000 {
		return ErrMovement
	}
	return nil
}

func validAck(a MovementAck) error {
	for _, v := range []int64{a.Pos.X, a.Pos.Y, a.Pos.Z} {
		if v < -maxWireWorldExtentMM || v > maxWireWorldExtentMM {
			return ErrMovement
		}
	}
	return nil
}

// EncodeIntent emits one canonical movement frame for an explicitly v3 peer.
func EncodeIntent(i MovementIntent) ([]byte, error) {
	if err := validIntent(i); err != nil {
		return nil, err
	}
	b := appendHeader(nil, MovementVersion, KindIntent)
	b = binary.LittleEndian.AppendUint64(b, i.Sequence)
	// Equal-width conversions preserve the signed direction's two's-complement bits.
	b = binary.LittleEndian.AppendUint16(b, directionBits(i.X))
	b = binary.LittleEndian.AppendUint16(b, directionBits(i.Z))
	sprint := byte(0)
	if i.Sprint {
		sprint = 1
	}
	return append(b, sprint, i.Mode), nil
}

func EncodeMovementAck(a MovementAck) ([]byte, error) {
	if err := validAck(a); err != nil {
		return nil, err
	}
	b := appendHeader(nil, MovementVersion, KindMovementAck)
	b = binary.LittleEndian.AppendUint64(b, a.AppliedSequence)
	b = binary.LittleEndian.AppendUint64(b, a.Tick)
	return appendVec3(b, a.Pos), nil
}

func decodeMovement(r *reader, m *Message) error {
	if m.Version != MovementVersion {
		return ErrVersion
	}
	if m.Kind == KindIntent {
		if err := r.need(IntentFrameSize - headerSize); err != nil {
			return err
		}
		seq, _ := r.u64()
		x, _ := r.u16()
		z, _ := r.u16()
		sprint, _ := r.u8()
		mode, _ := r.u8()
		if sprint > 1 {
			return ErrMovement
		}
		m.Intent = MovementIntent{Sequence: seq, X: signedDirection(x), Z: signedDirection(z), Sprint: sprint == 1, Mode: mode}
		return validIntent(m.Intent)
	}
	if err := r.need(40); err != nil {
		return err
	}
	seq, _ := r.u64()
	tick, _ := r.u64()
	m.Ack = MovementAck{AppliedSequence: seq, Tick: tick, Pos: r.vec3Unchecked()}
	return validAck(m.Ack)
}

// Preserve signed two's-complement words with range-checked conversions.
// The complementary branch handles the negative half without signed overflow.
func directionBits(v int16) uint16 {
	if v >= 0 {
		return uint16(v)
	}
	n := -int32(v) - 1
	if n >= 0 && n <= 32767 {
		return ^uint16(n)
	}
	return 0 // unreachable for an int16
}

func signedDirection(v uint16) int16 {
	if v <= 32767 {
		return int16(v)
	}
	n := ^v
	if n <= 32767 {
		return -1 - int16(n)
	}
	return 0 // unreachable for a uint16
}
