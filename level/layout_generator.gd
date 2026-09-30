class_name LayoutGenerator
extends Node3D

@export var floor_gridmap: GridMap
@export var wall_generator: Node
@export var camera: Node

@export_group("Map Bounds")
@export var map_bounds: Vector2i = Vector2i(64, 64)
@export var total_floor_tiles_target: int = 1024
@export var floor_item_id: int = 0

@export_group("Tree Walker Tuning")
@export var deadend_chance: float = 0.02      # Chance to spontaneously terminate branch into a dead end
@export var t_junction_chance: float = 0.06   # Chance to connect branch on collision
@export var dir_change_chance: float = 0.14    # Chance to turn on step
@export var width_change_chance: float = 0.10  # Chance to toggle between 1 and room width
@export var max_room_width: int = 4            # Maximum room width when expanding (> 1)
@export var width_buffer_steps: int = 4        # Forced minimum steps before width can change again
@export var backtrack_depth: int = 4           # How many steps to rewind on collision failure

var committed_cells: Dictionary = {}
var active_trail: Array[Dictionary] = []

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
	active_trail.clear()

	var cardinal_dirs: Array[Vector2i] = [
		Vector2i.UP,
		Vector2i.DOWN,
		Vector2i.LEFT,
		Vector2i.RIGHT
	]

	# Start seed at center
	var start_pos: Vector2i = map_bounds / 2
	var current_pos: Vector2i = start_pos
	var current_dir: Vector2i = cardinal_dirs.pick_random()
	var current_width: int = 1
	var width_cooldown: int = width_buffer_steps

	# Seed starting footprint
	var start_cells: Array[Vector2i] = _get_step_cells(current_pos, current_dir, current_width)
	_commit_cells(start_cells)

	var iterations: int = 0
	var max_iterations: int = 35000

	while committed_cells.size() < total_floor_tiles_target and iterations < max_iterations:
		iterations += 1

		# 1. RANDOM DEADEND CHECK (Only if walker has drawn a path)
		if not active_trail.is_empty() and randf() < deadend_chance:
			_commit_active_trail()
			current_pos = _get_random_committed_floor()
			current_dir = cardinal_dirs.pick_random()
			current_width = 1
			width_cooldown = width_buffer_steps
			continue

		# 2. MUTUALLY EXCLUSIVE DIRECTION OR WIDTH CHANGE
		var roll: float = randf()
		if roll < dir_change_chance:
			current_dir = _get_perpendicular_dir(current_dir)
		elif roll < dir_change_chance + width_change_chance:
			if width_cooldown <= 0:
				if current_width == 1:
					current_width = randi_range(2, max_room_width)
				else:
					current_width = 1
				width_cooldown = width_buffer_steps

		if width_cooldown > 0:
			width_cooldown -= 1

		# 3. CALCULATE TARGET STEP FOOTPRINT
		var next_pos: Vector2i = current_pos + current_dir
		var target_cells: Array[Vector2i] = _get_step_cells(next_pos, current_dir, current_width)

		# 4. COLLISION CHECKS (Border & Committed Tree only)
		var is_border_collision: bool = not _are_cells_in_bounds(target_cells)
		var is_tree_collision: bool = false

		if not is_border_collision:
			for cell in target_cells:
				if committed_cells.has(cell):
					is_tree_collision = true
					break

		# 5. HANDLE BORDER & TREE COLLISIONS
		if is_border_collision or is_tree_collision:
			if randf() < t_junction_chance:
				if not is_border_collision:
					_render_cells(target_cells)
					active_trail.append({
						"pos": next_pos,
						"dir": current_dir,
						"width": current_width,
						"cooldown": width_cooldown,
						"cells": target_cells
					})
				_commit_active_trail()
				current_pos = _get_random_committed_floor()
				current_dir = cardinal_dirs.pick_random()
				current_width = 1
				width_cooldown = width_buffer_steps
			else:
				# REWIND TRAIL: Use active_trail purely for backtracking
				_rewind_trail(backtrack_depth)
				if active_trail.is_empty():
					current_pos = _get_random_committed_floor()
					current_dir = cardinal_dirs.pick_random()
					current_width = 1
					width_cooldown = width_buffer_steps
				else:
					var last_step: Dictionary = active_trail.back()
					current_pos = last_step.pos
					current_dir = _get_perpendicular_dir(last_step.dir)
					current_width = last_step.width
					width_cooldown = last_step.cooldown
			continue

		# 6. CLEAR PATH: Advance walker and push step to rewind history
		var step_data: Dictionary = {
			"pos": next_pos,
			"dir": current_dir,
			"width": current_width,
			"cooldown": width_cooldown,
			"cells": target_cells
		}
		active_trail.append(step_data)
		_render_cells(target_cells)
		current_pos = next_pos

	_commit_active_trail()

func _get_step_cells(center_pos: Vector2i, dir: Vector2i, width: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var perp: Vector2i = Vector2i(0, 1) if dir.x != 0 else Vector2i(1, 0)
	var start_offset: int = -floori(float(width - 1) / 2.0)

	for i in range(width):
		cells.append(center_pos + (perp * (start_offset + i)))
	return cells

func _get_perpendicular_dir(dir: Vector2i) -> Vector2i:
	if dir.x != 0:
		return [Vector2i.UP, Vector2i.DOWN].pick_random()
	return [Vector2i.LEFT, Vector2i.RIGHT].pick_random()

func _are_cells_in_bounds(cells: Array[Vector2i]) -> bool:
	for cell in cells:
		if cell.x <= 2 or cell.x >= map_bounds.x - 2 or cell.y <= 2 or cell.y >= map_bounds.y - 2:
			return false
	return true

func _get_random_committed_floor() -> Vector2i:
	if committed_cells.is_empty():
		return map_bounds / 2
	var keys: Array = committed_cells.keys()
	return keys.pick_random()

func _render_cells(cells: Array[Vector2i]) -> void:
	for pos in cells:
		floor_gridmap.set_cell_item(Vector3i(pos.x, 0, pos.y), floor_item_id)

func _commit_cells(cells: Array[Vector2i]) -> void:
	for pos in cells:
		committed_cells[pos] = true
		floor_gridmap.set_cell_item(Vector3i(pos.x, 0, pos.y), floor_item_id)

func _commit_active_trail() -> void:
	for step in active_trail:
		for cell in step.cells:
			committed_cells[cell] = true
	active_trail.clear()

func _rewind_trail(steps_to_pop: int) -> void:
	var unreferenced_cells: Array[Vector2i] = []
	
	for i in range(steps_to_pop):
		if active_trail.is_empty():
			break
		var popped_step: Dictionary = active_trail.pop_back()
		for cell in popped_step.cells:
			unreferenced_cells.append(cell)

	for cell in unreferenced_cells:
		if committed_cells.has(cell):
			continue
		
		var is_still_in_trail: bool = false
		for step in active_trail:
			if step.cells.has(cell):
				is_still_in_trail = true
				break
		
		if not is_still_in_trail:
			floor_gridmap.set_cell_item(Vector3i(cell.x, 0, cell.y), -1)
