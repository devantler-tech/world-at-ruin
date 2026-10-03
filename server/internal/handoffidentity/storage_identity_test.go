package handoffidentity

import (
	"strings"
	"testing"
)

func TestSHA256HexKeepsCanonicalCurrentKeySpelling(t *testing.T) {
	for _, size := range []int{0, 63, 64, 65} {
		if got := SHA256Hex(strings.Repeat("a", size)); got != (size == 64) {
			t.Fatalf("size %d accepted = %t", size, got)
		}
	}
	for code := range 256 {
		c := byte(code)
		value := strings.Repeat("0", 63) + string([]byte{c})
		want := strings.ContainsRune("0123456789abcdef", rune(c))
		if SHA256Hex(value) != want {
			t.Errorf("hex byte %02x accepted incorrectly", c)
		}
	}
}

func TestUUIDSpellingKeepsHistoricalCaseAndSystemOwner(t *testing.T) {
	for _, value := range []string{"00000000-0000-0000-0000-000000000000", "AABBCCDD-0000-0000-0000-AABBCCDDEEFF"} {
		if !UUID(value) {
			t.Fatalf("historical UUID refused: %q", value)
		}
	}
	for _, value := range []string{"", "000000000000-0000-0000-000000000000", "00000000-0000-0000-0000-00000000000g", "00000000-0000-0000-0000-0000000000000", "00000000-0000-0000-0000-00000000000é"} {
		if UUID(value) {
			t.Fatalf("malformed UUID accepted: %q", value)
		}
	}
}
