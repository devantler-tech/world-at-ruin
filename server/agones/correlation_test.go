package agones

import (
	"strings"
	"testing"
)

func TestCorrelationLabelUsesTheFullCanonicalSHA256Digest(t *testing.T) {
	got, err := CorrelationLabel("attempt-7")
	if err != nil {
		t.Fatalf("CorrelationLabel returned an error: %v", err)
	}
	const want = "tacnzegdot6y5a6jxfnhkyi7tpwg4ddozxf62uyz2zereccbouqq"
	if got != want {
		t.Fatalf("CorrelationLabel = %q, want %q", got, want)
	}
	if len(got) != 52 {
		t.Fatalf("CorrelationLabel length = %d, want full 52-character digest", len(got))
	}
}

func TestCorrelationLabelRefusesUnsafeRawIdentity(t *testing.T) {
	for _, value := range []string{
		"",
		"attempt/7",
		"attempt\r\ninjected",
		strings.Repeat("a", 129),
	} {
		t.Run(value, func(t *testing.T) {
			if got, err := CorrelationLabel(value); err == nil || got != "" {
				t.Fatalf("CorrelationLabel(%q) = %q, %v; want refusal", value, got, err)
			}
		})
	}
}
