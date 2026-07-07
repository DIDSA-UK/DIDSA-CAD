"""Pure-Python tests for `app.document.mesh_import` - no OCCT needed, same
as `test_mesh_export.py`. Most cases round-trip through the existing
`mesh_export` encoders (encode then decode, assert the geometry survives),
which also doubles as an implicit cross-check that the two modules agree
on each format's own byte layout. A few cases exercise decoder-only paths
(ASCII STL, OBJ without normals/with a quad face, glTF without a NORMAL
accessor) that the encoders never themselves produce.
"""

import base64
import json
import struct

import pytest

from app.document.mesh_data import MeshData, Triangle
from app.document.mesh_export import encode_glb, encode_obj, encode_stl
from app.document.mesh_import import MeshImportError, decode_gltf, decode_obj, decode_stl


def _two_triangle_mesh() -> MeshData:
    mesh = MeshData()
    mesh.vertices = [
        (0.0, 0.0, 0.0),
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (1.0, 0.0, 0.0),
        (1.0, 1.0, 0.0),
        (0.0, 1.0, 0.0),
    ]
    mesh.normals = [(0.0, 0.0, 1.0)] * 6
    mesh.triangles = [Triangle(a=0, b=1, c=2), Triangle(a=3, b=4, c=5)]
    return mesh


def _assert_same_geometry(mesh: MeshData, original: MeshData) -> None:
    assert len(mesh.triangles) == len(original.triangles)
    for triangle, original_triangle in zip(mesh.triangles, original.triangles):
        for index, original_index in zip((triangle.a, triangle.b, triangle.c), (original_triangle.a, original_triangle.b, original_triangle.c)):
            assert mesh.vertices[index] == pytest.approx(original.vertices[original_index])
            assert mesh.normals[index] == pytest.approx(original.normals[original_index])


def test_decode_stl_round_trips_through_encode_stl():
    original = _two_triangle_mesh()
    decoded = decode_stl(encode_stl(original))
    _assert_same_geometry(decoded, original)


def test_decode_stl_rejects_empty_binary_stl_by_falling_back_to_ascii_and_failing():
    with pytest.raises(MeshImportError):
        decode_stl(b"not an stl file at all")


def test_decode_ascii_stl():
    text = (
        "solid test\n"
        "facet normal 0 0 1\n"
        "outer loop\n"
        "vertex 0 0 0\n"
        "vertex 1 0 0\n"
        "vertex 0 1 0\n"
        "endloop\n"
        "endfacet\n"
        "endsolid test\n"
    )
    mesh = decode_stl(text.encode("ascii"))
    assert mesh.vertices == [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    assert mesh.normals == [(0.0, 0.0, 1.0)] * 3
    assert len(mesh.triangles) == 1


def test_decode_ascii_stl_computes_a_normal_when_the_facet_normal_is_all_zero():
    text = (
        "solid test\n"
        "facet normal 0 0 0\n"
        "outer loop\n"
        "vertex 0 0 0\n"
        "vertex 1 0 0\n"
        "vertex 0 1 0\n"
        "endloop\n"
        "endfacet\n"
        "endsolid test\n"
    )
    mesh = decode_stl(text.encode("ascii"))
    assert mesh.normals[0] == pytest.approx((0.0, 0.0, 1.0))


def test_decode_obj_round_trips_through_encode_obj():
    original = _two_triangle_mesh()
    decoded = decode_obj(encode_obj(original))
    _assert_same_geometry(decoded, original)


def test_decode_obj_without_normals_computes_them():
    text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
    mesh = decode_obj(text)
    assert mesh.vertices == [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    assert mesh.normals[0] == pytest.approx((0.0, 0.0, 1.0))


def test_decode_obj_fan_triangulates_a_quad_face():
    text = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"
    mesh = decode_obj(text)
    assert len(mesh.triangles) == 2


def test_decode_obj_rejects_a_face_with_an_unknown_vertex():
    with pytest.raises(MeshImportError):
        decode_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 5\n")


def test_decode_obj_rejects_a_file_with_no_vertices():
    with pytest.raises(MeshImportError):
        decode_obj("# just a comment\n")


def test_decode_gltf_round_trips_through_encode_glb():
    original = _two_triangle_mesh()
    decoded = decode_gltf(encode_glb(original))
    _assert_same_geometry(decoded, original)


def test_decode_gltf_rejects_bad_magic():
    with pytest.raises(MeshImportError):
        decode_gltf(b"not a glb file" + b"\0" * 20)


def test_decode_gltf_rejects_length_mismatch():
    data = bytearray(encode_glb(_two_triangle_mesh()))
    # Corrupt the declared total length (bytes 8:12) so it no longer matches.
    data[8:12] = (len(data) + 4).to_bytes(4, "little")
    with pytest.raises(MeshImportError):
        decode_gltf(bytes(data))


def _embedded_json_gltf_bytes(mesh: MeshData) -> bytes:
    """A self-contained, plain-JSON `.gltf` (not `.glb`) - the common
    real-world form most authoring tools default to - built by unwrapping
    `encode_glb`'s own glb container and re-embedding its BIN chunk as a
    `data:` URI instead, exactly the "export embedded" option those same
    tools offer."""
    glb = encode_glb(mesh)
    json_len, = struct.unpack_from("<I", glb, 12)
    gltf = json.loads(glb[20 : 20 + json_len])
    bin_offset = 20 + json_len
    bin_len, = struct.unpack_from("<I", glb, bin_offset)
    bin_bytes = glb[bin_offset + 8 : bin_offset + 8 + bin_len]
    gltf["buffers"][0]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(
        bin_bytes
    ).decode("ascii")
    return json.dumps(gltf).encode("utf-8")


def test_decode_gltf_accepts_a_plain_json_gltf_with_an_embedded_data_uri_buffer():
    original = _two_triangle_mesh()
    decoded = decode_gltf(_embedded_json_gltf_bytes(original))
    _assert_same_geometry(decoded, original)


def test_decode_gltf_rejects_a_json_gltf_referencing_an_external_buffer_file():
    original = _two_triangle_mesh()
    glb = encode_glb(original)
    json_len, = struct.unpack_from("<I", glb, 12)
    gltf = json.loads(glb[20 : 20 + json_len])
    gltf["buffers"][0]["uri"] = "geometry.bin"
    with pytest.raises(MeshImportError):
        decode_gltf(json.dumps(gltf).encode("utf-8"))
