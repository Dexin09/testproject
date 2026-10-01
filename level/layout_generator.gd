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
@export var slope_floor_item_id: int = 33

@export_group("Sector Sizes")
@export var hub_size: Vector2i = Vector2i(24, 24)
@export var spoke_depth: int = 8
@export var min_spokes: int = 2
@export var fill_density: float = 0.5

@export_group("Tree Walker Tuning")
@export var deadend_chance: float = 0.17
@export var dir_change_chance: float = 0.33
@export var max_room_width: int = 2
@export var backtrack_depth: int = 16

const CARDINAL_DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const SLOPE_RESERVED_REGION: int = -999

var committed_cells: Dictionary = {}
var trail: Array[Step] = []
var placed_doors: Array[DoorData] = []
var placed_keys: Array[KeyData] = []
var dead_ends_by_region: Dictionary = {}
var hub_bounds: Rect2i
var spoke_slots: Array[Dictionary] = []
var elevator_pos: Vector2i
var slope_placed: bool = false

class Step:
	var pos: Vector2i; var dir: Vector2i; var width: int; var region_id: int; var level_y: int; var cells: Array[Vector2i]
	func _init(p: Vector2i, d: Vector2i, w: int, r: int, cl: Array[Vector2i], y: int = 0) -> void:
		pos = p; dir = d; width = w; region_id = r; cells = cl; level_y = y

class DoorData:
	var pos: Vector3i; var key_index: int
	func _init(p: Vector3i, idx: int) -> void: pos = p; key_index = idx

class KeyData:
	var pos: Vector3i; var key_index: int
	func _init(p: Vector3i, idx: int) -> void: pos = p; key_index = idx


func _ready() -> void:
	_calculate_cross_bounds()
	generate_tree_walker_layout()

	if camera:
		var hub_center: Vector2i = hub_bounds.get_center()
		var center_world: Vector3 = floor_gridmap.map_to_local(Vector3i(hub_center.x, 0, hub_center.y)) if floor_gridmap else Vector3(hub_center.x * 2.0, 0.0, hub_center.y * 2.0)
		camera.position = Vector3(center_world.x, camera.position.y, center_world.z)

	if wall_generator and wall_generator.has_method("run"):
		wall_generator.run()


func _calculate_cross_bounds() -> void:
	var hub_origin: Vector2i = Vector2i(spoke_depth + 1, spoke_depth + 1)
	hub_bounds = Rect2i(hub_origin, hub_size)
	spoke_slots.clear()
	var half_w: int = hub_size.x / 2
	var half_h: int = hub_size.y / 2

	for dir in [Vector2i.UP, Vector2i.DOWN]:
		var y: int = hub_origin.y - 1 - spoke_depth if dir == Vector2i.UP else hub_bounds.end.y + 1
		for i in 2:
			var x0: int = hub_origin.x + i * half_w
			var x1: int = x0 + half_w if i == 0 else hub_bounds.end.x
			spoke_slots.append({"dir": dir, "bounds": Rect2i(Vector2i(x0, y), Vector2i(half_w, spoke_depth)), "seam_range": [x0, x1]})

	for dir in [Vector2i.LEFT, Vector2i.RIGHT]:
		var x: int = hub_origin.x - 1 - spoke_depth if dir == Vector2i.LEFT else hub_bounds.end.x + 1
		for i in 2:
			var y0: int = hub_origin.y + i * half_h
			var y1: int = y0 + half_h if i == 0 else hub_bounds.end.y
			spoke_slots.append({"dir": dir, "bounds": Rect2i(Vector2i(x, y0), Vector2i(spoke_depth, half_h)), "seam_range": [y0, y1]})


func generate_tree_walker_layout() -> void:
	if not floor_gridmap: return
	_clear_state()

	elevator_pos = hub_bounds.get_center()
	_set_floor_tile(elevator_pos, 0, 0, elevator_floor_item_id)

	var hub_target: int = int(hub_bounds.size.x * hub_bounds.size.y * fill_density * 2.0)
	_generate_sector(hub_bounds, 0, hub_floor_item_id, hub_target, elevator_pos + Vector2i.UP, Vector2i.UP, 0, [elevator_pos], true)

	var active_slots: Array = spoke_slots.filter(func(_s): return randf() < 0.5)
	if active_slots.size() < min_spokes:
		var inactive: Array = spoke_slots.filter(func(s): return not active_slots.has(s))
		inactive.shuffle()
		while active_slots.size() < min_spokes and not inactive.is_empty():
			active_slots.append(inactive.pop_back())

	var region_id: int = 1
	for slot in active_slots:
		var dir: Vector2i = slot["dir"]
		var rect: Rect2i = slot["bounds"]
		var target: int = int(rect.size.x * rect.size.y * fill_density)
		var door_3d: Vector3i = _connect_spoke_door(slot, region_id)
		var door_2d: Vector2i = Vector2i(door_3d.x, door_3d.z)

		_generate_sector(rect, region_id, spoke_floor_item_id, target, door_2d + dir, dir, door_3d.y, [door_2d])
		region_id += 1

	_assign_keys(active_slots.size())


func _generate_sector(bounds: Rect2i, region_id: int, floor_id: int, target_tiles: int, start_pos: Vector2i, start_dir: Vector2i, level_y: int, origin_cells: Array[Vector2i] = [], is_hub: bool = false) -> void:
	trail.clear()
	dead_ends_by_region.get_or_add(region_id, [])

	var start_cells: Array[Vector2i] = _get_step_cells(start_pos, start_dir, 1)
	if not _is_step_valid(start_cells, origin_cells, bounds, level_y): return
	_push_step(Step.new(start_pos, start_dir, 1, region_id, start_cells, level_y), floor_id)

	var initial_count: int = committed_cells.size()
	var iterations: int = 0

	while (committed_cells.size() - initial_count) < target_tiles and iterations < 25000:
		iterations += 1

		if is_hub and not slope_placed and (committed_cells.size() - initial_count) >= (target_tiles * 0.4):
			if _try_place_hub_slope(bounds, level_y):
				slope_placed = true
				level_y = -1
				continue

		if trail.is_empty() or (trail.size() > 1 and randf() < deadend_chance):
			if not _reset_and_branch(region_id, bounds, floor_id, level_y): break
			continue

		var current: Step = trail.back()
		var next_dir: Vector2i = _get_perp_dirs(current.dir).pick_random() if randf() < dir_change_chance else current.dir
		var next_pos: Vector2i = current.pos + next_dir
		var target_cells: Array[Vector2i] = _get_step_cells(next_pos, next_dir, current.width)

		if _is_step_valid(target_cells, current.cells, bounds, level_y):
			_push_step(Step.new(next_pos, next_dir, current.width, region_id, target_cells, level_y), floor_id)
			continue

		if _try_perpendicular_turn_at_step(current, bounds, floor_id, level_y): continue

		var branched: bool = false
		for _i in range(min(backtrack_depth, trail.size() - 1)):
			trail.pop_back()
			if _try_perpendicular_turn_at_step(trail.back(), bounds, floor_id, level_y):
				branched = true
				break

		if not branched and not _reset_and_branch(region_id, bounds, floor_id, level_y): break

	_mark_current_dead_end()


func _reset_and_branch(region_id: int, bounds: Rect2i, floor_id: int, level_y: int) -> bool:
	_mark_current_dead_end()
	trail.clear()
	return _start_new_branch(region_id, bounds, floor_id, level_y)


func _try_place_hub_slope(bounds: Rect2i, level_y: int) -> bool:
	if trail.is_empty(): return false
	var dir: Vector2i = trail.back().dir
	var entry_pos: Vector2i = trail.back().pos
	var top_pos: Vector2i = entry_pos + dir
	var bot_pos: Vector2i = top_pos + dir
	var exit_pos: Vector2i = bot_pos + dir

	var slope_corridor_2d: Array[Vector2i] = [top_pos, bot_pos]

	for p in [top_pos, bot_pos, exit_pos]:
		if not bounds.has_point(p) or _is_too_close_to_seam(p, bounds):
			return false

	if not _is_slope_clear(slope_corridor_2d, level_y, entry_pos):
		return false

	if not _is_slope_clear(slope_corridor_2d, level_y - 1, exit_pos):
		return false

	var slope_rot: int = _get_slope_orientation(dir)
	_set_floor_tile(top_pos, level_y, SLOPE_RESERVED_REGION, slope_floor_item_id, slope_rot)

	committed_cells[Vector3i(top_pos.x, level_y, top_pos.y)] = SLOPE_RESERVED_REGION
	committed_cells[Vector3i(bot_pos.x, level_y, bot_pos.y)] = SLOPE_RESERVED_REGION
	committed_cells[Vector3i(top_pos.x, level_y - 1, top_pos.y)] = SLOPE_RESERVED_REGION
	committed_cells[Vector3i(bot_pos.x, level_y - 1, bot_pos.y)] = SLOPE_RESERVED_REGION

	_push_step(Step.new(exit_pos, dir, 1, 0, [exit_pos], level_y - 1), hub_floor_item_id)
	return true


func _is_slope_clear(corridor_cells: Array[Vector2i], check_y: int, single_allowed_connection: Vector2i) -> bool:
	var corridor_dict: Dictionary = {}
	for c in corridor_cells:
		corridor_dict[c] = true

	for cell in corridor_cells:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var check_pos: Vector2i = cell + Vector2i(dx, dy)
				if corridor_dict.has(check_pos):
					continue
				if committed_cells.has(Vector3i(check_pos.x, check_y, check_pos.y)):
					if check_pos != single_allowed_connection:
						return false
	return true


func _is_too_close_to_seam(pos: Vector2i, bounds: Rect2i, margin: int = 2) -> bool:
	return pos.x < bounds.position.x + margin or pos.x >= bounds.end.x - margin \
		or pos.y < bounds.position.y + margin or pos.y >= bounds.end.y - margin


func _connect_spoke_door(slot: Dictionary, region_id: int) -> Vector3i:
	var dir: Vector2i = slot["dir"]
	var valid_candidates: Array[Vector3i] = []

	for p in _get_seam_positions(slot):
		for y in [0, -1]:
			if committed_cells.get(Vector3i(p.x - dir.x, y, p.y - dir.y), -1) == 0:
				valid_candidates.append(Vector3i(p.x, y, p.y))

	var fallback_pos: int = slot["seam_range"][0] + (slot["seam_range"][1] - slot["seam_range"][0]) / 2
	var chosen: Vector3i = valid_candidates.pick_random() if not valid_candidates.is_empty() else Vector3i(fallback_pos, 0, fallback_pos)

	if valid_candidates.is_empty():
		var hub_side: Vector2i = Vector2i(chosen.x, chosen.z) - dir
		_carve_path(_find_closest_cell_in_region(hub_side, 0, 0), hub_side, 0, hub_floor_item_id, 0)

	_set_floor_tile(Vector2i(chosen.x, chosen.z), chosen.y, region_id, door_floor_item_id)
	placed_doors.append(DoorData.new(chosen, region_id))
	return chosen


func _get_seam_positions(slot: Dictionary) -> Array[Vector2i]:
	var dir: Vector2i = slot["dir"]
	var is_vert: bool = (dir.y != 0)
	var fixed_c: int = (hub_bounds.position.y - 1 if dir == Vector2i.UP else hub_bounds.end.y) if is_vert else (hub_bounds.position.x - 1 if dir == Vector2i.LEFT else hub_bounds.end.x)
	var res: Array[Vector2i] = []
	for i in range(slot["seam_range"][0], slot["seam_range"][1]):
		res.append(Vector2i(i, fixed_c) if is_vert else Vector2i(fixed_c, i))
	return res


func _is_step_valid(target_cells: Array[Vector2i], origin_cells: Array[Vector2i], bounds: Rect2i, level_y: int) -> bool:
	for cell in target_cells:
		if not bounds.has_point(cell) or committed_cells.has(Vector3i(cell.x, level_y, cell.y)):
			return false

	var allowed: Dictionary = {}
	for c in origin_cells: allowed[c] = true
	for step in trail.slice(-min(2, trail.size())):
		for c in step.cells: allowed[c] = true

	var origin_neighbors: Dictionary = {}
	for ac in allowed:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				origin_neighbors[ac + Vector2i(dx, dy)] = true

	for c in target_cells: allowed[c] = true

	for cell in target_cells:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n: Vector2i = cell + Vector2i(dx, dy)
				var neighbor_3d := Vector3i(n.x, level_y, n.y)
				if committed_cells.has(neighbor_3d):
					if committed_cells[neighbor_3d] == SLOPE_RESERVED_REGION:
						return false
					if not allowed.has(n) and not origin_neighbors.has(n):
						return false
	return true


func _try_perpendicular_turn_at_step(step: Step, bounds: Rect2i, floor_id: int, level_y: int) -> bool:
	var perp_dirs: Array[Vector2i] = _get_perp_dirs(step.dir)
	perp_dirs.shuffle()
	var widths: Array = [step.width, 1] if step.width > 1 else [1]

	for p_dir in perp_dirs:
		for w in widths:
			var test_pos: Vector2i = step.pos + p_dir
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, p_dir, w)
			if _is_step_valid(test_cells, step.cells, bounds, level_y):
				_push_step(Step.new(test_pos, p_dir, w, step.region_id, test_cells, level_y), floor_id)
				return true
	return false


func _start_new_branch(region_id: int, bounds: Rect2i, floor_id: int, level_y: int) -> bool:
	var region_cells: Array[Vector2i] = []
	for c: Vector3i in committed_cells:
		if committed_cells[c] == region_id and c.y == level_y and Vector2i(c.x, c.z) != elevator_pos:
			region_cells.append(Vector2i(c.x, c.z))

	if region_cells.is_empty(): return false

	region_cells.shuffle()
	for i in range(min(200, region_cells.size())):
		var cell: Vector2i = region_cells[i]
		var dirs: Array[Vector2i] = CARDINAL_DIRS.duplicate()
		dirs.shuffle()

		for d in dirs:
			var test_pos: Vector2i = cell + d
			var test_cells: Array[Vector2i] = _get_step_cells(test_pos, d, 1)
			if _is_step_valid(test_cells, [cell], bounds, level_y):
				_push_step(Step.new(test_pos, d, 1, region_id, test_cells, level_y), floor_id)
				return true
	return false


func _find_closest_cell_in_region(target_pos: Vector2i, region_id: int, level_y: int) -> Vector2i:
	var best_cell: Vector2i = target_pos
	var min_dist: float = INF
	for c: Vector3i in committed_cells:
		if committed_cells[c] == region_id and c.y == level_y:
			var cell_2d: Vector2i = Vector2i(c.x, c.z)
			var dist: float = cell_2d.distance_squared_to(target_pos)
			if dist < min_dist:
				min_dist = dist
				best_cell = cell_2d
	return best_cell


func _carve_path(from_cell: Vector2i, to_cell: Vector2i, region_id: int, floor_id: int, level_y: int) -> void:
	var curr: Vector2i = from_cell
	_set_floor_tile(curr, level_y, region_id, floor_id)
	while curr != to_cell:
		if curr.x != to_cell.x:
			curr.x += 1 if to_cell.x > curr.x else -1
		elif curr.y != to_cell.y:
			curr.y += 1 if to_cell.y > curr.y else -1
		_set_floor_tile(curr, level_y, region_id, floor_id)


func _assign_keys(active_spoke_count: int) -> void:
	placed_keys.clear()
	var spoke_order: Array = range(1, active_spoke_count + 1)
	spoke_order.shuffle()

	var sector_chain: Array = [0] + spoke_order
	for i in range(sector_chain.size() - 1):
		var source_sector: int = sector_chain[i]
		var target_spoke: int = sector_chain[i + 1]

		var dead_ends: Array = dead_ends_by_region.get(source_sector, [])
		if not dead_ends.is_empty():
			var key_pos_3d: Vector3i = dead_ends.pick_random()
			dead_ends.erase(key_pos_3d)
			placed_keys.append(KeyData.new(key_pos_3d, target_spoke))


func _mark_current_dead_end() -> void:
	if not trail.is_empty():
		var last_step: Step = trail.back()
		var list: Array = dead_ends_by_region.get_or_add(last_step.region_id, [])
		var pos_3d: Vector3i = Vector3i(last_step.pos.x, last_step.level_y, last_step.pos.y)
		if not list.has(pos_3d): list.append(pos_3d)


func _push_step(step: Step, floor_id: int) -> void:
	trail.append(step)
	for cell in step.cells:
		_set_floor_tile(cell, step.level_y, step.region_id, floor_id)


func _set_floor_tile(cell: Vector2i, level_y: int, region_id: int, floor_id: int, orientation: int = 0) -> void:
	var cell_3d: Vector3i = Vector3i(cell.x, level_y, cell.y)
	committed_cells[cell_3d] = region_id
	floor_gridmap.set_cell_item(cell_3d, floor_id, orientation)


func _get_step_cells(center: Vector2i, dir: Vector2i, width: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	for i in width:
		cells.append(center + perp * (i - (width - 1) / 2))
	return cells


func _get_perp_dirs(dir: Vector2i) -> Array[Vector2i]:
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	return [perp, -perp]


func _get_slope_orientation(dir: Vector2i) -> int:
	var target_fwd: Vector3 = Vector3(dir.x, 0, dir.y)
	var angle: float = Vector3.FORWARD.signed_angle_to(target_fwd, Vector3.UP) - PI / 2
	var basis: Basis = Basis.from_euler(Vector3(0, angle, 0))
	return floor_gridmap.get_orthogonal_index_from_basis(basis) if floor_gridmap else 0


func _clear_state() -> void:
	floor_gridmap.clear()
	committed_cells.clear()
	dead_ends_by_region.clear()
	placed_doors.clear()
	placed_keys.clear()
	trail.clear()
	slope_placed = false
	elevator_pos = Vector2i.MIN
