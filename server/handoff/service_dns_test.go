package handoff

import "testing"

func TestDNSNameEndpointPolicy(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"single", "123", "Zone.Example", "12.3"} {
		if !validDNSName(name) {
			t.Errorf("handoff rejected %q", name)
		}
	}
	for _, name := range []string{"127.0.0.1", "::1", "a..example", "a_b.example", "Zone.Example."} {
		if validDNSName(name) {
			t.Errorf("handoff accepted %q", name)
		}
	}
}
