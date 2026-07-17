package artgen

import "math"

// Vec3 is a minimal 3-component vector.
type Vec3 struct{ X, Y, Z float64 }

func (v Vec3) Add(o Vec3) Vec3      { return Vec3{v.X + o.X, v.Y + o.Y, v.Z + o.Z} }
func (v Vec3) Scale(s float64) Vec3 { return Vec3{v.X * s, v.Y * s, v.Z * s} }
func (v Vec3) Dot(o Vec3) float64   { return v.X*o.X + v.Y*o.Y + v.Z*o.Z }
func (v Vec3) Len() float64         { return math.Sqrt(v.Dot(v)) }
func (v Vec3) Norm() Vec3 {
	l := v.Len()
	if l == 0 {
		return v
	}
	return v.Scale(1 / l)
}

// Mesh is indexed triangle geometry.
type Mesh struct {
	Verts []Vec3
	Tris  [][3]int
}

// Icosphere builds a unit icosphere with the given subdivision level.
// Construction is fully deterministic: fixed icosahedron seed vertices and a
// midpoint cache keyed on sorted edge indices.
func Icosphere(subdivisions int) *Mesh {
	t := (1 + math.Sqrt(5)) / 2
	verts := []Vec3{
		{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
		{0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
		{t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1},
	}
	for i := range verts {
		verts[i] = verts[i].Norm()
	}
	tris := [][3]int{
		{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
		{1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
		{3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
		{4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
	}
	m := &Mesh{Verts: verts, Tris: tris}
	for s := 0; s < subdivisions; s++ {
		cache := map[[2]int]int{}
		mid := func(a, b int) int {
			k := [2]int{min(a, b), max(a, b)}
			if idx, ok := cache[k]; ok {
				return idx
			}
			m.Verts = append(m.Verts, m.Verts[a].Add(m.Verts[b]).Scale(0.5).Norm())
			cache[k] = len(m.Verts) - 1
			return cache[k]
		}
		var next [][3]int
		for _, tri := range m.Tris {
			a, b, c := tri[0], tri[1], tri[2]
			ab, bc, ca := mid(a, b), mid(b, c), mid(c, a)
			next = append(next,
				[3]int{a, ab, ca}, [3]int{b, bc, ab}, [3]int{c, ca, bc}, [3]int{ab, bc, ca})
		}
		m.Tris = next
	}
	return m
}
