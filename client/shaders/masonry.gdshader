shader_type spatial;
// Ruin and shrine masonry: cut stone blocks, entirely procedural ("as code":
// no textures, the look is arithmetic — same idiom as terrain.gdshader and
// cave_rock.gdshader).
//
// Before this, every column, lintel, fallen block, monolith and pedestal in
// the world shared ONE StandardMaterial3D: a single albedo_color and a single
// roughness scalar. Not even noise — a constant. Two ruins 200 m apart were
// the same shade as each other and as the shrine they surround, and no face
// responded to the low sun at any angle.
//
// The art direction (docs/art-direction/README.md) names the fix precisely:
// the problem with generated surfaces is that they are smooth interpolations
// of noise, so nothing reads as DECIDED. More octaves is the wrong move. What
// authored masonry has, and noise does not, is EDGES — a mason cut these
// blocks and stacked them in courses. So the primary structure here is
// discrete, not continuous:
//   1. Courses and blocks — hard joints on a running bond, the one feature
//      that says "someone built this" rather than "this was generated".
//   2. Per-block variation — each block draws its own shade, roughness and
//      wear from its own world position, so a wall is many stones and two
//      ruin sites are not the same grey.
//   3. Cavity darkening and edge wear at the joints — recessed mortar reads
//      dark, exposed corners read light and rough. This is the stylisation
//      rule the art direction sanctions, and it is what gives a block relief.
//   4. NORMAL perturbation from that same block relief, so grazing light rakes
//      across the courses instead of washing the whole face flat.
//   5. Ash settling on up-facing surfaces, matching the world's ash law from
//      the terrain (ash banks on flats, washes off steep faces).

// Base stone. Ruins and the shrine pass different tints through this uniform,
// which is what the old materials used albedo_color for.
uniform vec3 stone_color: source_color = vec3(0.42, 0.39, 0.35);
// Mortar/joint colour — the shadowed recess between blocks.
uniform vec3 joint_color: source_color = vec3(0.19, 0.17, 0.16);
// Ash that settles on anything facing the sky, tying masonry to the ground.
uniform vec3 ash_color: source_color = vec3(0.52, 0.48, 0.42);

// Course height in metres. Blocks read as masonry at roughly this size; the
// ruin columns are ~0.5-0.9 m across, so a course near 0.45 m gives two to
// three courses per visible span rather than one flat face.
uniform float course_height = 0.45;
// Block length along the course, in metres.
uniform float block_length = 0.72;
// Width of the recessed joint, as a fraction of a block.
uniform float joint_width: hint_range(0.0, 0.3) = 0.055;
// How much the joints and block relief bend the normal.
uniform float bump_strength: hint_range(0.0, 3.0) = 0.9;
// How much each block's own draw shifts its brightness.
uniform float block_variation: hint_range(0.0, 1.0) = 0.16;
// Fine grit over the whole surface, in cycles per metre.
uniform float grain_scale = 11.0;
uniform float stone_roughness: hint_range(0.0, 1.0) = 0.88;
// Worn corners polish slightly; recessed joints hold dust and stay matte.
uniform float wear_roughness: hint_range(0.0, 1.0) = 0.62;
// How strongly ash accumulates on up-facing surfaces.
uniform float ash_amount: hint_range(0.0, 1.0) = 0.45;
// Distance over which fine detail fades, so the far field stays calm instead
// of shimmering — same treatment the terrain uses.
uniform float detail_fade_start = 40.0;
uniform float detail_fade_end = 120.0;

varying vec3 world_pos;
varying vec3 world_normal;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
		mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
		u.z);
}

float fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 3; i++) {
		sum += amp * value_noise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return sum;
}

// Block coordinates for a point on a surface with the given normal.
//
// Masonry courses are horizontal in WORLD space no matter how the mesh is
// oriented, which is what makes this work on a column, a toppled lintel and a
// monolith alike without tangents or UVs (none of these meshes carry usable
// ones — they are BoxMesh and CylinderMesh primitives).
//
// Returns: xy = position within the block in [0,1), zw = the block's id.
vec4 block_coords(vec3 wp, vec3 n) {
	// How much this face points at the sky. Near 1 we are on a top surface,
	// where "courses" make no sense and the stone reads as paving instead.
	float up = clamp(abs(n.y), 0.0, 1.0);

	// --- Wall mode: courses stacked in Y, blocks running along the face. ---
	// The horizontal tangent of the face gives a stable coordinate along it.
	vec2 flat_n = vec2(n.x, n.z);
	float flat_len = length(flat_n);
	vec2 tangent = flat_len > 0.0001 ? vec2(-flat_n.y, flat_n.x) / flat_len : vec2(1.0, 0.0);
	float along = dot(wp.xz, tangent);

	float course = floor(wp.y / course_height);
	// Running bond: every other course is offset by half a block, the way a
	// wall is actually laid. Aligned joints would read as a grid, not masonry.
	float bond = fract(course * 0.5) * 0.5 + hash2(vec2(course, 3.7)) * 0.12;
	float wall_u = along / block_length + bond;
	float wall_v = wp.y / course_height;

	// --- Top mode: paving slabs on the XZ plane. ---
	float pave_u = wp.x / block_length;
	float pave_v = wp.z / block_length;

	float u = mix(wall_u, pave_u, up);
	float v = mix(wall_v, pave_v, up);

	return vec4(fract(u), fract(v), floor(u), floor(v));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Surface relief: 1 on the face of a block, falling to 0 in the joints. This
// is the height field the normal perturbation differentiates, so the joints
// read as real recesses rather than painted lines.
float relief(vec3 wp, vec3 n) {
	vec4 bc = block_coords(wp, n);
	// Distance to the nearest joint, in block units, on each axis.
	float du = min(bc.x, 1.0 - bc.x);
	float dv = min(bc.y, 1.0 - bc.y);
	float d = min(du, dv);
	// Hard-ish shoulder: the block face is flat, the joint drops away. This
	// edge is the whole point — a smooth falloff here would put us straight
	// back to an interpolation of noise.
	return smoothstep(0.0, joint_width, d);
}

void fragment() {
	vec3 n = normalize(world_normal);

	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);

	vec4 bc = block_coords(world_pos, n);
	float face = relief(world_pos, n);

	// Each block draws its own shade and wear from its own id, so a wall is
	// many stones. Because the id comes from WORLD position, two ruin sites in
	// different places never land on the same sequence of draws.
	float block_id = hash2(bc.zw + vec2(0.0, floor(world_pos.y * 0.37)));
	float block_wear = hash2(bc.zw * 1.71 + vec2(9.2, 4.4));

	// Fine grit across the whole surface.
	float grain = fbm(world_pos * grain_scale);

	// --- Colour ---
	vec3 stone = stone_color * (1.0 + (block_id - 0.5) * 2.0 * block_variation);
	// Grit modulates brightness slightly; subtle, so it reads as stone rather
	// than dirt sprayed over the frame.
	stone *= 0.94 + 0.12 * mix(0.5, grain, detail);

	// Cavity darkening: the recessed joint is in shadow from everything.
	vec3 surface = mix(joint_color, stone, face);

	// Edge wear: the outermost band of each block face is chipped and exposed,
	// so it catches light. Only on blocks whose draw says they are worn.
	float edge = (1.0 - face) * face * 4.0;
	surface = mix(surface, surface * 1.35, clamp(edge * block_wear, 0.0, 1.0) * 0.8);

	// Ash settles on anything facing the sky, tying masonry into the ash field
	// the terrain already lays down.
	float up_facing = clamp(n.y, 0.0, 1.0);
	float ash = smoothstep(0.35, 0.95, up_facing) * ash_amount * (0.7 + 0.6 * grain);
	surface = mix(surface, ash_color, clamp(ash, 0.0, 1.0));

	ALBEDO = surface;

	// --- Roughness ---
	// Joints hold dust and stay matte; worn corners polish slightly.
	float rough = mix(stone_roughness, wear_roughness, clamp(edge * block_wear, 0.0, 1.0));
	rough = mix(stone_roughness + 0.06, rough, face);
	ROUGHNESS = clamp(rough - 0.05 * (grain - 0.5) * detail, 0.0, 1.0);
	SPECULAR = 0.16;

	// --- Normal ---
	// Perturb from the gradient of the block relief plus the fine grit. Sampled
	// along two tangents built from the face normal, so this works on a column,
	// a fallen lintel and a flat slab alike without the meshes carrying
	// tangents (BoxMesh/CylinderMesh primitives do not have usable ones here).
	vec3 helper = abs(n.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t1 = normalize(cross(n, helper));
	vec3 t2 = normalize(cross(n, t1));

	float e = 0.02;
	float h0 = relief(world_pos, n) + 0.25 * fbm(world_pos * grain_scale);
	float h1 = relief(world_pos + t1 * e, n) + 0.25 * fbm((world_pos + t1 * e) * grain_scale);
	float h2 = relief(world_pos + t2 * e, n) + 0.25 * fbm((world_pos + t2 * e) * grain_scale);

	vec3 bump = (t1 * (h0 - h1) + t2 * (h0 - h2)) * bump_strength * detail;
	vec3 perturbed = normalize(n + bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}
