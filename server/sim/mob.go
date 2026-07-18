package sim

import "fmt"

// The mob combat core: the smallest server-side actor that makes the game's
// central combat promise — "step out of the circle" — real. Phase 1's exit
// criteria demand one mob that casts a circle you must step out of (#8), and
// Phase 2 demands the aggro basics under it (#9); this file is that mob's
// brain. It is a controller in the InterestTracker / SnapshotTracker mould:
// the zone loop steps it once per tick AFTER World.Step, it reads the world
// and emits events, and it never mutates world state — so every settled
// movement/AoI/snapshot golden is unchanged by construction, and a test pins
// that read-only contract so a future chase-movement change must break it
// consciously.
//
// Deliberate limits of this first slice (each a named follow-up on #188):
//   - No damage or health exist yet, so a resolve reports who was caught and
//     nothing more; applying the hit is the next child.
//   - The mob does not move. Chase and leash need navmesh-aware movement.
//   - Target eligibility is "any other entity". That is correct for the
//     vertical slice's single mob, but two controllers would aggro each
//     other — factions/eligibility are a later child.
//   - There is no interruption: once cast, the telegraph resolves at its
//     anchor. The World cannot remove entities yet, so despawn-mid-cast
//     semantics do not arise; when removal exists, interruption is decided
//     then, deliberately.

// MobPhase is the controller's current state. The machine is Idle → Casting →
// Cooldown → Idle, with exactly one transition per Step so the timeline is
// trivially deterministic.
type MobPhase uint8

const (
	// MobIdle scans for a target every step.
	MobIdle MobPhase = iota
	// MobCasting counts down the telegraph wind-up.
	MobCasting
	// MobCooldown counts down the recovery gap before the next acquisition.
	MobCooldown
)

// MobEventKind labels a MobEvent. Events are the controller's only output —
// the seam the future damage, replication, and presentation children consume.
type MobEventKind uint8

const (
	// MobAggro fires when an idle mob acquires a target.
	MobAggro MobEventKind = iota
	// MobCastStart fires when the wind-up begins; its Anchor is the telegraph
	// centre, snapshotted from the target's position at this instant. The
	// circle is ground-anchored from here on — it does not track the target.
	// That snapshot is what makes the attack escapable, and escapability is a
	// product law (telegraphs must be dodgeable by moving well).
	MobCastStart
	// MobResolve fires when the wind-up ends; Caught lists who stood inside.
	MobResolve
)

// MobEvent is one observable step of the mob's combat loop.
type MobEvent struct {
	Kind MobEventKind
	// Tick is the world tick whose step this event followed (World.Tick at
	// emission, i.e. after World.Step incremented it).
	Tick uint64
	// Target is the acquired entity on MobAggro and MobCastStart; zero on
	// MobResolve, which judges the anchor, not the target.
	Target EntityID
	// Anchor is the telegraph centre on MobCastStart and MobResolve.
	Anchor Vec3
	// Caught lists, on MobResolve only, every entity inside the circle at
	// resolution, ascending by ID, excluding the casting mob itself — caster
	// filtering is this layer's job (World.Caught is pure geometry and tests
	// everyone).
	Caught []EntityID
}

// MobConfig sizes one mob's combat loop. All fields are validated once at
// construction — sanitize at ingestion, so the per-tick path never re-checks.
type MobConfig struct {
	// AggroRadiusMM is the horizontal (ground-plane) distance within which an
	// idle mob acquires a target, inclusive of the boundary — the same
	// inclusive-edge convention every telegraph shape follows. Bounded to
	// maxInterestRadiusMM so the squared comparison can never overflow.
	AggroRadiusMM int64
	// TelegraphRadiusMM is the cast circle's radius in mm, bounded like every
	// telegraph extent.
	TelegraphRadiusMM int64
	// CastTicks is the wind-up length in ticks, at least 1. A zero wind-up
	// would resolve the instant it was cast — an undodgeable telegraph, which
	// the readability law forbids. How *generous* the window is remains a
	// reviewed balance decision (#153's lesson), not a library constraint.
	CastTicks uint64
	// CooldownTicks is the recovery gap after a resolve before the mob may
	// acquire again. Zero is legal: recovery ends immediately and the mob
	// re-acquires on the next step.
	CooldownTicks uint64
}

func (c MobConfig) validate() error {
	if c.AggroRadiusMM <= 0 {
		return fmt.Errorf("sim: mob aggro radius %d mm must be positive", c.AggroRadiusMM)
	}
	if c.AggroRadiusMM > maxInterestRadiusMM {
		return fmt.Errorf("sim: mob aggro radius %d mm exceeds the maximum %d", c.AggroRadiusMM, int64(maxInterestRadiusMM))
	}
	if c.TelegraphRadiusMM <= 0 {
		return fmt.Errorf("sim: mob telegraph radius %d mm must be positive", c.TelegraphRadiusMM)
	}
	if c.TelegraphRadiusMM > maxTelegraphExtentMM {
		return fmt.Errorf("sim: mob telegraph radius %d mm exceeds the maximum %d", c.TelegraphRadiusMM, int64(maxTelegraphExtentMM))
	}
	if c.CastTicks == 0 {
		return fmt.Errorf("sim: mob cast wind-up must be at least 1 tick — an instant telegraph cannot be dodged")
	}
	return nil
}

// MobController runs one mob's aggro → cast → resolve loop against a World it
// only reads. Build it with NewMobController; the zero value refuses to step.
type MobController struct {
	id  EntityID
	cfg MobConfig

	phase     MobPhase
	target    EntityID
	anchor    Vec3
	ticksLeft uint64
}

// NewMobController validates cfg and returns a controller for the entity with
// the given ID. The entity need not exist yet — spawn order is the caller's —
// but stepping the controller while it is absent panics (see Step).
func NewMobController(id EntityID, cfg MobConfig) (*MobController, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &MobController{id: id, cfg: cfg}, nil
}

// Phase reports the controller's current state.
func (m *MobController) Phase() MobPhase { return m.phase }

// Step advances the combat loop by one tick and returns the events it fired,
// oldest first (nil when nothing happened). Call it once per tick, after
// World.Step, like the tracker Update methods. It reads w and never mutates
// it. It panics if the controller was not built by NewMobController or if the
// mob's entity is not in the world: the caller owns mob lifecycle, and a
// controller for an absent mob must be dropped, not stepped — silently idling
// would hide the bug.
func (m *MobController) Step(w *World) []MobEvent {
	if m.cfg.CastTicks == 0 {
		panic("sim: mob controller was not built by NewMobController")
	}
	me := w.Get(m.id)
	if me == nil {
		panic("sim: mob controller stepped for an entity not in the world")
	}

	switch m.phase {
	case MobIdle:
		target, ok := m.acquire(w, me.Pos)
		if !ok {
			return nil
		}
		m.phase = MobCasting
		m.target = target
		m.anchor = w.Get(target).Pos
		m.ticksLeft = m.cfg.CastTicks
		return []MobEvent{
			{Kind: MobAggro, Tick: w.Tick, Target: target},
			{Kind: MobCastStart, Tick: w.Tick, Target: target, Anchor: m.anchor},
		}

	case MobCasting:
		m.ticksLeft--
		if m.ticksLeft > 0 {
			return nil
		}
		caught := w.Caught(CircleTelegraph(m.anchor, m.cfg.TelegraphRadiusMM))
		// Exclude the caster: a mob is not "hit" by standing in its own
		// circle. World.Caught returns ascending IDs, and removing one
		// element preserves that order.
		for i, id := range caught {
			if id == m.id {
				caught = append(caught[:i], caught[i+1:]...)
				break
			}
		}
		ev := MobEvent{Kind: MobResolve, Tick: w.Tick, Anchor: m.anchor, Caught: caught}
		m.target = 0
		if m.cfg.CooldownTicks == 0 {
			m.phase = MobIdle
		} else {
			m.phase = MobCooldown
			m.ticksLeft = m.cfg.CooldownTicks
		}
		return []MobEvent{ev}

	case MobCooldown:
		m.ticksLeft--
		if m.ticksLeft == 0 {
			m.phase = MobIdle
		}
		return nil
	}
	panic(fmt.Sprintf("sim: mob controller in impossible phase %d", m.phase))
}

// acquire returns the nearest other entity within the aggro radius,
// horizontal-inclusive, ties broken by lowest EntityID. Iterating w.order
// (ascending) with a strict improvement test yields that tie-break for free
// and keeps acquisition independent of map iteration order — the same
// determinism requirement every other pass upholds.
func (m *MobController) acquire(w *World, from Vec3) (EntityID, bool) {
	r2 := m.cfg.AggroRadiusMM * m.cfg.AggroRadiusMM
	var best EntityID
	bestD2 := int64(-1)
	for _, id := range w.order {
		if id == m.id {
			continue
		}
		d2 := horizontalDist2(from, w.ents[id].Pos)
		if d2 > r2 {
			continue
		}
		if bestD2 < 0 || d2 < bestD2 {
			best, bestD2 = id, d2
		}
	}
	return best, bestD2 >= 0
}
