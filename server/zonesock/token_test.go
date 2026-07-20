package zonesock

import (
	"bytes"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

func testSecret(b byte) []byte { return bytes.Repeat([]byte{b}, minSecretBytes) }

func TestTokenRoundTrip(t *testing.T) {
	secret := testSecret(0xA5)
	v, err := NewHMACVerifier(secret, "allocation-a")
	if err != nil {
		t.Fatalf("NewHMACVerifier: %v", err)
	}
	tok, err := MintToken(secret, "allocation-a", 7, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken: %v", err)
	}
	obs, err := v.Verify(tok)
	if err != nil {
		t.Fatalf("Verify(valid): %v", err)
	}
	if obs != sim.EntityID(7) {
		t.Fatalf("Verify returned observer %d, want 7", obs)
	}
}

func TestTokenRefusedByDifferentAllocation(t *testing.T) {
	secret := testSecret(0xA5)
	tok, err := MintToken(secret, "allocation-a", 7, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken: %v", err)
	}
	v, err := NewHMACVerifier(secret, "allocation-b")
	if err != nil {
		t.Fatalf("NewHMACVerifier: %v", err)
	}
	if _, err := v.Verify(tok); !errors.Is(err, ErrTokenForged) {
		t.Fatalf("Verify(token for another allocation) = %v, want %v", err, ErrTokenForged)
	}
}

func TestTokenRefusals(t *testing.T) {
	secret := testSecret(0xA5)
	v, err := NewHMACVerifier(secret, "allocation-a")
	if err != nil {
		t.Fatalf("NewHMACVerifier: %v", err)
	}
	valid, err := MintToken(secret, "allocation-a", 7, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken: %v", err)
	}
	expired, err := MintToken(secret, "allocation-a", 7, time.Now().Add(-time.Minute))
	if err != nil {
		t.Fatalf("MintToken(expired): %v", err)
	}
	forged, err := MintToken(testSecret(0x5A), "allocation-a", 7, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("MintToken(other secret): %v", err)
	}
	// A forged token whose expiry ALSO lies in the past must still report
	// forged: integrity is checked before any field is trusted.
	forgedAndExpired, err := MintToken(testSecret(0x5A), "allocation-a", 7, time.Now().Add(-time.Minute))
	if err != nil {
		t.Fatalf("MintToken(other secret, expired): %v", err)
	}
	tampered := strings.Replace(valid, ".7.", ".8.", 1)

	cases := []struct {
		name  string
		token string
		want  error
	}{
		{"empty", "", ErrTokenFormat},
		{"garbage", "not-a-token", ErrTokenFormat},
		{"wrong prefix", "v1" + valid[2:], ErrTokenFormat},
		{"non-numeric observer", "v1.x.1.aa", ErrTokenFormat},
		{"non-hex signature", "v1.7.1.zz", ErrTokenFormat},
		{"expired", expired, ErrTokenExpired},
		{"forged", forged, ErrTokenForged},
		{"forged and expired", forgedAndExpired, ErrTokenForged},
		{"tampered observer", tampered, ErrTokenForged},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := v.Verify(c.token); !errors.Is(err, c.want) {
				t.Fatalf("Verify(%q) = %v, want %v", c.token, err, c.want)
			}
		})
	}
}

func TestShortSecretRefused(t *testing.T) {
	short := bytes.Repeat([]byte{1}, minSecretBytes-1)
	if _, err := NewHMACVerifier(short, "allocation-a"); err == nil {
		t.Fatal("NewHMACVerifier accepted a short secret")
	}
	if _, err := MintToken(short, "allocation-a", 1, time.Now().Add(time.Minute)); err == nil {
		t.Fatal("MintToken accepted a short secret")
	}
}

func TestInvalidAllocationRefused(t *testing.T) {
	secret := testSecret(0xA5)
	for _, allocation := range []string{"", "contains.dot"} {
		if _, err := NewHMACVerifier(secret, allocation); err == nil {
			t.Errorf("NewHMACVerifier accepted allocation %q", allocation)
		}
		if _, err := MintToken(secret, allocation, 1, time.Now().Add(time.Minute)); err == nil {
			t.Errorf("MintToken accepted allocation %q", allocation)
		}
	}
}
