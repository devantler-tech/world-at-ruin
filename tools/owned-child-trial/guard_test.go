package ownedchild

import (
	"errors"
	"testing"
)

// TestPendingSealCannotAdmit catches treating a live original process as sealed.
func TestPendingSealCannotAdmit(t *testing.T) {
	b := boundary{original: sender{pid: 101, uid: 10001, gid: 10001}}
	if b.authorize(b.original, true, func() (bool, error) { return true, nil }) || b.count() != 0 {
		t.Fatal("unsealed original admitted a diagnostic effect")
	}
}

// TestExactSenderAndPermanentRetirement catches a connection/PID-string shortcut
// and reopening after stop, death or an unreadable process handle.
func TestExactSenderAndPermanentRetirement(t *testing.T) {
	for _, cause := range []string{"stop", "death", "lost handle"} {
		t.Run(cause, func(t *testing.T) {
			b := boundary{original: sender{pid: 101, uid: 10001, gid: 10001}}
			if !b.completeSeal(0, 0) {
				t.Fatal("successful seal refused")
			}
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

// TestSealResultIsExactAndIrreversible separates a failing thread from errno.
func TestSealResultIsExactAndIrreversible(t *testing.T) {
	for _, result := range [][2]uint64{{120, 0}, {0, 22}, {^uint64(0), 22}, {0, 0}} {
		b := boundary{original: sender{pid: 101, uid: 10001, gid: 10001}}
		good := result == [2]uint64{}
		if b.completeSeal(result[0], result[1]) != good {
			t.Fatalf("seal result %v incorrectly classified", result)
		}
		if b.authorize(b.original, true, func() (bool, error) { return true, nil }) != good {
			t.Fatal("effect disagrees with complete sealing result")
		}
		if !good && b.completeSeal(0, 0) {
			t.Fatal("refused seal reopened")
		}
		b.retire()
		if b.completeSeal(0, 0) || b.authorize(b.original, true, func() (bool, error) { return true, nil }) {
			t.Fatal("retired seal reopened")
		}
	}
}
