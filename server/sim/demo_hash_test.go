package sim

import (
	"encoding/binary"
	"hash"
	"hash/fnv"
)

// newDemoHashWriter shares only serialization; each demo keeps its independent event stream and golden.
func newDemoHashWriter() (hash.Hash64, func(uint64)) {
	h := fnv.New64a()
	var buf [8]byte
	return h, func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}
}
