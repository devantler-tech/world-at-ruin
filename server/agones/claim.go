package agones

import (
	"context"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"strings"
	"sync"

	sdkproto "agones.dev/agones/pkg/sdk"
)

// ErrClaimBinding refuses admission without revealing allocation metadata.
var ErrClaimBinding = errors.New("agones: allocated claim binding is unavailable")

// ClaimBinding is an observed route to a private handoff lease, never authority
// to claim it. The private service independently verifies the token and lease.
type ClaimBinding struct {
	Namespace     string
	AllocationID  string
	GameServerUID string
	LeaseObjectID string
	AttemptDigest string
	revision      uint64
}

// ClaimBinding returns the exact allocation observed by the preparation watch.
func (p *PreparedAdmission) ClaimBinding() (ClaimBinding, error) {
	return p.binding.snapshot()
}

// ClaimBindingCurrent detects intervening invalidation, including an identical
// locator that appeared again after a conflicting observation.
func (p *PreparedAdmission) ClaimBindingCurrent(binding ClaimBinding) bool {
	current, err := p.ClaimBinding()
	return err == nil && current == binding
}

// This lock is independent of PreparedAdmission.mu: sidecar RPCs can deliver
// watch callbacks while Ready or Shutdown owns the lifecycle lock.
type claimBindingState struct {
	mu          sync.Mutex
	ctx         context.Context
	cancel      context.CancelFunc
	identity    gameServerIdentity
	envelope    string
	fingerprint string
	readyValue  string
	current     ClaimBinding
	revision    uint64
	closed      bool
}

func (s *claimBindingState) snapshot() (ClaimBinding, error) {
	if s == nil {
		return ClaimBinding{}, ErrClaimBinding
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.ctx.Err() != nil || s.current.LeaseObjectID == "" {
		return ClaimBinding{}, ErrClaimBinding
	}
	return s.current, nil
}

func (s *claimBindingState) live() bool {
	if s == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closed && s.ctx.Err() == nil
}

func (s *claimBindingState) observe(gs *sdkproto.GameServer) {
	next := ClaimBinding{}
	if admissionIdentityMetadataMatches(gs, s.identity, s.envelope, s.fingerprint, s.readyValue) &&
		gs.GetStatus().GetState() == "Allocated" && gs.GetObjectMeta().GetDeletionTimestamp() == 0 {
		leaseID, digest, valid := parseClaimLocator(gs.GetObjectMeta().GetAnnotations()[ClaimLocatorAnnotation])
		if valid && gs.GetObjectMeta().GetLabels()[AttemptLabel] == digest {
			next = ClaimBinding{
				Namespace:     s.identity.namespace,
				AllocationID:  s.identity.name,
				GameServerUID: s.identity.uid,
				LeaseObjectID: leaseID,
				AttemptDigest: digest,
			}
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	previous := s.current
	previous.revision = 0
	if previous == next {
		return
	}
	s.revision++
	next.revision = s.revision
	s.current = next
}

func (s *claimBindingState) close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.closed = true
	s.current = ClaimBinding{}
	s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
}

func parseClaimLocator(locator string) (string, string, bool) {
	if len(locator) != 120 {
		return "", "", false
	}
	parts := strings.Split(locator, ".")
	if len(parts) != 3 || parts[0] != "v1" || len(parts[1]) != 64 || len(parts[2]) != 52 {
		return "", "", false
	}
	key, err := hex.DecodeString(parts[1])
	if err != nil || hex.EncodeToString(key) != parts[1] {
		return "", "", false
	}
	encoding := base32.StdEncoding.WithPadding(base32.NoPadding)
	digest, err := encoding.DecodeString(strings.ToUpper(parts[2]))
	if err != nil || len(digest) != 32 || strings.ToLower(encoding.EncodeToString(digest)) != parts[2] {
		return "", "", false
	}
	return parts[1], parts[2], true
}
