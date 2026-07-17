package sim

// Vec3 is a point or displacement in world space, measured in **integer
// millimetres**. Integer units are a deliberate, load-bearing choice: the
// authoritative simulation must be bit-identical on every host that runs it,
// and floating point is the classic source of physics desync (the same
// operations round differently across compilers, CPUs and optimisation
// levels). The product law — no desync, no undo — makes determinism a day-one
// requirement, not a later optimisation, so every world coordinate is an
// int64 and every step is integer-only arithmetic.
//
// Y is the vertical (up) axis. The skeleton keeps actors on the XZ plane; the
// vertical axis exists so gravity and terrain height can arrive in a later
// child without a coordinate migration.
type Vec3 struct {
	X, Y, Z int64
}

// Add returns a+b.
func (a Vec3) Add(b Vec3) Vec3 { return Vec3{a.X + b.X, a.Y + b.Y, a.Z + b.Z} }

// Sub returns a-b.
func (a Vec3) Sub(b Vec3) Vec3 { return Vec3{a.X - b.X, a.Y - b.Y, a.Z - b.Z} }

// HorizontalLen returns the length of the XZ (ground-plane) component in
// millimetres, floored to an integer. Vertical extent is ignored — movement
// speed on the navmesh is a ground-plane quantity.
//
// Callers must keep |X| and |Z| within the world bounds (see maxWorldExtentMM):
// X*X + Z*Z must not overflow int64. At the 1 km bound the largest squared sum
// is 2e12, four million times below the int64 ceiling, so the invariant holds
// with a wide margin.
func (a Vec3) HorizontalLen() int64 { return isqrt(a.X*a.X + a.Z*a.Z) }

// isqrt returns floor(sqrt(n)) for n >= 0 using integer-only Newton iteration.
// It replaces math.Sqrt (a float operation) so the simulation stays
// deterministic across architectures. It panics on negative input, which can
// only arise from an arithmetic overflow bug upstream — failing loudly is
// correct there.
func isqrt(n int64) int64 {
	if n < 0 {
		panic("sim: isqrt of negative value (upstream overflow?)")
	}
	if n < 2 {
		return n
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
