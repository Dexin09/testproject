class_name LayoutGenerator
extends Node3D

@export var floor_gridmap: GridMap
@export var wall_generator: Node
@export var camera: Node

@export_group("Floor Item Setup")
@export var hub_floor_item_id: int = 11
@export var spoke_floor_item_id: int = 14
@export var door_floor_item_id: int = 14
@export var elevator_floor_item_id: int = 15

@export_group("Sector Sizes")
@export var hub_size: Vector2i = Vector2i(24, 24)
@export var spoke_depth: int = 8
@export var fill_density: float = 0.5

@export_group("Tree Walker Tuning")
@export var deadend_chance: float = 0.17
@export var dir_change_chance: float = 0.33
@export var max_room_width: int = 2
@export var backtrack_depth: int = 16

const CARDINAL_DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var committed_cells: Dictionary = {}
var trail: Array[Step] = []
var placed_doors: Array[DoorData] = []
var placed_keys: Array[KeyData] = []
var dead_ends_by_region: Dictionary = {}
var hub_bounds: Rect2i
var spoke_bounds: Dictionary = {}
var elevator_pos: Vector2i

class Step:
	var pos: Vector2i; var dir: Vector2i; var width: int; var region_id: int; var cells: Array[Vector2i]
	func _init(p: Vector2i, d: Vector2i, w: int, r: int, cl: Array[Vector2i]) -> void:
		pos = p; dir = d; width = w; region_id = r; cells = cl

class DoorData:
	var pos: Vector2i; var key_index: int
	func _init(p: Vector2i, idx: int) -> void: pos = p; key_index = idx

class KeyData:
	var pos: Vector2i; var key_index: int
	func _init(p: Vector2i, idx: int) -> void: pos = p; key_index = idx


func _ready() -> void:
	_calculate_cross_bounds()
	generate_tree_walker_layout()

	if camera:
		var hub_center: Vector2i = hub_bounds.get_center()
		var center_world: Vector3 = floor_gridmap.map_to_local(Vector3i(hub_center.x, 0, hub_center.y)) if floor_gridmap else Vector3(hub_center.x * 2.0, 0.0, hub_center.y * 2.0)
		camera.position.x = center_world.x
		camera.position.z = center_world.z

	if wall_generator and wall_generator.has_method("run"):
		wall_generator.run()


func _calculate_cross_bounds() -> void:
	var hub_origin: Vector2i = Vector2i(spoke_depth + 1, spoke_depth + 1)
	hub_bounds = Rect2i(hub_origin, hub_size)

	spoke_bounds[Vector2i.UP]    = Rect2i(Vector2i(hub_origin.x, hub_origin.y - 1 - spoke_depth), Vector2i(hub_size.x, spoke_depth))
	spoke_bounds[Vector2i.DOWN]  = Rect2i(Vector2i(hub_origin.x, hub_bounds.end.y + 1), Vector2i(hub_size.x, spoke_depth))
	spoke_bounds[Vector2i.LEFT]  = Rect2i(Vector2i(hub_origin.x - 1 - spoke_depth, hub_origin.y), Vector2i(spoke_depth, hub_size.y))
	spoke_bounds[Vector2i.RIGHT] = Rect2i(Vector2i(hub_bounds.end.x + 1, hub_origin.y), Vector2i(spoke_depth, hub_size.y))


func generate_tree_walker_layout() -> void:
	if not floor_gridmap: return
	_clear_state()

	# 1. Place Elevator at Hub Center
	elevator_pos = hub_bounds.get_center()
	_set_floor_tile(elevator_pos, 0, elevator_floor_item_id)

	# 2. Build Hub Sector starting 1 tile North (Vector2i.UP) of Elevator
	var hub_start: Vector2i = elevator_pos + Vector2i.UP
	var hub_target: int = int(hub_bounds.size.x * hub_bounds.size.y * fill_density)
	_generate_sector(hub_bounds, 0, hub_floor_item_id, hub_target, hub_start, Vector2i.UP, [elevator_pos])

	# 3. Generate Spoke Sectors & Connect Doors
	var region_id: int = 1
	for dir in CARDINAL_DIRS:
		var spoke_rect: Rect2i = spoke_bounds[dir]
		var spoke_target: int = int(spoke_rect.size.x * spoke_rect.size.y * fill_density)
		var spoke_start: Vector2i = _get_spoke_start_pos(dir)

		# Generate Spoke
		_generate_sector(spoke_rect, region_id, spoke_floor_item_id, spoke_target, spoke_start, dir)

		# Find natural door connection or fallback
		_connect_spoke_door(dir, region_id)
		region_id += 1

	_assign_keys()


func _get_spoke_start_pos(dir: Vector2i) -> Vector2i:
	if dir == Vector2i.UP:    return Vector2i(hub_bounds.position.x + hub_size.x / 2, hub_bounds.position.y - 2)
	if dir == Vector2i.DOWN:  return Vector2i(hub_bounds.position.x + hub_size.x / 2, hub_bounds.end.y + 1)
	if dir == Vector2i.LEFT:  return Vector2i(hub_bounds.position.x - 2, hub_bounds.position.y + hub_size.y / 2)
	return Vector2i(hub_bounds.end.x + 1, hub_bounds.position.y + hub_size.y / 2)


func _connect_spoke_door(dir: Vector2i, region_id: int) -> void:
	var seam_positions: Array[Vector2i] = _get_seam_positions(dir)
	var valid_candidates: Array[Vector2i] = []

	# Check for natural adjacent tile connections across the seam
	for door_pos in seam_positions:
		var hub_tile: Vector2i = door_pos - dir
		var spoke_tile: Vector2i = door_pos + dir
		if committed_cells.get(hub_tile, -1) == 0 and committed_cells.get(spoke_tile, -1) == region_id:
			valid_candidates.append(door_pos)

	var chosen_door_pos: Vector2i

	if not valid_candidates.is_empty():
		# Use a natural connection point
		chosen_door_pos = valid_candidates.pick_random()
	else:
		# Rare fallback: force a connection near center of seam
		chosen_door_pos = seam_positions[seam_positions.size() / 2]
		var hub_side: Vector2i = chosen_door_pos - dir
		var spoke_side: Vector2i = chosen_door_pos + dir

		_carve_path(_find_closest_cell_in_region(hub_side, 0), hub_side, 0, hub_floor_item_id)
		_carve_path(_find_closest_cell_in_region(spoke_side, region_id), spoke_side, region_id, spoke_floor_item_id)

	_set_floor_tile(chosen_door_pos, region_id, door_floor_item_id)
	placed_doors.append(DoorData.new(chosen_door_pos, region_id))


func _get_seam_positions(dir: Vector2i) -> Array[Vector2i]:
	var positions: Array[Vector2i] = []
	if dir == Vector2i.UP or dir == Vector2i.DOWN:
		var door_y: int = hub_bounds.position.y - 1 if dir == Vector2i.UP else hub_bounds.end.y
		for x in range(hub_bounds.position.x, hub_bounds.end.x):
			positions.append(Vector2i(x, door_y))
	else:
		var door_x: int = hub_bounds.position.x - 1 if dir == Vector2i.LEFT else hub_bounds.end.x
		for y in range(hub_bounds.position.y, hub_bounds.end.y):
			positions.append(Vector2i(door_x, y))
	return positions


func _find_closest_cell_in_region(target_pos: Vector2i, region_id: int) -> Vector2i:
	var best_cell: Vector2i = target_pos
	var min_dist: float = INF
	for cell: Vector2i in committed_cells:
		if committed_cells[cell] == region_id:
			var dist: float = cell.distance_squared_to(target_pos)
			if dist < min_dist:
				min_dist = dist
				best_cell = cell
	return best_cell


func _carve_path(from_cell: Vector2i, to_cell: Vector2i, region_id: int, floor_id: int) -> void:
	var curr: Vector2i = from_cell
	_set_floor_tile(curr, region_id, floor_id)
	while curr != to_cell:
		if curr.x != to_cell.x:
			curr.x += 1 if to_cell.x > curr.x else -1
		elif curr.y != to_cell.y:
			curr.y += 1 if to_cell.y > curr.y else -1
		_set_floor_tile(curr, region_id, floor_id)


func _generate_sector(bounds: Rect2i, region_id: int, floor_id: int, target_tiles: int, start_pos: Vector2i, start_dir: Vector2i, origin_override: Array[Vector2i] = []) -> void:
	trail.clear()
	dead_ends_by_region.get_or_add(region_id, [])

	var start_cells: Array[Vector2i] = _get_step_cells(start_pos, start_dir, 1)
	if not _is_step_valid(start_cells, origin_override, bounds): return
	_push_step(Step.new(start_pos, start_dir, 1, region_id, start_cells), floor_id)

	var initial_count: int = committed_cells.size()
	var iterations: int = 0

	while (committed_cells.size() - initial_count) < target_tiles and iterations < 25000:
		iterations += 1

		if trail.is_empty() or (trail.size() > 1 and randf() < deadend_chance):
			_mark_current_dead_end()
			trail.clear()
			if not _start_new_branch(region_id, bounds, floor_id): break
			continue

		var current: Step = trail.back()
		var next_dir: Vector2i = current.dir
		var next_width: int = current.width

		var roll: float = randf()
		if roll < dir_change_chance:
			next_dir = _get_perp_dirs(current.dir).pick_random()

		var next_pos: Vector2i = current.pos + next_dir
		var target_cells: Array[Vector2i] = _get_step_cells(next_pos, next_dir, next_width)

		if _is_step_valid(target_cells, current.cells, bounds):
			_push_step(Step.new(next_pos, next_dir, next_width, region_id, target_cells), floor_id)
			continue

		if _try_perpendicular_turn_at_step(current, bounds, floor_id): continue

		var branched: bool = false
		var backtracked: int = 0
		while trail.size() > 1 and backtracked < backtrack_depth:
			trail.pop_back()
			backtracked += 1
			if _try_perpendicular_turn_at_step(trail.back(), bounds, floor_id):
				branched = true
				break

		if not branched:
			_mark_current_dead_end()
			trail.clear()
			if not _start_new_branch(region_id, bounds, floor_id): break

	_mark_current_dead_end()


func _is_step_valid(target_cells: Array[Vector2i], origin_cells: Array[Vector2i], bounds: Rect2i) -> bool:
	for cell in target_cells:
		if not bounds.has_point(cell) or committed_cells.has(cell):
			return false

	var allowed: Dictionary = {}
	var origin_neighbors: Dictionary = {}

	for c in origin_cells: allowed[c] = true
	var recent_count: int = min(2, trail.size())
	for i in range(trail.size() - recent_count, trail.size()):
		for c in trail[i].cells: allowed[c] = true

	for allowed_cell in allowed.keys():
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				origin_neighbors[allowed_cell + Vector2i(dx, dy)] = true

	for c in target_cells: allowed[c] = true

	for cell in target_cells:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var neighbor: Vector2i = cell + Vector2i(dx, dy)
				if not allowed.has(neighbor) and not origin_neighbors.has(neighbor) and committed_cells.has(neighbor):
					return false
	return true


func _try_perpendicular_turn_at_step(step: Step, bounds: Rect2i, floor_id: int) -> bool:
	var perp_dirs: Array[Vector2i] = _get_perp_dirs(step.dir)
	perp_dirs.shuffle()
	var widths: Array = [step.width, 1] if step.width > 1 else [1]

	for p_dir in perp_dirs:
		for w in widths:
			var test_pos: Vector2i = step.pos + p_dir
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, p_dir, w)
			if _is_step_valid(test_cells, step.cells, bounds):
				_push_step(Step.new(test_pos, p_dir, w, step.region_id, test_cells), floor_id)
				return true
	return false


func _start_new_branch(region_id: int, bounds: Rect2i, floor_id: int) -> bool:
	var region_cells: Array = committed_cells.keys().filter(
		func(c): return committed_cells[c] == region_id and c != elevator_pos
	)
	if region_cells.is_empty(): return false

	region_cells.shuffle()
	for i in range(min(200, region_cells.size())):
		var cell: Vector2i = region_cells[i]
		var dirs: Array[Vector2i] = CARDINAL_DIRS.duplicate()
		dirs.shuffle()

		for d in dirs:
			var test_pos: Vector2i = cell + d
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, d, 1)
			if _is_step_valid(test_cells, [cell], bounds):
				_push_step(Step.new(test_pos, d, 1, region_id, test_cells), floor_id)
				return true
	return false


func _assign_keys() -> void:
	placed_keys.clear()

	var spoke_order: Array[int] = [1, 2, 3, 4]
	spoke_order.shuffle()

	var sector_chain: Array[int] = [0]
	sector_chain.append_array(spoke_order)

	for i in range(sector_chain.size() - 1):
		var source_sector: int = sector_chain[i]
		var target_spoke: int = sector_chain[i + 1]

		var dead_ends: Array = dead_ends_by_region.get(source_sector, [])
		if not dead_ends.is_empty():
			var key_pos: Vector2i = dead_ends.pick_random()
			dead_ends.erase(key_pos)
			placed_keys.append(KeyData.new(key_pos, target_spoke))


func _mark_current_dead_end() -> void:
	if not trail.is_empty():
		var last_step: Step = trail.back()
		var list: Array = dead_ends_by_region.get_or_add(last_step.region_id, [])
		if not list.has(last_step.pos):
			list.append(last_step.pos)


func _push_step(step: Step, floor_id: int) -> void:
	trail.append(step)
	for cell in step.cells:
		_set_floor_tile(cell, step.region_id, floor_id)


func _set_floor_tile(cell: Vector2i, region_id: int, floor_id: int) -> void:
	committed_cells[cell] = region_id
	floor_gridmap.set_cell_item(Vector3i(cell.x, 0, cell.y), floor_id)


func _get_step_cells(center_pos: Vector2i, dir: Vector2i, width: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	var start_offset: int = -(width - 1) / 2
	for i in range(width):
		cells.append(center_pos + perp * (start_offset + i))
	return cells


func _get_perp_dirs(dir: Vector2i) -> Array[Vector2i]:
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	return [perp, -perp]


func _clear_state() -> void:
	floor_gridmap.clear()
	committed_cells.clear()
	dead_ends_by_region.clear()
	placed_doors.clear()
	placed_keys.clear()
	trail.clear()
	elevator_pos = Vector2i.MIN
