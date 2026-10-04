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
