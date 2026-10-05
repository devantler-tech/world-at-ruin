// Package groundgoldens produces cross-tier fixtures from the real isolated
// simulation. It has no serving or player-controller caller.
package groundgoldens

import (
	"encoding/json"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// Vector is an integer position or velocity encoded with client axis names.
type Vector struct {
	X int64 `json:"x"`
	Y int64 `json:"y"`
	Z int64 `json:"z"`
}

// Spec is the explicit isolated flat-zone configuration used by both tiers.
type Spec struct {
	MaxSpeedMMPerS int64  `json:"max_speed_mm_s"`
	MinX           int64  `json:"min_x"`
	MinY           int64  `json:"min_y"`
	MinZ           int64  `json:"min_z"`
	MaxX           int64  `json:"max_x"`
	MaxY           int64  `json:"max_y"`
	MaxZ           int64  `json:"max_z"`
	HoldTicks      int    `json:"hold_ticks"`
	CollisionMode  string `json:"collision_mode"`
}

// Case contains each input and the position observed after the actual step.
type Case struct {
	Name      string   `json:"name"`
	Spec      Spec     `json:"spec"`
	Initial   Vector   `json:"initial"`
	Inputs    []Vector `json:"inputs"`
	Positions []Vector `json:"positions"`
}

// Sample is the direction-only wire payload, without ownership or clocks.
type Sample struct {
	X      int16 `json:"x"`
	Z      int16 `json:"z"`
	Sprint bool  `json:"sprint"`
}

// Direction binds the client conversion to the zonesock production function.
type Direction struct {
	Spec     Spec   `json:"spec"`
	Sample   Sample `json:"sample"`
	Velocity Vector `json:"velocity"`
}

// Fixture is the complete reproducible position and direction corpus.
type Fixture struct {
	Version    int         `json:"version"`
	Cases      []Case      `json:"cases"`
	Directions []Direction `json:"directions"`
}

// spec returns the shared isolated bounds and hold limit for the selected speed.
func spec(speed int64) Spec {
	return Spec{MaxSpeedMMPerS: speed, MinX: -20000, MinY: 0, MinZ: -20000,
		MaxX: 20000, MaxY: 4000, MaxZ: 20000, HoldTicks: 2, CollisionMode: "isolated_flat"}
}

// vector preserves the simulation's integer axes in the client fixture shape.
func vector(value sim.Vec3) Vector { return Vector{X: value.X, Y: value.Y, Z: value.Z} }

// scenario records every position from an actual isolated World.Step.
func scenario(name string, speed int64, initial sim.Vec3, inputs ...sim.Vec3) Case {
	config := spec(speed)
	world := sim.NewWorld(sim.Bounds{Min: sim.Vec3{X: config.MinX, Y: config.MinY, Z: config.MinZ},
		Max: sim.Vec3{X: config.MaxX, Y: config.MaxY, Z: config.MaxZ}})
	entity := world.Add(sim.Entity{ID: 1, Pos: initial, MaxSpeed: speed})
	row := Case{Name: name, Spec: config, Initial: vector(initial)}
	for _, input := range inputs {
		world.SetIntent(entity.ID, input)
		world.Step()
		row.Inputs = append(row.Inputs, vector(input))
		row.Positions = append(row.Positions, vector(entity.Pos))
	}
	return row
}

// direction pins the wire conversion for independent checks against zonesock.
func direction(speed int64, sample Sample) Direction {
	capMM := speed
	if !sample.Sprint {
		capMM /= 2
	}
	return Direction{Spec: spec(speed), Sample: sample,
		Velocity: Vector{X: int64(sample.X) * capMM / 1000, Z: int64(sample.Z) * capMM / 1000}}
}

// Bytes serializes the fixed corpus; every position comes from World.Step.
func Bytes() ([]byte, error) {
	initial := sim.Vec3{Y: 147}
	fixture := Fixture{Version: 1, Cases: []Case{
		scenario("cardinal", 4000, initial, sim.Vec3{X: 4000}, sim.Vec3{X: 4000}, sim.Vec3{}),
		scenario("negative-truncation", 4000, initial, sim.Vec3{X: -31, Z: -29}, sim.Vec3{X: -4000}, sim.Vec3{Z: -4000}),
		scenario("diagonal-clamp", 4000, initial, sim.Vec3{X: 4000, Z: 4000}, sim.Vec3{X: -4000, Z: -4000}),
		scenario("odd-cap", 4001, initial, sim.Vec3{X: 4001}, sim.Vec3{X: 4001, Z: 4001}, sim.Vec3{X: -4001}),
		scenario("sanitized-extremes", 4000, initial, sim.Vec3{X: 2000000000, Y: 999999999, Z: -2000000000}, sim.Vec3{X: -2000000000, Y: -999999999, Z: 2000000000}),
		scenario("vertical-discard", 4000, initial, sim.Vec3{Y: 9000}, sim.Vec3{Y: -9000}, sim.Vec3{X: 31, Y: 1000000000}),
		scenario("zero-cap", 0, initial, sim.Vec3{X: 999999999, Z: -999999999}),
		scenario("subtick-cap", 29, initial, sim.Vec3{X: -29}, sim.Vec3{X: 29, Z: 29}),
		scenario("bounds", 4000, sim.Vec3{X: 19999, Y: 4000, Z: -19999}, sim.Vec3{X: 4000, Z: -4000}, sim.Vec3{X: -4000, Z: 4000}),
		scenario("large-safe-square", 1000000000, initial, sim.Vec3{X: 1000000000, Z: -1000000000}, sim.Vec3{X: -1000000000, Z: 1000000000}),
	}, Directions: []Direction{
		direction(4001, Sample{X: 1000}),
		direction(4001, Sample{X: -707, Z: 707, Sprint: true}),
		direction(4001, Sample{X: -707, Z: 707}),
		direction(1, Sample{X: 1000}),
		direction(0, Sample{X: 1000, Sprint: true}),
		direction(1000000000, Sample{X: 707, Z: -707, Sprint: true}),
	}}
	raw, err := json.MarshalIndent(fixture, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(raw, '\n'), nil
}
