package zoneclaim

import (
	"strings"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// Receipt identifies the original admitted allocation lifetime. It contains no
// secret, and possession never proves termination or grants cleanup authority.
type Receipt struct {
	Namespace string
	Observer  sim.EntityID
	Fence     nakamalease.SessionFence
}

// Equal compares every identity field and the exact generation instant without
// requiring the same time zone representation or process-local monotonic clock.
func (r Receipt) Equal(other Receipt) bool {
	a, b := r.Fence, other.Fence
	return r.Namespace == other.Namespace && r.Observer == other.Observer &&
		a.LeaseObjectID == b.LeaseObjectID && a.LeaseVersion == b.LeaseVersion &&
		a.AttemptDigest == b.AttemptDigest && a.AllocationID == b.AllocationID &&
		a.GameServerUID == b.GameServerUID && a.Generation.Equal(b.Generation)
}

// Matches binds a receipt to the server-observed allocation and player observer.
// Storage versions are bounded printable opaque values, never wildcard writes.
func (r Receipt) Matches(binding agones.ClaimBinding, observer sim.EntityID) bool {
	f := r.Fence
	return r.Namespace == binding.Namespace && r.Observer == observer && observer != 0 &&
		f.LeaseObjectID == binding.LeaseObjectID && f.AttemptDigest == binding.AttemptDigest &&
		f.AllocationID == binding.AllocationID && f.GameServerUID == binding.GameServerUID &&
		f.LeaseVersion != "" && f.LeaseVersion != "*" && len(f.LeaseVersion) <= 1024 &&
		strings.IndexFunc(f.LeaseVersion, func(c rune) bool { return c < 33 || c > 126 }) < 0 &&
		!f.Generation.IsZero() && f.Generation.UnixNano() > 0
}
