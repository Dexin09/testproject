class_name Door
extends Area3D
@export var key_colour: Color

func _on_body_entered(body: Node3D) -> void:
	if body is Player and key_colour in body.keys:
		open(body)

func open(player):
	player.objectives.pop_front()
	queue_free()
