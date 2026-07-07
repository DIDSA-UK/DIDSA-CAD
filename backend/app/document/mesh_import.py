"""Hand-rolled STL/OBJ/glTF(.glb) decoders - the inverse of
`app.document.mesh_export`'s encoders, and (like them) OCCT-free: these
only ever produce a plain `MeshData`, never touch pythonocc-core. Support
is pragmatic rather than exhaustive (real-world files vary more than this
codebase's own encoders' output), but each format's own common shape is
covered: binary and ASCII STL; OBJ with or without per-vertex normals,
fan-triangulating any polygon face; glTF with or without an index buffer,
falling back to a computed face normal wherever NORMAL is absent.
"""

import json
import struct

from app.document.mesh_data import MeshData, Triangle


class MeshImportError(ValueError):
    """Raised for anything wrong with an uploaded mesh file's own content -
    always a client-supplied-file problem, never an internal bug, mirroring
    `app.document.native_format.NativeFormatError`'s own role. `app.
    document.import_geometry` maps this to a structured 422."""


def _face_normal(
    v1: tuple[float, float, float], v2: tuple[float, float, float], v3: tuple[float, float, float]
) -> tuple[float, float, float]:
    ux, uy, uz = v2[0] - v1[0], v2[1] - v1[1], v2[2] - v1[2]
    wx, wy, wz = v3[0] - v1[0], v3[1] - v1[1], v3[2] - v1[2]
    nx, ny, nz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
    length = (nx**2 + ny**2 + nz**2) ** 0.5
    return (nx / length, ny / length, nz / length) if length else (0.0, 0.0, 0.0)


# --- STL --------------------------------------------------------------------


def decode_stl(data: bytes) -> MeshData:
    """Binary STL if the file's own declared triangle count exactly accounts
    for its length (the standard binary-vs-ASCII sniff, since an ASCII STL
    can itself start with the word "solid" the same way a binary one's
    80-byte header conventionally does); ASCII STL text otherwise."""
    if len(data) >= 84:
        (declared_count,) = struct.unpack_from("<I", data, 80)
        if len(data) == 84 + declared_count * 50:
            return _decode_binary_stl(data, declared_count)
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise MeshImportError(f"Not a recognizable STL file: {exc}") from exc
    return _decode_ascii_stl(text)


def _decode_binary_stl(data: bytes, count: int) -> MeshData:
    mesh = MeshData()
    offset = 84
    for _ in range(count):
        normal_x, normal_y, normal_z, *rest = struct.unpack_from("<12f", data, offset)
        v1, v2, v3 = tuple(rest[0:3]), tuple(rest[3:6]), tuple(rest[6:9])
        normal = (normal_x, normal_y, normal_z)
        base = len(mesh.vertices)
        mesh.vertices.extend([v1, v2, v3])
        mesh.normals.extend([normal, normal, normal])
        mesh.triangles.append(Triangle(a=base, b=base + 1, c=base + 2))
        offset += 50
    return mesh


def _decode_ascii_stl(text: str) -> MeshData:
    mesh = MeshData()
    normal: tuple[float, float, float] | None = None
    pending_vertices: list[tuple[float, float, float]] = []

    for raw_line in text.splitlines():
        tokens = raw_line.split()
        if not tokens:
            continue
        keyword = tokens[0].lower()
        if keyword == "facet" and len(tokens) >= 5 and tokens[1].lower() == "normal":
            normal = (float(tokens[2]), float(tokens[3]), float(tokens[4]))
            pending_vertices = []
        elif keyword == "vertex" and len(tokens) >= 4:
            pending_vertices.append((float(tokens[1]), float(tokens[2]), float(tokens[3])))
        elif keyword == "endfacet":
            if len(pending_vertices) != 3:
                raise MeshImportError("ASCII STL facet does not have exactly 3 vertices")
            v1, v2, v3 = pending_vertices
            face_normal = normal if normal and normal != (0.0, 0.0, 0.0) else _face_normal(v1, v2, v3)
            base = len(mesh.vertices)
            mesh.vertices.extend([v1, v2, v3])
            mesh.normals.extend([face_normal, face_normal, face_normal])
            mesh.triangles.append(Triangle(a=base, b=base + 1, c=base + 2))
            normal = None
            pending_vertices = []

    if not mesh.triangles:
        raise MeshImportError("ASCII STL file has no facets")
    return mesh


# --- OBJ ----------------------------------------------------------------------


def _obj_index(token: str, count: int) -> int:
    """OBJ's own 1-based (or negative, relative-to-end) index syntax -> a
    0-based index into the vertex/normal list built up so far."""
    raw = int(token)
    return raw - 1 if raw > 0 else count + raw


def decode_obj(text: str) -> MeshData:
    positions: list[tuple[float, float, float]] = []
    normals: list[tuple[float, float, float]] = []
    mesh = MeshData()

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        keyword, rest = parts[0], parts[1:]

        if keyword == "v":
            if len(rest) < 3:
                raise MeshImportError(f"OBJ vertex line has fewer than 3 components: {line!r}")
            positions.append((float(rest[0]), float(rest[1]), float(rest[2])))
        elif keyword == "vn":
            if len(rest) < 3:
                raise MeshImportError(f"OBJ normal line has fewer than 3 components: {line!r}")
            normals.append((float(rest[0]), float(rest[1]), float(rest[2])))
        elif keyword == "f":
            if len(rest) < 3:
                raise MeshImportError(f"OBJ face has fewer than 3 vertices: {line!r}")
            corners: list[tuple[tuple[float, float, float], tuple[float, float, float] | None]] = []
            for token in rest:
                fields = token.split("/")
                position_index = _obj_index(fields[0], len(positions))
                if not (0 <= position_index < len(positions)):
                    raise MeshImportError(f"OBJ face references an unknown vertex: {line!r}")
                normal_index = (
                    _obj_index(fields[2], len(normals)) if len(fields) >= 3 and fields[2] else None
                )
                normal = (
                    normals[normal_index]
                    if normal_index is not None and 0 <= normal_index < len(normals)
                    else None
                )
                corners.append((positions[position_index], normal))
            # Fan-triangulate any polygon face with more than 3 vertices.
            for i in range(1, len(corners) - 1):
                triangle_corners = [corners[0], corners[i], corners[i + 1]]
                if any(normal is None for _, normal in triangle_corners):
                    v1, v2, v3 = (position for position, _ in triangle_corners)
                    shared_normal = _face_normal(v1, v2, v3)
                    triangle_corners = [(position, shared_normal) for position, _ in triangle_corners]
                base = len(mesh.vertices)
                for position, normal in triangle_corners:
                    mesh.vertices.append(position)
                    mesh.normals.append(normal)
                mesh.triangles.append(Triangle(a=base, b=base + 1, c=base + 2))

    if not mesh.vertices:
        raise MeshImportError("OBJ file has no vertices")
    return mesh


# --- glTF (.glb) --------------------------------------------------------------

_GLTF_INDEX_FORMAT_FOR_COMPONENT_TYPE = {5121: "B", 5123: "H", 5125: "I"}


def _read_vec3_accessor(gltf: dict, bin_chunk: bytes, accessor_index: int) -> list[tuple[float, float, float]]:
    accessor = gltf["accessors"][accessor_index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    count = accessor["count"]
    values = struct.unpack_from(f"<{3 * count}f", bin_chunk, offset)
    return [(values[i], values[i + 1], values[i + 2]) for i in range(0, len(values), 3)]


def _read_index_accessor(gltf: dict, bin_chunk: bytes, accessor_index: int) -> list[int]:
    accessor = gltf["accessors"][accessor_index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    count = accessor["count"]
    fmt = _GLTF_INDEX_FORMAT_FOR_COMPONENT_TYPE.get(accessor["componentType"])
    if fmt is None:
        raise MeshImportError(f"Unsupported glTF index componentType: {accessor['componentType']}")
    return list(struct.unpack_from(f"<{count}{fmt}", bin_chunk, offset))


def decode_glb(data: bytes) -> MeshData:
    if len(data) < 12:
        raise MeshImportError("Not a valid glb file: too short")
    magic, _version, total_length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise MeshImportError("Not a valid glb file: bad magic")
    if total_length != len(data):
        raise MeshImportError("Not a valid glb file: declared length does not match file size")

    json_chunk: bytes | None = None
    bin_chunk = b""
    offset = 12
    while offset + 8 <= len(data):
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        chunk_data = data[offset + 8 : offset + 8 + chunk_length]
        if chunk_type == 0x4E4F534A:
            json_chunk = chunk_data
        elif chunk_type == 0x004E4942:
            bin_chunk = chunk_data
        offset += 8 + chunk_length

    if json_chunk is None:
        raise MeshImportError("Not a valid glb file: missing JSON chunk")
    try:
        gltf = json.loads(json_chunk)
        primitive = gltf["meshes"][0]["primitives"][0]
        position_accessor_index = primitive["attributes"]["POSITION"]
        normal_accessor_index = primitive["attributes"].get("NORMAL")
        indices_accessor_index = primitive.get("indices")
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        raise MeshImportError(f"Not a valid glb file: {exc}") from exc

    positions = _read_vec3_accessor(gltf, bin_chunk, position_accessor_index)
    normals = (
        _read_vec3_accessor(gltf, bin_chunk, normal_accessor_index)
        if normal_accessor_index is not None
        else None
    )
    indices = (
        _read_index_accessor(gltf, bin_chunk, indices_accessor_index)
        if indices_accessor_index is not None
        else list(range(len(positions)))
    )

    mesh = MeshData()
    triangle_count = len(indices) // 3
    for i in range(triangle_count):
        ia, ib, ic = indices[3 * i], indices[3 * i + 1], indices[3 * i + 2]
        v1, v2, v3 = positions[ia], positions[ib], positions[ic]
        if normals:
            n1, n2, n3 = normals[ia], normals[ib], normals[ic]
        else:
            n1 = n2 = n3 = _face_normal(v1, v2, v3)
        base = len(mesh.vertices)
        mesh.vertices.extend([v1, v2, v3])
        mesh.normals.extend([n1, n2, n3])
        mesh.triangles.append(Triangle(a=base, b=base + 1, c=base + 2))

    if not mesh.vertices:
        raise MeshImportError("glb file has no triangles")
    return mesh
