#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_image;
layout(r16f, set = 1, binding = 0) uniform restrict writeonly image2D sundisk_image;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	vec2 effect_size;
	vec2 sun_pos;
	float sun_size;
	float fade_size;
} params;

// The code we want to execute in each invocation
void main() {
	float epsilon = 1e-6f;

	ivec2 render_size = ivec2(params.render_size.xy);
	ivec2 effect_size = ivec2(params.effect_size.xy);

	ivec2 sundisk_uv = ivec2(gl_GlobalInvocationID.xy);

	// Just in case the effect_size size is not divisable by 8
	if ((sundisk_uv.x >= effect_size.x) || (sundisk_uv.y >= effect_size.y)) {
		return;
	}

	// Get our depth
	vec2 depth_uv = vec2(sundisk_uv) / params.effect_size;

	float depth = 1.0 - textureLod(depth_image, depth_uv, 0).r;
	if (depth + epsilon < 1.0) {
		imageStore(sundisk_image, sundisk_uv, vec4(0.0));
		return;
	}

	// Apply our sun calculation
	vec2 sun_pos = (vec2(params.sun_pos.x, -params.sun_pos.y) * 0.5 + 0.5) * params.effect_size;
	float distance = length(vec2(gl_GlobalInvocationID.xy) - sun_pos); 

	float sun = clamp((params.sun_size - distance) / params.fade_size, 0.0, 1.0);

	imageStore(sundisk_image, sundisk_uv, vec4(sun));
}
