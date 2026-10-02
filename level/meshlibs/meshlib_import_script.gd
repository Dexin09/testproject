@tool
extends EditorScenePostImport

const TEXTURES_DIR: String = "res://level/textures/source"


const LIB_1_SUFFIX: String = "_walls.meshlib"
const LIB_1_MAPPING: Dictionary = {
	# "BlenderMeshNodeName": ["texture1.png", "material2.tres"]
	"Wall": ["plastic_light.png"],
	"Corner": ["plastic_light.png"],
	"Cross": ["plastic_light.png"],
}

const LIB_2_SUFFIX: String = "_floors.meshlib"
const LIB_2_MAPPING: Dictionary = {
	"Floor": ["plastic_dark.png", "plastic_red.png", "metal_tarnished.png"],
	"Slope": ["plastic_dark.png"],
	"Vent": ["metal_tarnished.png"],
}


var _material_cache: Dictionary = {}

func _post_import(scene: Node) -> Object:
	_material_cache.clear()

	var mesh_map: Dictionary = {} # StringName/String -> MeshInstance3D
	_collect_meshes(scene, mesh_map)

	var source_base: String = get_source_file().get_basename()

	var lib1 := _build_mesh_library(mesh_map, LIB_1_MAPPING)
	var path1 := source_base + LIB_1_SUFFIX
	ResourceSaver.save(lib1, path1)
	print("Exported MeshLibrary 1 (%d items) to: %s" % [lib1.get_item_list().size(), path1])

	var lib2 := _build_mesh_library(mesh_map, LIB_2_MAPPING)
	var path2 := source_base + LIB_2_SUFFIX
	ResourceSaver.save(lib2, path2)
	print("Exported MeshLibrary 2 (%d items) to: %s" % [lib2.get_item_list().size(), path2])

	return scene


func _build_mesh_library(mesh_map: Dictionary, mapping: Dictionary) -> MeshLibrary:
	var mesh_lib := MeshLibrary.new()
	var item_id: int = 0

	for mesh_name: String in mapping:
		if not mesh_map.has(mesh_name):
			push_warning("MeshLibrary Export: Could not find mesh node '%s' in blend file." % mesh_name)
			continue

		var node: MeshInstance3D = mesh_map[mesh_name]
		if not node.mesh:
			continue

		var shape: Shape3D = node.mesh.create_trimesh_shape()
		var textures: Array = mapping[mesh_name]

		for tex_filename: String in textures:
			var tex_path: String = TEXTURES_DIR.path_join(tex_filename)
			var mat: Material = _get_or_load_material(tex_path)
			
			if not mat:
				push_warning("MeshLibrary Export: Could not load texture/material at '%s'" % tex_path)
				continue

			# Duplicate mesh and assign surface material
			var new_mesh: Mesh = node.mesh.duplicate()
			new_mesh.surface_set_material(0, mat)

			# Register in MeshLibrary
			var tex_basename: String = tex_filename.get_basename()
			var item_name: String = "%s_%s" % [mesh_name, tex_basename]

			mesh_lib.create_item(item_id)
			mesh_lib.set_item_name(item_id, item_name)
			mesh_lib.set_item_mesh(item_id, new_mesh)

			if shape:
				mesh_lib.set_item_shapes(item_id, [shape, Transform3D.IDENTITY])

			item_id += 1

	return mesh_lib


func _get_or_load_material(tex_path: String) -> Material:
	if _material_cache.has(tex_path):
		return _material_cache[tex_path]

	if not FileAccess.file_exists(tex_path):
		return null

	var mat: Material
	if tex_path.ends_with(".tres"):
		mat = load(tex_path) as Material
	else:
		var std_mat := StandardMaterial3D.new()
		std_mat.albedo_texture = load(tex_path)
		std_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat = std_mat

	if mat:
		_material_cache[tex_path] = mat

	return mat


func _collect_meshes(node: Node, result: Dictionary) -> void:
	if node is MeshInstance3D:
		result[node.name] = node
	for child in node.get_children():
		_collect_meshes(child, result)
