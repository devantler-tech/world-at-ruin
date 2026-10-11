package spiretrial

import "testing"

func TestRolePolicyIsOneDirectedCycle(t *testing.T) {
	for _, server := range []string{"supervisor", "custodian", "child"} {
		allowed := 0
		for _, caller := range []string{"supervisor", "custodian", "child", "unknown"} {
			if caller == expectedCaller(server) {
				allowed++
			}
		}
		if allowed != 1 {
			t.Fatalf("%s has %d allowed callers", server, allowed)
		}
	}
	if expectedCaller("custodian") != "supervisor" || expectedCaller("child") != "custodian" || expectedCaller("supervisor") != "child" || expectedCaller("unknown") != "" {
		t.Fatal("role policy changed")
	}
}
