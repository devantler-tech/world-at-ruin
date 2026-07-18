package sim

import (
	"encoding/binary"
	"hash/fnv"
	"strings"
	"testing"
)

// The mob combat core's contract, pinned test by test:
//
//   - losable by standing still, winnable by moving well (#9's exit criterion
//     in miniature), with a too-short wind-up as the negative control proving
//     the escape test can fail;
//   - ground-anchored snapshot-at-cast (the circle judges the anchor, never
//     tracks the target);
//   - deterministic acquisition (nearest wins over ID order, lowest ID breaks
//     ties, inclusive radius edge);
//   - caster exclusion, cooldown gating, loud failure on misuse;
//   - an event-stream golden over a scripted scenario, and proof the
//     controller never moves the movement golden (read-only contract).

// mobTestBounds is a flat plane large enough that no scripted position ever
// hits the clamp.
var mobTestBounds = Bounds{
	Min: Vec3{X: -100_000, Y: 0, Z: -100_000},
	Max: Vec3{X: 100_000, Y: 0, Z: 100_000},
}

// mobTestConfig is the shared loop shape: aggro at 5 m, a 1.5 m circle, a
// 10-tick wind-up, a 5-tick recovery. At the players' 6 000 mm/s (200 mm/tick)
// a full wind-up covers 2 000 mm — comfortably past the circle's edge, so the
// attack is escapable by design, and shrinking the wind-up below the edge
// distance (see the negative control) makes it inescapable.
func mobTestConfig() MobConfig {
	return MobConfig{
		AggroRadiusMM:     5_000,
		TelegraphRadiusMM: 1_500,
		CastTicks:         10,
		CooldownTicks:     5,
	}
}

// newMobWorld builds a world holding the mob (stationary point capsule) plus
// the given players, and a controller for it. Point capsules keep the
// separation pass inert so every scripted position stays exact.
func newMobWorld(t *testing.T, cfg MobConfig, players ...Entity) (*World, *MobController) {
	t.Helper()
	w := NewWorld(mobTestBounds)
	w.Add(Entity{ID: 1})
	for _, p := range players {
		w.Add(p)
	}
	m, err := NewMobController(1, cfg)
	if err != nil {
		t.Fatalf("NewMobController: %v", err)
	}
	return w, m
}

// stepFor drives n ticks and returns every event fired, tagged with its tick.
func stepFor(w *World, m *MobController, n int) []MobEvent {
	var out []MobEvent
	for range n {
		w.Step()
		out = append(out, m.Step(w)...)
	}
	return out
}

func eventsOfKind(events []MobEvent, kind MobEventKind) []MobEvent {
	var out []MobEvent
	for _, e := range events {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

func TestMobConfigValidation(t *testing.T) {
	valid := mobTestConfig()
	if _, err := NewMobController(1, valid); err != nil {
		t.Fatalf("valid config refused: %v", err)
	}
	cases := []struct {
		name   string
		mutate func(*MobConfig)
		want   string
	}{
		{"zero aggro radius", func(c *MobConfig) { c.AggroRadiusMM = 0 }, "aggro radius"},
		{"negative aggro radius", func(c *MobConfig) { c.AggroRadiusMM = -1 }, "aggro radius"},
		{"aggro radius over bound", func(c *MobConfig) { c.AggroRadiusMM = maxInterestRadiusMM + 1 }, "exceeds"},
		{"zero telegraph radius", func(c *MobConfig) { c.TelegraphRadiusMM = 0 }, "telegraph radius"},
		{"negative telegraph radius", func(c *MobConfig) { c.TelegraphRadiusMM = -1 }, "telegraph radius"},
		{"telegraph radius over bound", func(c *MobConfig) { c.TelegraphRadiusMM = maxTelegraphExtentMM + 1 }, "exceeds"},
		{"zero cast ticks", func(c *MobConfig) { c.CastTicks = 0 }, "cannot be dodged"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := valid
			tc.mutate(&cfg)
			_, err := NewMobController(1, cfg)
			if err == nil {
				t.Fatal("degenerate config accepted")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

// TestMobStandStillIsCaught pins the losing half of the exit criterion: a
// target that does not move stands at the anchor and is caught.
func TestMobStandStillIsCaught(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(), Entity{ID: 2, Pos: Vec3{X: 3_000}, MaxSpeed: 6_000})
	events := stepFor(w, m, 12)
	resolves := eventsOfKind(events, MobResolve)
	if len(resolves) != 1 {
		t.Fatalf("want exactly 1 resolve, got %d (events: %v)", len(resolves), events)
	}
	if got := resolves[0].Caught; len(got) != 1 || got[0] != 2 {
		t.Fatalf("standing target must be caught: got %v", got)
	}
}

// TestMobStepOutEscapes pins the winning half: moving away for the whole
// wind-up clears the circle's edge.
func TestMobStepOutEscapes(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(), Entity{ID: 2, Pos: Vec3{X: 3_000}, MaxSpeed: 6_000})
	w.Step()
	if got := eventsOfKind(m.Step(w), MobCastStart); len(got) != 1 {
		t.Fatalf("want the cast to start on the first step, got %v", got)
	}
	// React to the wind-up: run away along +X at full speed.
	w.SetIntent(2, Vec3{X: 6_000})
	events := stepFor(w, m, 11)
	resolves := eventsOfKind(events, MobResolve)
	if len(resolves) != 1 {
		t.Fatalf("want exactly 1 resolve, got %d", len(resolves))
	}
	if got := resolves[0].Caught; len(got) != 0 {
		t.Fatalf("a target that ran the full wind-up must escape: caught %v", got)
	}
}

// TestMobEscapeNeedsTheWindow is the negative control for the escape test: the
// identical run under a wind-up too short to cover the circle's edge distance
// ends in a catch. This proves the escape above is earned by distance over the
// window, not handed out by the harness.
func TestMobEscapeNeedsTheWindow(t *testing.T) {
	cfg := mobTestConfig()
	cfg.CastTicks = 5 // 5 ticks * 200 mm = 1 000 mm, inside the 1 500 mm circle
	w, m := newMobWorld(t, cfg, Entity{ID: 2, Pos: Vec3{X: 3_000}, MaxSpeed: 6_000})
	w.Step()
	m.Step(w)
	w.SetIntent(2, Vec3{X: 6_000})
	events := stepFor(w, m, 6)
	resolves := eventsOfKind(events, MobResolve)
	if len(resolves) != 1 {
		t.Fatalf("want exactly 1 resolve, got %d", len(resolves))
	}
	if got := resolves[0].Caught; len(got) != 1 || got[0] != 2 {
		t.Fatalf("under a too-short wind-up the same run must end in a catch, got %v", got)
	}
}

// TestMobAnchorDoesNotTrack pins snapshot-at-cast from both sides: the target
// that leaves the anchor escapes, and a bystander who walks onto it is caught.
func TestMobAnchorDoesNotTrack(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(),
		Entity{ID: 2, Pos: Vec3{X: 3_000}, MaxSpeed: 6_000},
		Entity{ID: 3, Pos: Vec3{X: 3_000, Z: 4_000}, MaxSpeed: 12_000},
	)
	w.Step()
	casts := eventsOfKind(m.Step(w), MobCastStart)
	if len(casts) != 1 || casts[0].Target != 2 {
		t.Fatalf("want the nearer entity 2 acquired, got %v", casts)
	}
	if casts[0].Anchor != (Vec3{X: 3_000}) {
		t.Fatalf("anchor must snapshot the target's position at cast start, got %v", casts[0].Anchor)
	}
	// The target flees; the bystander walks exactly onto the anchor.
	w.SetIntent(2, Vec3{X: 6_000})
	w.SetIntent(3, Vec3{Z: -12_000})
	events := stepFor(w, m, 11)
	resolves := eventsOfKind(events, MobResolve)
	if len(resolves) != 1 {
		t.Fatalf("want exactly 1 resolve, got %d", len(resolves))
	}
	if got := resolves[0].Caught; len(got) != 1 || got[0] != 3 {
		t.Fatalf("the circle judges the anchor: want the bystander [3], got %v", got)
	}
}

// TestMobAggroNearestWins pins distance-first acquisition: the nearer entity
// wins even when a lower ID sits farther away.
func TestMobAggroNearestWins(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(),
		Entity{ID: 2, Pos: Vec3{X: 4_000}},
		Entity{ID: 3, Pos: Vec3{X: -2_000}},
	)
	w.Step()
	aggros := eventsOfKind(m.Step(w), MobAggro)
	if len(aggros) != 1 || aggros[0].Target != 3 {
		t.Fatalf("want the nearer entity 3 acquired over the lower ID, got %v", aggros)
	}
}

// TestMobAggroTieBreaksByLowestID pins the tie-break: exactly equidistant
// candidates resolve to the lowest EntityID, independent of map order.
func TestMobAggroTieBreaksByLowestID(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(),
		Entity{ID: 3, Pos: Vec3{X: -3_000}},
		Entity{ID: 2, Pos: Vec3{X: 3_000}},
	)
	w.Step()
	aggros := eventsOfKind(m.Step(w), MobAggro)
	if len(aggros) != 1 || aggros[0].Target != 2 {
		t.Fatalf("want the equidistant tie broken to ID 2, got %v", aggros)
	}
}

// TestMobAggroEdgeInclusive pins the boundary convention: exactly on the
// radius aggros (the same inclusive edge every telegraph shape uses), one
// millimetre beyond does not.
func TestMobAggroEdgeInclusive(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(), Entity{ID: 2, Pos: Vec3{X: 5_000}})
	w.Step()
	if got := eventsOfKind(m.Step(w), MobAggro); len(got) != 1 {
		t.Fatalf("a target exactly on the aggro radius must be acquired, got %v", got)
	}

	w2, m2 := newMobWorld(t, mobTestConfig(), Entity{ID: 2, Pos: Vec3{X: 5_001}})
	if events := stepFor(w2, m2, 5); len(events) != 0 {
		t.Fatalf("a target one mm beyond the radius must not be acquired, got %v", events)
	}
}

// TestMobResolveExcludesSelf pins caster filtering: a mob standing inside its
// own circle is not among the caught, while everyone else inside is.
func TestMobResolveExcludesSelf(t *testing.T) {
	w, m := newMobWorld(t, mobTestConfig(),
		Entity{ID: 2, Pos: Vec3{X: 1_000}},
		Entity{ID: 3, Pos: Vec3{X: 2_000}},
	)
	events := stepFor(w, m, 12)
	resolves := eventsOfKind(events, MobResolve)
	if len(resolves) != 1 {
		t.Fatalf("want exactly 1 resolve, got %d", len(resolves))
	}
	// Anchor (1000,0,0), radius 1500: the mob at the origin and both players
	// are inside the circle geometrically; only the mob is filtered out.
	if got := resolves[0].Caught; len(got) != 2 || got[0] != 2 || got[1] != 3 {
		t.Fatalf("want [2 3] caught with the caster excluded, got %v", got)
	}
}

// TestMobCooldownGates pins recovery: no acquisition during cooldown, then a
// fresh cast right after it ends.
func TestMobCooldownGates(t *testing.T) {
	cfg := mobTestConfig()
	cfg.CastTicks = 2
	cfg.CooldownTicks = 3
	w, m := newMobWorld(t, cfg, Entity{ID: 2, Pos: Vec3{X: 1_000}})

	// Tick 1: aggro+cast. Ticks 2-3: wind-up, resolve on 3.
	events := stepFor(w, m, 3)
	if n := len(eventsOfKind(events, MobResolve)); n != 1 {
		t.Fatalf("want the first resolve by tick 3, got %d", n)
	}
	// Ticks 4-6: cooldown — the standing target must not be re-acquired.
	if events := stepFor(w, m, 3); len(events) != 0 {
		t.Fatalf("cooldown must gate re-acquisition, got %v", events)
	}
	// Tick 7: recovered — a fresh aggro fires.
	if got := eventsOfKind(stepFor(w, m, 1), MobAggro); len(got) != 1 {
		t.Fatalf("want re-aggro on the first tick after cooldown, got %v", got)
	}
}

// TestMobZeroCooldownReacquiresNextTick pins the zero-cooldown carve-out:
// recovery ends immediately and acquisition happens on the following step.
func TestMobZeroCooldownReacquiresNextTick(t *testing.T) {
	cfg := mobTestConfig()
	cfg.CastTicks = 2
	cfg.CooldownTicks = 0
	w, m := newMobWorld(t, cfg, Entity{ID: 2, Pos: Vec3{X: 1_000}})
	events := stepFor(w, m, 3) // aggro+cast, wind-up, resolve
	if n := len(eventsOfKind(events, MobResolve)); n != 1 {
		t.Fatalf("want the first resolve by tick 3, got %d", n)
	}
	if got := eventsOfKind(stepFor(w, m, 1), MobAggro); len(got) != 1 {
		t.Fatalf("zero cooldown must re-acquire on the very next step, got %v", got)
	}
}

// TestMobStepPanicsLoudly pins the misuse contract: a zero-value controller
// and a controller whose entity is absent both refuse to run silently.
func TestMobStepPanicsLoudly(t *testing.T) {
	w := NewWorld(mobTestBounds)
	w.Add(Entity{ID: 1})

	t.Run("zero-value controller", func(t *testing.T) {
		defer func() {
			if recover() == nil {
				t.Fatal("stepping a zero-value controller must panic")
			}
		}()
		var m MobController
		m.Step(w)
	})

	t.Run("entity not in world", func(t *testing.T) {
		m, err := NewMobController(99, mobTestConfig())
		if err != nil {
			t.Fatalf("NewMobController: %v", err)
		}
		defer func() {
			if recover() == nil {
				t.Fatal("stepping a controller for an absent entity must panic")
			}
		}()
		m.Step(w)
	})
}

// --- Golden mob event log ---------------------------------------------------

// mobGoldenTicks and mobGoldenHash pin the exact event stream a scripted
// three-actor scenario produces: an approach that aggros on the inclusive
// edge, a walk-through escape, a mid-wind-up stop that ends in a catch, and an
// immediate re-acquisition catch. The stream derives only from integer
// positions in a stable order, so the hash is identical on amd64 and arm64 —
// the same cross-platform determinism claim the movement and AoI goldens make.
// Changing it is a deliberate, reviewed act.
const mobGoldenTicks = 60
const mobGoldenHash uint64 = 0x58cb4b4955bdb723

// runMobGoldenScenario drives the scripted scenario and folds the event stream
// into an order-stable FNV-1a hash. It also reports how many resolves ended
// empty (escapes) and non-empty (catches), so the golden cannot vacuously pin
// a stream in which the interesting halves never happened.
func runMobGoldenScenario(n int) (hash uint64, escapes, catches int) {
	w := NewWorld(mobTestBounds)
	w.Add(Entity{ID: 1})                                         // the mob, pinned at the origin
	w.Add(Entity{ID: 2, Pos: Vec3{X: 8_000}, MaxSpeed: 6_000})   // the walker
	w.Add(Entity{ID: 3, Pos: Vec3{Z: 20_000}, MaxSpeed: 12_000}) // a distant bystander
	m, err := NewMobController(1, mobTestConfig())
	if err != nil {
		panic(err)
	}

	h := fnv.New64a()
	var buf [8]byte
	put := func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}

	w.SetIntent(2, Vec3{X: -6_000}) // walk toward and through the mob
	for i := 1; i <= n; i++ {
		if i == 36 {
			w.SetIntent(2, Vec3{}) // freeze mid-wind-up: this cast must catch
		}
		w.Step()
		for _, e := range m.Step(w) {
			put(uint64(e.Kind))
			put(e.Tick)
			put(uint64(e.Target))
			put(uint64(e.Anchor.X))
			put(uint64(e.Anchor.Y))
			put(uint64(e.Anchor.Z))
			put(uint64(len(e.Caught)))
			for _, id := range e.Caught {
				put(uint64(id))
			}
			if e.Kind == MobResolve {
				if len(e.Caught) == 0 {
					escapes++
				} else {
					catches++
				}
			}
		}
	}
	return h.Sum64(), escapes, catches
}

func TestMobGoldenEventLog(t *testing.T) {
	got, escapes, catches := runMobGoldenScenario(mobGoldenTicks)
	if escapes == 0 || catches == 0 {
		t.Fatalf("golden scenario must contain both an escape and a catch (got %d escapes, %d catches) — the golden would be vacuous", escapes, catches)
	}
	if got != mobGoldenHash {
		t.Fatalf("mob event-log hash after %d ticks = %#016x (%d escapes, %d catches), want %#016x\n"+
			"if this change to mob behaviour is intentional, update mobGoldenHash",
			mobGoldenTicks, got, escapes, catches, mobGoldenHash)
	}
}

// TestMobGoldenScenarioIsDeterministic runs the scripted scenario twice and
// demands identical streams — no hidden state, no map-order leakage.
func TestMobGoldenScenarioIsDeterministic(t *testing.T) {
	a, _, _ := runMobGoldenScenario(mobGoldenTicks)
	b, _, _ := runMobGoldenScenario(mobGoldenTicks)
	if a != b {
		t.Fatalf("two identical runs hashed differently: %#016x != %#016x", a, b)
	}
}

// TestMovementGoldenUnaffectedByMob proves the controller is a read-only
// query: stepping a mob controller over the demo scenario must not move the
// movement golden, because the controller never mutates world state. A future
// chase-movement change must break this test consciously, with a new golden.
func TestMovementGoldenUnaffectedByMob(t *testing.T) {
	w := NewDemoWorld()
	m, err := NewMobController(demoActors[0].id, mobTestConfig())
	if err != nil {
		t.Fatalf("NewMobController: %v", err)
	}
	for range demoGoldenTicks {
		DriveDemoTick(w)
		w.Step()
		m.Step(w)
	}
	if got := w.Hash(); got != demoGoldenHash {
		t.Fatalf("stepping a mob controller moved the movement golden: %#016x != %#016x", got, demoGoldenHash)
	}
}
