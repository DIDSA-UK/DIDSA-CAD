"""Pure-Python tests for `app.document.mesh_export` against synthetic
`MeshData` - no OCCT needed at all, since these encoders only ever touch
already-tessellated data, not a real shape. A single right triangle is
enough to exercise every byte-layout/structure detail of all three formats.
"""

import json
import struct

from app.document.mesh_data import MeshData, Triangle
from app.document.mesh_export import AssemblyGlbInstance, encode_assembly_glb, encode_glb, encode_obj, encode_stl
from app.document.mesh_import import decode_gltf


def _single_triangle_mesh() -> MeshData:
    mesh = MeshData()
    mesh.vertices = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    mesh.normals = [(0.0, 0.0, 1.0), (0.0, 0.0, 1.0), (0.0, 0.0, 1.0)]
    mesh.triangles = [Triangle(a=0, b=1, c=2)]
    return mesh


def test_stl_header_is_exactly_80_bytes():
    data = encode_stl(_single_triangle_mesh())
    assert data[:80] == b"DIDSA-CAD STL export".ljust(80, b"\0")


def test_stl_triangle_count_and_total_length():
    mesh = _single_triangle_mesh()
    data = encode_stl(mesh)
    (count,) = struct.unpack_from("<I", data, 80)
    assert count == 1
    # header(80) + count(4) + one triangle record (12 floats * 4 bytes + 2-byte attribute count = 50)
    assert len(data) == 80 + 4 + 50


def test_stl_facet_matches_the_source_triangle():
    mesh = _single_triangle_mesh()
    data = encode_stl(mesh)
    values = struct.unpack_from("<12fH", data, 84)
    normal, v1, v2, v3, attr = values[0:3], values[3:6], values[6:9], values[9:12], values[12]
    assert normal == (0.0, 0.0, 1.0)
    assert v1 == (0.0, 0.0, 0.0)
    assert v2 == (1.0, 0.0, 0.0)
    assert v3 == (0.0, 1.0, 0.0)
    assert attr == 0


def test_stl_of_an_empty_mesh_has_zero_triangles():
    data = encode_stl(MeshData())
    (count,) = struct.unpack_from("<I", data, 80)
    assert count == 0
    assert len(data) == 84


def test_obj_emits_expected_vertex_normal_and_face_lines():
    text = encode_obj(_single_triangle_mesh())
    lines = text.splitlines()
    assert "v 0.0 0.0 0.0" in lines
    assert "v 1.0 0.0 0.0" in lines
    assert "v 0.0 1.0 0.0" in lines
    assert "vn 0.0 0.0 1.0" in lines
    assert "f 1//1 2//2 3//3" in lines


def test_obj_of_an_empty_mesh_has_no_vertex_or_face_lines():
    text = encode_obj(MeshData())
    assert "v " not in text
    assert "f " not in text


def _parse_glb(data: bytes):
    magic, version, total_length = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF"
    assert version == 2
    assert total_length == len(data)

    json_len, json_type = struct.unpack_from("<II", data, 12)
    json_bytes = data[20 : 20 + json_len]
    assert json_type == 0x4E4F534A

    bin_offset = 20 + json_len
    bin_len, bin_type = struct.unpack_from("<II", data, bin_offset)
    bin_bytes = data[bin_offset + 8 : bin_offset + 8 + bin_len]
    assert bin_type == 0x004E4942

    return json.loads(json_bytes), bin_bytes


def test_glb_header_and_chunk_structure_round_trip():
    data = encode_glb(_single_triangle_mesh())
    gltf, bin_bytes = _parse_glb(data)
    assert gltf["asset"]["version"] == "2.0"
    assert len(bin_bytes) % 4 == 0


def test_glb_accessors_describe_the_source_triangle():
    mesh = _single_triangle_mesh()
    data = encode_glb(mesh)
    gltf, bin_bytes = _parse_glb(data)

    position_accessor, normal_accessor = gltf["accessors"]
    assert position_accessor["count"] == 3
    assert position_accessor["type"] == "VEC3"
    assert position_accessor["min"] == [0.0, 0.0, 0.0]
    assert position_accessor["max"] == [1.0, 1.0, 0.0]
    assert normal_accessor["count"] == 3

    position_view = gltf["bufferViews"][position_accessor["bufferView"]]
    positions = struct.unpack_from(
        f"<{3 * position_accessor['count']}f", bin_bytes, position_view["byteOffset"]
    )
    assert positions[:3] == (0.0, 0.0, 0.0)
    assert positions[3:6] == (1.0, 0.0, 0.0)
    assert positions[6:9] == (0.0, 1.0, 0.0)


def test_glb_of_an_empty_mesh_still_produces_a_valid_container():
    data = encode_glb(MeshData())
    gltf, bin_bytes = _parse_glb(data)
    assert gltf["accessors"][0]["count"] == 0
    assert bin_bytes == b""


def _second_triangle_mesh() -> MeshData:
    mesh = MeshData()
    mesh.vertices = [(0.0, 0.0, 5.0), (2.0, 0.0, 5.0), (0.0, 2.0, 5.0)]
    mesh.normals = [(0.0, 0.0, 1.0), (0.0, 0.0, 1.0), (0.0, 0.0, 1.0)]
    mesh.triangles = [Triangle(a=0, b=1, c=2)]
    return mesh


def test_assembly_glb_node_count_equals_instance_count():
    meshes = {"part-a": _single_triangle_mesh(), "part-b": _second_triangle_mesh()}
    instances = [
        AssemblyGlbInstance(part_id="part-a", translation=(0.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
        AssemblyGlbInstance(part_id="part-a", translation=(5.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
        AssemblyGlbInstance(part_id="part-b", translation=(0.0, 5.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
    ]
    data = encode_assembly_glb(meshes, instances)
    gltf, _bin_bytes = _parse_glb(data)
    assert len(gltf["nodes"]) == 3
    assert gltf["scenes"][0]["nodes"] == [0, 1, 2]


def test_assembly_glb_mesh_count_equals_unique_parts_when_colour_is_uniform_per_part():
    meshes = {"part-a": _single_triangle_mesh(), "part-b": _second_triangle_mesh()}
    instances = [
        AssemblyGlbInstance(
            part_id="part-a", translation=(0.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0), color="#ff0000"
        ),
        AssemblyGlbInstance(
            part_id="part-a", translation=(5.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0), color="#ff0000"
        ),
        AssemblyGlbInstance(part_id="part-b", translation=(0.0, 5.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
    ]
    data = encode_assembly_glb(meshes, instances)
    gltf, _bin_bytes = _parse_glb(data)
    assert len(gltf["meshes"]) == 2
    # Both part-a instances share one mesh entry (same colour).
    assert gltf["nodes"][0]["mesh"] == gltf["nodes"][1]["mesh"]
    assert gltf["nodes"][2]["mesh"] != gltf["nodes"][0]["mesh"]


def test_assembly_glb_one_material_per_distinct_colour():
    meshes = {"part-a": _single_triangle_mesh()}
    instances = [
        AssemblyGlbInstance(
            part_id="part-a", translation=(0.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0), color="#ff0000"
        ),
        AssemblyGlbInstance(
            part_id="part-a", translation=(5.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0), color="#00ff00"
        ),
        AssemblyGlbInstance(
            part_id="part-a", translation=(0.0, 5.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0), color="#ff0000"
        ),
        AssemblyGlbInstance(part_id="part-a", translation=(0.0, 0.0, 5.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
    ]
    data = encode_assembly_glb(meshes, instances)
    gltf, _bin_bytes = _parse_glb(data)
    # Two distinct colours used -> two materials; the uncoloured instance's
    # primitive carries no "material" key at all (renderer default).
    assert len(gltf["materials"]) == 2
    assert gltf["materials"][0]["pbrMetallicRoughness"]["baseColorFactor"] == [1.0, 0.0, 0.0, 1.0]
    assert gltf["materials"][1]["pbrMetallicRoughness"]["baseColorFactor"] == [0.0, 1.0, 0.0, 1.0]
    red_node = gltf["nodes"][0]
    uncoloured_node = gltf["nodes"][3]
    red_primitive = gltf["meshes"][red_node["mesh"]]["primitives"][0]
    uncoloured_primitive = gltf["meshes"][uncoloured_node["mesh"]]["primitives"][0]
    assert red_primitive["material"] == 0
    assert "material" not in uncoloured_primitive


def test_assembly_glb_node_transform_matches_instance():
    meshes = {"part-a": _single_triangle_mesh()}
    instances = [
        AssemblyGlbInstance(
            part_id="part-a",
            translation=(1.5, -2.0, 3.0),
            rotation_quaternion=(0.7071067811865476, 0.0, 0.0, 0.7071067811865476),
        )
    ]
    data = encode_assembly_glb(meshes, instances)
    gltf, _bin_bytes = _parse_glb(data)
    node = gltf["nodes"][0]
    assert node["translation"] == [1.5, -2.0, 3.0]
    # glTF node rotation is (x, y, z, w); the encoder's own input is (w, x, y, z).
    assert node["rotation"] == [0.0, 0.0, 0.7071067811865476, 0.7071067811865476]


def test_assembly_glb_reparses_with_the_existing_gltf_decoder():
    meshes = {"part-a": _single_triangle_mesh(), "part-b": _second_triangle_mesh()}
    instances = [
        AssemblyGlbInstance(part_id="part-a", translation=(0.0, 0.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
        AssemblyGlbInstance(part_id="part-b", translation=(0.0, 5.0, 0.0), rotation_quaternion=(1.0, 0.0, 0.0, 0.0)),
    ]
    data = encode_assembly_glb(meshes, instances)
    decoded = decode_gltf(data)
    # The existing decoder only ever reads `meshes[0]`'s own geometry (it
    # has no concept of nodes/instancing) - this just proves the container
    # itself is well-formed glTF, the same "output re-parses" contract every
    # other encoder in this module already gets exercised against.
    assert len(decoded.vertices) == 3
    assert len(decoded.triangles) == 1
