extends GLTFDocumentExtension

const vrm_constants_class = preload("../vrm_constants.gd")
const vrm_meta_class = preload("../vrm_meta.gd")
const vrm_secondary = preload("../vrm_secondary.gd")
const vrm_top_level = preload("../vrm_toplevel.gd")

const vrm_spring_bone = preload("../vrm_spring_bone.gd")
const vrm_collider_group = preload("../vrm_collider_group.gd")
const vrm_collider = preload("../vrm_collider.gd")

func _get_skel_godot_node(gstate: GLTFState, nodes: Array, skeletons: Array, skel_id: int) -> Node:
	# There's no working direct way to convert from skeleton_id to node_id.
	# Bugs:
	# GLTFNode.parent is -1 if skeleton bone.
	# skeleton_to_node is empty
	# get_scene_node(skeleton bone) works though might maybe return an attachment.
	# var skel_node_idx = nodes[gltfskel.roots[0]]
	# return gstate.get_scene_node(skel_node_idx) # as Skeleton
	for i in range(nodes.size()):
		if nodes[i].skeleton == skel_id:
			return gstate.get_scene_node(i)
	return null

func _parse_secondary_node(secondary_node: Node, vrm_extension: Dictionary, gstate: GLTFState) -> void:
	var nodes = gstate.get_nodes()
	var skeletons = gstate.get_skeletons()

	var colliders: Array[vrm_collider]
	var collider_groups: Array[vrm_collider_group]

	for collider_gltf in vrm_extension.get("colliders", []):
		var gltfnode: GLTFNode = nodes[int(collider_gltf["node"])]
		var collider = vrm_collider.new()
		var pose_diff: Basis = Basis()
		if gltfnode.skeleton == -1:
			var found_node: Node = gstate.get_scene_node(int(collider_gltf["node"]))
			collider.skeleton_or_node = secondary_node.get_path_to(found_node)
			collider.bone = ""
			collider.resource_name = found_node.name
		else:
			var skeleton: Skeleton3D = _get_skel_godot_node(gstate, nodes, skeletons, gltfnode.skeleton)
			if skeleton.has_meta("vrm_pose_diffs"):
				# FIXME: We haven't decided yet which format is better
				if typeof(skeleton.get_meta("vrm_pose_diffs")) == TYPE_DICTIONARY:
					pose_diff = skeleton.get_meta("vrm_pose_diffs")[collider.bone]
				else: # array by bone idx.
					pose_diff = skeleton.get_meta("vrm_pose_diffs")[skeleton.find_bone(collider.bone)]
			collider.skeleton_or_node = secondary_node.get_path_to(skeleton)
			collider.bone = nodes[int(collider_gltf["node"])].resource_name
			collider.resource_name = collider.bone
		
		if collider_gltf.has("name"):
			collider.resource_name = collider_gltf["name"]
		
		var collider_shape = collider_gltf["shape"]
		var is_capsule = false
		var radius: float
		var offset_gltf: Array = [0.0,0.0,0.0]
		var tail_gltf: Array = [0.0,0.0,0.0]
		if collider_shape.has("sphere"):
			radius = collider_shape["sphere"]["radius"]
			offset_gltf = collider_shape["sphere"]["offset"]
			tail_gltf = offset_gltf
		if collider_shape.has("capsule"):
			is_capsule = true
			radius = collider_shape["capsule"]["radius"]
			offset_gltf = collider_shape["capsule"]["offset"]
			tail_gltf = collider_shape["capsule"]["tail"]
		var offset: Vector3 = Vector3(offset_gltf[0], offset_gltf[1], offset_gltf[2])
		var tail: Vector3 = Vector3(tail_gltf[0], tail_gltf[1], tail_gltf[2])
		var local_pos: Vector3 = pose_diff * offset
		var local_tail_pos: Vector3 = pose_diff * tail
		collider.offset = local_pos
		collider.tail = local_tail_pos
		collider.radius = radius
		collider.is_capsule = is_capsule
		colliders.append(collider)

	for cgroup in vrm_extension.get("colliderGroups", []):
		var collider_group: vrm_collider_group = vrm_collider_group.new()
		collider_group.colliders.clear()

		for collider_node in cgroup["colliders"]:
			collider_group.colliders.append(colliders[collider_node])
		collider_groups.append(collider_group)

	var spring_bones: Array = [].duplicate()
	for sbone in vrm_extension.get("springs", []):
		if sbone.get("joints", []).size() == 0:
			continue
		var first_joint: Dictionary = sbone["joints"][0]
		var first_bone_node: int = first_joint["node"]
		var gltfnode: GLTFNode = nodes[int(first_bone_node)]
		var skeleton: Skeleton3D = _get_skel_godot_node(gstate, nodes, skeletons, gltfnode.skeleton)

		var spring_bone: vrm_spring_bone = vrm_spring_bone.new()
		spring_bone.skeleton = secondary_node.get_path_to(skeleton)
		spring_bone.comment = sbone.get("name", "")
		for sjoint in sbone["joints"]:
			spring_bone.hit_radius.append(float(sbone.get("hitRadius", 0.0)))
			spring_bone.stiffness_force.append(float(sbone.get("stiffiness", 1.0)))
			spring_bone.gravity_power.append(float(sbone.get("gravityPower", 0.0)))
			var gravity_dir = sbone.get("gravityDir", [0.0, -1.0, 0.0])
			spring_bone.gravity_dir.append(Vector3(gravity_dir[0], gravity_dir[1], gravity_dir[2]))
			spring_bone.drag_force.append(float(sbone.get("dragForce", 0.5)))

			var bone_node: int = sjoint["node"]
			var bone_name: String = nodes[int(bone_node)].resource_name
			if skeleton.find_bone(bone_name) == -1:
				# Note that we make an assumption that a given SpringBone object is
				# only part of a single Skeleton*. This error might print if a given
				# SpringBone references bones from multiple Skeleton's.
				printerr("Failed to find node " + str(bone_node) + " in skel " + str(skeleton))
			else:
				spring_bone.joint_nodes.append(bone_name)

		if not spring_bone.comment.is_empty():
			spring_bone.resource_name = spring_bone.comment.split("\n")[0]
		else:
			spring_bone.resource_name = nodes[int(first_bone_node)].resource_name

		spring_bone.collider_groups = [].duplicate()  # HACK HACK HACK
		for cgroup_idx in sbone.get("colliderGroups", []):
			spring_bone.collider_groups.append(collider_groups[int(cgroup_idx)])

		# Center commonly points outside of the glTF Skeleton, such as the root node.
		spring_bone.center_node = secondary_node.get_path_to(secondary_node)
		spring_bone.center_bone = ""
		var center_node_idx = sbone.get("center", -1)
		if center_node_idx != -1:
			var center_gltfnode: GLTFNode = nodes[int(center_node_idx)]
			var bone_name: String = center_gltfnode.resource_name
			if center_gltfnode.skeleton == gltfnode.skeleton and skeleton.find_bone(bone_name) != -1:
				spring_bone.center_bone = bone_name
				spring_bone.center_node = NodePath()
			else:
				spring_bone.center_bone = ""
				spring_bone.center_node = (secondary_node.get_path_to(gstate.get_scene_node(int(center_node_idx))))
				if spring_bone.center_node == NodePath():
					printerr("Failed to find center scene node " + str(center_node_idx))
					spring_bone.center_node = secondary_node.get_path_to(secondary_node)  # Fallback

		spring_bones.append(spring_bone)

	secondary_node.set_script(vrm_secondary)
	secondary_node.set("spring_bones", spring_bones)
	secondary_node.set("collider_groups", collider_groups)


func _add_joints_recursive(new_joints_set: Dictionary, gltf_nodes: Array, bone: int, include_child_meshes: bool = false) -> void:
	if bone < 0:
		return
	var gltf_node: Dictionary = gltf_nodes[bone]
	if not include_child_meshes and gltf_node.get("mesh", -1) != -1:
		return
	new_joints_set[bone] = true
	for child_node in gltf_node.get("children", []):
		if not new_joints_set.has(child_node):
			_add_joints_recursive(new_joints_set, gltf_nodes, int(child_node))


func _add_joint_set_as_skin(obj: Dictionary, new_joints_set: Dictionary) -> void:
	var new_joints = [].duplicate()
	for node in new_joints_set:
		new_joints.push_back(node)
	new_joints.sort()

	var new_skin: Dictionary = {"joints": new_joints}

	if not obj.has("skins"):
		obj["skins"] = [].duplicate()

	obj["skins"].push_back(new_skin)


func _add_vrm_nodes_to_skin(obj: Dictionary) -> bool:
	var vrm_extension: Dictionary = obj.get("extensions", {}).get("VRMC_springBone", {})
	var new_joints_set = {}.duplicate()

	for bone_group in vrm_extension.get("springs", []):
		for joint in bone_group["joints"]:
			_add_joints_recursive(new_joints_set, obj["nodes"], joint["node"], true)

	for collider_group in vrm_extension.get("colliders", []):
		if int(collider_group["node"]) >= 0:
			new_joints_set[int(collider_group["node"])] = true

	_add_joint_set_as_skin(obj, new_joints_set)

	return true


func _import_preflight(state: GLTFState, extensions = PackedStringArray()) -> Error:
	if not extensions.has("VRMC_springBone"):
		return ERR_INVALID_DATA
	var gltf_json_parsed: Dictionary = state.json
	if not _add_vrm_nodes_to_skin(gltf_json_parsed):
		push_error("Failed to find required VRMC_springBone extension properties in json")
		return ERR_INVALID_DATA
	return OK


# Called when the node enters the scene tree for the first time.
func _import_post(state: GLTFState, root_node: Node):
	var gltf_json: Dictionary = state.json
	var vrm_extension: Dictionary = gltf_json["extensions"]["VRMC_springBone"]
	var secondary_node: Node
	if root_node.has_node("secondary"):
		secondary_node = root_node.get_node("secondary")
	else:
		secondary_node = Node3D.new()
		root_node.add_child(secondary_node, true)
		secondary_node.set_owner(root_node)
		secondary_node.set_name("secondary")

	var secondary_path: NodePath = root_node.get_path_to(secondary_node)
	root_node.set("vrm_secondary", secondary_path)

	_parse_secondary_node(secondary_node, vrm_extension, state)
	return OK

func _export_preflight(state: GLTFState, root: Node):
	if not root.has_node("secondary"):
		print("No secondary node")
		return ERR_INVALID_DATA
	var secondary = root.get_node("secondary")
	if secondary.get_script() != vrm_secondary:
		print("Incorrect secondary node script")
		return ERR_INVALID_DATA
	state.add_used_extension("VRMC_springBone", false)
	state.set_additional_data("VRMC_springBone", secondary)
	#secondary_node.set_script(vrm_secondary)
	#secondary_node.set("spring_bones", spring_bones)
	#secondary_node.set("collider_groups", collider_groups)
	return OK

static func _get_humanoid_skel(root_node: Node3D) -> Skeleton3D:
	var humanoid_skeleton: Skeleton3D
	if root_node.has_node("%GeneralSkeleton"):
		humanoid_skeleton = root_node.get_node("%GeneralSkeleton")
	else:
		var skels: Array[Node] = root_node.find_children("*", "Skeleton3D", true)
		if not skels.is_empty():
			humanoid_skeleton = skels[0]
	return humanoid_skeleton

func _export_post(state: GLTFState):
	var secondary: vrm_secondary = state.get_additional_data("VRMC_springBone")
	var collider_groups: Array = secondary.collider_groups
	var spring_bones: Array = secondary.spring_bones

	var unique_colliders: Dictionary = {}
	var colliders: Array[vrm_collider] = []
	for current_group in collider_groups:
		for collider in current_group.colliders:
			if collider not in unique_colliders:
				unique_colliders[collider] = len(colliders)
				colliders.push_back(collider)

	var json: Dictionary = state.json
	var sbone_extension: Dictionary = {}
	if not json.has("extensions"):
		json["extensions"] = {}
	json["extensions"]["VRMC_springBone"] = sbone_extension
	var humanoid_skeleton: Skeleton3D = _get_humanoid_skel(secondary.get_parent())

	var skel_to_godot_bone_to_gltf_node_map: Dictionary
	for skel in state.skeletons:
		skel_to_godot_bone_to_gltf_node_map[skel.get_godot_skeleton()] = skel.get_godot_bone_node()
	var godot_node_to_idx: Dictionary = {}
	for i in range(len(json["nodes"])):
		godot_node_to_idx[state.get_scene_node(i)] = i
	godot_node_to_idx[secondary.get_parent()] = godot_node_to_idx[secondary]

	var json_colliders: Array = []
	for collider in colliders:
		var shape: Dictionary = {}
		if collider.is_capsule:
			shape = {"capsule": {
				"offset": [collider.offset.x, collider.offset.y, collider.offset.z],
				"radius": collider.radius,
				"tail": [collider.tail.x, collider.tail.y, collider.tail.z],
			}}
		else:
			shape = {"sphere": {
				"offset": [collider.offset.x, collider.offset.y, collider.offset.z],
				"radius": collider.radius,
			}}
		var node_ref: Node = secondary.get_node(collider.skeleton_or_node)
		var node_idx: int
		if collider.bone != "":
			print(skel_to_godot_bone_to_gltf_node_map[node_ref].keys())
			print("LOoking up " + str(collider.bone))
			node_idx = skel_to_godot_bone_to_gltf_node_map[node_ref][collider.bone]
		else:
			# FIXME: This case should perhaps no longer be supported.
			node_idx = godot_node_to_idx[node_ref]
		json_colliders.push_back({"node": node_idx, "shape": shape})
	sbone_extension["colliders"] = json_colliders

	var json_collider_groups: Array = []
	var collider_group_indices: Dictionary = {}
	for current_group in collider_groups:
		var json_collider_list: Array = []
		for collider in current_group.colliders:
			json_collider_list.push_back(unique_colliders[collider])
		var json_collider_group: Dictionary = {}
		json_collider_group["colliders"] = json_collider_list
		if current_group.resource_name != "":
			json_collider_group["name"] = current_group.resource_name
		collider_group_indices[current_group] = len(json_collider_groups)
		json_collider_groups.push_back(json_collider_group)
	sbone_extension["colliderGroups"] = json_collider_groups

	var json_springs: Array = []
	for springbone in spring_bones:
		var spring: Dictionary = {}
		var skeleton_node: Skeleton3D = secondary.get_node(springbone.skeleton)
		if springbone.resource_name != "":
			spring["name"] = springbone.resource_name
		if springbone.center_node == NodePath():
			spring["center"] = skel_to_godot_bone_to_gltf_node_map[skeleton_node][springbone.center_bone]
		else:
			spring["center"] = godot_node_to_idx[secondary.get_node(springbone.center_node)]
		var spring_groups: Array = []
		for collider_group in springbone.collider_groups:
			spring_groups.push_back(collider_group_indices[collider_group])
		spring["colliderGroups"] = spring_groups
		var joints: Array = []
		for i in range(len(springbone.joints)):
			var joint: Dictionary = {}
			joint["node"] = skel_to_godot_bone_to_gltf_node_map[skeleton_node][springbone.joint_nodes[i]]
			joint["hitRadius"] = springbone.hit_radius[i]
			joint["stiffness"] = springbone.stiffness_force[i]
			joint["gravityPower"] = springbone.gravity_power[i]
			var grav: Vector3 = springbone.gravity_dir[i]
			joint["gravityDir"] = [grav[0], grav[1], grav[2]]
			joint["dragForce"] = springbone.drag_force[i]
			joints.push_back(joint)
		spring["joints"] = joints
		json_springs.push_back(spring)
	sbone_extension["springs"] = json_springs
