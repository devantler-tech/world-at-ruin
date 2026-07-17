package artgen

import (
	"fmt"
	"math"
	"math/rand"
)

// CaveParams shape a generated cave chamber; everything derives from Seed.
type CaveParams struct {
	Seed   int64
	Radius float64
}

// Cave carves a chamber: a noise-displaced icosphere shell with a flattened
// walkable floor band, an entrance mouth cut toward +X, and interior-facing
// windings (the camera lives inside).
func Cave(p CaveParams) *Mesh {
	rng := rand.New(rand.NewSource(p.Seed))
	n := newPerlin(p.Seed)
	roughness := 0.16 + rng.Float64()*0.08
	floorZ := -0.55 * p.Radius

	m := Icosphere(5)
	scale := 1.6 / p.Radius
	for i, v := range m.Verts {
		pos := v.Scale(p.Radius)
		d := n.FBM(pos.X*scale, pos.Y*scale, pos.Z*scale, 4)
		pos = pos.Add(v.Norm().Scale(d * roughness * p.Radius))
		if pos.Z < floorZ {
			rumple := 0.08 * p.Radius * n.FBM(pos.X*3/p.Radius, pos.Y*3/p.Radius, 7.31, 4)
			pos.Z = floorZ + rumple
		}
		m.Verts[i] = pos
	}

	// Cut the entrance: drop triangles whose outward direction is within ~22°
	// of +X and above the floor band.
	cone := math.Cos(22 * math.Pi / 180)
	var kept [][3]int
	for _, tri := range m.Tris {
		c := m.Verts[tri[0]].Add(m.Verts[tri[1]]).Add(m.Verts[tri[2]]).Scale(1.0 / 3)
		if c.Norm().Dot(Vec3{1, 0, 0}) > cone && c.Z > floorZ*0.5 {
			continue
		}
		kept = append(kept, tri)
	}
	m.Tris = kept

	// Flip windings so the interior is the visible side.
	for i, tri := range m.Tris {
		m.Tris[i] = [3]int{tri[0], tri[2], tri[1]}
	}
	return m
}

// Manifest is the determinism fingerprint CI diffs across two runs.
func (m *Mesh) Manifest() string {
	lo := Vec3{math.Inf(1), math.Inf(1), math.Inf(1)}
	hi := Vec3{math.Inf(-1), math.Inf(-1), math.Inf(-1)}
	for _, v := range m.Verts {
		lo = Vec3{math.Min(lo.X, v.X), math.Min(lo.Y, v.Y), math.Min(lo.Z, v.Z)}
		hi = Vec3{math.Max(hi.X, v.X), math.Max(hi.Y, v.Y), math.Max(hi.Z, v.Z)}
	}
	r := func(f float64) float64 { return math.Round(f*10000) / 10000 }
	return fmt.Sprintf("MANIFEST verts=%d tris=%d lo=[%v %v %v] hi=[%v %v %v]",
		len(m.Verts), len(m.Tris), r(lo.X), r(lo.Y), r(lo.Z), r(hi.X), r(hi.Y), r(hi.Z))
}
