"""Hand-rolled STL/OBJ/glTF(.glb) encoders from an existing `MeshData` -
per the locked-in export scope, these reuse the same tessellation data
`/mesh` already produces (`app.document.mesh.tessellate_shape`), not OCCT's
own STL/glTF writers. `MeshData`'s flat triangle-soup layout (every triangle
owns 3 fresh, unshared vertices/normals - see its own docstring) maps
directly onto all three formats with no vertex-welding step needed.
"""

import json
import struct

from app.document.mesh_data import MeshData

_STL_HEADER = b"DIDSA-CAD STL export".ljust(80, b"\0")[:80]

# glTF 2.0 chunk type magic numbers (glb container spec).
_GLB_MAGIC = b"glTF"
_GLB_VERSION = 2
_GLB_CHUNK_TYPE_JSON = 0x4E4F534A
_GLB_CHUNK_TYPE_BIN = 0x004E4942
_GLTF_COMPONENT_TYPE_FLOAT = 5126
_GLTF_MODE_TRIANGLES = 4
_GLTF_TARGET_ARRAY_BUFFER = 34962


def encode_stl(mesh: MeshData) -> bytes:
    """Binary STL: an 80-byte header, a uint32 triangle count, then per
    triangle 12 float32s (facet normal, then its 3 vertices) plus a 2-byte
    attribute byte count (always 0 here) - the standard binary STL layout."""
    body = bytearray()
    body += struct.pack("<I", len(mesh.triangles))
    for triangle in mesh.triangles:
        normal = mesh.normals[triangle.a]
        v1 = mesh.vertices[triangle.a]
        v2 = mesh.vertices[triangle.b]
        v3 = mesh.vertices[triangle.c]
        body += struct.pack("<12fH", *normal, *v1, *v2, *v3, 0)
    return bytes(_STL_HEADER) + bytes(body)


def encode_obj(mesh: MeshData) -> str:
    """ASCII OBJ: `v`/`vn` lines straight from `mesh.vertices`/`mesh.normals`
    (already 1:1 parallel, so a vertex's own normal shares its index), then
    one `f` line per triangle using OBJ's 1-based `vertex//normal` indices."""
    lines = ["# DIDSA-CAD OBJ export"]
    for x, y, z in mesh.vertices:
        lines.append(f"v {x} {y} {z}")
    for x, y, z in mesh.normals:
        lines.append(f"vn {x} {y} {z}")
    for triangle in mesh.triangles:
        a, b, c = triangle.a + 1, triangle.b + 1, triangle.c + 1
        lines.append(f"f {a}//{a} {b}//{b} {c}//{c}")
    return "\n".join(lines) + "\n"


def _pad(data: bytes, pad_byte: bytes) -> bytes:
    remainder = len(data) % 4
    return data if remainder == 0 else data + pad_byte * (4 - remainder)


def encode_glb(mesh: MeshData) -> bytes:
    """Binary glTF 2.0 (.glb): one mesh, one primitive, POSITION+NORMAL
    attributes only, no index buffer - `mesh.triangles` is already an
    unindexed flat triangle soup (`mode: TRIANGLES` reads attributes
    sequentially in groups of 3), so there is nothing to index."""
    position_bytes = b"".join(struct.pack("<3f", x, y, z) for x, y, z in mesh.vertices)
    normal_bytes = b"".join(struct.pack("<3f", x, y, z) for x, y, z in mesh.normals)
    bin_chunk = position_bytes + normal_bytes

    if mesh.vertices:
        xs, ys, zs = zip(*mesh.vertices)
        position_min = [min(xs), min(ys), min(zs)]
        position_max = [max(xs), max(ys), max(zs)]
    else:
        position_min = position_max = [0.0, 0.0, 0.0]

    gltf = {
        "asset": {"version": "2.0", "generator": "DIDSA-CAD"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [
            {
                "primitives": [
                    {"attributes": {"POSITION": 0, "NORMAL": 1}, "mode": _GLTF_MODE_TRIANGLES}
                ]
            }
        ],
        "buffers": [{"byteLength": len(bin_chunk)}],
        "bufferViews": [
            {
                "buffer": 0,
                "byteOffset": 0,
                "byteLength": len(position_bytes),
                "target": _GLTF_TARGET_ARRAY_BUFFER,
            },
            {
                "buffer": 0,
                "byteOffset": len(position_bytes),
                "byteLength": len(normal_bytes),
                "target": _GLTF_TARGET_ARRAY_BUFFER,
            },
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": _GLTF_COMPONENT_TYPE_FLOAT,
                "count": len(mesh.vertices),
                "type": "VEC3",
                "min": position_min,
                "max": position_max,
            },
            {
                "bufferView": 1,
                "componentType": _GLTF_COMPONENT_TYPE_FLOAT,
                "count": len(mesh.normals),
                "type": "VEC3",
            },
        ],
    }

    json_bytes = _pad(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    bin_bytes = _pad(bin_chunk, b"\0")

    json_chunk = struct.pack("<II", len(json_bytes), _GLB_CHUNK_TYPE_JSON) + json_bytes
    bin_chunk_full = struct.pack("<II", len(bin_bytes), _GLB_CHUNK_TYPE_BIN) + bin_bytes
    total_length = 12 + len(json_chunk) + len(bin_chunk_full)
    header = struct.pack("<4sII", _GLB_MAGIC, _GLB_VERSION, total_length)

    return header + json_chunk + bin_chunk_full
