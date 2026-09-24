"""Hand-rolled STL/OBJ/glTF(.glb) encoders from an existing `MeshData` -
per the locked-in export scope, these reuse the same tessellation data
`/mesh` already produces (`app.document.mesh.tessellate_shape`), not OCCT's
own STL/glTF writers. `MeshData`'s flat triangle-soup layout (every triangle
owns 3 fresh, unshared vertices/normals - see its own docstring) maps
directly onto all three formats with no vertex-welding step needed.
"""

import json
import struct
from dataclasses import dataclass
from typing import Sequence

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


@dataclass
class AssemblyGlbInstance:
    """One placed instance for `encode_assembly_glb` - the encoder's own
    input shape, deliberately not `app.document.schemas.AssemblyOccurrence
    Instance` itself (this module stays free of any pydantic/OCCT
    dependency, per its own module docstring) - the caller (`app.document.
    router`) is responsible for translating a real `AssemblyOccurrenceInstance`
    (and its world-space axis-angle `RigidTransform`) into this. `rotation_
    quaternion` is `(qw, qx, qy, qz)` - the same convention `app.document.
    assembly_solver._quaternion_from_axis_angle` returns - converted to
    glTF's own `(x, y, z, w)` node `rotation` order at encode time.
    `hidden` is carried through only so a caller can build the full instance
    list once and filter afterwards (`?include_hidden`); `encode_assembly_glb`
    itself renders every instance it's given, filtering is the caller's job."""

    part_id: str
    translation: tuple[float, float, float]
    rotation_quaternion: tuple[float, float, float, float]
    color: str | None = None
    hidden: bool = False


def _color_to_base_color_factor(color: str) -> list[float]:
    """`color` is always `"#RRGGBB"` (see `app.document.models.Occurrence.
    color`'s own docstring) - straight 0-255 -> 0-1 channel scaling, no
    sRGB-to-linear conversion, matching every other hand-rolled encoder in
    this module's own "keep it simple" convention."""
    hex_digits = color.lstrip("#")
    r, g, b = (int(hex_digits[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    return [r, g, b, 1.0]


def encode_assembly_glb(
    meshes_by_part_id: dict[str, MeshData], instances: Sequence[AssemblyGlbInstance]
) -> bytes:
    """Node-instanced binary glTF 2.0 for an assembly scene (`docs/vr-recon-
    2-2026-09-24.md` SS3's own size estimate) - one glTF mesh per unique
    `part_id` (`meshes_by_part_id`'s own keys, reusing whatever per-part
    `MeshData` the assembly-mesh path already computed) and one node per
    `instances` entry, rather than `encode_glb`'s single-mesh/single-node
    shape or `export/assembly-glb`'s fully-flattened one-copy-of-geometry-
    per-instance shape. Unindexed, same as `encode_glb` (`mesh.triangles`'s
    own flat, unwelded triangle-soup layout - see that function's own
    docstring) - no vertex-welding step, kept simple deliberately (see
    `docs/status-*.md` for why welding was left out of this pass).

    A mesh is actually keyed by `(part_id, color)`, not `part_id` alone - an
    instance's own colour override (`AssemblyGlbInstance.color`) can't be
    expressed as a node-level property in plain glTF (materials attach to
    primitives, not nodes), so a Part whose placed instances use more than
    one distinct colour gets one JSON `mesh` entry per colour used, each
    referencing the *same* shared position/normal accessors (no geometry
    duplicated in the binary buffer, only a few extra bytes of JSON) - mesh
    count only equals unique-part count in the common case where every
    instance of a given Part shares one colour (including "no override" on
    all of them)."""
    buffer_bytes = bytearray()
    accessors: list[dict] = []
    buffer_views: list[dict] = []

    def _append_vec3_accessor(values: list[tuple[float, float, float]], with_bounds: bool) -> int:
        offset = len(buffer_bytes)
        data = b"".join(struct.pack("<3f", x, y, z) for x, y, z in values)
        buffer_bytes.extend(data)
        buffer_views.append(
            {
                "buffer": 0,
                "byteOffset": offset,
                "byteLength": len(data),
                "target": _GLTF_TARGET_ARRAY_BUFFER,
            }
        )
        accessor = {
            "bufferView": len(buffer_views) - 1,
            "componentType": _GLTF_COMPONENT_TYPE_FLOAT,
            "count": len(values),
            "type": "VEC3",
        }
        if with_bounds and values:
            xs, ys, zs = zip(*values)
            accessor["min"] = [min(xs), min(ys), min(zs)]
            accessor["max"] = [max(xs), max(ys), max(zs)]
        accessors.append(accessor)
        return len(accessors) - 1

    part_accessor_indices: dict[str, tuple[int, int]] = {}
    for part_id, mesh in meshes_by_part_id.items():
        position_accessor = _append_vec3_accessor(mesh.vertices, with_bounds=True)
        normal_accessor = _append_vec3_accessor(mesh.normals, with_bounds=False)
        part_accessor_indices[part_id] = (position_accessor, normal_accessor)

    materials: list[dict] = []
    material_index_by_color: dict[str, int] = {}
    meshes: list[dict] = []
    mesh_index_by_variant: dict[tuple[str, str | None], int] = {}
    nodes: list[dict] = []

    for instance in instances:
        variant_key = (instance.part_id, instance.color)
        mesh_index = mesh_index_by_variant.get(variant_key)
        if mesh_index is None:
            position_accessor, normal_accessor = part_accessor_indices[instance.part_id]
            primitive = {
                "attributes": {"POSITION": position_accessor, "NORMAL": normal_accessor},
                "mode": _GLTF_MODE_TRIANGLES,
            }
            if instance.color is not None:
                material_index = material_index_by_color.get(instance.color)
                if material_index is None:
                    material_index = len(materials)
                    material_index_by_color[instance.color] = material_index
                    materials.append(
                        {"pbrMetallicRoughness": {"baseColorFactor": _color_to_base_color_factor(instance.color)}}
                    )
                primitive["material"] = material_index
            mesh_index = len(meshes)
            mesh_index_by_variant[variant_key] = mesh_index
            meshes.append({"primitives": [primitive]})
        qw, qx, qy, qz = instance.rotation_quaternion
        nodes.append(
            {
                "mesh": mesh_index,
                "translation": list(instance.translation),
                "rotation": [qx, qy, qz, qw],
            }
        )

    gltf: dict = {
        "asset": {"version": "2.0", "generator": "DIDSA-CAD"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "buffers": [{"byteLength": len(buffer_bytes)}],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }
    if materials:
        gltf["materials"] = materials

    json_bytes = _pad(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    bin_bytes = _pad(bytes(buffer_bytes), b"\0")

    json_chunk = struct.pack("<II", len(json_bytes), _GLB_CHUNK_TYPE_JSON) + json_bytes
    bin_chunk_full = struct.pack("<II", len(bin_bytes), _GLB_CHUNK_TYPE_BIN) + bin_bytes
    total_length = 12 + len(json_chunk) + len(bin_chunk_full)
    header = struct.pack("<4sII", _GLB_MAGIC, _GLB_VERSION, total_length)

    return header + json_chunk + bin_chunk_full
