package sim

import (
	"encoding/binary"
	"hash/fnv"
	"slices"
	"testing"
)

// combatBounds is a roomy flat test zone: nothing in these tests should ever
// touch a wall, so positions stay exactly where the arithmetic puts them.
var combatBounds = Bounds{
	Min: Vec3{X: -20_000, Y: 0, Z: -20_000},
	Max: Vec3{X: 20_000, Y: 4_000, Z: 20_000},
}

// newCombatWorld builds a world with one stationary mob (ID 100 at the
// origin) registered with the given params. Targets are added by the tests;
// they use radius 0 (point capsules) so the separation pass can never move
// anyone and every position is exactly what the movement math produced.
func newCombatWorld(p MobParams) *World {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 100, Pos: Vec3{}, MaxSpeed: 0, Radius: 300})
	w.AddMob(100, p)
	return w
}

// steps advances the world n ticks.
func steps(w *World, n int) {
	for range n {
		w.Step()
	}
}

func TestStandStillTargetIsCaught(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 30_000})

	steps(w, 3) // cast painted during tick 0, resolves during tick 3
	if got := w.DrainHits(); len(got) != 0 {
		t.Fatalf("cast resolved before its cast time elapsed: %+v", got)
	}
	steps(w, 1)
	hits := w.DrainHits()
	if len(hits) != 1 {
		t.Fatalf("want exactly 1 resolution, got %d: %+v", len(hits), hits)
	}
	h := hits[0]
	if h.Tick != 3 || h.Caster != 100 {
		t.Fatalf("want resolution at tick 3 by caster 100, got %+v", h)
	}
	if !slices.Equal(h.Targets, []EntityID{1}) {
		t.Fatalf("a target that never moved must be caught, got targets %v", h.Targets)
	}
}

func TestWalkOutEscapesAndAnchorStaysPut(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 4, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 30_000})

	w.Step() // tick 0: circle painted at the target's position
	casts := w.ActiveCasts()
	if len(casts) != 1 {
		t.Fatalf("want 1 active cast after the decide tick, got %d", len(casts))
	}
	if casts[0].Shape.Origin != (Vec3{X: 1_000}) {
		t.Fatalf("circle must be anchored where the target stood at cast start, got %+v", casts[0].Shape.Origin)
	}

	// Walk +X at 1000 mm/tick for ticks 1-3: x = 4000, 3000 mm from the
	// anchor — strictly outside the 2000 mm circle at resolution (tick 4).
	w.SetIntent(1, Vec3{X: 30_000})
	steps(w, 4)
	if got := w.ActiveCasts(); len(got) != 0 {
		t.Fatalf("cast should have resolved, still active: %+v", got)
	}
	hits := w.DrainHits()
	if len(hits) != 1 {
		t.Fatalf("want exactly 1 resolution, got %d", len(hits))
	}
	if len(hits[0].Targets) != 0 {
		t.Fatalf("a target that stepped out must not be caught, got targets %v", hits[0].Targets)
	}
	if hits[0].Tick != 4 {
		t.Fatalf("want resolution at tick 4, got %d", hits[0].Tick)
	}
}

// TestStepBackInIsCaughtAtResolution pins the snapshot-at-resolution law:
// membership is measured once, at resolution, against where you are standing
// THEN — leaving during the cast and wandering back in still gets you hit.
func TestStepBackInIsCaughtAtResolution(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 6, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 30_000})

	w.Step() // tick 0: anchor {1000,0,0}, resolves during tick 6
	w.SetIntent(1, Vec3{X: 30_000})
	steps(w, 3) // ticks 1-3: x=4000 — 3000 mm out, outside the circle
	w.SetIntent(1, Vec3{X: -30_000})
	steps(w, 2) // ticks 4-5: back to x=2000 — 1000 mm from the anchor
	w.SetIntent(1, Vec3{})
	steps(w, 1) // tick 6: resolution

	hits := w.DrainHits()
	if len(hits) != 1 || !slices.Equal(hits[0].Targets, []EntityID{1}) {
		t.Fatalf("membership must be measured at resolution (back inside ⇒ caught), got %+v", hits)
	}
}

// TestAnchorCatchesBystanderNotEscapedTarget proves the mark belongs to the
// ground, not to the target: the aggro target walks out, an uninvolved
// bystander standing on the painted spot is the one caught.
func TestAnchorCatchesBystanderNotEscapedTarget(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 4, CooldownTicks: 600, CircleRadiusMM: 1_500})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 30_000}) // nearest ⇒ aggro target
	w.Add(Entity{ID: 2, Pos: Vec3{X: 2_000}, MaxSpeed: 0})      // 1000 mm from the anchor-to-be

	w.Step() // anchor {1000,0,0}
	w.SetIntent(1, Vec3{X: 30_000})
	steps(w, 4)

	hits := w.DrainHits()
	if len(hits) != 1 || !slices.Equal(hits[0].Targets, []EntityID{2}) {
		t.Fatalf("want the bystander (2) caught and the escaped target (1) free, got %+v", hits)
	}
}

// TestEscapeNeedsTheWindow is the negative control for the walk-out escape:
// the identical run under a wind-up too short to cover the circle's edge
// distance ends in a catch. This proves the escape above is earned by
// distance over the window, not handed out by the harness. (Ported from the
// converged MobController suite, #207.)
func TestEscapeNeedsTheWindow(t *testing.T) {
	// 2 ticks at 1000 mm/tick = 2000 mm from x=1000: at resolution the target
	// is 2000 mm from the anchor — exactly ON the 2000 mm circle's inclusive
	// edge, so it is caught where the 4-tick run above escapes cleanly.
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 30_000})

	w.Step()
	w.SetIntent(1, Vec3{X: 30_000})
	steps(w, 2)
	hits := w.DrainHits()
	if len(hits) != 1 || len(hits[0].Targets) != 1 || hits[0].Targets[0] != 1 {
		t.Fatalf("under a too-short wind-up the same run must end in a catch, got %+v", hits)
	}
}

// TestAggroNearestWinsOverLowerID pins distance-first acquisition: the nearer
// entity wins even when a lower ID sits farther away. (Ported, #207.)
func TestAggroNearestWinsOverLowerID(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 1_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 4_000}, MaxSpeed: 0})
	w.Add(Entity{ID: 2, Pos: Vec3{X: -2_000}, MaxSpeed: 0})

	w.Step()
	casts := w.ActiveCasts()
	if len(casts) != 1 || casts[0].Shape.Origin != (Vec3{X: -2_000}) {
		t.Fatalf("want the nearer entity 2 acquired over the lower ID, got %+v", casts)
	}
}

// TestAggroEdgeInclusive pins the boundary convention: exactly on the aggro
// radius aggros (the same inclusive edge every telegraph shape uses), one
// millimetre beyond does not. (Ported, #207.)
func TestAggroEdgeInclusive(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 5_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 1_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 5_000}, MaxSpeed: 0})
	w.Step()
	if casts := w.ActiveCasts(); len(casts) != 1 {
		t.Fatalf("a target exactly on the aggro radius must be acquired, got %+v", casts)
	}

	w2 := newCombatWorld(MobParams{AggroRadiusMM: 5_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 1_000})
	w2.Add(Entity{ID: 1, Pos: Vec3{X: 5_001}, MaxSpeed: 0})
	steps(w2, 5)
	if casts := w2.ActiveCasts(); len(casts) != 0 {
		t.Fatalf("a target one mm beyond the radius must not be acquired, got %+v", casts)
	}
}

// TestHitCarriesDamage pins the latent-landing seam ported from #195: a
// resolution carries its caster's configured damage on the record, so the
// consumer lands it with ApplyDamage(hit.Targets, hit.Damage) and needs no
// access to the mob registry. An unconfigured mob carries zero.
func TestHitCarriesDamage(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000, Damage: 7})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})
	steps(w, 3)
	hits := w.DrainHits()
	if len(hits) != 1 || hits[0].Damage != 7 {
		t.Fatalf("a resolution must carry the configured damage 7, got %+v", hits)
	}

	w2 := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w2.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})
	steps(w2, 3)
	hits = w2.DrainHits()
	if len(hits) != 1 || hits[0].Damage != 0 {
		t.Fatalf("an unconfigured mob's resolution must carry zero damage, got %+v", hits)
	}
}

// TestNegativeDamageIsClampedInert pins damage's ingestion clamp at the mob
// registry: a negative configured amount survives as zero (a telegraph that
// marks but never heals), mirroring every other MobParams bound.
func TestNegativeDamageIsClampedInert(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000, Damage: -10})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0, MaxHealth: 50})
	steps(w, 3)
	hits := w.DrainHits()
	if len(hits) != 1 || hits[0].Damage != 0 {
		t.Fatalf("negative configured damage must clamp to zero, got %+v", hits)
	}
	if deaths := w.ApplyDamage(hits[0].Targets, hits[0].Damage); len(deaths) != 0 || w.Get(1).Health != 50 {
		t.Fatalf("landing a zero-damage hit must change nothing, got health %d", w.Get(1).Health)
	}
}

// TestCombatNeverMovesAnyone pins the record-only contract the converged
// controller suite used to pin against the movement golden: the combat layer
// records hits and paints casts but never touches a position, so a world
// with a registered mob ends every entity exactly where the identical world
// without one does. A future chase-movement change must break this test
// consciously.
func TestCombatNeverMovesAnyone(t *testing.T) {
	build := func(withMob bool) *World {
		w := NewWorld(combatBounds)
		w.Add(Entity{ID: 9, Pos: Vec3{}, MaxSpeed: 0, Radius: 300})
		w.Add(Entity{ID: 1, Pos: Vec3{X: -6_000, Z: -6_000}, MaxSpeed: 4_000, Radius: 300})
		if withMob {
			w.AddMob(9, MobParams{AggroRadiusMM: 15_000, CastTicks: 5, CooldownTicks: 10, CircleRadiusMM: 2_500, Damage: 3})
		}
		return w
	}
	a, b := build(true), build(false)
	for i := range 120 {
		for _, w := range []*World{a, b} {
			w.SetIntent(1, Vec3{X: int64(1_000 * (i%3 - 1)), Z: 2_000})
		}
		a.Step()
		b.Step()
	}
	if a.DroppedHits() == 0 && len(a.DrainHits()) == 0 {
		t.Fatal("the mob-bearing twin never resolved a cast — the comparison would be vacuous")
	}
	for _, id := range []EntityID{9, 1} {
		if pa, pb := a.Get(id).Pos, b.Get(id).Pos; pa != pb {
			t.Fatalf("combat moved entity %d: %+v vs %+v", id, pa, pb)
		}
	}
}

func TestCasterIsNeverCaughtByItsOwnCircle(t *testing.T) {
	// The circle is painted 500 mm from the mob with a 2000 mm radius, so the
	// mob is standing deep inside its own mark at resolution.
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 500}, MaxSpeed: 0})

	steps(w, 3)
	hits := w.DrainHits()
	if len(hits) != 1 || !slices.Equal(hits[0].Targets, []EntityID{1}) {
		t.Fatalf("caster must be excluded from its own circle, got %+v", hits)
	}
}

func TestEqualDistanceTieBreaksToLowerID(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 1_000})
	w.Add(Entity{ID: 3, Pos: Vec3{X: -3_000}, MaxSpeed: 0})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 3_000}, MaxSpeed: 0})

	w.Step()
	casts := w.ActiveCasts()
	if len(casts) != 1 || casts[0].Shape.Origin != (Vec3{X: 3_000}) {
		t.Fatalf("equidistant targets must tie-break to the lower ID (2 at x=3000), got %+v", casts)
	}
}

// TestZeroCastTicksIsClampedToADodgeableTick pins the minCastTicks floor: a
// zero cast time is clamped to one full tick, so a movement pass always runs
// between paint and resolution and no instant, undodgeable cast can exist.
func TestZeroCastTicksIsClampedToADodgeableTick(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 0, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})

	w.Step()
	casts := w.ActiveCasts()
	if len(casts) != 1 {
		t.Fatalf("want 1 active cast, got %d", len(casts))
	}
	if got := casts[0].ResolveTick - casts[0].StartTick; got != minCastTicks {
		t.Fatalf("zero cast time must clamp to %d tick(s), got %d", minCastTicks, got)
	}
	if hits := w.DrainHits(); len(hits) != 0 {
		t.Fatalf("nothing may resolve on the paint tick, got %+v", hits)
	}
	w.Step()
	if hits := w.DrainHits(); len(hits) != 1 {
		t.Fatalf("want the clamped cast resolved one tick after the paint, got %+v", hits)
	}
}

// TestCooldownCadence pins the recast law: cooldown runs from cast START, one
// cast in flight at a time, and resolution precedes decision so a mob may
// recast on the very tick its previous cast resolves.
func TestCooldownCadence(t *testing.T) {
	// Cooldown dominates: casts start at ticks 0, 10, 20; resolve at 2, 12, 22.
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 2, CooldownTicks: 10, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})
	steps(w, 23)
	var got []uint64
	for _, h := range w.DrainHits() {
		got = append(got, h.Tick)
	}
	if !slices.Equal(got, []uint64{2, 12, 22}) {
		t.Fatalf("cooldown-dominated cadence wrong: want resolutions at [2 12 22], got %v", got)
	}

	// Cast time dominates: recast lands the tick the previous cast resolves —
	// casts at 0, 5, 10; resolutions at 5, 10, 15.
	w2 := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 5, CooldownTicks: 1, CircleRadiusMM: 2_000})
	w2.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})
	steps(w2, 16)
	got = nil
	for _, h := range w2.DrainHits() {
		got = append(got, h.Tick)
	}
	if !slices.Equal(got, []uint64{5, 10, 15}) {
		t.Fatalf("cast-time-dominated cadence wrong: want resolutions at [5 10 15], got %v", got)
	}
}

func TestOutOfAggroRangeNeverCasts(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 3_000, CastTicks: 2, CooldownTicks: 1, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 5_000}, MaxSpeed: 0}) // 5000 > 3000: out of range
	steps(w, 30)
	if casts := w.ActiveCasts(); len(casts) != 0 {
		t.Fatalf("out-of-range target must never be aggroed, got casts %+v", casts)
	}
	if hits := w.DrainHits(); len(hits) != 0 {
		t.Fatalf("out-of-range target must never produce resolutions, got %+v", hits)
	}
}

// TestHugeAggroRadiusIsClampedNotBroken pins the ingestion clamp. Without it,
// squaring a near-max radius overflows negative and the comparison silently
// aggros NOTHING — the classic wrapped-overflow no-op. With the clamp the mob
// simply has the largest legal radius and works.
func TestHugeAggroRadiusIsClampedNotBroken(t *testing.T) {
	w := newCombatWorld(MobParams{AggroRadiusMM: 1 << 62, CastTicks: 2, CooldownTicks: 600, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 15_000}, MaxSpeed: 0})
	w.Step()
	if casts := w.ActiveCasts(); len(casts) != 1 {
		t.Fatalf("a clamped huge aggro radius must still aggro an in-range target, got %+v", casts)
	}
}

func TestHitLogBoundCountsDrops(t *testing.T) {
	// castTicks 1 + cooldown 0 resolves one cast per tick from tick 1 on.
	w := newCombatWorld(MobParams{AggroRadiusMM: 10_000, CastTicks: 1, CooldownTicks: 0, CircleRadiusMM: 2_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 1_000}, MaxSpeed: 0})
	const n = 1_300
	steps(w, n) // n-1 resolutions, never drained
	kept := w.DrainHits()
	if len(kept) != maxHitRecords {
		t.Fatalf("undrained log must cap at %d records, got %d", maxHitRecords, len(kept))
	}
	if want := uint64(n - 1 - maxHitRecords); w.DroppedHits() != want {
		t.Fatalf("want %d dropped resolutions counted, got %d", want, w.DroppedHits())
	}
}

// TestDeterminismAcrossInsertionOrder drives two identically-configured
// worlds whose entities and mobs were added in opposite orders through a
// full aggro→cast→dodge→resolve cycle: every tick's world hash and the
// entire hit stream must match exactly.
func TestDeterminismAcrossInsertionOrder(t *testing.T) {
	build := func(reverse bool) *World {
		w := NewWorld(combatBounds)
		ents := []Entity{
			{ID: 7, Pos: Vec3{X: -4_000, Z: 2_000}, MaxSpeed: 4_000, Radius: 300},
			{ID: 3, Pos: Vec3{X: 3_000, Z: -1_000}, MaxSpeed: 3_000, Radius: 300},
			{ID: 40, Pos: Vec3{}, MaxSpeed: 0, Radius: 300},
			{ID: 12, Pos: Vec3{X: 9_000, Z: 9_000}, MaxSpeed: 0, Radius: 300},
		}
		if reverse {
			slices.Reverse(ents)
		}
		for _, e := range ents {
			w.Add(e)
		}
		mobs := []EntityID{40, 12}
		if reverse {
			slices.Reverse(mobs)
		}
		for _, id := range mobs {
			w.AddMob(id, MobParams{AggroRadiusMM: 12_000, CastTicks: 15, CooldownTicks: 20, CircleRadiusMM: 2_500})
		}
		return w
	}
	a, b := build(false), build(true)
	var hitsA, hitsB []TelegraphHit
	for i := range 120 {
		for _, w := range []*World{a, b} {
			w.SetIntent(7, Vec3{X: int64(1_000 * (i%3 - 1))})
			w.SetIntent(3, Vec3{Z: int64(2_000 * (i%2*2 - 1))})
		}
		a.Step()
		b.Step()
		if a.Hash() != b.Hash() {
			t.Fatalf("world hash diverged at tick %d", i)
		}
		hitsA = append(hitsA, a.DrainHits()...)
		hitsB = append(hitsB, b.DrainHits()...)
	}
	if len(hitsA) == 0 {
		t.Fatal("determinism fixture produced no resolutions — the comparison would be vacuous")
	}
	if len(hitsA) != len(hitsB) {
		t.Fatalf("hit streams diverged: %d vs %d records", len(hitsA), len(hitsB))
	}
	for i := range hitsA {
		x, y := hitsA[i], hitsB[i]
		if x.Tick != y.Tick || x.Caster != y.Caster || !slices.Equal(x.Targets, y.Targets) {
			t.Fatalf("hit %d diverged: %+v vs %+v", i, x, y)
		}
	}
}

func TestAddMobPanicsOnUnknownEntity(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("AddMob for an entity that does not exist must panic")
		}
	}()
	NewWorld(combatBounds).AddMob(1, MobParams{})
}

func TestAddMobPanicsOnDuplicate(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1})
	w.AddMob(1, MobParams{})
	defer func() {
		if recover() == nil {
			t.Fatal("registering the same mob twice must panic")
		}
	}()
	w.AddMob(1, MobParams{})
}

func newChaseWorld(enabled bool) *World {
	w := NewWorld(combatBounds)
	w.MobChase = enabled
	w.Add(Entity{ID: 100, Pos: Vec3{}, MaxSpeed: 3_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 6_000}})
	w.AddMob(100, MobParams{
		AggroRadiusMM:  10_000,
		CastRangeMM:    2_000,
		ChaseSpeedMM:   3_000,
		CastTicks:      4,
		CooldownTicks:  600,
		CircleRadiusMM: 1_500,
	})
	return w
}

func TestMobChaseFlagGatesMovementAndCastRange(t *testing.T) {
	off := newChaseWorld(false)
	off.Step()
	if got := off.Get(100).Pos; got != (Vec3{}) {
		t.Fatalf("flag off moved the stationary caster to %+v", got)
	}
	if casts := off.ActiveCasts(); len(casts) != 1 || casts[0].Shape.Origin != (Vec3{X: 6_000}) {
		t.Fatalf("flag off must preserve the immediate stationary cast, got %+v", casts)
	}

	on := newChaseWorld(true)
	on.Step()
	if casts := on.ActiveCasts(); len(casts) != 0 {
		t.Fatalf("flag on cast from outside the configured range: %+v", casts)
	}
	if intent := on.Get(100).Intent; intent.X <= 0 || intent.Y != 0 || intent.Z != 0 {
		t.Fatalf("flag on did not author horizontal chase intent toward +X: %+v", intent)
	}

	for range 80 {
		if len(on.ActiveCasts()) != 0 {
			break
		}
		on.Step()
	}
	casts := on.ActiveCasts()
	if len(casts) != 1 {
		t.Fatalf("chaser never reached cast range, got position %+v and casts %+v", on.Get(100).Pos, casts)
	}
	mob := on.Get(100)
	if mob.Pos.X <= 0 || horizontalDist2(mob.Pos, on.Get(1).Pos) > 2_000*2_000 {
		t.Fatalf("chaser cast before closing to range: mob=%+v target=%+v", mob.Pos, on.Get(1).Pos)
	}
	if mob.Intent != (Vec3{}) {
		t.Fatalf("chaser must stop while its cast is in flight, intent %+v", mob.Intent)
	}
	castPos := mob.Pos
	on.Step()
	on.Step()
	if got := on.Get(100).Pos; got != castPos {
		t.Fatalf("chaser drifted during its in-flight cast: %+v -> %+v", castPos, got)
	}
}

func TestMobChaseClearsIntentAfterLosingTarget(t *testing.T) {
	w := newChaseWorld(true)
	w.Step()
	if w.Get(100).Intent == (Vec3{}) {
		t.Fatal("fixture never began chasing")
	}

	w.Get(1).Pos = Vec3{X: 15_000}
	w.Step() // one already-authored movement tick, then acquisition clears
	if got := w.Get(100).Intent; got != (Vec3{}) {
		t.Fatalf("losing every eligible target left stale AI intent %+v", got)
	}
	stoppedAt := w.Get(100).Pos
	w.Step()
	if got := w.Get(100).Pos; got != stoppedAt {
		t.Fatalf("mob kept walking after target loss: %+v -> %+v", stoppedAt, got)
	}
}

func TestMobChaseReachesZeroRangeWithoutTruncating(t *testing.T) {
	w := NewWorld(combatBounds)
	w.MobChase = true
	w.Add(Entity{ID: 100, MaxSpeed: 3_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 31}})
	w.AddMob(100, MobParams{
		AggroRadiusMM: 1_000,
		CastRangeMM:   0,
		ChaseSpeedMM:  3_000,
		CastTicks:     2,
	})

	steps(w, 100)
	if got := w.Get(100).Pos; got != (Vec3{X: 31}) {
		t.Fatalf("zero-range chaser stopped short after movement truncation: got %+v", got)
	}
	if casts := w.ActiveCasts(); len(casts) == 0 {
		t.Fatal("zero-range chaser never reached its target to cast")
	}
}

func TestMobChaseFlagDisableClearsAuthoredIntentBeforeMovement(t *testing.T) {
	w := newChaseWorld(true)
	w.Step()
	if w.Get(100).Intent == (Vec3{}) {
		t.Fatal("fixture never began chasing")
	}

	w.MobChase = false
	w.Step()
	if got := w.Get(100).Pos; got != (Vec3{}) {
		t.Fatalf("disabling chase allowed stale AI intent to move the mob: %+v", got)
	}
	if got := w.Get(100).Intent; got != (Vec3{}) {
		t.Fatalf("disabling chase left stale AI intent %+v", got)
	}
	if casts := w.ActiveCasts(); len(casts) != 1 || casts[0].Shape.Origin != (Vec3{X: 6_000}) {
		t.Fatalf("flag off must resume the stationary cast contract, got %+v", casts)
	}
}

func TestMobChaseParametersClampAtIngestion(t *testing.T) {
	w := NewWorld(combatBounds)
	w.MobChase = true
	w.Add(Entity{ID: 100, MaxSpeed: 3_000})
	w.Add(Entity{ID: 1, Pos: Vec3{X: 5_000}})
	w.AddMob(100, MobParams{
		AggroRadiusMM: 10_000,
		CastRangeMM:   1 << 62,
		ChaseSpeedMM:  1 << 62,
		CastTicks:     2,
	})
	st := w.mobs[100]
	if st.params.CastRangeMM != st.params.AggroRadiusMM {
		t.Fatalf("cast range must clamp to aggro range, got %d vs %d", st.params.CastRangeMM, st.params.AggroRadiusMM)
	}
	if st.params.ChaseSpeedMM != maxIntentComponentMM {
		t.Fatalf("chase speed must clamp to the safe intent bound, got %d", st.params.ChaseSpeedMM)
	}
}

func TestMobChaseIsDeterministicAcrossInsertionOrder(t *testing.T) {
	build := func(reverse bool) *World {
		w := NewWorld(combatBounds)
		w.MobChase = true
		ents := []Entity{
			{ID: 100, MaxSpeed: 4_000},
			{ID: 1, Pos: Vec3{X: 8_000}},
			{ID: 2, Pos: Vec3{X: -8_000}},
		}
		if reverse {
			slices.Reverse(ents)
		}
		for _, e := range ents {
			w.Add(e)
		}
		w.AddMob(100, MobParams{
			AggroRadiusMM:  10_000,
			CastRangeMM:    2_000,
			ChaseSpeedMM:   4_000,
			CastTicks:      3,
			CooldownTicks:  10,
			CircleRadiusMM: 1_000,
		})
		return w
	}

	a, b := build(false), build(true)
	sawCast := false
	for tick := range 100 {
		a.Step()
		b.Step()
		if a.Hash() != b.Hash() {
			t.Fatalf("insertion order changed chase state at tick %d: %#x vs %#x", tick, a.Hash(), b.Hash())
		}
		castsA, castsB := a.ActiveCasts(), b.ActiveCasts()
		if !slices.Equal(castsA, castsB) {
			t.Fatalf("insertion order changed active casts at tick %d: %+v vs %+v", tick, castsA, castsB)
		}
		sawCast = sawCast || len(castsA) > 0
	}
	if a.Get(100).Pos.X <= 0 {
		t.Fatalf("equal-distance acquisition did not deterministically chase lower ID 1: %+v", a.Get(100).Pos)
	}
	if !sawCast {
		t.Fatal("determinism fixture never reached a cast, so it only proved movement")
	}
}

// --- Golden combat stream ---------------------------------------------------

// combatGoldenTicks and combatGoldenHash pin the exact resolution stream a
// deterministic mob-vs-walkers scenario produces: one stationary caster, one
// walker orbiting a square, one walker that alternates approaching and
// standing. Because the stream derives only from integer positions in a
// stable order, the hash is identical on amd64 and arm64 — the combat layer's
// cross-platform determinism proof, exactly as the movement, AoI, snapshot
// and telegraph goldens prove theirs. Changing it is a deliberate, reviewed
// act.
const combatGoldenTicks = 600
const combatGoldenHash uint64 = 0x5e3f6d2d1c1fed28

// runCombatGolden drives the golden scenario and folds every resolution into
// an order-stable FNV-1a hash, returning the hash plus how many resolutions
// caught someone and how many caught no one (so the golden cannot vacuously
// pin a stream where either outcome never happens).
func runCombatGolden(n int) (digest uint64, caught, empty int) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 9, Pos: Vec3{}, MaxSpeed: 0, Radius: 300})
	w.Add(Entity{ID: 1, Pos: Vec3{X: -6_000, Z: -6_000}, MaxSpeed: 4_000, Radius: 300})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 6_000, Z: 6_000}, MaxSpeed: 3_500, Radius: 300})
	w.AddMob(9, MobParams{AggroRadiusMM: 15_000, CastTicks: 30, CooldownTicks: 45, CircleRadiusMM: 2_500})

	h := fnv.New64a()
	var buf [8]byte
	put := func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}

	// Walker 1 orbits a square (60 ticks per leg); walker 2 alternates 45
	// ticks of walking toward the mob with 45 ticks of standing still — the
	// standing halves are what let some casts connect.
	legs := []Vec3{{X: 4_000}, {Z: 4_000}, {X: -4_000}, {Z: -4_000}}
	for i := range n {
		w.SetIntent(1, legs[(i/60)%len(legs)])
		if (i/45)%2 == 0 {
			w.SetIntent(2, Vec3{X: -3_500, Z: -3_500})
		} else {
			w.SetIntent(2, Vec3{})
		}
		w.Step()
		for _, hit := range w.DrainHits() {
			put(hit.Tick)
			put(uint64(hit.Caster))
			put(uint64(len(hit.Targets)))
			for _, id := range hit.Targets {
				put(uint64(id))
			}
			if len(hit.Targets) > 0 {
				caught++
			} else {
				empty++
			}
		}
	}
	return h.Sum64(), caught, empty
}

func TestCombatGoldenStream(t *testing.T) {
	got, caught, empty := runCombatGolden(combatGoldenTicks)
	if caught == 0 {
		t.Fatal("golden scenario never caught anyone — the golden would be vacuous on the hit side")
	}
	if empty == 0 {
		t.Fatal("golden scenario never resolved empty — the golden would be vacuous on the dodge side")
	}
	if got != combatGoldenHash {
		t.Fatalf("combat golden stream diverged: got %#x want %#x (caught=%d empty=%d) — changing the golden is a deliberate, reviewed act", got, combatGoldenHash, caught, empty)
	}
}
