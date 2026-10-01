class_name Freecam
extends Camera3D

@export var move_speed: float = 10.0
@export var sprint_speed: float = 25.0
@export var mouse_sensitivity: float = 0.003
@export var capture_mouse_on_start: bool = true

var _pitch: float = 0.0
var _yaw: float = 0.0

func _ready() -> void:
	_pitch = rotation.x
	_yaw = rotation.y

	if capture_mouse_on_start:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))

		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	var input_2d = Input.get_vector("move_left", "move_right", "move_forwards", "move_backwards")
	var direction = (global_transform.basis * Vector3(input_2d.x, 0.0, input_2d.y)).normalized()
	var speed = move_speed #sprint_speed if Input.is_action_pressed("sprint") else move_speed

	global_position += direction * speed * delta
