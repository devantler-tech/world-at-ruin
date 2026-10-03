package fencereference_test

import (
	"fmt"

	"github.com/devantler-tech/world-at-ruin/server/internal/fencereference"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
)

func ExampleReference() {
	config := fencereference.Config{
		Enabled: true,
		Record: nakamageneration.Record{
			GenerationID: "generation-1", MemberPodUIDs: []string{"actor-a", "actor-b"},
			MemberSetDigest: "0b9f16d661afb1f86220747ba6a7302a190925b4f682b7dafd576400370f3d57",
			State:           "open", Version: "source-version-1",
		},
		// Illustrative keys only; real pins come from trusted server issuance.
		ActorSPKI: map[string][32]byte{"actor-a": {1}, "actor-b": {2}},
	}
	authority, err := fencereference.New(config)
	if err != nil {
		panic(err)
	}
	ticket, err := authority.Admit("actor-a", "attempt-1")
	if err != nil {
		panic(err)
	}
	if err := authority.Commit(ticket, "actor-a", "resource-1"); err != nil {
		panic(err)
	}
	if err := authority.Drain(); err != nil {
		panic(err)
	}
	receipt, err := authority.Fence()
	if err != nil {
		panic(err)
	}
	if err := authority.Accept(receipt, authority.Binding()); err != nil {
		panic(err)
	}
	result, err := authority.Resolve(ticket, receipt)
	if err != nil {
		panic(err)
	}
	fmt.Println(result.Allocation.ResourceUID, result.Unallocated)
	// Output: resource-1 false
}
