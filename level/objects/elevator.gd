class_name Elevator
extends Area3D
@export var key_colour: Color

func _on_body_entered(body: Node3D) -> void:
	if body is Player and key_colour in body.keys:
		open()

func open():
	get_tree().quit()
