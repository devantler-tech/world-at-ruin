package sim

// This file defines a small, fully deterministic demo zone shared by the
// runnable server binary (cmd/zone) and the golden-hash regression test. Both
// drive the exact same scenario through the exact same code, so the committed
// golden hash actually pins the behaviour the binary exhibits — and there is
// one source of the scenario, not two that can drift apart. Nothing here uses
// wall-clock time or randomness.

// DemoBounds is the demo zone's navmesh extent: a 40 m square, 4 m tall.
var DemoBounds = Bounds{
	Min: Vec3{X: -20_000, Y: 0, Z: -20_000},
	Max: Vec3{X: 20_000, Y: 4_000, Z: 20_000},
}

// demoActor seeds one actor in the demo zone.
type demoActor struct {
	id       EntityID
	pos      Vec3
	maxSpeed int64 // mm/s
	radius   int64 // mm
}

var demoActors = []demoActor{
	{id: 1, pos: Vec3{X: -5_000, Z: -5_000}, maxSpeed: 4_000, radius: 300}, // 4.0 m/s
	{id: 2, pos: Vec3{X: 5_000, Z: -5_000}, maxSpeed: 6_000, radius: 300},  // 6.0 m/s
	{id: 3, pos: Vec3{X: 0, Z: 8_000}, maxSpeed: 2_500, radius: 400},       // 2.5 m/s
}

// NewDemoWorld builds the seeded demo zone. Deterministic: no randomness, no
// clock.
func NewDemoWorld() *World {
	w := NewWorld(DemoBounds)
	for _, a := range demoActors {
		w.Add(Entity{ID: a.id, Pos: a.pos, MaxSpeed: a.maxSpeed, Radius: a.radius})
	}
	return w
}

// cardinalMM holds the four ground-plane directions at 1 m/s. clampSpeed then
// stretches the scripted intent up to each actor's own max speed.
var cardinalMM = []Vec3{
	{X: 1_000},  // +X (east)
	{Z: 1_000},  // +Z (north)
	{X: -1_000}, // -X (west)
	{Z: -1_000}, // -Z (south)
}

// demoLegTicks is how long an actor walks one direction before turning.
const demoLegTicks = 45

// DriveDemoTick sets every actor's intent for the coming step as a pure
// function of the current tick and the actor's ID: each actor walks one
// cardinal direction for demoLegTicks ticks, then turns, cycling forever. The
// +id phase offset spreads the actors apart and drives several into the bounds,
// exercising both the speed clamp and the bounds clamp. It must be called once
// per tick, before Step.
func DriveDemoTick(w *World) {
	leg := w.Tick / demoLegTicks
	for _, a := range demoActors {
		dir := cardinalMM[(leg+uint64(a.id))%uint64(len(cardinalMM))]
		// Intent well above max speed on purpose: clampSpeed sets the real pace,
		// so this also exercises the clamp every tick.
		w.SetIntent(a.id, Vec3{X: dir.X * 100, Y: dir.Y, Z: dir.Z * 100})
	}
}
