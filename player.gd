class_name Player
extends CharacterBody3D

@export_group("Movement")
@export var walk_speed: float = 6.0
@export var crouch_speed: float = 4.0
@export var jump_velocity: float = 4.0
@export var lerp_speed: float = 16.0

@export_group("Camera & Control")
@export var mouse_sensitivity: float = 0.003
@export var capture_mouse_on_start: bool = true
@export var stand_height: float = 1.5
@export var crouch_height: float = 0.8
@export var freecam_speed: float = 12.0

var keys: Array[Color] = []
var _pitch: float = 0.0
var _yaw: float = 0.0
var crouching: bool = false
var is_freecam: bool = false

@onready var camera: Camera3D = $Camera
@onready var marker: Node3D = $Camera/ObjectiveMarker

var objectives: Array[Vector3] = []

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

	if event.is_action_pressed("camera_mode"):
		is_freecam = not is_freecam
		if not is_freecam:
			# Reset camera transform local to player body when returning
			camera.transform = Transform3D.IDENTITY
			camera.position.y = crouch_height if crouching else stand_height

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if is_freecam:
			# Rotate camera independently in 3D world space
			camera.rotate_y(-event.relative.x * mouse_sensitivity)
			camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)
		else:
			_yaw -= event.relative.x * mouse_sensitivity
			_pitch -= event.relative.y * mouse_sensitivity
			_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))

			rotation = Vector3(0.0, _yaw, 0.0)
			camera.rotation = Vector3(_pitch, 0.0, 0.0)

func _physics_process(delta: float) -> void:
	if is_freecam:
		_process_freecam(delta)
		_update_objective_marker()
		return

	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	if Input.is_action_just_pressed("crouch"):
		crouching = not crouching
		if crouching:
			$CollisionShape.shape.height /= 2
			$CollisionShape.position.y /= 2
		else:
			$CollisionShape.shape.height *= 2
			$CollisionShape.position.y *= 2

	var current_speed = crouch_speed if crouching else walk_speed
	var target_cam_y = crouch_height if crouching else stand_height
	
	camera.position.y = lerp(camera.position.y, target_cam_y, delta * lerp_speed)

	var input_dir = Input.get_vector("move_left", "move_right", "move_forwards", "move_backwards")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
	else:
		velocity.x = move_toward(velocity.x, 0, current_speed)
		velocity.z = move_toward(velocity.z, 0, current_speed)

	move_and_slide()
	_update_objective_marker()

func _process_freecam(delta: float) -> void:
	var input_dir = Input.get_vector("move_left", "move_right", "move_forwards", "move_backwards")
	var up_down := 0.0
	if Input.is_action_pressed("ui_accept"):
		up_down += 1.0
	if Input.is_action_pressed("crouch"):
		up_down -= 1.0

	var move_dir = (camera.global_transform.basis * Vector3(input_dir.x, up_down, input_dir.y)).normalized()
	camera.global_position += move_dir * freecam_speed * delta

func _update_objective_marker() -> void:
	if not marker or objectives.is_empty():
		if marker:
			marker.visible = false
		return

	marker.visible = true
	
	var target_pos: Vector3 = objectives[0]
	if not marker.global_position.is_equal_approx(target_pos):
		marker.look_at(target_pos, Vector3.UP)
