package dnsname

import (
	"strings"
	"testing"
)

func TestASCIINameBoundaries(t *testing.T) {
	t.Parallel()
	max := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)
	for _, name := range []string{"Zone.Example", "single", "123", "12.3", "a-b.example", strings.Repeat("x", 63), max} {
		if !Valid(name) {
			t.Errorf("rejected %q", name)
		}
	}
	for _, name := range []string{"", ".", "a..b", "a.", ".a", "-a", "a-", "*.example", "a_b", "é.example", strings.Repeat("x", 64), max + "d"} {
		if Valid(name) {
			t.Errorf("accepted %q", name)
		}
	}
}
