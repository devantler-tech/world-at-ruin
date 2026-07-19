package sim

// Damage application: the consequence layer that makes a resolved telegraph
// COST something (#195; the follow-up #190's mob core named). A resolve —
// MobController's MobResolve event or combat.go's TelegraphHit record —
// reports who was standing in the shape; this file is the one place that fact
// is turned into lost health, and death is health reaching zero here.
//
// Application is an explicit call, not a hidden phase of Step: the zone loop
// owns the ordering between stepping controllers, applying their hits and
// replicating the outcome — the same latent-landing shape the mob core chose,
// so wiring stays a later child and nothing changes for a world that never
// calls it.
//
// What death DOES is deliberately out of scope. The World cannot even remove
// entities yet; a DeathEvent is the seam the future despawn/respawn child and
// the death→bloodstain→reclaim system (#131, client-side today) will consume.
// Until then a dead entity keeps standing where it died — visibly odd, and
// exactly as much as this slice honestly delivers.

// DeathEvent records one entity's health reaching zero. It is emitted exactly
// once per death: further damage on a dead entity changes nothing and emits
// nothing.
type DeathEvent struct {
	// Tick is World.Tick at application time. In the settled consumption
	// order (World.Step, then controller steps, then application) that is the
	// post-increment tick — the same clock MobEvent.Tick reads, so a death
	// carries the same tick as the MobResolve that caused it.
	Tick uint64
	// Entity is who died.
	Entity EntityID
}

// ApplyDamage subtracts damage from each target's health, in the order given,
// and returns the deaths it caused, in that same order. The caller owns the
// ordering — targets come straight from a resolve's ascending-ID list, and
// applying one resolve is one call.
//
// Sanitized at ingestion, like every input to the tick core: damage is
// clamped into [0, maxHealth], so with health in the same bound the
// subtraction can never under- or overflow. A target with no health pool
// (MaxHealth 0) is untouched; a dead target (Health 0) is skipped, which is
// what makes a death observable exactly once. An unknown ID is skipped too —
// the SetIntent no-op contract, chosen deliberately so the future
// entity-removal child cannot turn a stale resolve into a panic.
func (w *World) ApplyDamage(targets []EntityID, damage int64) []DeathEvent {
	damage = clampAxis(damage, 0, maxHealth)
	if damage == 0 {
		return nil
	}
	var deaths []DeathEvent
	for _, id := range targets {
		e := w.ents[id]
		if e == nil || e.MaxHealth == 0 || e.Health == 0 {
			continue
		}
		e.Health -= damage
		if e.Health <= 0 {
			e.Health = 0
			deaths = append(deaths, DeathEvent{Tick: w.Tick, Entity: id})
		}
	}
	return deaths
}
