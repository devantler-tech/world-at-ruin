package agones

import (
	"strings"
	"testing"
)

func TestParseClaimLocatorPreservesCanonicalRoutingGrammar(t *testing.T) {
	key := strings.Repeat("a", 64)
	digest := strings.Repeat("a", 52)
	locator := "v1." + key + "." + digest
	gotKey, gotDigest, ok := parseClaimLocator(locator)
	if !ok || gotKey != key || gotDigest != digest {
		t.Fatal("canonical locator was changed or refused")
	}
	for _, bad := range []string{
		"v2." + key + "." + digest,
		"v1." + strings.ToUpper(key) + "." + digest,
		"v1." + key + "." + strings.Repeat("a", 51) + "b", // same decoded bytes, nonzero unused bits
		"v1." + key + "." + strings.ToUpper(digest),
		locator + ".extra",
		"v1." + key[:63] + "." + digest,
	} {
		if _, _, accepted := parseClaimLocator(bad); accepted {
			t.Fatalf("noncanonical locator accepted: %q", bad)
		}
	}
}
