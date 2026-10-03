package admissionformat

import (
	"bytes"
	"testing"
)

func TestLabelPreservesLiteralDomainAndIdentityOrder(t *testing.T) {
	want := []byte("world-at-ruin/zone-admission/v1\x00zone\x00server\x00uid\x00fingerprint")
	if got := OAEPLabel("zone", "server", "uid", "fingerprint"); !bytes.Equal(got, want) {
		t.Fatalf("label = %q", got)
	}
}
func TestEnvelopeCanonicalBytes(t *testing.T) {
	for _, value := range []string{"v1.", "v2.AAE", "v1.AAE=", "v1.AAE\n", "v1.\rAAE", "v1.AAF"} {
		if _, ok := DecodeEnvelope(value); ok {
			t.Fatalf("accepted noncanonical envelope %q", value)
		}
	}
	got, ok := DecodeEnvelope("v1.AAE")
	if !ok || !bytes.Equal(got, []byte{0, 1}) {
		t.Fatalf("canonical bytes changed: %x %v", got, ok)
	}
}
