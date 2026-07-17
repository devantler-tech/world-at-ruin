package artgen

import "math/rand"

// perlin is classic Ken Perlin gradient noise over a seeded permutation table,
// so the whole field — not just the sampling offsets — derives from the seed.
type perlin struct{ p [512]int }

func newPerlin(seed int64) *perlin {
	rng := rand.New(rand.NewSource(seed))
	var base [256]int
	for i := range base {
		base[i] = i
	}
	rng.Shuffle(256, func(i, j int) { base[i], base[j] = base[j], base[i] })
	n := &perlin{}
	for i := 0; i < 512; i++ {
		n.p[i] = base[i&255]
	}
	return n
}

func fade(t float64) float64 { return t * t * t * (t*(t*6-15) + 10) }

func lerp(t, a, b float64) float64 { return a + t*(b-a) }

func grad(hash int, x, y, z float64) float64 {
	h := hash & 15
	u := x
	if h >= 8 {
		u = y
	}
	v := y
	if h >= 4 {
		v = z
		if h == 12 || h == 14 {
			v = x
		}
	}
	if h&1 != 0 {
		u = -u
	}
	if h&2 != 0 {
		v = -v
	}
	return u + v
}

// Noise returns gradient noise in [-1, 1] at (x, y, z).
func (n *perlin) Noise(x, y, z float64) float64 {
	xi, yi, zi := int(floor(x))&255, int(floor(y))&255, int(floor(z))&255
	xf, yf, zf := x-floor(x), y-floor(y), z-floor(z)
	u, v, w := fade(xf), fade(yf), fade(zf)
	p := &n.p
	a := p[xi] + yi
	aa, ab := p[a]+zi, p[a+1]+zi
	b := p[xi+1] + yi
	ba, bb := p[b]+zi, p[b+1]+zi
	return lerp(w,
		lerp(v,
			lerp(u, grad(p[aa], xf, yf, zf), grad(p[ba], xf-1, yf, zf)),
			lerp(u, grad(p[ab], xf, yf-1, zf), grad(p[bb], xf-1, yf-1, zf))),
		lerp(v,
			lerp(u, grad(p[aa+1], xf, yf, zf-1), grad(p[ba+1], xf-1, yf, zf-1)),
			lerp(u, grad(p[ab+1], xf, yf-1, zf-1), grad(p[bb+1], xf-1, yf-1, zf-1))))
}

// FBM layers octaves of Noise into fractal Brownian motion.
func (n *perlin) FBM(x, y, z float64, octaves int) float64 {
	total, amplitude, frequency := 0.0, 1.0, 1.0
	for i := 0; i < octaves; i++ {
		total += amplitude * n.Noise(x*frequency, y*frequency, z*frequency)
		amplitude *= 0.5
		frequency *= 2.0
	}
	return total
}

func floor(x float64) float64 {
	f := float64(int64(x))
	if x < f {
		return f - 1
	}
	return f
}
