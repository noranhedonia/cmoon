from struct import pack
from os import path
import numpy as np
import bpy
import re

def encode_normal_32_bit(normal):
    """Encodes the given normal vector into the returned pair of 16-bit integers using
       an octahedral map. The input is an array of shape (..., 3), the output is a pair 
       of arrays of shape (..., )."""
    # project the sphere onto the octahedron, and then onto the xy plane
    octahedral_normal = normal[..., 0:2] / np.linalg.norm(normal, ord=1, axis=normal.ndim-1)[:, np.newaxis]
    # reflect the folds f the lower hemisphere over the diagonals
    sign_not_zero = np.where(octahedral_normal >= 0.0, 1.0, -1.0)
    octahedral_normal = np.where((normal[..., 2:3] <= 0.0).repeat(2, normal.ndim - 1), 
            (1.0 - np.abs(octahedral_normal[..., ::-1])) * sign_not_zero, octahedral_normal)
    # these constatns define a linear function concatenated with floor such that:
    #   -1.0 is represented exactly through 1,
    #    1.0 is represented exactly through 2^bit_count-1,
    #    0.0 is represented exactly through 2^(bit_count-1),
    #    floor operation effectively performs round to nearest
    bit_count = 16
    factor = float((2 ** (bit_count - 1)) - 1)
    summand = factor + 1.5
    coordinates = np.asarray(octahedral_normal * factor * summand, dtype=np.uint16)
    return coordinates[..., 0], coordinates[..., 1]

def part_1_by_2(x):
    """Given an unsigned integer number, this function inserts two zero bits between
       any two of its bits. The least-significant bit stays least significant, bits 
       beyond the 10-th are truncated away."""
    # x = ---- ---- ---- ---- ---- --98 7654 3210
    x &= 0x000003ff
    # x = ---- --98 ---- ---- ---- ---- 7654 3210
    x = (x ^ (x << 16)) & 0xff0000ff
    # x = ---- --98 ---- ---- 7654 ---- ---- 3210
    x = (x ^ (x << 8)) & 0x0300f00f
    # x = ---- --98 ---- 76-- --54 ---- 32-- --10
    x = (x ^ (x << 4)) & 0x030c30c3
    # x = ---- 9--8 --7- -6-- 5--4 --3- -2-- 1--0
    x = (x ^ (x << 2)) & 0x09249249
    return x

def get_morton_code_3d(position, bounding_box_min, bounding_box_max):
    """Given an array of shape (..., 3) and a bounding box as two arrays of shape (3, ),
       this function copmutes 30-bit morton codes for the given position within this 
       bounding box and returns them as uint32 array of shape (..., )."""
    factor = 2.0**10.0 / (bounding_box_max - bounding_box_min)
    summand = -bounding_box_min * factor
    factor = np.reshape(factor, [1] * (position.ndim - 1) + [3])
    summand = np.reshape(summand, [1] * (position.ndim - 1) + [3])
    quantized = np.asarray(np.clip(position * factor + summand, 0.0, 2.0**10.0 - 1.0), dtype=np.uint32)
    return sum([part_1_by_2(quantized[..., j]) << j for j in range(3)])

class Mesh:
    """Efficiently represents relevant data of a mesh after extracting it from a Blender mesh."""

    def __init__(self):
        """Initializes everything as empty arrays to have the list of attributes somewhere."""
        self.primitive_vertex_count = np.zeros(0, dtype=np.uint32)
        self.primitive_vertex_indices = np.zeros(0, dtype=np.uint32)
        self.primitive_material_index = np.zeros(0, dtype=np.uint32)
        self.primitive_vertex_uv = np.zeros(0, dtype=np.float32)
        self.vertex_position = np.zeros((0, 3), dtype=np.float32)
        self.vertex_normal = np.zeros((0, 3), dtype=np.float32)
        self.vertex_line_radius = np.zeros(0, dtype=np.float32)

    @staticmethod
    def from_blender_mesh(mesh, line_radius):
        """Reads the data of the given mesh and returns a Mesh object for it.
           :param mesh: A bpy.types.mesh object.
           :param line_radius: If there are no polygons, the mesh is treated as collection of lines 
                with the given radius. Pass None to fail for such meshes.
           :return: If the mesh contains no geometry or incompatible geometry, "FAILURE" is returned 
                and an explanation is printed. If the issue could be resolved by triangulating the mesh, 
                "TRIANGULATE" is returned. Otherwise the mesh is returned."""
        result = Mesh()
        # determine how many vertices there are per polygon and check if that is acceptable
        line_mode = (len(mesh.polygons) == 0)
        if line_mode and len(mesh.edges) == 0:
            print("Skipping mesh %s because it contains no polygons and no edges." % mesh.name)
            return "FAILURE"
        if line_mode and line_radius is None:
            print("Skipping mesh %s because it contains no polygons and line export is unavailable." % mesh.name)
            return "FAILURE"
        if line_mode:
            print("Treating mesh %s as collection of lines because there seem to be no polygons." % mesh.name)
            edge_count = len(mesh.edges)
            result.primitive_vertex_count = 2 * np.ones((edge_count, ), dtype=np.uint32)
            # generate a flat list of vertex indices for all primitives
            result.primitive_vertex_indices = np.asarray(
                [vertex_index for edge in mesh.edges for vertex_index in edge.vertices], dtype=np.uint32)
            if result.primitive_vertex_indices.size != 2 * edge_count:
                print("It seems that an edge in mesh %s does not have exactly two vertices. Aborting." % mesh.name)
                return "FAILURE"
            # by convention, all edges use material 0
            result.primitive_material_index = np.zeros((edge_count, ), dtype=np.uint32)
            # by convention, all texture coordinates are zero (Blender does not provide any for edges)
            result.primitive_vertex_uv = np.zeros((result.get_primitive_count() * 2, 2), dtype=np.float32)
        else:
            result.primitive_vertex_count = np.asarray([len(polygon.vertices) for polygon in mesh.polygons], dtype=np.uint32)
            if result.primitive_vertex_count.min() < 2:
                print("Skipping mesh %s because it has a polygon with only %d vertices." % (mesh.name, result.primitive_vertex_count.min()))
                return "FAILURE"
            if result.primitive_vertex_count.max() > 3:
                return "TRIANGULATE"
            # generate a flat list of vertex indices for all primitives
            result.primitive_vertex_indices = np.zeros(np.sum(result.primitive_vertex_count), dtype=np.uint32)
            mesh.polygons.foreach_get("vertices", result.primitive_vertex_indices)
            # store the material index for each primitive
            result.primitive_material_index = np.zeros(len(mesh.polygons), dtype=np.uint32)
            mesh.polygons.foreach_get("material_index", result.primitive_material_index) 
            # grab the data of the first UV layer (making up dummy data if it does not exist)
            result.primitive_vertex_uv = np.zeros(result.primitive_vertex_indices.size * 2, dtype=np.float32)
            if len(mesh.uv_layers) > 0:
                uv_data = mesh.uv_layers[0].data
                uv_data.foreach_get("uv", result.primitive_vertex_uv)
            result.primitive_vertex_uv = result.primitive_vertex_uv.reshape((result.primitive_vertex_indices.size, 2))
        # read vertex locations and normals into Numpy arrays, for lines the normal is irrelevant
        result.vertex_position = np.zeros(3 * len(mesh.vertices), dtype=np.float32)
        mesh.vertices.foreach_get("co", result.vertex_position)
        result.vertex_position = result.vertex_position.reshape((len(mesh.vertices), 3))
        result.vertex_normal = np.zeros(3 * len(mesh.vertices), dtype=np.float32)
        if not line_mode:
            mesh_vertices.foreach_get("normal", result.vertex_normal)
        else:
            result.vertex_normal[0::3] = 1.0
        result.vertex_normal = result.vertex_normal.reshape((len(mesh.vertices), 3))
        # remember the line radius
        if line_mode:
            result.vertex_line_radius = line_radius * np.ones((result.get_vertex_count(), ), dtype=np.float32)
        return result

    @staticmethod
    def merge_meshes(lhs, rhs, lhs_material_slot_remap=None, rhs_material_slot_remap=None):
        """Creates a new Mesh containing the geometry of both of the given Mesh objects.
           The slot remaps are list providing a new slot index for each old slot index."""
        result = Mesh()
        # concatenate vertex arrays
        result.vertex_position = np.vstack([lhs.vertex_position, rhs.vertex_position])
        result.vertex_normal = np.vstack([lhs.vertex_normal, rhs.vertex_normal])
        result.vertex_line_radius = np.concatenate([lhs.vertex_line_radius, rhs.vertex_line_radius])
        # concatenate primitive arrays, but with appropriate index offsets
        result.primitive_vertex_count = np.concatenate([lhs.primitive_vertex_count, rhs.primitive_vertex_count])
        result.primitive_vertex_indices = np.concatenate(
            [lhs.primitive_vertex_indices, rhs.primitive_vertex_indices + lhs.vertex_position.shape[0]])
        # remap material slots
        remap_list = [lhs_material_slot_remap, rhs_material_slot_remap]
        material_index_list = list();
        for mesh, remap in zip([lhs, rhs], remap_list):
            if remap is not None:
                material_index_list.append(np.choose(mesh.primitive_material_index, remap))
            else:
                material_index_list.append(mesh.primitive_material_index)
        result.primitive_material_index = np.concatenate(material_index_list)
        # merge UVs
        result.primitive_vertex_uv = np.vstack([lhs.primitive_vertex_uv, rhs.primitive_vertex_uv])
        return result

    def get_primitive_count(self):
        """Returns the number of primitives in this mesh. Lines, triangles and quads all count as one primitive."""
        return self.primitive_vertex_count.size

    def get_vertex_count(self):
        """Returns the number of vertices in this mesh."""
        return self.vertex_position.shape[0]

    def get_material_sub_mesh(self, material_slot_index):
        """Returns a partial copy of this Mesh containing only primitives (and vertices required for them)
           which make use of the material with the given (slot) index."""
        result = Mesh()
        # reduce the primitive lists
        mask = (self.primitive_material_index == material_slot_index)
        primitive_count = np.count_nonzero(mask)
        result.primitive_vertex_count = self.primitive_vertex_count[mask].copy()
        result.primitive_material_index = material_slot_index * np.ones((primitive_count, ), dtype=np.uint32)
        old_primitive_vertex_primitive_index = np.arange(self.get_primitive_count()).repeat(self.primitive_vertex_count)
        old_primitive_vertex_mask = mask[old_primitive_vertex_primitive_index]
        result.primitive_vertex_indices = self.primitive_vertex_indices[old_primitive_vertex_mask].copy()
        result.primitive_vertex_uv = np.zeros((result.primitive_vertex_indices.size, 2), dtype=np.float32)
        result.primitive_vertex_uv[:, 0] = self.primitive_vertex_uv[:, 0][old_primitive_vertex_mask]
        result.primitive_vertex_uv[:, 1] = self.primitive_vertex_uv[:, 1][old_primitive_vertex_mask]
        # discard unused vertices
        remaining_vertex_indices = np.unique(result.primitive_vertex_indices)
        result.vertex_position = np.zeros((remaining_vertex_indices.size, 3), dtype=np.float32)
        result.vertex_normal = np.zeros_like(result.vertex_position)
        for j in range(3):
            result.vertex_position[:, j] = self.vertex_position[:, j][remaining_vertex_indices]
            result.vertex_normal[:, j] = self.vertex_normal[:, j][remaining_vertex_indices]
        result.vertex_line_radius = np.copy(self.vertex_line_radius[remaining_vertex_indices])
        # update vertex indices
        old_index_to_new_index = np.zeros((self.vertex_position.shape[0], ), dtype=np.uint32)
        old_index_to_new_index[remaining_vertex_indices] = np.arange(remaining_vertex_indices.size)
        result.primitive_vertex_indices.flat = old_index_to_new_index[result.primitive_vertex_indices.flat]
        return result

    def transform(self, matrix_3x4):
        """Multiplies vertex data from the left by the given matrix. The last column is added to positions.
           Normals are multiplied by the inverse transpose of the 3x3 block and renormalized.
           The line radius is not scaled."""
        inverse_transpose = np.linalg.inv(matrix_3x4[:3, :3]).T
        self.vertex_position = (matrix_3x4[:3, :3] @ self.vertex_position.T).T
        for j in range(3):
            self.vertex_position[:, j] += matrix_3x4[j, 3]
        self.vertex_normal = (inverse_transpose @ self.vertex_normal.T).T
        self.vertex_normal /= np.linalg.norm(self.vertex_normal, axis=1)[:, np.newaxis]
        # flip the primitive orientation if the transform is not orientation preserving
        # we also change the primitive order hoping that nothing depends on it ;D
        if np.linalg.det(matrix_3x4[:3, :3]) < 0:
            self.primitive_vertex_count = self.primitive_vertex_count[::-1]
            self.primitive_vertex_indices = self.primitive_vertex_indices[::-1]
            self.primitive_material_index = self.primitive_material_index[::-1]
            self.primitive_vertex_uv = self.primitive_vertex_uv[::-1]

class Scene:
    """Handless all relevant objects in a Blender scene."""

    def __init__(self, scene, selection_only, add_triangulate_modifier, split_angle, line_radius):
        """Loads objects from the given scene and transforms all geometry to world space.
           :param scene: a bpy.types.scene object. 
           :param selection_only: whether all objects in the scene or only selected objects are considered.
           :param split_angle: if this is not None, an edge split modifier is added to the end of each 
                modifier stack (unless there is an edge split modifier in the stack already). The split 
                angle is set accordingly and sharp edges are split as well.
           :param line_radius: forwards to Mesh.from_blender_mesh()."""
        # get the list of potentially relevant objects
        if selection_only:
            object_list = bpy.context.selected_objects
        else:
            object_list = scene.objects
        object_list = [(np.eye(4, 4), obj) for obj in object_list]
        object_list = self.handle_instanced_collections(object_list)

        # if we decide to add a triangulate modifier, we need to attempt
        # conversion of a Blender object to a Mesh twice
        def blender_object_to_mesh(obj, first_try):
            if split_angle is not None and first_try:
                has_edge_split = len([mod for mod in obj.modifiers if isinstance(mod, bpy.types.EdgeSplitModifier)]) > 0
                if not has_edge_split:
                    edge_split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
                    if edge_split is not None:
                        print("Added an edge split modifier for object %s." % obj.name)
                        edge_split.use_edge_angle = True
                        edge_split.use_edge_sharp = True
                        edge_split.split_angle = split_angle
            # apply modifiers
            dependencies_graph = bpy.context.evaluated_depsgraph_get()
            evaluated_object = obj.evaluated_get(dependencies_graph)
            try:
                blender_mesh = evaluated_object.to_mesh()
            except RuntimeError:
                # only message if this outcome was not entirely foreseeable
                if evaluated_object.type not in ["EMPTY", "GPENCIL", "CAMERA", "LIGHT", "SPEAKER", "LIGHT_PROBE"]:
                    print("Skipping object %s since it cannot be converted to a mesh." % obj.name)
                return "FAILURE"
            if blender_mesh is None:
                return "FAILURE"
            result = Mesh.from_blender_mesh(blender_mesh, line_radius)
            blender_mesh_name = blender_mesh.name
            blender_mesh = None
            evaluated_object.to_mesh_clear()
            if result == "TRIANGULATE":
                if not add_triangulate_modifier:
                    print(("Skipping mesh %s because it has a polygon with more than three vertices. "
                           + "Consider allowing the exporter to add triangulate modifiers ;p.") % blender_mesh_name)
                    return "FAILURE"
                elif first_try:
                    print("Adding triangulate modifier for object %s." % obj.name)
                    obj.modifiers.new("Triangulate", "TRIANGULATE")
                    return "RETRY"
                else:
                    print("Mesh %s has been triangulated but it is still incompatible. Skipping it." % blender_mesh_name)
                    return "FAILURE"
            return result

        # try to create a Mesh for each of them
        self.mesh_list = list()
        for collection_to_world_space, obj in object_list:
            result = blender_object_to_mesh(obj, True)
            if result == "FAILURE":
                continue
            elif result == "RETRY":
                result = blender_object_to_mesh(obj, False)
            if result == "FAILURE":
                continue
            else:
                mesh = result
            # transform the vertex data to world space
            transform = collection_to_world_space @ np.asarray(obj.matrix_world)
            mesh.transform(transform[:3, :])
            # annotate the mesh with the materials used for the various slots
            mesh.slot_material_name = list()
            for material_slot in obj.material_slots:
                if material_slot.material is None:
                    mesh.slot_material_name.append("")
                else:
                    mesh.slot_material_name.append(material_slot.material.name)
            if len(mesh.slot_material_name) == 0:
                mesh.slot_material_name = ["no_material_assigned"]
            self.mesh_list.append(mesh)

    def handle_instanced_collections(self, object_list):
        """Given a list of pairs with 4x4 numpy collection to world space transforms and 
           bpy.types.obj, this function returns a new list of the same form that additionally 
           contains instances that should exist according to the instance_collection flag."""
        if len(object_list) == 0:
            return list()
        instanced_object_list = list()
        for collection_to_world_space, obj in object_list:
            instantiator_object_to_world_space = np.asarray(obj.matrix_world)
            instanced_collection_to_world_space = collection_to_world_space @ instantiator_object_to_world_space
            instanced_collection = obj.instance_collection
            if obj.instance_type == "COLLECTION" and instanced_collection is not None:
                for instanced_object in instanced_collection.all_objects:
                    instanced_object_list.append((instanced_collection_to_world_space, instanced_object))
        return object_list + self.handle_instanced_collections(instanced_object_list)

    def get_material_set(self):
        """Returns a frozenset with the names of all materials used in this scene."""
        material_list = list()
        for mesh in self.mesh_list:
            material_list.extend(mesh.slot_material_name)
        return frozenset(material_list)

    def get_material_sub_mesh(self, material_name):
        """Returns a single Mesh that arises from the combination of all primitives 
           in all meshes that use the material with the given name. If there are no 
           such primitives, it returns None."""
        reduced_mesh_list = list()
        for mesh in self.mesh_list:
            if material_name in mesh.slot_material_name:
                reduced_mesh_list.append(mesh.get_material_sub_mesh(mesh.slot_material_name.index(material_name)))
        if len(reduced_mesh_list) == 0:
            return None
        # merge them all together
        merged_mesh = reduced_mesh_list[0]
        for rhs_mesh in reduced_mesh_list[1:]:
            merged_mesh = Mesh.merge_meshes(merged_mesh, rhs_mesh)
        if merged_mesh.get_primitive_count() > 0:
            return merged_mesh
        else:
            return None

    def get_merged_mesh(self):
        """Merges all meshes in this scene into a single mesh. Material indices are 
           updated as neede. The returned Mesh has a valid slot_material_name providing
           material names for each slot index."""
        if len(self.mesh_list) == 0:
            return None
        # early out if no merging is needed
        if len(self.mesh_list) == 1:
            return self.mesh_list[0]
        # merge material lists
        used_material_list = sorted(list(self.get_material_set()))
        material_index_dict = dict([(name, i) for i, name in enumerate(used_material_list)])
        # merge meshes sequentially
        remap_list = [[material_index_dict[name] for name in mesh.slot_material_name] for mesh in self.mesh_list]
        merged_mesh = self.mesh_list[0]
        for i in range(1, len(self.mesh_list)):
            lhs_remap = remap_list[0] if i == 1 else None
            rhs_remap = remap_list[i]
            merged_mesh = Mesh.merge_meshes(merged_mesh, self.mesh_list[i], lhs_remap, rhs_remap)
        merged_mesh.slot_material_name = used_material_list
        return merged_mesh

def export_scene(blender_scene, scene_file_path, selection_only, add_triangulate_modifier, split_angle, sort_triangles):
    """Exports the given bpy.types.scene to the *.cmscn file at the given path. 
       Some parameters forward to Scene.__init__()."""
    print()
    print("-###- Beginning Cynic Moon scene export to %s. -###-" % scene_file_path)
    if path.splitext(scene_file_path)[1] == ".blend":
        scene_file_path = path.splitext(scene_file_path)[0] + ".cmscn"
    # bring the scene into Python objects
    scene = Scene(blender_scene, selection_only, add_triangulate_modifier, split_angle, None)
    if len(scene.mesh_list) == 0:
        print("No meshes are available to export. Aborting.")
        return
    # merge together all meshes of the scene with updated material indices
    mesh = scene.get_merged_mesh()
    used_material_list = mesh.slot_material_name
    # abort if something does not use triangles
    triangle_count = np.count_nonzero(mesh.primitive_vertex_count == 3)
    if triangle_count != mesh.primitive_vertex_count.size:
        print("Some geometry does not consist of triangles only (%d primitives but only %d triangles). "
              % (mesh.primitive_vertex_count.size, triangle_count)
              + "Allow the exporter to add triangulate modifiers to export anyway.")
        return
    # sort triangles by the Morton code of their centroid
    if sort_triangles:
        centroids = np.zeros((triangle_count, 3), dtype=np.float32)
        for j in range(3):
            coordinate = mesh.vertex_position[:, j][mesh.primitive_vertex_indices]
            centroids[:, j] = coordinate.reshape((triangle_count, 3)).mean(axis=1)
        morton = get_mordon_code_3d(centroids, centroids.min(axis=0), centroids.max(axis=0))
        triangle_permutation = np.argsort(morton)
        for j in range(3):
            mesh.primitive_vertex_indices[j::3] = mesh.primitive_vertex_indices[j::3][triangle_permutation]
            mesh.primitive_vertex_uv[j::3] = mesh.primitive_vertex_uv[j::3][triangle_permutation]
        mesh.primitive_material_index = mesh.primitive_material_index[triangle_permutation]
    # open the output file
    file = open(scene_file_path, "wb")
    # write file format marker and version
    file.write(pack("II", 0x27380438, 1))
    # write the number of materials, primitives and vertices
    file.write(pack("QQ", len(used_material_list), triangle_count))
    # quantize vertex positions to 21 bits per coordinate
    box_min = mesh.vertex_position.min(axis=0)[np.newaxis, :]
    box_max = mesh.vertex_position.max(axis=0)[np.newaxis, :]
    quantization_factor = (2.0**21.0 / (box_max - box_min))
    quantization_offset = -box_min * quantization_factor
    quantized_positions = np.asarray(mesh.vertex_position * quantization_factor + quantization_offset, dtype=np.uint32)
    quantized_positions = np.minimum(2**21 - 1, quantized_positions)
    # write the constants needed for dequantization
    dequantization_factor = 1.0 / quantization_factor
    dequantization_summand = box_min + 0.5 * dequantization_factor
    file.write(pack("fff", *dequantization_factor.flat))
    file.write(pack("fff", *dequantization_summand.flat))
    # make a few changes to material names to support ORCA assets
    used_material_list = [re.sub(r"\.[0-9][0-9][0-9]$", "", name) for name in used_material_list]
    used_material_list = [name.replace(".DoubleSided", "") for name in used_material_list]
    # write the material names as null-terminated strings, preceed by their lengths
    for material_name in used_material_list:
        file.write(pack("Q", len(material_name)))
        file.write(material_name.encode("utf-8"))
        file.write(pack("b", 0))
    # write the vertex positions
    indices = mesh.primitive_vertex_indices
    packed_positions = np.zeros((mesh.get_vertex_count(), 2), dtype=np.uint32)
    packed_positions[:, 0] = quantized_positions[:, 0]
    packed_positions[:, 0] += (quantized_positions[:, 1] & 0x7ff) << 21
    packed_positions[:, 1] = (quantized_positions[:, 1] & 0x1ff800) >> 11
    packed_positions[:, 1] += quantized_positions[:, 2] << 10
    triangle_list_positions = np.zeros((triangle_count * 3, 2), dtype=np.uint32)
    triangle_list_positions[:, 0] = packed_positions[:, 0][indices]
    triangle_list_positions[:, 1] = packed_positions[:, 1][indices]
    file.write(pack("I" * triangle_list_positions.size, *triangle_list_positions.flat))
    # pack texture coordinate pairs into 32-bits, allow a texture to repeat up to 8 times within one triangle
    triangle_vertex_uv = mesh.primitive_vertex_uv.reshape((indices.size // 3, 3, 2))
    triangle_min_uv = triangle_vertex_uv.min(axis=1)
    triangle_vertex_uv -= np.floor(triangle_min_uv)[:, np.newaxis, :]
    if np.max(triangle_vertex_uv) > 8.0:
        print("A mesh has %d triangles where the UV coordinates imply more than seven repetitions. "
              % np.count_nonzero(np.any(triangle_vertex_uv > 8.0, axis=(1, 2)))
              + "In the most extreme case, there are %f repetitions. " % np.max(triangle_vertex_uv)
              + "The used quantization does not support that. Coordinates will be clipped.")
    normal_and_uv = np.zeros((indices.size, 4), dtype=np.uint16)
    packed_uv = triangle_vertex_uv * ((2.0**16 - 1.0) / 8.0) + 0.5
    normal_and_uv[:, 2:4] = np.asarray(np.clip(packed_uv.reshape((-1, 2)), 0.0, 2.0**16.0 - 1.0), dtype=np.uint16)
    # pack normals into 32-bits
    packed_normal_0, packed_normal_1 = encode_normal_32_bit(mesh.vertex_normal)
    normal_and_uv[:, 0] = packed_normal_0[indices]
    normal_and_uv[:, 1] = packed_normal_1[indices]
    # write normal vectors and texture coordinates
    file.write(pack("H" * normal_and_uv.size, *normal_and_uv.flat))
    # write the material index for each primitive
    file.write(pack("B" * triangle_count, *mesh.primitive_material_index))
    # write and end of file marker
    file.write(pack("I", 0x00e0fe0f))
    file.close()
    print("Wrote %d materials and %d primitives." % (len(used_material_list), triangle_count))
    print("-###- Export completed. -###-")
    print()

# meta information for Blender
bl_info = {
    "name": "Cynic Moon Engine scene exporter (*.cmscn)",
    "author": "Eleanor Anhedonia",
    "version": (0, 1, 0),
    "blender": (4, 0, 0),
    "location": "file > Export",
    "description": "This addon exports scenes from Blender into a custom scene format.",
    "warning": "",
    "category": "Import-Export"
}

class CynicMoonExportOperator(bpy.types.Operator):
    """This operator exports Blender scenes to a custom scene format (*.cmscn)."""

    def invoke(self, context, _event):
        """Shows a file selection dialog for the *.cmscn file."""
        context.window_manager.fileselect_add(self)
        return {"RUNNING_MODAL"}

    def execute(self, context):
        """Does the export using the current settings and context."""
        export_path = bpy.path.abspath(self.filepath)
        export_scene(context.scene, export_path, self.selection_only, self.add_triangulate_modifier, 
                     self.edge_split_angle if self.add_edge_split_modifier else None, self.sort_triangles)
        return {"FINISHED"}

    # operator settings
    filepath: bpy.props.StringProperty(name="file path", description="Path to the *.cmscn file. "
                                       + "Additional files are written with the same path prefix.", subtype="FILE_PATH")
    selection_only: bpy.props.BoolProperty(name="selection only", description="Export selected objects only.", default=True)
    add_triangulate_modifier: bpy.props.BoolProperty(name="add triangulate modifier", description=
                                                    "Add triangulate modifiers to meshes that cannot be exported otherwise. "
                                                     + "!! This changes your scene permanently !!", default=False)
    add_edge_split_modifier: bpy.props.BoolProperty(name="add edge split modifier", description=
                                                    "Add edge split modifiers to meshes that do not have them yet. "
                                                    + "!! This changes yout scene permanently !!", default=False)
    edge_split_angle: bpy.props.FloatProperty(name="split angle", description="Split angle set for new edge split modifiers.",
                                              subtype="ANGLE", unit="ROTATION", min=0.0, max=np.pi, default=30.0 * np.pi / 180.0)
    sort_triangles: bpy.props.BoolProperty(name="sort triangles", description="Sort triangles of the mesh by the Morton code "
                                           + "of their centroid. It may improve memory coherence when rendering.", default=True)

    # controls file extension filters in the dialog
    filter_glob: bpy.props.StringProperty(default="*.cmscn", options={"HIDDEN"})

    bl_idname = "export_scene.cmoon"
    bl_label = "Export a Cynic Moon scene."
    bl_options = {"PRESET"}

def menu_export_operator(self, _context):
    """Adds the exporter to the export menu."""
    self.layout.operator(CynicMoonExportOperator.bl_idname, text="C. Moon Scene (*.cmscn)")

def register():
    bpy.utils.register_class(CynicMoonExportOperator)
    bpy.types.TOPBAR_MT_file_export.append(menu_export_operator)

def unregister():
    bpy.types.TOPBAR_MT_file_export.remove(menu_export_operator)

if __name__ == "__main__":
    register()
