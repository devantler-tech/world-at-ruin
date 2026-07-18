class_name FoliageArt
extends RefCounted
## How a cosmetic ground prop LOOKS. [FoliageGen] answers where a prop sits and
## which kind it is; this library answers what the player actually sees there.
##
## Split out of [WorldGen] deliberately: prop art is generated "as code" — every
## mesh, texture and material here is built from a seeded, deterministic recipe
## with no imported assets — so it deserves its own testable surface rather than
## a pair of `match` blocks buried in the world builder.
##
## Nothing here touches placement. Swapping a mesh cannot move a prop, so the
## committed world and foliage goldens are unaffected by anything in this file.

## Crossed alpha-cutout cards: the standard way vegetation gets a real
## silhouette without real geometry. `planes` quads share a centre, each rotated
## about Y, so the prop reads as leaves from every angle instead of as a ball.
static func crossed_cards(width: float, height: float, planes: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var half := width * 0.5
	for plane in maxi(planes, 1):
		var yaw := PI * float(plane) / float(maxi(planes, 1))
		var right := Vector3(cos(yaw), 0.0, sin(yaw)) * half
		var facing := Vector3(-sin(yaw), 0.0, cos(yaw))
		var base := verts.size()
		verts.push_back(-right)
		verts.push_back(right)
		verts.push_back(right + Vector3.UP * height)
		verts.push_back(-right + Vector3.UP * height)
		uvs.push_back(Vector2(0.0, 1.0))
		uvs.push_back(Vector2(1.0, 1.0))
		uvs.push_back(Vector2(1.0, 0.0))
		uvs.push_back(Vector2(0.0, 0.0))
		for _n in 4:
			normals.push_back(facing)
		for offset in [0, 1, 2, 0, 2, 3]:
			indices.push_back(base + offset)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
