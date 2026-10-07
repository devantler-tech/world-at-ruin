package wire

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"math"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// These hand-written bytes catch rejection of the additive input contract and
// reinterpretation of its signed direction or fixed-width own-state payload.
const movementIntentGolden = "030003" + "0700000000000000" + "e803" + "0000" + "01" + "00"
const movementAckGolden = "030004" + "0700000000000000" + "0900000000000000" + "feffffffffffffff" + "0000000000000000" + "0300000000000000"

func TestMovementFramesDecodeCanonicalGoldens(t *testing.T) {
	for _, golden := range []string{movementIntentGolden, movementAckGolden} {
		b, err := hex.DecodeString(golden)
		if err != nil {
			t.Fatal(err)
		}
		m, err := Decode(b)
		if err != nil {
			t.Fatalf("canonical movement frame refused: %v", err)
		}
		if m.Version != 3 || m.Kind != b[2] {
			t.Fatal("movement frame changed identity")
		}
	}
}

func TestMovementValuesRoundTripAndRefuseMalformedFrames(t *testing.T) {
	i := MovementIntent{Sequence: 7, X: 1000, Sprint: true}
	b, err := EncodeIntent(i)
	if err != nil || hex.EncodeToString(b) != movementIntentGolden {
		t.Fatalf("input golden changed: %x %v", b, err)
	}
	m, err := Decode(b)
	if err != nil || m.Intent != i {
		t.Fatal("direction or sprint lost")
	}
	a := MovementAck{AppliedSequence: 7, Tick: 9, Pos: sim.Vec3{X: -2, Z: 3}}
	b, err = EncodeMovementAck(a)
	if err != nil || hex.EncodeToString(b) != movementAckGolden {
		t.Fatalf("ack golden changed: %x %v", b, err)
	}
	m, err = Decode(b)
	if err != nil || m.Ack != a {
		t.Fatal("authoritative state lost")
	}
	for _, golden := range []string{movementIntentGolden, movementAckGolden} {
		b, _ = hex.DecodeString(golden)
		for cut := 0; cut < len(b); cut++ {
			if _, err := Decode(b[:cut]); err == nil {
				t.Fatalf("truncated movement accepted at %d", cut)
			}
		}
		if _, err := Decode(append(bytes.Clone(b), 0)); err == nil {
			t.Fatal("trailing movement accepted")
		}
		for _, version := range []uint16{1, 2, 4} {
			bad := bytes.Clone(b)
			binary.LittleEndian.PutUint16(bad, version)
			if _, err := Decode(bad); err == nil {
				t.Fatal("movement crossed protocol boundary")
			}
		}
	}
	for _, invalid := range []MovementIntent{{}, {Sequence: 1, X: 1001}, {Sequence: 1, X: 1000, Z: 1}, {Sequence: 1, X: math.MinInt16}, {Sequence: 1, Mode: 1}} {
		if _, err := EncodeIntent(invalid); err == nil {
			t.Fatalf("invalid movement encoded: %+v", invalid)
		}
	}
	b, _ = hex.DecodeString(movementIntentGolden)
	b[15] = 2
	if _, err := Decode(b); err == nil {
		t.Fatal("noncanonical sprint accepted")
	}
}

func TestSignedMovementDirectionRoundTrip(t *testing.T) {
	for _, i := range []MovementIntent{{Sequence: 1, X: -1000}, {Sequence: 1, X: -600, Z: 800}, {Sequence: 1, X: 600, Z: -800}, {Sequence: 1, Z: -1000}} {
		b, err := EncodeIntent(i)
		if err != nil {
			t.Fatal(err)
		}
		m, err := Decode(b)
		if err != nil || m.Intent != i {
			t.Fatalf("signed direction changed: %+v %v", m.Intent, err)
		}
	}
}
