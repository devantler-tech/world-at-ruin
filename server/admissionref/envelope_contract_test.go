package admissionref

import (
	"bytes"
	"testing"
)

func TestEnvelopeCanonicalBytes(t *testing.T) {
	for _, value := range []string{"v1.", "v2.AAE", "v1.AAE=", "v1.AAE\n", "v1.\rAAE", "v1.AAF"} {
		if _, ok := decodeEnvelope(value); ok {
			t.Fatalf("accepted noncanonical envelope %q", value)
		}
	}
	got, ok := decodeEnvelope("v1.AAE")
	if !ok || !bytes.Equal(got, []byte{0, 1}) {
		t.Fatalf("short canonical reference changed: %x %v", got, ok)
	}
}
