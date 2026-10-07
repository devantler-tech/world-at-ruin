package main

import "errors"

type movementOptions struct {
	enabled   bool
	holdTicks uint64
}

func (m movementOptions) validate(listening, minting bool) error {
	if m.enabled && (!listening || minting || m.holdTicks == 0 || m.holdTicks > 300) {
		return errors.New("movement intents: require -listen, no token minting, and -movement-hold-ticks in 1..300")
	}
	return nil
}
