@tool
extends Node3D

@onready var enabled_btn = $UI/MarginContainer/VBoxContainer/Enabled
@onready var half_size_btn = $UI/MarginContainer/VBoxContainer/HalfSize

var radial_sky_rays : RadialSkyRays

# Called when the node enters the scene tree for the first time.
func _ready():
	var compositor : Compositor = $WorldEnvironment.compositor
	for effect in compositor.compositor_effects:
		if effect is RadialSkyRays:
			radial_sky_rays = effect

	if radial_sky_rays and !Engine.is_editor_hint():
		enabled_btn.button_pressed = radial_sky_rays.enabled
		half_size_btn.button_pressed = radial_sky_rays.half_size

func _process(_delta):
	if radial_sky_rays:
		# Pointing towards our sun.
		radial_sky_rays.sun_location = $DirectionalLight3D.global_transform.basis.z

func _on_enabled_toggled(toggled_on):
	if !Engine.is_editor_hint():
		radial_sky_rays.enabled = toggled_on

func _on_half_size_toggled(toggled_on):
	if !!Engine.is_editor_hint():
		radial_sky_rays.half_size = toggled_on
