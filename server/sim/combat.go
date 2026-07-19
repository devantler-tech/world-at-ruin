package sim

// Combat: the telegraph CAST LIFECYCLE and the game's ONE mob AI — a
// stationary caster that aggros the nearest entity in range and casts a
// circle you must step out of (#189; the Phase 1 exit criterion's mob half,
// and the first of Phase 2's "threat, aggro, mob AI" work items). This file
// is the single mob-AI implementation by decision (#207): a parallel
// controller-shaped twin (`MobController`, #190) briefly coexisted and was
// converged into this layer — the integrated engine won on the one-tick-loop
// design rule, the ActiveCasts replication seam, multi-mob support, and
// non-mob target eligibility; its damage carriage (#195) was ported here as
// MobParams.Damage / TelegraphHit.Damage.
//
// telegraph.go answers "who is standing in this shape RIGHT NOW"; this file
// adds time: a cast paints its shape at cast start and resolves it once, a
// fixed number of ticks later, against where everyone is standing AT
// RESOLUTION (the settled snapshot-at-resolution semantics, #9). The gap
// between paint and resolution is the dodge: the mark is public from the tick
// it is painted, so a player who moves is not where the circle was cast at.
//
// Like every sim system this layer is deterministic and integer-only: cast
// times and cooldowns are measured in ticks, never wall-clock; mobs decide in
// ascending-ID order; targets are recorded in ascending-ID order; nothing
// iterates a Go map. It is opt-in by construction — a world with no mobs and
// no casts takes a single early return and behaves byte-identically to one
// built before this file existed, so every shipped golden is unchanged.
//
// Deliberately absent (later children of #9/#4): threat from damage,
// chase/movement AI (this slice's mobs never set intent), and replication of
// casts to clients (needs a wire schema bump once the v1 client decoder
// lands). This layer still only RECORDS outcomes: a resolution carries its
// caster's configured damage, and the zone loop lands each drained hit with
// one explicit World.ApplyDamage(hit.Targets, hit.Damage) call (damage.go) —
// application stays caller-owned ordering, never a hidden phase of Step.
// Acquisition remains health-blind, so a mob keeps casting at a dead target
// until the eligibility child teaches it better.

import "sort"

// minCastTicks floors a cast time at one tick. The floor is the dodge
// guarantee: at least one movement pass always runs between the paint and the
// resolution, so no configuration can create an undodgeable instant cast.
const minCastTicks = 1

// maxCastTicks caps a cast at 30 seconds of ticks — far beyond any real
// ability, tight enough that a miswritten parameter cannot park a cast
// effectively forever.
const maxCastTicks = 30 * TickHz

// maxCooldownTicks caps a recast gap at 10 minutes of ticks, the same hygiene
// bound as maxCastTicks: generous for real design, hostile to garbage.
const maxCooldownTicks = 600 * TickHz

// maxHitRecords bounds the pending hit log. The log is meant to be drained
// every tick by the consumer (replication, tests); the bound is the safety
// net for a consumer that stops draining, so an unattended zone cannot grow
// memory without limit. Overflow is never silent: dropped resolutions are
// counted on DroppedHits.
const maxHitRecords = 1024

// MobParams configures a registered mob. Every field is untrusted-at-the-edge
// in the same sense as spawn data: AddMob clamps each into its documented
// bound, so no parameter can overflow the integer math downstream.
type MobParams struct {
	// AggroRadiusMM is how far the mob looks for a target, on the ground
	// plane. Clamped into [0, maxInterestRadiusMM] — the same bound AoI uses,
	// for the same reason: the squared-distance comparison must not overflow.
	// Zero aggros nothing.
	AggroRadiusMM int64

	// CastTicks is how many ticks pass between painting the circle and
	// resolving it — the dodge window. Clamped into
	// [minCastTicks, maxCastTicks].
	CastTicks uint64

	// CooldownTicks is the minimum number of ticks between one cast STARTING
	// and the next. A cooldown shorter than the cast time never overlaps
	// casts — a mob has at most one cast in flight, and the resolve phase
	// runs before the decide phase, so the earliest recast is the tick the
	// previous cast resolves. Clamped into [0, maxCooldownTicks].
	CooldownTicks uint64

	// CircleRadiusMM is the painted circle's radius. Clamped exactly as the
	// telegraph constructors clamp an extent; a negative radius survives as
	// the degenerate catches-nothing circle, matching the telegraph law.
	CircleRadiusMM int64

	// Damage is how much health each caught entity loses when a cast
	// resolves, clamped into [0, maxHealth] so application can never
	// overflow (see damage.go). Zero — the default — is a telegraph that
	// marks but does not hurt, which is every mob configured before damage
	// existed. How much a hit HURTS, like how generous the wind-up is,
	// remains a reviewed balance decision (#153's lesson), not a library
	// constraint.
	Damage int64
}

// mobState is one registered mob's AI state.
type mobState struct {
	params MobParams

	// inFlight is true while this mob's cast is awaiting resolution; a mob
	// has at most one cast in flight.
	inFlight bool

	// nextCastTick is the earliest tick a new cast may start (cooldown gate,
	// measured from the previous cast's START).
	nextCastTick uint64
}

// ActiveCast is one painted, not-yet-resolved telegraph. The shape is
// anchored where it was painted — it never follows the target; that anchor
// staying put is what makes stepping out possible.
type ActiveCast struct {
	Caster      EntityID
	Shape       Telegraph
	StartTick   uint64
	ResolveTick uint64
}

// TelegraphHit is one resolved cast: who painted it, when it resolved, who
// was standing in it at resolution (ascending-ID order), and how much each of
// them should lose. Targets is empty when everyone stepped out — an empty
// resolution is still an observable outcome and is recorded. The hit is a
// RECORD, not an application: the zone loop lands it with one explicit
// World.ApplyDamage(Targets, Damage) call, so the caller owns the ordering
// between resolution, application and replication.
type TelegraphHit struct {
	// Tick is the step index during which the cast resolved (the value of
	// World.Tick while that step ran; after Step returns, World.Tick reads
	// Tick+1).
	Tick    uint64
	Caster  EntityID
	Targets []EntityID
	// Damage is the caster's configured per-cast damage (MobParams.Damage)
	// at resolution time, carried on the record so the consumer needs no
	// access to the mob registry to land the hit.
	Damage int64
}

// AddMob registers an existing entity as a stationary caster with the given
// (clamped) parameters. It panics on an unknown entity or a duplicate
// registration, mirroring Add: both are programming errors and silently
// accepting either would corrupt determinism. The mob's movement is whatever
// its entity does — this slice's AI never sets intent, so a fixture that
// wants a stationary mob gives its entity MaxSpeed 0.
func (w *World) AddMob(id EntityID, p MobParams) {
	if w.ents[id] == nil {
		panic("sim: AddMob for unknown entity")
	}
	if _, dup := w.mobs[id]; dup {
		panic("sim: duplicate mob registration")
	}
	p.AggroRadiusMM = clampAxis(p.AggroRadiusMM, 0, maxInterestRadiusMM)
	p.CastTicks = clampTicks(p.CastTicks, minCastTicks, maxCastTicks)
	p.CooldownTicks = clampTicks(p.CooldownTicks, 0, maxCooldownTicks)
	p.CircleRadiusMM = clampExtent(p.CircleRadiusMM)
	p.Damage = clampAxis(p.Damage, 0, maxHealth)
	if w.mobs == nil {
		w.mobs = make(map[EntityID]*mobState)
	}
	w.mobs[id] = &mobState{params: p}
	w.mobOrder = append(w.mobOrder, id)
	sort.Slice(w.mobOrder, func(i, j int) bool { return w.mobOrder[i] < w.mobOrder[j] })
}

// clampTicks bounds a tick count into [lo, hi].
func clampTicks(v, lo, hi uint64) uint64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// MobCount returns the number of registered mobs.
func (w *World) MobCount() int { return len(w.mobOrder) }

// ActiveCasts returns a copy of the painted, unresolved casts in paint order.
// It is the read seam the future replication child consumes (the client must
// SEE the mark to step out of it) and what tests assert anchors against.
func (w *World) ActiveCasts() []ActiveCast {
	out := make([]ActiveCast, len(w.casts))
	copy(out, w.casts)
	return out
}

// DrainHits returns every resolution recorded since the last drain, in
// resolution order, and clears the pending log. The cumulative DroppedHits
// counter is deliberately NOT reset: a drop means the consumer stopped
// draining, and that evidence should survive the drain that follows.
func (w *World) DrainHits() []TelegraphHit {
	out := w.hits
	w.hits = nil
	return out
}

// DroppedHits returns how many resolutions were discarded because the
// pending hit log was full (see maxHitRecords). Nonzero means the consumer
// is not draining every tick.
func (w *World) DroppedHits() uint64 { return w.droppedHits }

// combatStep is the combat phase of Step: resolve casts that are due, then
// let mobs start new ones. It runs after movement and separation, so
// membership is measured against where everyone ENDED this tick — the moves
// a player made this very tick count toward the dodge. Resolution runs
// before decisions so a mob whose cooldown allows it may re-cast on the tick
// its previous cast resolves.
func (w *World) combatStep() {
	if len(w.casts) == 0 && len(w.mobs) == 0 {
		return
	}
	w.resolveDueCasts()
	w.decideMobCasts()
}

// resolveDueCasts resolves, in paint order, every cast whose resolve tick
// has arrived. The <= (rather than ==) cannot fire for a well-formed cast —
// CastTicks >= minCastTicks puts every resolve tick in the future — but if a
// bug ever produced an overdue cast, resolving it late and loudly in the
// record beats leaking it forever.
func (w *World) resolveDueCasts() {
	remaining := w.casts[:0]
	for _, c := range w.casts {
		if c.ResolveTick > w.Tick {
			remaining = append(remaining, c)
			continue
		}
		var targets []EntityID
		for _, id := range w.order {
			if id == c.Caster {
				// A mob is never caught by its own circle. Any OTHER
				// entity standing in it — including another mob — is
				// recorded: membership is a fact about the ground, and
				// what a hit does to whom is the damage child's question.
				continue
			}
			if c.Shape.Catches(w.ents[id].Pos) {
				targets = append(targets, id)
			}
		}
		var damage int64
		if st := w.mobs[c.Caster]; st != nil {
			damage = st.params.Damage
			st.inFlight = false
		}
		if len(w.hits) >= maxHitRecords {
			w.droppedHits++
		} else {
			w.hits = append(w.hits, TelegraphHit{Tick: w.Tick, Caster: c.Caster, Targets: targets, Damage: damage})
		}
	}
	w.casts = remaining
}

// decideMobCasts runs each mob's decision, in ascending-ID order: a mob with
// no cast in flight and its cooldown elapsed aggros the nearest non-mob
// entity within its aggro radius (ties broken toward the LOWER entity ID)
// and paints a circle at that target's position — where the target is
// standing NOW, not where it will be. Cooldown is measured from cast start.
func (w *World) decideMobCasts() {
	for _, id := range w.mobOrder {
		st := w.mobs[id]
		if st.inFlight || w.Tick < st.nextCastTick {
			continue
		}
		target := w.nearestTargetable(id, st.params.AggroRadiusMM)
		if target == nil {
			continue
		}
		w.casts = append(w.casts, ActiveCast{
			Caster:      id,
			Shape:       CircleTelegraph(target.Pos, st.params.CircleRadiusMM),
			StartTick:   w.Tick,
			ResolveTick: w.Tick + st.params.CastTicks,
		})
		st.inFlight = true
		st.nextCastTick = w.Tick + st.params.CooldownTicks
	}
}

// nearestTargetable returns the closest non-mob entity within radiusMM of the
// mob's current position on the ground plane, or nil if none is in range.
// Iterating w.order ascending with a strictly-closer comparison makes the
// lower entity ID win an exact distance tie — deterministically, never by
// map order. The radius is clamped on ingestion to maxInterestRadiusMM, so
// r*r cannot overflow (the AoI bound, for the AoI reason).
func (w *World) nearestTargetable(mob EntityID, radiusMM int64) *Entity {
	if radiusMM <= 0 {
		return nil
	}
	m := w.ents[mob]
	r2 := radiusMM * radiusMM
	var best *Entity
	var bestD2 int64
	for _, id := range w.order {
		if _, isMob := w.mobs[id]; isMob {
			continue
		}
		d2 := horizontalDist2(m.Pos, w.ents[id].Pos)
		if d2 > r2 {
			continue
		}
		if best == nil || d2 < bestD2 {
			best, bestD2 = w.ents[id], d2
		}
	}
	return best
}
