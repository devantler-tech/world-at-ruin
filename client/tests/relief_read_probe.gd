extends "res://tools/relief_read.gd"
## Test double for the rendered crop only. Camera ownership and frame settling
## remain the production implementation under test.


func _ready() -> void:
	pass


func _crop_luma() -> PackedFloat32Array:
	return PackedFloat32Array([0.25])
