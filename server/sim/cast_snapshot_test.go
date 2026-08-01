package sim

import (
	"reflect"
	"testing"
)

func TestSnapshotTrackerCarriesActiveCastLifecycle(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, Radius: 400, InterestRadius: 5_000})
	w.Add(Entity{ID: 100, Pos: Vec3{X: 2_000}, Radius: 300})
	w.AddMob(100, MobParams{
		AggroRadiusMM:  10_000,
		CastTicks:      3,
		CooldownTicks:  600,
		CircleRadiusMM: 1_500,
	})

	tracker := NewSnapshotTracker(1)
	tracker.Update(w) // prime before the cast exists

	w.Step() // tick 0 paints the cast; the post-step snapshot is tick 1
	want := ActiveCast{
		Caster:      100,
		Shape:       CircleTelegraph(Vec3{}, 1_500),
		StartTick:   0,
		ResolveTick: 3,
	}
	if got := w.Snapshot(1).Casts; !reflect.DeepEqual(got, []ActiveCast{want}) {
		t.Fatalf("snapshot casts = %+v, want the authoritative active cast %+v", got, want)
	}

	started := tracker.Update(w)
	if !reflect.DeepEqual(started.StartedCasts, []ActiveCast{want}) || len(started.EndedCasts) != 0 {
		t.Fatalf("cast start delta = %+v, want one start and no end", started)
	}

	w.Step()
	if unchanged := tracker.Update(w); !unchanged.Empty() {
		t.Fatalf("unchanged cast produced bandwidth: %+v", unchanged)
	}

	w.Step()
	if unchanged := tracker.Update(w); !unchanged.Empty() {
		t.Fatalf("cast still active before resolve tick produced bandwidth: %+v", unchanged)
	}

	w.Step() // tick 3 resolves before the post-step snapshot is built
	ended := tracker.Update(w)
	if len(ended.StartedCasts) != 0 || !reflect.DeepEqual(ended.EndedCasts, []EntityID{100}) {
		t.Fatalf("cast end delta = %+v, want caster 100 ended exactly once", ended)
	}
}

func TestSnapshotOmitsCastWhoseCasterIsOutsideInterest(t *testing.T) {
	w := NewWorld(combatBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, Radius: 400, InterestRadius: 5_000})
	w.Add(Entity{ID: 100, Pos: Vec3{X: 6_000}, Radius: 300})
	w.AddMob(100, MobParams{AggroRadiusMM: 10_000, CastTicks: 3, CircleRadiusMM: 1_500})

	w.Step()
	if got := w.ActiveCasts(); len(got) != 1 {
		t.Fatalf("scenario did not paint its control cast: %+v", got)
	}
	if got := w.Snapshot(1).Casts; len(got) != 0 {
		t.Fatalf("snapshot leaked an out-of-interest caster's cast: %+v", got)
	}
}
