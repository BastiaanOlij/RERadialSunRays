shader_type spatial;
render_mode cull_disabled;

void vertex() {
	// Called for every vertex the material is visible on.
	POSITION = PROJECTION_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	// Called for every pixel the material is visible on.
}

void light() {
	// Called for every pixel for every light affecting the material.
}
