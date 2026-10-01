class_name LayoutGenerator
extends Node3D

@export var floor_gridmap: GridMap
@export var wall_generator: Node
@export var camera: Node

@export_group("Map Bounds")
@export var map_bounds: Vector2i = Vector2i(96, 64)
@export var total_floor_tiles_target: int = map_bounds.x * map_bounds.y / 3.0
@export var floor_item_id: int = 0

@export_group("Tree Walker Tuning")
@export var deadend_chance: float = 0.02
@export var dir_change_chance: float = 0.10
@export var width_change_chance: float = 0.18
@export var max_room_width: int = 8
@export var backtrack_depth: int = 16

var committed_cells: Dictionary = {}
var trail: Array[Step] = []

var placed_doors: Array[DoorData] = [] # This generates gridmap positions for doors and keys in a way that prevents softlocks, but doesn't spawn them yet.
var placed_keys: Array[KeyData] = []
var dead_ends_by_region: Dictionary = {}

var current_region: int = 0

const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT
]

class Step:
	var pos: Vector2i
	var dir: Vector2i
	var width: int
	var region_id: int
	var cells: Array[Vector2i]

	func _init(p: Vector2i, d: Vector2i, w: int, r: int, cl: Array[Vector2i]) -> void:
		pos = p
		dir = d
		width = w
		region_id = r
		cells = cl

class DoorData:
	var pos: Vector2i
	var key_index: int

	func _init(p: Vector2i, idx: int) -> void:
		pos = p
		key_index = idx

class KeyData:
	var pos: Vector2i
	var key_index: int

	func _init(p: Vector2i, idx: int) -> void:
		pos = p
		key_index = idx

func _ready() -> void:
	generate_tree_walker_layout()
	if camera:
		camera.position = Vector3(map_bounds.x, 0.0, map_bounds.y)
	if wall_generator and wall_generator.has_method("run"):
		wall_generator.run()

func generate_tree_walker_layout() -> void:
	if not floor_gridmap:
		return

	floor_gridmap.clear()
	committed_cells.clear()
	trail.clear()
	placed_doors.clear()
	placed_keys.clear()
	dead_ends_by_region.clear()
	current_region = 0

	_start_new_branch()

	var iterations: int = 0
	var max_iterations: int = 25000

	while committed_cells.size() < total_floor_tiles_target and iterations < max_iterations:
		iterations += 1

		if trail.is_empty():
			if not _start_new_branch():
				break
			continue

		if trail.size() > 1 and randf() < deadend_chance:
			_mark_current_dead_end()
			trail.clear()
			if not _start_new_branch():
				break
			continue

		var current: Step = trail.back()
		var next_dir: Vector2i = current.dir
		var next_width: int = current.width
		var next_region: int = current.region_id

		var roll: float = randf()
		if roll < dir_change_chance:
			next_dir = _get_perp_dirs(current.dir).pick_random()
		elif roll < dir_change_chance + width_change_chance:
			var target_w: int = randi_range(2, max_room_width) if current.width == 1 else 1
			if current.width == 1 and target_w > 1:
				current_region += 1
				next_region = current_region
				placed_doors.append(DoorData.new(current.pos, next_region))
			next_width = target_w

		var next_pos: Vector2i = current.pos + next_dir
		var target_cells: Array[Vector2i] = _get_step_cells(next_pos, next_dir, next_width)

		if _is_step_valid(target_cells, current.cells):
			_push_step(Step.new(next_pos, next_dir, next_width, next_region, target_cells))
			continue

		if _try_perpendicular_turn_at_step(current):
			continue

		var branched: bool = false
		var steps_backtracked: int = 0

		while trail.size() > 1 and steps_backtracked < backtrack_depth:
			trail.pop_back()
			steps_backtracked += 1
			if _try_perpendicular_turn_at_step(trail.back()):
				branched = true
				break

		if not branched:
			_mark_current_dead_end()
			trail.clear()
			if not _start_new_branch():
				break

	_assign_keys_to_dead_ends()

func _assign_keys_to_dead_ends() -> void:
	for door: DoorData in placed_doors:
		var target_region: int = door.key_index
		
		# Traverse backwards through earlier regions to guarantee the key spawns before the door blocking it
		for r: int in range(target_region - 1, -1, -1):
			var dead_ends: Array = dead_ends_by_region.get(r, [])
			if not dead_ends.is_empty():
				var key_pos: Vector2i = dead_ends.pop_back()
				placed_keys.append(KeyData.new(key_pos, target_region))
				break

func _mark_current_dead_end() -> void:
	if not trail.is_empty():
		var last_step: Step = trail.back()
		var reg: int = last_step.region_id
		if not dead_ends_by_region.has(reg):
			dead_ends_by_region[reg] = []
		
		var list: Array = dead_ends_by_region[reg]
		if not list.has(last_step.pos):
			list.append(last_step.pos)

func _try_perpendicular_turn_at_step(step: Step) -> bool:
	var perp_dirs: Array[Vector2i] = _get_perp_dirs(step.dir)
	perp_dirs.shuffle()

	var widths: Array[int] = [1]
	if step.width > 1:
		widths.push_front(step.width)

	for p_dir: Vector2i in perp_dirs:
		for w: int in widths:
			var test_pos: Vector2i = step.pos + p_dir
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, p_dir, w)
			if _is_step_valid(test_cells, step.cells):
				_push_step(Step.new(test_pos, p_dir, w, step.region_id, test_cells))
				return true
	return false

func _is_step_valid(target_cells: Array[Vector2i], origin_cells: Array[Vector2i] = []) -> bool:
	for cell: Vector2i in target_cells:
		if cell.x <= 2 or cell.x >= map_bounds.x - 2 or cell.y <= 2 or cell.y >= map_bounds.y - 2:
			return false
		if committed_cells.has(cell):
			return false

	var allowed: Dictionary = {}
	var origin_neighbors: Dictionary = {}

	for c: Vector2i in origin_cells:
		allowed[c] = true

	var recent_count: int = min(2, trail.size())
	for i: int in range(trail.size() - recent_count, trail.size()):
		for c: Vector2i in trail[i].cells:
			allowed[c] = true

	# Allow immediate neighbors of recent trail steps so sharp turns do not trigger false self-collisions
	for allowed_cell: Vector2i in allowed.keys():
		for dx: int in range(-1, 2):
			for dy: int in range(-1, 2):
				origin_neighbors[allowed_cell + Vector2i(dx, dy)] = true

	for c: Vector2i in target_cells:
		allowed[c] = true

	for cell: Vector2i in target_cells:
		for dx: int in range(-1, 2):
			for dy: int in range(-1, 2):
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not allowed.has(neighbor) and not origin_neighbors.has(neighbor) and committed_cells.has(neighbor):
					return false

	return true

func _start_new_branch() -> bool:
	if committed_cells.is_empty():
		var start_pos: Vector2i = map_bounds / 2
		var start_dir: Vector2i = CARDINAL_DIRS.pick_random()
		var start_cells: Array[Vector2i] = _get_step_cells(start_pos, start_dir, 1)
		_push_step(Step.new(start_pos, start_dir, 1, 0, start_cells))
		return true

	var keys: Array = committed_cells.keys()
	var attempts: int = min(200, keys.size())

	for _i: int in range(attempts):
		var cell: Vector2i = keys.pick_random()
		var dirs: Array[Vector2i] = CARDINAL_DIRS.duplicate()
		dirs.shuffle()

		for d: Vector2i in dirs:
			var test_pos: Vector2i = cell + d
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, d, 1)
			if _is_step_valid(test_cells, [cell]):
				var parent_region: int = committed_cells[cell]
				_push_step(Step.new(test_pos, d, 1, parent_region, test_cells))
				return true

	return false

func _push_step(step: Step) -> void:
	trail.append(step)
	for cell: Vector2i in step.cells:
		committed_cells[cell] = step.region_id
		floor_gridmap.set_cell_item(Vector3i(cell.x, 0, cell.y), floor_item_id)

func _get_step_cells(center_pos: Vector2i, dir: Vector2i, width: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	var start_offset: int = -(width - 1) / 2
	for i: int in range(width):
		cells.append(center_pos + perp * (start_offset + i))
	return cells

func _get_perp_dirs(dir: Vector2i) -> Array[Vector2i]:
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	return [perp, -perp]
