package ownedchild

import (
	"errors"
	"testing"
)

// TestExactSenderAndPermanentRetirement catches a connection/PID-string shortcut
// and reopening after stop, death or an unreadable process handle.
func TestExactSenderAndPermanentRetirement(t *testing.T) {
	for _, cause := range []string{"stop", "death", "lost handle"} {
		t.Run(cause, func(t *testing.T) {
			b := boundary{original: sender{pid: 101, uid: 10001, gid: 10001}}
			live := func() (bool, error) { return true, nil }
			if !b.authorize(b.original, true, live) {
				t.Fatal("original refused")
			}
			if b.authorize(sender{pid: 102, uid: 10001, gid: 10001}, true, live) {
				t.Fatal("same-user replacement accepted")
			}
			if b.authorize(b.original, false, live) {
				t.Fatal("invalid frame accepted")
			}
			switch cause {
			case "stop":
				b.retire()
			case "death":
				b.authorize(b.original, true, func() (bool, error) { return false, nil })
			case "lost handle":
				b.authorize(b.original, true, func() (bool, error) { return false, errors.New("unreadable") })
			}
			if b.authorize(b.original, true, live) {
				t.Fatal("retired authority reopened")
			}
			b.retire()
			if b.count() != 1 {
				t.Fatalf("effects=%d, want exactly the original positive", b.count())
			}
		})
	}
}
