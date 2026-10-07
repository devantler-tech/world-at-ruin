// Package nakamamastery owns an inactive, server-only mastery transaction
// boundary. No production runtime composes it or accepts client award amounts.
package nakamamastery

import "errors"

var ErrInvalid = errors.New("mastery: invalid state or event")

type Track struct {
	Banked   int64 `json:"banked"`
	Unbanked int64 `json:"unbanked"`
}
type Stain struct {
	ID     string           `json:"id"`
	Points map[string]int64 `json:"points"`
}
type State struct {
	Schema  int              `json:"schema"`
	Weapons map[string]Track `json:"weapons"`
	Stain   Stain            `json:"stain"`
}
type Outcome struct {
	Schema    int              `json:"schema"`
	Kind      string           `json:"kind"`
	Credited  int64            `json:"credited"`
	Dropped   map[string]int64 `json:"dropped"`
	Destroyed map[string]int64 `json:"destroyed"`
	State     State            `json:"state"`
}
type eventPayload struct {
	Kind    string `json:"kind"`
	Weapon  string `json:"weapon"`
	Amount  int64  `json:"amount"`
	Percent int    `json:"percent"`
	StainID string `json:"stain_id"`
}

func emptyState() State {
	return State{Schema: 1, Weapons: map[string]Track{}, Stain: Stain{Points: map[string]int64{}}}
}
func cloneState(state State) State {
	next := emptyState()
	next.Stain.ID = state.Stain.ID
	for k, v := range state.Weapons {
		next.Weapons[k] = v
	}
	for k, v := range state.Stain.Points {
		next.Stain.Points[k] = v
	}
	return next
}
