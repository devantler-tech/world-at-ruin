package handoffidentity

import (
	"strings"
	"testing"
)

func TestIdentifierGrammarsKeepTheirDistinctPunctuation(t *testing.T) {
	const lettersAndDigits = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	for code := range 256 {
		char := byte(code)
		value := "prefix" + string([]byte{char}) + "suffix"
		wantCorrelation := strings.ContainsRune(lettersAndDigits+"-_", rune(char))
		wantUID := strings.ContainsRune(lettersAndDigits+"-_.", rune(char))
		if got := CorrelationID(value); got != wantCorrelation {
			t.Errorf("correlation byte %02x = %t, want %t", char, got, wantCorrelation)
		}
		if got := GameServerUID(value); got != wantUID {
			t.Errorf("GameServer UID byte %02x = %t, want %t", char, got, wantUID)
		}
	}
	for _, size := range []int{0, 1, 127, 128, 129} {
		value := strings.Repeat("a", size)
		want := size > 0 && size <= 128
		if CorrelationID(value) != want || GameServerUID(value) != want {
			t.Errorf("identifier size %d did not preserve its bound", size)
		}
	}
}

func TestDNSNamesPreserveLabelAndWholeNameBounds(t *testing.T) {
	for _, test := range []struct {
		value            string
		label, subdomain bool
	}{
		{"a", true, true}, {"0", true, true}, {"a-b", true, true},
		{"a.b", false, true}, {"a.0", false, true},
		{"", false, false}, {"-a", false, false}, {"a-", false, false},
		{"A", false, false}, {"a_b", false, false}, {"a..b", false, false},
		{".a", false, false}, {"a.", false, false}, {"a.-b", false, false},
		{"a.b-", false, false}, {"é", false, false}, {"a\xff", false, false},
		{strings.Repeat("a", 63), true, true},
		{strings.Repeat("a", 64), false, false},
		{strings.Repeat("a.", 126) + "a", false, true},
		{strings.Repeat("a.", 126) + "aa", false, false},
	} {
		if DNSLabel(test.value) != test.label || DNSSubdomain(test.value) != test.subdomain {
			t.Errorf("DNS shape %q: label=%t subdomain=%t, want %t/%t", test.value, DNSLabel(test.value), DNSSubdomain(test.value), test.label, test.subdomain)
		}
	}
}

func TestFingerprintRejectsNoncanonicalSpellings(t *testing.T) {
	for _, test := range []struct {
		value string
		valid bool
	}{
		{strings.Repeat("a", 52), true},
		{strings.Repeat("7", 51) + "q", true},
		{"", false}, {strings.Repeat("a", 51), false},
		{strings.Repeat("a", 53), false}, {strings.Repeat("A", 52), false},
		{strings.Repeat("a", 51) + "b", false},
		{strings.Repeat("a", 51) + "0", false},
		{strings.Repeat("a", 52) + "====", false},
	} {
		if got := Fingerprint(test.value); got != test.valid {
			t.Errorf("fingerprint %q = %t, want %t", test.value, got, test.valid)
		}
	}
}
