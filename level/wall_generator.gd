class_name WallGenerator
extends Node3D

@export_group("GridMaps")
@export var floor_gridmap: GridMap
@export var wall_gridmap: GridMap
@export var roof_gridmap: GridMap ## Optional: Target for roofs. If empty, pastes roofs directly into floor_gridmap.

@export_group("Tiles")
@export var WALL_ITEM_ID: int = 51
@export var CORNER_ITEM_ID: int = 11
@export var INNER_CORNER_ITEM_ID: int = 11 # Set to a separate ID if inner corners require a flipped mesh
@export var CROSS_ITEM_ID: int = 31         # Cross/X wall tile for diagonal intersections
@export var slope_item_ids: Array[int] = [] ## Add slope/ramp Tile IDs here. Walls will leave openings for them.

@export_group("Rotations")
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_horizontal: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_vertical: int = 180

@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_left: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_right: int = 0
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_right: int = 270
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_left: int = 180

@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_1: int = 0 
@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_2: int = 90

var floor_cells: Dictionary = {}


func run() -> void:
	if floor_gridmap:
		var cell_size := floor_gridmap.cell_size
		if wall_gridmap:
			wall_gridmap.position = floor_gridmap.position - Vector3(cell_size.x * 0.5, 0, cell_size.z * 0.5)
		if roof_gridmap:
			roof_gridmap.position = floor_gridmap.position # Roofs share exact cell alignment with floors

	create_floors()
	create_walls()
	create_roofs()


func create_floors() -> void:
	floor_cells.clear()
	if floor_gridmap:
		for cell in floor_gridmap.get_used_cells():
			floor_cells[cell] = {
				"item": floor_gridmap.get_cell_item(cell),
				"orientation": floor_gridmap.get_cell_item_orientation(cell)
			}


func create_walls() -> void:
	if not wall_gridmap or floor_cells.is_empty():
		return
		
	wall_gridmap.clear()

	# Collect Y-levels and their respective 2D X/Z bounds
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

	# Generate walls for each floor level independently
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
		var roof_pos := cell + Vector3i(0, 1, 0)
		
		# Can't overwrite existing floors
		if not floor_cells.has(roof_pos):
			var data: Dictionary = floor_cells[cell]
			target_map.set_cell_item(roof_pos, data["item"], data["orientation"])


func _has_floor(x: int, y: int, z: int) -> bool:
	var pos := Vector3i(x, y, z)
	if floor_cells.has(pos):
		return true
		
	# Slope accommodation: if the cell directly above or below is a slope, 
	# treat this level as continuous so we don't spawn a blocking wall across the ramp.
	var below := Vector3i(x, y - 1, z)
	if floor_cells.has(below) and floor_cells[below]["item"] in slope_item_ids:
		return true
		
	var above := Vector3i(x, y + 1, z)
	if floor_cells.has(above) and floor_cells[above]["item"] in slope_item_ids:
		return true

	return false


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
