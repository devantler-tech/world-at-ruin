// Package zoneclaim binds a zone's socket admission to its observed private
// handoff locator. It has no public endpoint and owns no player-state writer.
package zoneclaim

import (
	"context"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// BindingSource is server-controlled observation, not request-supplied routing.
// PreparedAdmission supplies it from the exact sealed GameServer's SDK watch.
type BindingSource interface {
	ClaimBinding() (agones.ClaimBinding, error)
	ClaimBindingCurrent(agones.ClaimBinding) bool
}

// PrivateClaimer authenticates the zone workload, resolves the exact pinned
// resource, verifies the token independently and conditionally claims its lease.
// Implementations must honor context and preserve ambiguous committed outcomes.
type PrivateClaimer interface {
	Claim(context.Context, agones.ClaimBinding, string, sim.EntityID) error
}

// Gate joins the local allocation observation with the private claim boundary.
type Gate struct {
	source  BindingSource
	backend PrivateClaimer
}

// New refuses missing server boundaries; production activation also requires
// workload-identity transport and fenced session-end recovery.
func New(source BindingSource, backend PrivateClaimer) (*Gate, error) {
	if source == nil || backend == nil {
		return nil, errors.New("zoneclaim: binding source and private claimant are required")
	}
	return &Gate{source: source, backend: backend}, nil
}

// Claim authorizes one upgrade. Locators never come from a player request, and
// every outcome is checked against the same observation revision after the RPC.
// A failed or canceled upgrade never releases an already committed claim.
func (g *Gate) Claim(ctx context.Context, token string, observer sim.EntityID) error {
	if ctx.Err() != nil {
		return ErrRefused
	}
	binding, err := g.source.ClaimBinding()
	if err != nil || !g.source.ClaimBindingCurrent(binding) || ctx.Err() != nil {
		return ErrRefused
	}
	if err := g.backend.Claim(ctx, binding, token, observer); err != nil {
		return ErrRefused
	}
	if ctx.Err() != nil || !g.source.ClaimBindingCurrent(binding) {
		return ErrRefused
	}
	return nil
}

// ErrRefused carries no backend, token, or allocation detail.
var ErrRefused = errors.New("zoneclaim: admission refused")
