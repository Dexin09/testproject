class_name LayoutGenerator
extends Node3D

@export var floor_gridmap: GridMap
@export var wall_generator: WallGenerator
@export var player: Player
@export var camera: Node

@export_group("Floor Item Setup")
@export var hub_floor_item_id: int = 0
@export var spoke_floor_item_id: int = 1
@export var elevator_floor_item_id: int = 2
@export var slope_floor_item_id: int = 3
@export var vent_floor_item_id: int = 4

@export_group("Sector Sizes")
@export var hub_size: Vector2i = Vector2i(16, 16)
@export var spoke_depth: int = 8
@export var min_spokes: int = 4
@export_range(0.0, 1.0) var fill_density: float = 0.5
@export_range(0.0, 1.0) var vent_density: float = 0.05

@export_group("Tree Walker Tuning")
@export var deadend_chance: float = 0.2
@export var dir_change_chance: float = 0.4
@export var max_room_width: int = 2
@export var backtrack_depth: int = 16

const CARDINAL_DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const SLOPE_RESERVED_REGION: int = -999
const VENT_RESERVED_REGION: int = -998

# Packed Scenes
const PLAYER_SCENE: PackedScene = preload("res://player.tscn")
const DOOR_SCENE: PackedScene = preload("res://level/objects/door.tscn")
const ELEVATOR_SCENE: PackedScene = preload("res://level/objects/elevator.tscn")
const KEY_SCENE: PackedScene = preload("res://level/objects/key.tscn")

# Color palette for assigning key/door matching colors
const KEY_COLORS: Array[Color] = [
	Color.RED,
	Color.GREEN,
	Color.BLUE,
	Color.YELLOW,
	Color.MAGENTA,
	Color.CYAN,
	Color.ORANGE,
	Color.PURPLE
]

var committed_cells: Dictionary = {}
var trail: Array[Step] = []
var placed_doors: Array[DoorData] = []
var placed_keys: Array[KeyData] = []
var dead_ends_by_region: Dictionary = {}
var hub_bounds: Rect2i
var spoke_slots: Array[Dictionary] = []
var elevator_pos: Vector2i
var slope_placed: bool = false
var spawned_nodes: Array[Node] = []

class Step:
	var pos: Vector2i; var dir: Vector2i; var width: int; var region_id: int; var level_y: int; var cells: Array[Vector2i]
	func _init(p: Vector2i, d: Vector2i, w: int, r: int, cl: Array[Vector2i], y: int = 0) -> void:
		pos = p; dir = d; width = w; region_id = r; cells = cl; level_y = y

class DoorData:
	var pos: Vector3i; var key_index: int; var dir: Vector2i; var target_region: int
	func _init(p: Vector3i, idx: int, d: Vector2i = Vector2i.ZERO, region: int = 0) -> void: 
		pos = p; key_index = idx; dir = d; target_region = region

class KeyData:
	var pos: Vector3i; var key_index: int; var region_id: int
	func _init(p: Vector3i, idx: int, r_id: int = 0) -> void: 
		pos = p; key_index = idx; region_id = r_id


func _ready() -> void:
	_calculate_cross_bounds()
	generate_tree_walker_layout()

	if camera:
		var hub_center: Vector2i = hub_bounds.get_center()
		var center_world: Vector3 = _map_to_world(_to_3d(hub_center))
		camera.position = Vector3(center_world.x, camera.position.y, center_world.z)

	if wall_generator and wall_generator.has_method("run"):
		wall_generator.run()


func _calculate_cross_bounds() -> void:
	var hub_origin: Vector2i = Vector2i(spoke_depth + 1, spoke_depth + 1)
	hub_bounds = Rect2i(hub_origin, hub_size)
	spoke_slots.clear()

	for level_y in [0, -1]:
		for dir in CARDINAL_DIRS:
			var is_vert: bool = (dir.y != 0)
			var pos: Vector2i = Vector2i(
				hub_bounds.position.x if is_vert else (hub_origin.x - 1 - spoke_depth if dir == Vector2i.LEFT else hub_bounds.end.x + 1),
				hub_origin.y - 1 - spoke_depth if dir == Vector2i.UP else (hub_bounds.end.y + 1 if is_vert else hub_bounds.position.y)
			)
			var size: Vector2i = Vector2i(hub_size.x, spoke_depth) if is_vert else Vector2i(spoke_depth, hub_size.y)
			var seam: Array = [hub_bounds.position.x, hub_bounds.end.x] if is_vert else [hub_bounds.position.y, hub_bounds.end.y]
			spoke_slots.append({"dir": dir, "level_y": level_y, "bounds": Rect2i(pos, size), "seam_range": seam})


func generate_tree_walker_layout() -> void:
	if not floor_gridmap: return
	_clear_state()

	elevator_pos = hub_bounds.get_center()
	_set_floor_tile(elevator_pos, 0, 0, elevator_floor_item_id)
	_generate_hub(hub_bounds)

	var available_slots: Array = spoke_slots.filter(func(s): return slope_placed or s["level_y"] == 0)
	var active_slots: Array = available_slots.filter(func(_s): return randf() < 0.5)
	if active_slots.size() < min_spokes:
		var inactive: Array = available_slots.filter(func(s): return not active_slots.has(s))
		inactive.shuffle()
		active_slots.append_array(inactive.slice(0, min_spokes - active_slots.size()))

	var region_id: int = 1
	for slot in active_slots:
		var dir: Vector2i = slot["dir"]
		var rect: Rect2i = slot["bounds"]
		var target: int = int(rect.size.x * rect.size.y * fill_density)
		var door_3d: Vector3i = _connect_spoke_door(slot, region_id)
		var door_2d: Vector2i = Vector2i(door_3d.x, door_3d.z)

		_generate_sector(rect, region_id, spoke_floor_item_id, target, door_2d + dir, dir, door_3d.y, [door_2d])
		region_id += 1

	_assign_keys_and_doors_sequentially(active_slots.size())
	_spawn_level_entities()


func _generate_hub(bounds: Rect2i) -> void:
	var target: int = int(bounds.size.x * bounds.size.y * fill_density)
	dead_ends_by_region.get_or_add(0, [])

	var start_cells: Array[Vector2i] = [elevator_pos + Vector2i.UP]
	if _is_step_valid(start_cells, [elevator_pos], bounds, 0):
		_push_step(Step.new(start_cells[0], Vector2i.UP, 1, 0, start_cells, 0), hub_floor_item_id)

	_fill_walker(bounds, 0, hub_floor_item_id, 0, target)
	slope_placed = _try_place_hub_slope(bounds, 0) or _force_place_hub_slope(bounds, hub_floor_item_id)
	_fill_walker(bounds, 0, hub_floor_item_id, -1, target)

	var vent_target: int = int(target * 2 * vent_density)
	_try_place_vents(bounds, 0, vent_target / 2, 0)
	_try_place_vents(bounds, 0, vent_target / 2, -1)


func _generate_sector(bounds: Rect2i, region_id: int, floor_id: int, target_tiles: int, start_pos: Vector2i, start_dir: Vector2i, level_y: int, origin_cells: Array[Vector2i] = []) -> void:
	trail.clear()
	dead_ends_by_region.get_or_add(region_id, [])
	var start_cells: Array[Vector2i] = _get_step_cells(start_pos, start_dir, 1)
	if not _is_step_valid(start_cells, origin_cells, bounds, level_y): return
	_push_step(Step.new(start_pos, start_dir, 1, region_id, start_cells, level_y), floor_id)

	_fill_walker(bounds, region_id, floor_id, level_y, target_tiles)
	_try_place_vents(bounds, region_id, int(target_tiles * vent_density), level_y)


func _fill_walker(bounds: Rect2i, region_id: int, floor_id: int, level_y: int, target: int) -> void:
	var count_start: int = committed_cells.size()
	var iters: int = 0
	while (committed_cells.size() - count_start) < target and iters < 15000:
		iters += 1
		if not _step_walker(bounds, region_id, floor_id, level_y): break
	_mark_current_dead_end()


func _step_walker(bounds: Rect2i, region_id: int, floor_id: int, level_y: int) -> bool:
	if trail.is_empty() or (trail.size() > 1 and randf() < deadend_chance):
		return _reset_and_branch(region_id, bounds, floor_id, level_y)

	var current: Step = trail.back()
	var next_dir: Vector2i = _get_perp_dirs(current.dir).pick_random() if randf() < dir_change_chance else current.dir
	var next_pos: Vector2i = current.pos + next_dir
	var target_cells: Array[Vector2i] = _get_step_cells(next_pos, next_dir, current.width)

	if _is_step_valid(target_cells, current.cells, bounds, level_y):
		_push_step(Step.new(next_pos, next_dir, current.width, region_id, target_cells, level_y), floor_id)
		return true

	if _try_perpendicular_turn_at_step(current, bounds, floor_id, level_y): return true

	for _i in range(min(backtrack_depth, trail.size() - 1)):
		trail.pop_back()
		if _try_perpendicular_turn_at_step(trail.back(), bounds, floor_id, level_y): return true

	return _reset_and_branch(region_id, bounds, floor_id, level_y)


func _try_place_hub_slope(bounds: Rect2i, level_y: int) -> bool:
	for i in range(trail.size() - 1, -1, -1):
		for dir in CARDINAL_DIRS:
			if _attempt_slope_at(trail[i].pos, dir, bounds, level_y): return true

	var candidates: Array[Vector2i] = []
	for c in committed_cells:
		if committed_cells[c] == 0 and c.y == level_y: candidates.append(Vector2i(c.x, c.z))
	candidates.shuffle()

	for pos in candidates:
		for dir in CARDINAL_DIRS:
			if _attempt_slope_at(pos, dir, bounds, level_y): return true
	return false


func _attempt_slope_at(entry_pos: Vector2i, dir: Vector2i, bounds: Rect2i, level_y: int) -> bool:
	var top_pos: Vector2i = entry_pos + dir
	var bot_pos: Vector2i = top_pos + dir
	var exit_pos: Vector2i = bot_pos + dir

	for p in [entry_pos, top_pos, bot_pos, exit_pos]:
		if not bounds.has_point(p) or _is_too_close_to_seam(p, bounds, 1) or p == elevator_pos: return false

	for p in [top_pos, bot_pos]:
		if committed_cells.has(_to_3d(p, level_y)) or committed_cells.has(_to_3d(p, level_y - 1)): return false
	if committed_cells.has(_to_3d(exit_pos, level_y - 1)): return false

	_commit_slope(entry_pos, dir, hub_floor_item_id)
	return true


func _force_place_hub_slope(bounds: Rect2i, floor_id: int) -> bool:
	for x in range(bounds.position.x + 2, bounds.end.x - 2):
		for y in range(bounds.position.y + 2, bounds.end.y - 2):
			var entry: Vector2i = Vector2i(x, y)
			if entry == elevator_pos: continue
			for dir in CARDINAL_DIRS:
				var exit: Vector2i = entry + dir * 3
				if exit == elevator_pos or not bounds.has_point(exit) or _is_too_close_to_seam(exit, bounds, 1): continue
				if not committed_cells.has(_to_3d(entry, 0)):
					_carve_path(_find_closest_cell_in_region(entry, 0, 0), entry, 0, floor_id, 0)
				_commit_slope(entry, dir, floor_id)
				return true
	return true


func _commit_slope(entry_pos: Vector2i, dir: Vector2i, floor_id: int) -> void:
	var top_pos: Vector2i = entry_pos + dir
	var bot_pos: Vector2i = top_pos + dir
	var exit_pos: Vector2i = bot_pos + dir

	_set_floor_tile(entry_pos, 0, 0, floor_id)
	_set_floor_tile(top_pos, 0, SLOPE_RESERVED_REGION, slope_floor_item_id, _dir_to_orientation(dir, -PI / 2.0))

	for p in [top_pos, bot_pos]:
		committed_cells[_to_3d(p, 0)] = SLOPE_RESERVED_REGION
		committed_cells[_to_3d(p, -1)] = SLOPE_RESERVED_REGION

	_set_floor_tile(exit_pos, -1, 0, floor_id)
	trail.clear()
	_push_step(Step.new(exit_pos, dir, 1, 0, [exit_pos], -1), floor_id)


func _try_place_vents(bounds: Rect2i, region_id: int, vent_count: int, level_y: int) -> void:
	if vent_count <= 0: return
	var candidates: Array[Vector2i] = []
	for x in range(bounds.position.x, bounds.end.x):
		for y in range(bounds.position.y, bounds.end.y):
			var pos: Vector2i = Vector2i(x, y)
			if not committed_cells.has(_to_3d(pos, level_y)): candidates.append(pos)
	candidates.shuffle()

	var placed: int = 0
	for pos in candidates:
		if placed >= vent_count: break
		var vent_rot: int = _get_vent_orientation(pos, region_id, level_y)
		if vent_rot != -1:
			_set_floor_tile(pos, level_y, VENT_RESERVED_REGION, vent_floor_item_id, vent_rot)
			placed += 1


func _get_vent_orientation(pos: Vector2i, region_id: int, level_y: int) -> int:
	if committed_cells.has(_to_3d(pos, level_y)): return -1
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if (dx != 0 or dy != 0) and _is_special_tile(pos + Vector2i(dx, dy), level_y): return -1

	var u_fl: bool = _is_normal_floor_tile(pos + Vector2i.UP, level_y, region_id)
	var d_fl: bool = _is_normal_floor_tile(pos + Vector2i.DOWN, level_y, region_id)
	var l_fl: bool = _is_normal_floor_tile(pos + Vector2i.LEFT, level_y, region_id)
	var r_fl: bool = _is_normal_floor_tile(pos + Vector2i.RIGHT, level_y, region_id)

	var u_emp: bool = not committed_cells.has(_to_3d(pos + Vector2i.UP, level_y))
	var d_emp: bool = not committed_cells.has(_to_3d(pos + Vector2i.DOWN, level_y))
	var l_emp: bool = not committed_cells.has(_to_3d(pos + Vector2i.LEFT, level_y))
	var r_emp: bool = not committed_cells.has(_to_3d(pos + Vector2i.RIGHT, level_y))

	if u_fl and d_fl and l_emp and r_emp: return _dir_to_orientation(Vector2i.RIGHT)
	if l_fl and r_fl and u_emp and d_emp: return _dir_to_orientation(Vector2i.UP)
	return -1


func _is_special_tile(pos: Vector2i, level_y: int) -> bool:
	var pos_3d: Vector3i = _to_3d(pos, level_y)
	if level_y == 0 and pos == elevator_pos: return true
	var region: int = committed_cells.get(pos_3d, -1)
	if region == SLOPE_RESERVED_REGION or region == VENT_RESERVED_REGION: return true
	for door in placed_doors:
		if door.pos == pos_3d: return true
	return false


func _is_normal_floor_tile(pos: Vector2i, level_y: int, region_id: int) -> bool:
	return committed_cells.get(_to_3d(pos, level_y), -1) == region_id and not _is_special_tile(pos, level_y)


func _reset_and_branch(region_id: int, bounds: Rect2i, floor_id: int, level_y: int) -> bool:
	_mark_current_dead_end()
	trail.clear()
	return _start_new_branch(region_id, bounds, floor_id, level_y)


func _is_too_close_to_seam(pos: Vector2i, bounds: Rect2i, margin: int = 1) -> bool:
	return pos.x < bounds.position.x + margin or pos.x >= bounds.end.x - margin \
		or pos.y < bounds.position.y + margin or pos.y >= bounds.end.y - margin


func _connect_spoke_door(slot: Dictionary, region_id: int) -> Vector3i:
	var dir: Vector2i = slot["dir"]
	var level_y: int = slot["level_y"]
	var valid_candidates: Array[Vector3i] = []

	for p in _get_seam_positions(slot):
		if committed_cells.get(_to_3d(p - dir, level_y), -1) == 0:
			valid_candidates.append(_to_3d(p, level_y))

	var chosen: Vector3i
	if not valid_candidates.is_empty():
		chosen = valid_candidates.pick_random()
	else:
		var seam_positions: Array[Vector2i] = _get_seam_positions(slot)
		var mid_pos: Vector2i = seam_positions[seam_positions.size() / 2]
		chosen = _to_3d(mid_pos, level_y)
		var hub_side: Vector2i = Vector2i(chosen.x, chosen.z) - dir
		_carve_path(_find_closest_cell_in_region(hub_side, 0, level_y), hub_side, 0, hub_floor_item_id, level_y)

	_set_floor_tile(Vector2i(chosen.x, chosen.z), chosen.y, region_id, spoke_floor_item_id)
	# Key index and assignment are handled sequentially after sector generation
	placed_doors.append(DoorData.new(chosen, -1, dir, region_id))
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
		if not bounds.has_point(cell) or committed_cells.has(_to_3d(cell, level_y)): return false

	var allowed: Dictionary = {}
	for c in origin_cells: allowed[c] = true
	for step in trail.slice(-min(2, trail.size())):
		for c in step.cells: allowed[c] = true

	var origin_neighbors: Dictionary = {}
	for ac in allowed:
		for dx in range(-1, 2):
			for dy in range(-1, 2): origin_neighbors[ac + Vector2i(dx, dy)] = true

	for cell in target_cells:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n: Vector2i = cell + Vector2i(dx, dy)
				var neighbor_3d: Vector3i = _to_3d(n, level_y)
				if committed_cells.has(neighbor_3d):
					if committed_cells[neighbor_3d] == SLOPE_RESERVED_REGION or (not allowed.has(n) and not origin_neighbors.has(n)):
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
		if curr.x != to_cell.x: curr.x += signi(to_cell.x - curr.x)
		elif curr.y != to_cell.y: curr.y += signi(to_cell.y - curr.y)
		_set_floor_tile(curr, level_y, region_id, floor_id)

func _assign_keys_and_doors_sequentially(active_spoke_count: int) -> void:
	placed_keys.clear()
	
	# Shuffle spoke region order to create a unique level sequence each run
	var region_chain: Array[int] = []
	for r in range(1, active_spoke_count + 1):
		region_chain.append(r)
	region_chain.shuffle()

	# Region Sequence: Hub (Region 0) -> Chain[0] -> Chain[1] -> ... -> Chain[N-1]
	var progression_regions: Array[int] = [0]
	progression_regions.append_array(region_chain)

	# Assign doors to lock each next region in the progression chain
	for i in range(progression_regions.size() - 1):
		var target_region: int = progression_regions[i + 1]
		var key_index: int = i # Unique Key/Door Pair ID
		
		for door in placed_doors:
			if door.target_region == target_region:
				door.key_index = key_index
				break

		# Place Key inside current region to unlock Door entering the next region
		var source_region: int = progression_regions[i]
		var key_cell: Vector3i = _get_random_cell_in_region(source_region)
		placed_keys.append(KeyData.new(key_cell, key_index, source_region))

	# Final Key inside the last spoke region (used to activate the exit/elevator)
	var final_region: int = progression_regions.back()
	var final_key_cell: Vector3i = _get_random_cell_in_region(final_region)
	placed_keys.append(KeyData.new(final_key_cell, progression_regions.size() - 1, final_region))


func _spawn_level_entities() -> void:
	var created_player: Player = player
	var elevator_world_pos: Vector3 = Vector3.ZERO

	# 1. Spawn Elevator
	if ELEVATOR_SCENE:
		var elevator_instance: Node3D = ELEVATOR_SCENE.instantiate() as Node3D
		if elevator_instance:
			add_child(elevator_instance)
			elevator_world_pos = _map_to_world(_to_3d(elevator_pos, 0))
			elevator_instance.global_position = elevator_world_pos
			spawned_nodes.append(elevator_instance)

	# 2. Spawn Player adjacent to Elevator
	if PLAYER_SCENE:
		var player_instance: Node3D = PLAYER_SCENE.instantiate() as Node3D
		if player_instance:
			add_child(player_instance)
			var spawn_cell: Vector3i = _to_3d(elevator_pos + Vector2i.UP, 0)
			player_instance.global_position = _map_to_world(spawn_cell)
			spawned_nodes.append(player_instance)
			if player_instance is Player:
				created_player = player_instance as Player

	# 3. Clear existing objectives on target player reference
	if created_player and "objectives" in created_player:
		created_player.objectives.clear()

	# Sort keys and doors by index to build sequential objective list
	var sorted_keys: Array[KeyData] = placed_keys.duplicate()
	sorted_keys.sort_custom(func(a, b): return a.key_index < b.key_index)

	var sorted_doors: Array[DoorData] = placed_doors.duplicate()
	sorted_doors.sort_custom(func(a, b): return a.key_index < b.key_index)

	# 4. Spawn Keys & Register Objectives
	if KEY_SCENE:
		for key_data in sorted_keys:
			var key_instance: Node3D = KEY_SCENE.instantiate() as Node3D
			if key_instance:
				add_child(key_instance)
				var key_pos: Vector3 = _map_to_world(key_data.pos) + Vector3(0.0, 1.0, 0.0)
				key_instance.global_position = key_pos
				
				var key_color: Color = KEY_COLORS[key_data.key_index % KEY_COLORS.size()]
				_apply_color_to_node(key_instance, key_color)
				spawned_nodes.append(key_instance)

				# Push key position objective to player
				if created_player and "objectives" in created_player:
					created_player.objectives.append(key_pos)

			# Push corresponding door position objective right after the key (if door exists)
			var matching_doors: Array = sorted_doors.filter(func(d): return d.key_index == key_data.key_index)
			if not matching_doors.is_empty() and created_player and "objectives" in created_player:
				var door_world_pos: Vector3 = _map_to_world(matching_doors[0].pos)
				created_player.objectives.append(door_world_pos)

	# 5. Add Final Objective: Return to Elevator
	if created_player and "objectives" in created_player:
		created_player.objectives.append(elevator_world_pos)

	# 6. Spawn Doors
	if DOOR_SCENE:
		for door_data in placed_doors:
			var door_instance: Node3D = DOOR_SCENE.instantiate() as Node3D
			if door_instance:
				add_child(door_instance)
				door_instance.global_position = _map_to_world(door_data.pos)
				
				# Orient door to match corridor layout
				var angle: float = Vector3.FORWARD.signed_angle_to(Vector3(door_data.dir.x, 0.0, door_data.dir.y), Vector3.UP)
				door_instance.rotation.y = angle

				# Color door and apply material tint
				if door_data.key_index >= 0:
					var key_color: Color = KEY_COLORS[door_data.key_index % KEY_COLORS.size()]
					_apply_color_to_node(door_instance, key_color)
				spawned_nodes.append(door_instance)
				
				
func _get_random_cell_in_region(region_id: int) -> Vector3i:
	var dead_ends: Array = dead_ends_by_region.get(region_id, [])
	if not dead_ends.is_empty():
		var chosen: Vector3i = dead_ends.pick_random()
		dead_ends.erase(chosen)
		return chosen

	var fallback_cells: Array[Vector3i] = []
	for cell: Vector3i in committed_cells:
		if committed_cells[cell] == region_id:
			fallback_cells.append(cell)

	if not fallback_cells.is_empty():
		return fallback_cells.pick_random()

	return _to_3d(elevator_pos, 0)


func _apply_color_to_node(target: Node3D, color: Color) -> void:
	target.set("key_colour", color)
	
	# Recursively assign color to mesh materials if exported property isn't auto-applied by node
	var meshes: Array[Node] = target.find_children("*", "MeshInstance3D")
	for mesh_node in meshes:
		var mesh_inst: MeshInstance3D = mesh_node as MeshInstance3D
		if mesh_inst:
			var mat: StandardMaterial3D = mesh_inst.get_surface_override_material(0) as StandardMaterial3D
			if not mat:
				mat = StandardMaterial3D.new()
				mesh_inst.set_surface_override_material(0, mat)
			mat.albedo_color = color


func _map_to_world(map_pos: Vector3i) -> Vector3:
	if floor_gridmap:
		return floor_gridmap.map_to_local(map_pos)
	return Vector3(map_pos.x * 2.0, map_pos.y * 2.0, map_pos.z * 2.0)


func _mark_current_dead_end() -> void:
	if not trail.is_empty():
		var last_step: Step = trail.back()
		var list: Array = dead_ends_by_region.get_or_add(last_step.region_id, [])
		var pos_3d: Vector3i = _to_3d(last_step.pos, last_step.level_y)
		if not list.has(pos_3d): list.append(pos_3d)


func _push_step(step: Step, floor_id: int) -> void:
	trail.append(step)
	for cell in step.cells: _set_floor_tile(cell, step.level_y, step.region_id, floor_id)


func _set_floor_tile(cell: Vector2i, level_y: int, region_id: int, floor_id: int, orientation: int = 0) -> void:
	var cell_3d: Vector3i = _to_3d(cell, level_y)
	committed_cells[cell_3d] = region_id
	floor_gridmap.set_cell_item(cell_3d, floor_id, orientation)


func _get_step_cells(center: Vector2i, dir: Vector2i, width: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	for i in width: cells.append(center + perp * (i - (width - 1) / 2))
	return cells


func _get_perp_dirs(dir: Vector2i) -> Array[Vector2i]:
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	return [perp, -perp]


func _dir_to_orientation(dir: Vector2i, angle_offset: float = 0.0) -> int:
	if not floor_gridmap: return 0
	var target_fwd: Vector3 = Vector3(dir.x, 0, dir.y)
	var angle: float = Vector3.FORWARD.signed_angle_to(target_fwd, Vector3.UP) + angle_offset
	return floor_gridmap.get_orthogonal_index_from_basis(Basis(Vector3.UP, angle))


func _to_3d(pos: Vector2i, y: int = 0) -> Vector3i:
	return Vector3i(pos.x, y, pos.y)


func _clear_state() -> void:
	floor_gridmap.clear()
	committed_cells.clear()
	dead_ends_by_region.clear()
	placed_doors.clear()
	placed_keys.clear()
	trail.clear()
	slope_placed = false
	elevator_pos = Vector2i.MIN

	for node in spawned_nodes:
		if is_instance_valid(node):
			node.queue_free()
	spawned_nodes.clear()
