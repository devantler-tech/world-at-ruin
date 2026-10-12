// Package ownedchild is a disposable diagnostic experiment, with no serving caller.
package ownedchild

import "sync"

// sender records kernel-observed message credentials, never a caller claim.
type sender struct {
	pid      int32
	uid, gid uint32
}

// boundary serializes diagnostic effects and irreversible retirement.
type boundary struct {
	mu       sync.Mutex
	original sender
	retired  bool
	sealed   bool
	effects  int
}

// authorize checks the complete frame and exact live sender at one local point.
// It does not make the following effect atomic with physical process death.
func (b *boundary) authorize(got sender, valid bool, live func() (bool, error)) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.retired || !b.sealed || !valid || got != b.original {
		return false
	}
	alive, err := live()
	if err != nil || !alive {
		b.retired = true
		return false
	}
	b.effects++
	return true
}

// completeSeal consumes the trusted startup's complete raw TSYNC observation.
// A positive failing-thread TID is a refusal even when errno is zero.
func (b *boundary) completeSeal(value, errno uint64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.retired {
		return false
	}
	if value != 0 || errno != 0 {
		b.retired = true
		return false
	}
	b.sealed = true
	return true
}

// retire permanently closes the diagnostic boundary before stop or control loss.
func (b *boundary) retire() { b.mu.Lock(); defer b.mu.Unlock(); b.retired = true }

// count reads the effects under the same serialization as authorization.
func (b *boundary) count() int { b.mu.Lock(); defer b.mu.Unlock(); return b.effects }
