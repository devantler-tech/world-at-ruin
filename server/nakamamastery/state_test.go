package nakamamastery

import (
	"reflect"
	"testing"
)

func TestAwardBanksExactIntegers(t *testing.T) {
	state := State{Schema: 1, Weapons: map[string]Track{"axe": {200, 95}}, Stain: Stain{ID: "old", Points: map[string]int64{"axe": 9}}}
	next, out, err := transition(state, eventPayload{Kind: "award", Weapon: "axe", Amount: 8}, "award-1")
	if err != nil {
		t.Fatal(err)
	}
	if next.Weapons["axe"] != (Track{300, 3}) || out.Credited != 8 || !reflect.DeepEqual(next.Stain, state.Stain) {
		t.Fatalf("award = %#v, %#v", next, out)
	}
	if state.Weapons["axe"] != (Track{200, 95}) {
		t.Fatal("mutated input")
	}
}

func TestDeathReplacesOnlyPositiveLossAndAuditsDestruction(t *testing.T) {
	state := State{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "spear": {100, 49}}, Stain: Stain{ID: "old", Points: map[string]int64{"axe": 7, "spear": 3}}}
	next, out, err := transition(state, eventPayload{Kind: "death", Percent: 50}, "death-1")
	if err != nil {
		t.Fatal(err)
	}
	if next.Weapons["axe"] != (Track{200, 38}) || next.Weapons["spear"] != (Track{100, 25}) || next.Stain.ID != "death-1" ||
		!reflect.DeepEqual(next.Stain.Points, map[string]int64{"axe": 37, "spear": 24}) || !reflect.DeepEqual(out.Destroyed, map[string]int64{"axe": 7, "spear": 3}) {
		t.Fatalf("death = %#v, %#v", next, out)
	}
	state.Weapons = map[string]Track{"axe": {200, 1}}
	state.Stain = Stain{ID: "old", Points: map[string]int64{"axe": 9}}
	next, out, err = transition(state, eventPayload{Kind: "death", Percent: 50}, "death-noop")
	if err != nil || !reflect.DeepEqual(next, state) || len(out.Dropped) != 0 || len(out.Destroyed) != 0 {
		t.Fatalf("no-op = %#v, %#v, %v", next, out, err)
	}
}

func TestReclaimRequiresIdentityAndConservesWholeTransfer(t *testing.T) {
	state := State{Schema: 1, Weapons: map[string]Track{"axe": {200, 80}, "spear": {100, 95}}, Stain: Stain{ID: "death-2", Points: map[string]int64{"axe": 37, "spear": 24}}}
	next, out, err := transition(state, eventPayload{Kind: "reclaim", StainID: "death-2"}, "reclaim-1")
	if err != nil || next.Weapons["axe"] != (Track{300, 17}) || next.Weapons["spear"] != (Track{200, 19}) || next.Stain.ID != "" || len(next.Stain.Points) != 0 || out.Credited != 61 {
		t.Fatalf("reclaim = %#v, %#v, %v", next, out, err)
	}
	if _, _, err := transition(state, eventPayload{Kind: "reclaim", StainID: "death-1"}, "stale"); err == nil {
		t.Fatal("accepted stale stain")
	}
	state.Weapons["spear"] = Track{9007199254740900, 99}
	state.Stain.Points["spear"] = 1
	before := cloneState(state)
	if _, _, err := transition(state, eventPayload{Kind: "reclaim", StainID: "death-2"}, "overflow"); err == nil || !reflect.DeepEqual(state, before) {
		t.Fatal("partial overflow transfer")
	}
}

func TestAwardBoundaryAndOverflow(t *testing.T) {
	state := emptyState()
	next, _, err := transition(state, eventPayload{Kind: "award", Weapon: "future:weapon", Amount: 9007199254740991}, "max")
	if err != nil || next.Weapons["future:weapon"] != (Track{9007199254740900, 91}) {
		t.Fatalf("max = %#v %v", next, err)
	}
	next.Weapons["future:weapon"] = Track{9007199254740900, 99}
	for _, amount := range []int64{-1, 0, 1, 9007199254740992} {
		if _, _, err := transition(next, eventPayload{Kind: "award", Weapon: "future:weapon", Amount: amount}, "bad"); err == nil {
			t.Fatalf("accepted %d", amount)
		}
	}
}
