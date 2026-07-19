package sim

import (
	"math"
	"testing"
)

// The damage layer's contract, pinned test by test:
//
//   - health ingestion: poolless entities carry no health, pooled entities
//     never spawn dead or over-full;
//   - application: integer-only, clamped at ingestion, floored at zero, a
//     death observable exactly once, unknown and poolless targets skipped;
//   - the #9 criterion in miniature: one scripted encounter in which the
//     standing target dies and the moving target ends unharmed — with a
//     too-short wind-up as the negative control proving the unharmed half is
//     earned by escape distance, not handed out by the harness;
//   - a damaged-world golden over that scenario, with an application-ablated
//     twin proving the golden actually pins health (not just movement).

func TestHealthIngestion(t *testing.T) {
	cases := []struct {
		name           string
		spawn          Entity
		wantMax, wantH int64
	}{
		{"poolless drops health", Entity{ID: 1, Health: 50}, 0, 0},
		{"unset health spawns full", Entity{ID: 1, MaxHealth: 100}, 100, 100},
		{"wounded spawn is representable", Entity{ID: 1, MaxHealth: 100, Health: 40}, 100, 40},
		{"over-full clamps to full", Entity{ID: 1, MaxHealth: 100, Health: 150}, 100, 100},
		{"dead spawn is unrepresentable", Entity{ID: 1, MaxHealth: 100, Health: -5}, 100, 100},
		{"pool over bound clamps", Entity{ID: 1, MaxHealth: maxHealth + 1}, maxHealth, maxHealth},
		{"negative pool is poolless", Entity{ID: 1, MaxHealth: -1, Health: 3}, 0, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := NewWorld(combatBounds)
			e := w.Add(tc.spawn)
			if e.MaxHealth != tc.wantMax || e.Health != tc.wantH {
				t.Fatalf("stored MaxHealth/Health = %d/%d, want %d/%d",
					e.MaxHealth, e.Health, tc.wantMax, tc.wantH)
			}
		})
	}
}

func TestApplyDamageFloorsAtZeroAndDiesOnce(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1, MaxHealth: 100})

	if deaths := w.ApplyDamage([]EntityID{1}, 30); len(deaths) != 0 {
		t.Fatalf("a surviving hit must not emit deaths, got %v", deaths)
	}
	if got := w.Get(1).Health; got != 70 {
		t.Fatalf("health after one 30 hit = %d, want 70", got)
	}

	// The killing hit overshoots (70 left, 80 dealt): health floors at zero
	// and exactly one death fires, carrying the world's current tick.
	w.Tick = 42
	deaths := w.ApplyDamage([]EntityID{1}, 80)
	if len(deaths) != 1 || deaths[0] != (DeathEvent{Tick: 42, Entity: 1}) {
		t.Fatalf("killing hit: want exactly [{42 1}], got %v", deaths)
	}
	if got := w.Get(1).Health; got != 0 {
		t.Fatalf("health floors at zero, got %d", got)
	}

	// Hitting the dead again changes nothing and emits nothing — that skip is
	// what makes a death observable exactly once.
	if deaths := w.ApplyDamage([]EntityID{1}, 80); len(deaths) != 0 {
		t.Fatalf("damage on a dead entity must emit nothing, got %v", deaths)
	}
}

func TestApplyDamageSanitizesDamage(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1, MaxHealth: 100})

	// Negative damage is not healing: clamped to zero, a full no-op.
	if deaths := w.ApplyDamage([]EntityID{1}, -50); len(deaths) != 0 || w.Get(1).Health != 100 {
		t.Fatalf("negative damage must be a no-op, got health %d, deaths %v", w.Get(1).Health, deaths)
	}
	if deaths := w.ApplyDamage([]EntityID{1}, 0); len(deaths) != 0 || w.Get(1).Health != 100 {
		t.Fatalf("zero damage must be a no-op, got health %d, deaths %v", w.Get(1).Health, deaths)
	}
	// A pathological amount clamps to the bound and lands as an ordinary
	// lethal hit — no wrap-around, no panic.
	deaths := w.ApplyDamage([]EntityID{1}, math.MaxInt64)
	if len(deaths) != 1 || w.Get(1).Health != 0 {
		t.Fatalf("overflow-sized damage must clamp and kill once, got health %d, deaths %v", w.Get(1).Health, deaths)
	}
}

func TestApplyDamageSkipsPoollessAndUnknown(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1})                // poolless — cannot be damaged
	w.Add(Entity{ID: 2, MaxHealth: 10}) // pooled

	deaths := w.ApplyDamage([]EntityID{1, 99, 2}, 10)
	if len(deaths) != 1 || deaths[0].Entity != 2 {
		t.Fatalf("only the pooled entity may die, got %v", deaths)
	}
	if got := w.Get(1).Health; got != 0 {
		t.Fatalf("a poolless entity must stay untouched, got health %d", got)
	}
}

func TestApplyDamageDeathsFollowCallerOrder(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 2, MaxHealth: 5})
	w.Add(Entity{ID: 3, MaxHealth: 5})

	deaths := w.ApplyDamage([]EntityID{3, 2}, 5)
	if len(deaths) != 2 || deaths[0].Entity != 3 || deaths[1].Entity != 2 {
		t.Fatalf("deaths must follow the caller's target order, got %v", deaths)
	}
}

// damageScenarioParams is the shared encounter shape for the scenario and its
// golden: an escapable loop (a 10-tick wind-up covers 2 000 mm at the
// walker's 6 000 mm/s — comfortably past the 1 500 mm circle) plus a damage
// amount that kills the 25-point standing target on the third resolution.
func damageScenarioParams() MobParams {
	return MobParams{
		AggroRadiusMM:  5_000,
		CastTicks:      10,
		CooldownTicks:  5,
		CircleRadiusMM: 1_500,
		Damage:         10,
	}
}

// runDamageScenario drives the scripted encounter for n ticks: a stationary
// registered mob, a standing pooled target at the anchor, and a pooled walker
// who starts inside the circle and runs for the exit. Every drained hit is
// landed with ApplyDamage exactly as the future zone-loop wiring will —
// unless apply is false, the golden's ablated twin, which proves the hash
// pins application.
func runDamageScenario(p MobParams, n int, apply bool) (w *World, hits []TelegraphHit, deaths []DeathEvent) {
	w = NewWorld(combatBounds)
	w.Add(Entity{ID: 1})                                                      // the mob, pinned at the origin
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1_000}, MaxHealth: 25})                  // stands at the future anchor
	w.Add(Entity{ID: 3, Pos: Vec3{X: 1_500}, MaxSpeed: 6_000, MaxHealth: 25}) // starts inside the circle
	w.AddMob(1, p)
	w.SetIntent(3, Vec3{X: 6_000}) // the walker runs for the exit from tick one
	for range n {
		w.Step()
		for _, h := range w.DrainHits() {
			hits = append(hits, h)
			if apply {
				deaths = append(deaths, w.ApplyDamage(h.Targets, h.Damage)...)
			}
		}
	}
	return w, hits, deaths
}

// TestDamageScenarioStandingDiesMovingLives is the issue's success signal end
// to end: the same scripted encounter ends with the standing target dead and
// the moving target alive — and keeps running past the death to prove the
// corpse (still standing in every later circle) never dies twice.
func TestDamageScenarioStandingDiesMovingLives(t *testing.T) {
	w, hits, deaths := runDamageScenario(damageScenarioParams(), 80, true)

	if len(hits) < 4 {
		t.Fatalf("scenario too short to prove anything: %d resolutions", len(hits))
	}
	for _, h := range hits {
		for _, id := range h.Targets {
			if id == 3 {
				t.Fatalf("the walker must escape every cast, but was caught at tick %d", h.Tick)
			}
		}
	}
	if len(deaths) != 1 || deaths[0].Entity != 2 {
		t.Fatalf("want exactly one death, of the standing target, got %v", deaths)
	}
	// A hit records the step it resolved DURING; the death records the world
	// clock at application, one step later (see DeathEvent.Tick).
	if got := deaths[0].Tick; got != hits[2].Tick+1 {
		t.Fatalf("death must land applying the third resolution (25 hp / 10 dmg), tick %d, got %d", hits[2].Tick+1, got)
	}
	if got := w.Get(2).Health; got != 0 {
		t.Fatalf("standing target must end dead, health %d", got)
	}
	if got := w.Get(3).Health; got != 25 {
		t.Fatalf("moving target must end unharmed, health %d", got)
	}
}

// TestDamageScenarioEscapeIsEarned is the negative control: the identical
// encounter under a wind-up too short to cover the walker's exit distance
// must cost the walker health. This proves the unharmed walker above is
// earned by distance over the window — the harness demonstrably damages
// walkers who fail to escape.
func TestDamageScenarioEscapeIsEarned(t *testing.T) {
	p := damageScenarioParams()
	p.CastTicks = 2 // 2 ticks * 200 mm cannot clear the 1 500 mm circle from 500 mm in
	w, _, _ := runDamageScenario(p, 10, true)
	if got := w.Get(3).Health; got >= 25 {
		t.Fatalf("under a too-short wind-up the walker must lose health, still at %d", got)
	}
}

// --- Damaged-world golden ----------------------------------------------------

// damageGoldenTicks and damageGoldenHash pin the world state — positions AND
// health — the scripted damage scenario ends in. The pre-health goldens prove
// damage-free worlds are untouched (they run unchanged in this suite); this
// one pins the damaged half. Changing it is a deliberate, reviewed act.
// (The value survived the #207 engine convergence unchanged: the hash pins
// the FINAL state, and both engines end the same encounter in the same state
// — standing target dead, walker unharmed, identical positions and tick.)
const damageGoldenTicks = 80
const damageGoldenHash uint64 = 0x9ff5c8c5edc81a09

func TestDamagedWorldGolden(t *testing.T) {
	w, _, deaths := runDamageScenario(damageScenarioParams(), damageGoldenTicks, true)
	if len(deaths) == 0 {
		t.Fatal("the golden scenario must contain a death — the golden would be vacuous")
	}
	if got := w.Hash(); got != damageGoldenHash {
		t.Fatalf("damaged-world hash after %d ticks = %#016x, want %#016x\n"+
			"if this change to damage behaviour is intentional, update damageGoldenHash",
			damageGoldenTicks, got, damageGoldenHash)
	}

	// Determinism: an identical run lands on the identical state.
	w2, _, _ := runDamageScenario(damageScenarioParams(), damageGoldenTicks, true)
	if got := w2.Hash(); got != damageGoldenHash {
		t.Fatalf("two identical runs hashed differently: %#016x != %#016x", got, damageGoldenHash)
	}

	// The ablated twin — same encounter, application skipped — must hash
	// differently: health is genuinely part of the hashed state, and the
	// golden pins the application, not just the movement underneath it.
	w3, _, _ := runDamageScenario(damageScenarioParams(), damageGoldenTicks, false)
	if got := w3.Hash(); got == damageGoldenHash {
		t.Fatal("skipping damage application left the golden hash unchanged — the golden is blind to health")
	}
}
