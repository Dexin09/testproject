class_name WallGenerator
extends Node

@export_group("GridMaps")
@export var floor_gridmap: GridMap
@export var wall_gridmap: GridMap

@export_group("Tile IDs")
@export var WALL_ITEM_ID: int = 51
@export var CORNER_ITEM_ID: int = 11
@export var INNER_CORNER_ITEM_ID: int = 11 # Set to a separate ID if inner corners require a flipped mesh
@export var CROSS_ITEM_ID: int = 33         # Cross/X wall tile for diagonal intersections

@export_group("Straight Rotations")
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_horizontal: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var straight_vertical: int = 180

@export_group("Corner Rotations")
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_left: int = 90
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_top_right: int = 0
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_right: int = 270
@export_enum("0:0", "90:90", "180:180", "270:270") var corner_bottom_left: int = 180

@export_group("Cross Rotations")
@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_1: int = 0   # TL + BR
@export_enum("0:0", "90:90", "180:180", "270:270") var cross_diagonal_2: int = 90  # TR + BL

var floor_cells: Dictionary = {}

func _ready() -> void:
	if wall_gridmap and floor_gridmap:
		var cell_size := floor_gridmap.cell_size
		wall_gridmap.position = floor_gridmap.position - Vector3(cell_size.x * 0.5, 0, cell_size.z * 0.5)

	create_floors()
	create_walls()

func create_floors() -> void:
	floor_cells.clear()
	if floor_gridmap:
		for cell in floor_gridmap.get_used_cells():
			floor_cells[Vector2i(cell.x, cell.z)] = true

func create_walls() -> void:
	if not wall_gridmap or floor_cells.is_empty():
		return
		
	wall_gridmap.clear()

	var min_pos := Vector2i(999999, 999999)
	var max_pos := Vector2i(-999999, -999999)

	for cell in floor_cells.keys():
		min_pos.x = mini(min_pos.x, cell.x)
		min_pos.y = mini(min_pos.y, cell.y)
		max_pos.x = maxi(max_pos.x, cell.x)
		max_pos.y = maxi(max_pos.y, cell.y)

	for wx in range(min_pos.x, max_pos.x + 2):
		for wz in range(min_pos.y, max_pos.y + 2):
			_place_wall_tile_at_corner(wx, wz)

func _has_floor(x: int, z: int) -> bool:
	return floor_cells.has(Vector2i(x, z))

func _place_wall_tile_at_corner(wx: int, wz: int) -> void:
	var q_tl := 1 if _has_floor(wx - 1, wz - 1) else 0
	var q_tr := 2 if _has_floor(wx,     wz - 1) else 0
	var q_br := 4 if _has_floor(wx,     wz)     else 0
	var q_bl := 8 if _has_floor(wx - 1, wz)     else 0

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
		wall_gridmap.set_cell_item(Vector3i(wx, 0, wz), item_id, orientation)

func _get_ortho_index(deg: int) -> int:
	var basis := Basis.from_euler(Vector3(0, deg_to_rad(deg), 0))
	return wall_gridmap.get_orthogonal_index_from_basis(basis)
