extends Area3D

@export var key_colour: Color

func _on_body_entered(body: Node3D) -> void:
	if body is Player:
		body.keys.append(key_colour)
		queue_free()

func _process(delta: float) -> void:
	rotate_y(delta)
