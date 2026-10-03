package handoffidentity

import (
	"strings"
	"testing"
)

func TestSHA256Base32LiteralDigest(t *testing.T) {
	const want = "4oymiquy7qobjgx36tejs35zeqt24qpemsnzgtfeswmrw6csxbkq"
	if got := SHA256Base32(nil); got != want {
		t.Fatalf("digest = %q", got)
	}
}
func TestOpaqueUTF8PreservesSpellingAndByteBounds(t *testing.T) {
	for _, value := range []string{"opaque:identity", "é", "漢字", "escaped\\name"} {
		if !OpaqueUTF8(value, len(value)) {
			t.Fatalf("refused %q", value)
		}
	}
	for _, value := range []string{"", "a b", "a\u00a0b", "a\u2003b", "a\x00b", "a\x7fb", string([]byte{0xff}), strings.Repeat("é", 65)} {
		if OpaqueUTF8(value, 128) {
			t.Fatalf("accepted %q", value)
		}
	}
	if OpaqueUTF8("é", 1) || OpaqueUTF8("a", 0) || OpaqueUTF8("a", -1) {
		t.Fatal("byte bound ignored")
	}
}
