class_name WallGenerator
extends Node3D

@export_group("GridMaps")
@export var floor_gridmap: GridMap
@export var wall_gridmap: GridMap
@export var roof_gridmap: GridMap

@export_group("Tiles")
@export var WALL_ITEM_ID: int = 0
@export var CORNER_ITEM_ID: int = 1
@export var INNER_CORNER_ITEM_ID: int = 1
@export var CROSS_ITEM_ID: int = 2
@export var ROOF_ITEM_ID: int = 2
@export var slope_floor_item_id: int = 3
@export var slope_item_ids: Array[int] = []

@export_group("Roof/Ceiling Settings")
@export var inherit_floor_orientation: bool = true
@export_range(0, 23) var default_roof_orientation: int = 0

@export_group("Rotations")
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_horizontal: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_vertical: int = 180

@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_left: int = 270
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_right: int = 180
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_right: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_left: int = 0

@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_1: int = 0 
@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_2: int = 90

var floor_cells: Dictionary = {}


func run() -> void:
	if floor_gridmap:
		var cell_size := floor_gridmap.cell_size
		if wall_gridmap:
			wall_gridmap.position = floor_gridmap.position - Vector3(cell_size.x * 0.5, -0.0625, cell_size.z * 0.5)
		if roof_gridmap:
			roof_gridmap.position = floor_gridmap.position

	create_floors()
	create_walls()
	create_roofs()


func create_floors() -> void:
	floor_cells.clear()
	if not floor_gridmap:
		return

	for cell in floor_gridmap.get_used_cells():
		var item_id := floor_gridmap.get_cell_item(cell)
		var is_slope := (item_id == slope_floor_item_id) or (item_id in slope_item_ids)
		floor_cells[cell] = {
			"item": item_id,
			"orientation": floor_gridmap.get_cell_item_orientation(cell),
			"is_slope": is_slope,
			"is_virtual": false
		}

	var virtual_cells: Dictionary = {}

	for cell: Vector3i in floor_cells.keys():
		var data: Dictionary = floor_cells[cell]
		if data["is_slope"]:
			var dir_3d := _get_slope_dir(data["orientation"])

			var top_upper := cell
			var bot_upper := cell + dir_3d

			var top_lower := cell + Vector3i(0, -1, 0)
			var bot_lower := cell + dir_3d + Vector3i(0, -1, 0)

			var footprint := [top_upper, bot_upper, top_lower, bot_lower]

			for f_cell in footprint:
				if not floor_cells.has(f_cell):
					virtual_cells[f_cell] = {
						"item": -1,
						"orientation": data["orientation"],
						"is_slope": false,
						"is_virtual": true
					}

	for v_cell in virtual_cells:
		if not floor_cells.has(v_cell):
			floor_cells[v_cell] = virtual_cells[v_cell]


func create_walls() -> void:
	if not wall_gridmap or floor_cells.is_empty():
		return
		
	wall_gridmap.clear()

	var levels: Dictionary = {}

	for cell: Vector3i in floor_cells.keys():
		var y := cell.y
		if not levels.has(y):
			levels[y] = {
				"min": Vector2i(cell.x, cell.z),
				"max": Vector2i(cell.x, cell.z)
			}
		else:
			var bounds: Dictionary = levels[y]
			bounds["min"].x = mini(bounds["min"].x, cell.x)
			bounds["min"].y = mini(bounds["min"].y, cell.z)
			bounds["max"].x = maxi(bounds["max"].x, cell.x)
			bounds["max"].y = maxi(bounds["max"].y, cell.z)

	for wy in levels.keys():
		var bounds: Dictionary = levels[wy]
		var min_pos: Vector2i = bounds["min"]
		var max_pos: Vector2i = bounds["max"]

		for wx in range(min_pos.x, max_pos.x + 2):
			for wz in range(min_pos.y, max_pos.y + 2):
				_place_wall_tile_at_corner(wx, wy, wz)


func create_roofs() -> void:
	if floor_cells.is_empty():
		return
		
	var target_map: GridMap = roof_gridmap if roof_gridmap else floor_gridmap
	if not target_map:
		return
		
	if roof_gridmap:
		roof_gridmap.clear()
		
	for cell: Vector3i in floor_cells.keys():
		var data: Dictionary = floor_cells[cell]
		var roof_pos := cell + Vector3i(0, 1, 0)
		
		if not floor_cells.has(roof_pos):
			var roof_item := _get_roof_item_id(data, cell)
			if roof_item != -1:
				var orient: int = default_roof_orientation
				var is_slope_related: bool = data.get("is_slope", false) or data.get("is_virtual", false)
				if inherit_floor_orientation and data.has("orientation") and not is_slope_related:
					orient = data["orientation"]
				target_map.set_cell_item(roof_pos, roof_item, orient)


func _has_floor(x: int, y: int, z: int) -> bool:
	return floor_cells.has(Vector3i(x, y, z))


func _get_slope_dir(orientation: int) -> Vector3i:
	var gmap := wall_gridmap if wall_gridmap else floor_gridmap
	if gmap:
		var basis := gmap.get_basis_with_orthogonal_index(orientation)
		var dir := -basis.x
		return Vector3i(roundi(dir.x), 0, roundi(dir.z))
	return Vector3i(0, 0, 1)


func _get_roof_item_id(data: Dictionary, cell_pos: Vector3i = Vector3i.ZERO) -> int:
	if ROOF_ITEM_ID != -1:
		return ROOF_ITEM_ID
	var item: int = data.get("item", -1)
	if item != -1 and item != slope_floor_item_id and not item in slope_item_ids:
		return item

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var neighbor_pos := cell_pos + Vector3i(dx, 0, dz)
			if floor_cells.has(neighbor_pos):
				var n_item: int = floor_cells[neighbor_pos].get("item", -1)
				if n_item != -1 and n_item != slope_floor_item_id and not n_item in slope_item_ids:
					return n_item

	for c in floor_cells:
		var f_item: int = floor_cells[c].get("item", -1)
		if f_item != -1 and f_item != slope_floor_item_id and not f_item in slope_item_ids:
			return f_item

	return WALL_ITEM_ID


func _place_wall_tile_at_corner(wx: int, wy: int, wz: int) -> void:
	var q_tl := 1 if _has_floor(wx - 1, wy, wz - 1) else 0
	var q_tr := 2 if _has_floor(wx,     wy, wz - 1) else 0
	var q_br := 4 if _has_floor(wx,     wy, wz)     else 0
	var q_bl := 8 if _has_floor(wx - 1, wy, wz)     else 0

	var bitmask := q_tl | q_tr | q_br | q_bl
	var item_id := -1
	var angle_deg := 0

	match bitmask:
		0, 15:
			return

		# --- STRAIGHTS ---
		3, 12: 
			item_id = WALL_ITEM_ID
			angle_deg = straight_horizontal
		6, 9:  
			item_id = WALL_ITEM_ID
			angle_deg = straight_vertical

		# --- OUTER CORNERS (1 Floor) ---
		1: 
			item_id = CORNER_ITEM_ID
			angle_deg = corner_top_left
		2: 
			item_id = CORNER_ITEM_ID
			angle_deg = corner_top_right
		4: 
			item_id = CORNER_ITEM_ID
			angle_deg = corner_bottom_right
		8: 
			item_id = CORNER_ITEM_ID
			angle_deg = corner_bottom_left

		# --- INNER CORNERS (3 Floors) ---
		14: 
			item_id = INNER_CORNER_ITEM_ID
			angle_deg = corner_top_left
		13: 
			item_id = INNER_CORNER_ITEM_ID
			angle_deg = corner_top_right
		11: 
			item_id = INNER_CORNER_ITEM_ID
			angle_deg = corner_bottom_right
		7:  
			item_id = INNER_CORNER_ITEM_ID
			angle_deg = corner_bottom_left

		# --- DIAGONAL INTERSECTIONS (Cross Tile) ---
		5:  
			item_id = CROSS_ITEM_ID
			angle_deg = cross_diagonal_1
		10: 
			item_id = CROSS_ITEM_ID
			angle_deg = cross_diagonal_2

	if item_id != -1:
		var orientation := _get_ortho_index(angle_deg)
		wall_gridmap.set_cell_item(Vector3i(wx, wy, wz), item_id, orientation)


func _get_ortho_index(deg: int) -> int:
	var basis := Basis.from_euler(Vector3(0, deg_to_rad(deg), 0))
	return wall_gridmap.get_orthogonal_index_from_basis(basis)
