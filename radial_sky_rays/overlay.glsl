#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D sundisk_image;
layout(rgba8, set = 1, binding = 0) uniform image2D color_image;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	vec2 res;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 render_size = ivec2(params.render_size.xy);

	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	// Just in case the render_size size is not divisable by 8
	if ((uv.x >= render_size.x) || (uv.y >= render_size.y)) {
		return;
	}

	vec4 color = imageLoad(color_image, uv);
	float sundisk = textureLod(sundisk_image, vec2(uv) / params.render_size, 0).r;

	color.rgb += color.rgb * sundisk * 1.5;
	// color.rgb = vec3(sundisk);

	imageStore(color_image, uv, color);
}
