package artgen

import (
	"github.com/qmuntal/gltf"
	"github.com/qmuntal/gltf/modeler"
)

// WriteGLB exports the mesh as a binary glTF with a flat-shaded procedural
// rock material (dark warm greys, fully rough) — CC0 texture sets are a later
// stage; nothing is fetched at generate time.
func WriteGLB(m *Mesh, path string) error {
	doc := gltf.NewDocument()

	positions := make([][3]float32, len(m.Verts))
	for i, v := range m.Verts {
		positions[i] = [3]float32{float32(v.X), float32(v.Y), float32(v.Z)}
	}
	indices := make([]uint32, 0, len(m.Tris)*3)
	for _, t := range m.Tris {
		indices = append(indices, uint32(t[0]), uint32(t[1]), uint32(t[2]))
	}

	metallic := 0.0
	roughness := 0.95
	doc.Materials = append(doc.Materials, &gltf.Material{
		Name: "cave_rock",
		PBRMetallicRoughness: &gltf.PBRMetallicRoughness{
			BaseColorFactor: &[4]float64{0.21, 0.185, 0.16, 1},
			MetallicFactor:  &metallic,
			RoughnessFactor: &roughness,
		},
	})

	prim := &gltf.Primitive{
		Indices: gltf.Index(modeler.WriteIndices(doc, indices)),
		Attributes: map[string]int{
			gltf.POSITION: modeler.WritePosition(doc, positions),
		},
		Material: gltf.Index(0),
	}
	doc.Meshes = append(doc.Meshes, &gltf.Mesh{Name: "cave", Primitives: []*gltf.Primitive{prim}})
	doc.Nodes = append(doc.Nodes, &gltf.Node{Name: "cave", Mesh: gltf.Index(0)})
	doc.Scenes[0].Nodes = append(doc.Scenes[0].Nodes, 0)

	return gltf.SaveBinary(doc, path)
}
