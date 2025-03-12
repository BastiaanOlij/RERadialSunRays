@tool
extends CompositorEffect
class_name RadialSkyRays

# This is a rendering effect implementation that adds a god ray type
# post processing effect to our rendering pipeline that is loosly based
# on https://twitter.com/HarryAlisavakis/status/1405807665608015872?s=20
#
# It applies the effect in 4 stages:
# 1 - Renders a sun disk to a new texture but taking depth into account
# 2 - Applies a radial blur to this image
# 3 - Applies a guassian blur to this image
# 4 - Overlays the result onto our source image
#
# The first 3 steps are implemented as compute shaders, the last is a
# raster pass.

@export var half_size : bool = true

@export_group("Sun", "sun_")
@export var sun_location : Vector3 = Vector3(0.0, 1.0, 0.0)
@export var sun_size : float = 150.0
@export var sun_fade_size : float = 50.0

@export_group("Radial Blur", "radial_blur_")
@export_range(4, 32) var radial_blur_samples: int = 32
@export var radial_blur_radius: float = 150.0
@export var radial_blur_effect_amount : float = 0.9

@export_group("Guassian Blur", "gaussian_blur_")
@export_range(5.0, 50.0) var gaussian_blur_size: float = 16.0

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		# When this is called it should be safe to clean up our shader.
		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler)
		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler)
		if radial_blur_shader.is_valid():
			rd.free_rid(radial_blur_shader)
		if gaussian_blur_shader.is_valid():
			rd.free_rid(gaussian_blur_shader)
		if sundisk_shader.is_valid():
			rd.free_rid(sundisk_shader)
		if overlay_shader.is_valid():
			rd.free_rid(overlay_shader)

###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var nearest_sampler : RID
var linear_sampler : RID

var radial_blur_shader : RID
var radial_blur_pipeline : RID

var gaussian_blur_shader : RID
var gaussian_blur_pipeline : RID

var sundisk_shader : RID
var subdisk_pipeline : RID

var overlay_shader : RID
var overlay_pipeline : RID

var context : StringName = "RadialSkyRays"
var texture : StringName = "texture"
var pong_texture : StringName = "pong_texture"

func _initialize_compute():
	rd = RenderingServer.get_rendering_device()
	if !rd:
		return

	# Create our samplers
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_sampler = rd.sampler_create(sampler_state)

	sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler = rd.sampler_create(sampler_state)

	# Create our shaders
	var shader_file = load("res://radial_sky_rays/make_sun_disk.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	sundisk_shader = rd.shader_create_from_spirv(shader_spirv)
	subdisk_pipeline = rd.compute_pipeline_create(sundisk_shader)

	shader_file = load("res://radial_sky_rays/radial_blur.glsl")
	shader_spirv = shader_file.get_spirv()
	radial_blur_shader = rd.shader_create_from_spirv(shader_spirv)
	radial_blur_pipeline = rd.compute_pipeline_create(radial_blur_shader)

	shader_file = load("res://radial_sky_rays/gaussian_blur.glsl")
	shader_spirv = shader_file.get_spirv()
	gaussian_blur_shader = rd.shader_create_from_spirv(shader_spirv)
	gaussian_blur_pipeline = rd.compute_pipeline_create(gaussian_blur_shader)

	shader_file = load("res://radial_sky_rays/overlay.glsl")
	shader_spirv = shader_file.get_spirv()
	overlay_shader = rd.shader_create_from_spirv(shader_spirv)
	overlay_pipeline = rd.compute_pipeline_create(overlay_shader)

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)

	return uniform

func get_sampler_uniform(image : RID, binding : int = 0, linear : bool = true) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	if linear:
		uniform.add_id(linear_sampler)
	else:
		uniform.add_id(nearest_sampler)
	uniform.add_id(image)

	return uniform

## Pipeline Validation
func validate_pipelines():
	return subdisk_pipeline.is_valid() && overlay_pipeline.is_valid() && radial_blur_pipeline.is_valid() && gaussian_blur_pipeline.is_valid()

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT && validate_pipelines():
		# Get our render scene buffers object, this gives us access to our render buffers. 
		# Note that implementation differs per renderer hence the need for the cast.
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		var render_scene_data : RenderSceneDataRD = p_render_data.get_render_scene_data()
		if render_scene_buffers and render_scene_data:
			# Get our internal size, this is the buffer we're upscaling
			var render_size : Vector2 = render_scene_buffers.get_internal_size()
			var effect_size : Vector2 = render_size
			if effect_size.x == 0.0 and effect_size.y == 0.0:
				return

			# Render our intermediate at half size
			if half_size:
				effect_size *= 0.5;

			# If we have buffers for this viewport, check if they are the right size
			if render_scene_buffers.has_texture(context, texture):
				var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture)
				if tf.width != effect_size.x or tf.height != effect_size.y:
					# This will clear all textures for this viewport under this context
					render_scene_buffers.clear_context(context)

			if !render_scene_buffers.has_texture(context, texture):
				var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				render_scene_buffers.create_texture(context, texture, RenderingDevice.DATA_FORMAT_R16_UNORM, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, effect_size, 1, 1, true)
				render_scene_buffers.create_texture(context, pong_texture, RenderingDevice.DATA_FORMAT_R16_UNORM, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, effect_size, 1, 1, true)

			rd.draw_command_begin_label("Radial Sky Rays", Color(1.0, 1.0, 1.0, 1.0))

			# Loop through views just in case we're doing stereo rendering. No extra cost if this is mono.
			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# Get our images
				var color_image = render_scene_buffers.get_color_layer(view)
				var depth_image = render_scene_buffers.get_depth_layer(view)
				var texture_image = render_scene_buffers.get_texture_slice(context, texture, view, 0, 1, 1)
				var pong_texture_image = render_scene_buffers.get_texture_slice(context, pong_texture, view, 0, 1, 1)

				# Get some rendering info
				var projection : Projection = render_scene_data.get_view_projection(view)
				var view_matrix : Transform3D = render_scene_data.get_cam_transform().inverse()
				var eye_offset = render_scene_data.get_view_eye_offset(view)

				# We don't have access to our light (yet) so we get our sun direction as an export
				var sun_dist = 10000.0
				var adj_sun_loc = view_matrix * Vector3(sun_location.x * sun_dist, sun_location.y * sun_dist, sun_location.z * sun_dist)
				var sun_proj : Vector4 = projection * Vector4(adj_sun_loc.x, adj_sun_loc.y, adj_sun_loc.z, 1.0)
				var sun_pos : Vector2 = Vector2(sun_proj.x / sun_proj.w, -sun_proj.y / sun_proj.w)
				sun_pos.x += eye_offset.x
				sun_pos.y += eye_offset.y

				if sun_proj.z < 0:
					##############################################################
					# Step 1: Render our sundisk

					var uniform = get_sampler_uniform(depth_image)
					var depth_uniform_set = UniformSetCacheRD.get_cache(sundisk_shader, 0, [ uniform ])

					uniform = get_image_uniform(texture_image)
					var texture_uniform_set = UniformSetCacheRD.get_cache(sundisk_shader, 1, [ uniform ])

					# We don't have structures (yet) so we need to build our push constant
					# "the hard way"...
					var push_constant : PackedFloat32Array = PackedFloat32Array()
					push_constant.push_back(render_size.x)
					push_constant.push_back(render_size.y)
					push_constant.push_back(effect_size.x)
					push_constant.push_back(effect_size.y)
					push_constant.push_back(sun_pos.x)
					push_constant.push_back(sun_pos.y)
					push_constant.push_back(sun_size * (0.5 if half_size else 1.0))
					push_constant.push_back(sun_fade_size * (0.5 if half_size else 1.0))

					rd.draw_command_begin_label("Render sundisk " + str(view), Color(1.0, 1.0, 1.0, 1.0))

					# Run our compute shader
					var x_groups = (effect_size.x - 1) / 8 + 1
					var y_groups = (effect_size.y - 1) / 8 + 1

					var compute_list := rd.compute_list_begin()
					rd.compute_list_bind_compute_pipeline(compute_list, subdisk_pipeline)
					rd.compute_list_bind_uniform_set(compute_list, depth_uniform_set, 0)
					rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 1)
					rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
					rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
					rd.compute_list_end()

					rd.draw_command_end_label()

					##############################################################
					# Step 2: Apply radial blur

					uniform = get_image_uniform(texture_image)
					texture_uniform_set = UniformSetCacheRD.get_cache(radial_blur_shader, 0, [ uniform ])

					uniform = get_image_uniform(pong_texture_image)
					var pong_texture_uniform_set = UniformSetCacheRD.get_cache(radial_blur_shader, 1, [ uniform ])

					var center = Vector2(sun_pos.x * 0.5 + 0.5, 1.0 - (sun_pos.y * 0.5 + 0.5))
					center *= effect_size

					# Update push constant
					push_constant = PackedFloat32Array()
					push_constant.push_back(effect_size.x)
					push_constant.push_back(effect_size.y)
					push_constant.push_back(center.x)
					push_constant.push_back(center.y)
					push_constant.push_back(radial_blur_samples)
					push_constant.push_back(radial_blur_radius * (0.5 if half_size else 1.0))
					push_constant.push_back(radial_blur_effect_amount)
					push_constant.push_back(0.0)

					rd.draw_command_begin_label("Apply radial blur " + str(view), Color(1.0, 1.0, 1.0, 1.0))

					compute_list = rd.compute_list_begin()
					rd.compute_list_bind_compute_pipeline(compute_list, radial_blur_pipeline)
					rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 0)
					rd.compute_list_bind_uniform_set(compute_list, pong_texture_uniform_set, 1)
					rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
					rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
					rd.compute_list_end()

					rd.draw_command_end_label()

					# Swap so we know our pong image is our end result
					var swap = texture_image
					texture_image = pong_texture_image
					pong_texture_image = swap

					##############################################################
					# Step 3: Apply gaussian blur

					uniform = get_image_uniform(texture_image)
					texture_uniform_set = UniformSetCacheRD.get_cache(gaussian_blur_shader, 0, [ uniform ])

					uniform = get_image_uniform(pong_texture_image)
					pong_texture_uniform_set = UniformSetCacheRD.get_cache(gaussian_blur_shader, 1, [ uniform ])

					# Horizontal first

					# Update push constant
					push_constant = PackedFloat32Array()
					push_constant.push_back(effect_size.x)
					push_constant.push_back(effect_size.y)
					push_constant.push_back(gaussian_blur_size)
					push_constant.push_back(0.0)

					rd.draw_command_begin_label("Apply horizontal gaussian blur " + str(view), Color(1.0, 1.0, 1.0, 1.0))

					compute_list = rd.compute_list_begin()
					rd.compute_list_bind_compute_pipeline(compute_list, gaussian_blur_pipeline)
					rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 0)
					rd.compute_list_bind_uniform_set(compute_list, pong_texture_uniform_set, 1)
					rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
					rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
					rd.compute_list_end()

					rd.draw_command_end_label()

					# And vertical
					push_constant = PackedFloat32Array()
					push_constant.push_back(effect_size.x)
					push_constant.push_back(effect_size.y)
					push_constant.push_back(0.0)
					push_constant.push_back(gaussian_blur_size)

					rd.draw_command_begin_label("Apply vertical gaussian blur " + str(view), Color(1.0, 1.0, 1.0, 1.0))

					compute_list = rd.compute_list_begin()
					rd.compute_list_bind_compute_pipeline(compute_list, gaussian_blur_pipeline)
					rd.compute_list_bind_uniform_set(compute_list, pong_texture_uniform_set, 0)
					rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 1)
					rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
					rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
					rd.compute_list_end()

					rd.draw_command_end_label()

					##############################################################
					# Step 4: Overlay

					rd.draw_command_begin_label("Overlay result " + str(view), Color(1.0, 1.0, 1.0, 1.0))

					uniform = get_sampler_uniform(texture_image)
					texture_uniform_set = UniformSetCacheRD.get_cache(overlay_shader, 0, [ uniform ])

					uniform = get_image_uniform(color_image)
					var color_uniform_set = UniformSetCacheRD.get_cache(overlay_shader, 1, [ uniform ])

					# Update push constant
					push_constant = PackedFloat32Array()
					push_constant.push_back(render_size.x)
					push_constant.push_back(render_size.y)
					push_constant.push_back(0.0)
					push_constant.push_back(0.0)

					# Run our compute shader
					x_groups = (render_size.x - 1) / 8 + 1
					y_groups = (render_size.y - 1) / 8 + 1

					compute_list = rd.compute_list_begin()
					rd.compute_list_bind_compute_pipeline(compute_list, overlay_pipeline)
					rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 0)
					rd.compute_list_bind_uniform_set(compute_list, color_uniform_set, 1)
					rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
					rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
					rd.compute_list_end()

					rd.draw_command_end_label()

			rd.draw_command_end_label()
