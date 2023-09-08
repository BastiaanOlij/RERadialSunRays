#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(r16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 center;
    float samples;
    float radius;
    float effect_amount;
    float reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 size = ivec2(params.size.xy);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	// Just in case the effect_size size is not divisable by 8
	if ((uv.x >= size.x) || (uv.y >= size.y)) {
		return;
	}

    float blurred = 0.0;
    float samples = floor(params.samples);
    vec2 dist = vec2(gl_GlobalInvocationID.xy) - params.center;
    float ratio = clamp(length(dist) / params.radius, 0.0, 1.0);

    for (float i = 0.0; i < samples; i += 1.0) {
        float scale = 1.0 - params.effect_amount * (i / samples) * ratio;
        ivec2 read_uv = ivec2(dist * scale + params.center);
        blurred += imageLoad(input_image, read_uv).r;
    }

	imageStore(output_image, uv, vec4(blurred / samples));
}
