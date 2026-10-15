class_name Door
extends Area3D
@export var key_colour: Color

func _on_input_event(camera: Node, event: InputEvent, event_position: Vector3, normal: Vector3, shape_idx: int) -> void:
	open() # for debug purposes only

func _on_body_entered(body: Node3D) -> void:
	if body is Player and key_colour in body.keys:
		open()

func open():
	queue_free()
