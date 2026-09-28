@tool
extends EditorScenePostImport

const TEXTURES_DIR: String = "res://level/textures/"

func _post_import(scene: Node) -> Object:
	# 1. Grab all texture files directly from the textures folder
	var texture_paths: Array[String] = []
	if DirAccess.dir_exists_absolute(TEXTURES_DIR):
		for file in DirAccess.get_files_at(TEXTURES_DIR):
			if (file.ends_with(".png") or file.ends_with(".tres")) and not file.ends_with(".import"):
				texture_paths.append(TEXTURES_DIR.path_join(file))

	# 2. Collect all meshes from the .blend file
	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_meshes(scene, mesh_nodes)

	# 3. Create the MeshLibrary
	var mesh_lib := MeshLibrary.new()
	var item_id: int = 0

	for node in mesh_nodes:
		if not node.mesh: 
			continue
			
		var shape: Shape3D = node.mesh.create_trimesh_shape()

		for tex_path in texture_paths:
			var tex_name: String = tex_path.get_file().get_basename()
			var new_mesh: Mesh = node.mesh.duplicate()

			# Load material or create a low-poly standard material for raw PNGs
			var mat: Material
			if tex_path.ends_with(".tres"):
				mat = load(tex_path)
			else:
				var std_mat := StandardMaterial3D.new()
				std_mat.albedo_texture = load(tex_path)
				std_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST # Pixel/low-poly look
				mat = std_mat

			new_mesh.surface_set_material(0, mat)

			# Add item to MeshLibrary
			var item_name: String = "%s_%s" % [node.name, tex_name]
			mesh_lib.create_item(item_id)
			mesh_lib.set_item_name(item_id, item_name)
			mesh_lib.set_item_mesh(item_id, new_mesh)
			
			if shape:
				mesh_lib.set_item_shapes(item_id, [shape, Transform3D.IDENTITY])

			item_id += 1

	# 4. Save walls.meshlib right next to walls.blend
	var save_path: String = get_source_file().get_basename() + ".meshlib"
	ResourceSaver.save(mesh_lib, save_path)
	print("Successfully exported MeshLibrary (%d items) to: %s" % [item_id, save_path])

	return scene


func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_meshes(child, result)
