from dataclasses import dataclass, field

from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.GCPnts import GCPnts_TangentialDeflection
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Face, topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape


@dataclass
class MeshQuality:
    """Real OCCT tessellation tolerance controls, not a fake wrapper:
    `linear_deflection` and `angular_deflection` are passed straight
    through to BRepMesh_IncrementalMesh. Defaults are deliberately coarse
    (large deflection = fewer triangles) since the Pi 5 is the target
    deployment hardware for this stage's viewport, but every caller can
    override them per-shape."""

    linear_deflection: float = 0.5
    angular_deflection: float = 0.5


DEFAULT_MESH_QUALITY = MeshQuality()

# Chord-height tolerance (Stage 11) for subdividing curved edges into
# polyline segments - independent of the triangle mesh's own deflection
# above, since edges are sampled straight from the OCCT curve, not derived
# from the triangulation.
EDGE_CHORD_HEIGHT_TOLERANCE = 0.1
EDGE_ANGULAR_DEFLECTION = 0.5


@dataclass
class Triangle:
    """Indices into a MeshData's `vertices`/`normals` lists, one flat
    (face-normal, not vertex-averaged) normal per triangle - matches what
    BRepMesh_IncrementalMesh actually produces per-face, with no smoothing
    step added on top."""

    a: int
    b: int
    c: int


@dataclass
class MeshData:
    vertices: list[tuple[float, float, float]] = field(default_factory=list)
    normals: list[tuple[float, float, float]] = field(default_factory=list)
    triangles: list[Triangle] = field(default_factory=list)
    # Stage 11: flat [x1,y1,z1, x2,y2,z2, ...] polyline segments, one run per
    # OCCT edge - straight edges collapse to a single segment, curved edges
    # subdivide per EDGE_CHORD_HEIGHT_TOLERANCE. Independent of `triangles`;
    # never derived from the mesh's own triangle edges.
    edges: list[float] = field(default_factory=list)
    # Stage 23: stable per-triangle face id (dense, TopExp_Explorer face
    # order), parallel to `triangles` - one entry per triangle, all
    # triangles from the same OCCT face share an id. Foundation for the 3D
    # viewport's face hit-testing/selection; only stable within one
    # response, since the underlying shape is rebuilt from scratch on every
    # request (see app.document.router.get_part_mesh).
    face_ids: list[int] = field(default_factory=list)
    # Stage 23: stable per-segment edge id, parallel to `edges` divided into
    # 6-float segments (one id per segment) - every segment sampled from the
    # same OCCT edge shares an id, dense over edges that actually emit
    # segments (a degenerate edge contributes none, so it never consumes an
    # id). Same per-request-only stability caveat as `face_ids`.
    edge_ids: list[int] = field(default_factory=list)
    # Stage 23: real OCCT topology vertices - the points where 2+ edges
    # meet - distinct from the flat triangle-soup `vertices` above, which
    # has no topology (every triangle owns 3 fresh, unshared vertices, so a
    # nearest-mesh-vertex hit-test could land on a tessellation seam that
    # isn't a real corner). `topology_vertex_ids` is its parallel dense id
    # list, same per-request-only stability caveat as `face_ids`/`edge_ids`.
    topology_vertices: list[tuple[float, float, float]] = field(default_factory=list)
    topology_vertex_ids: list[int] = field(default_factory=list)
    # Fillet follow-up: per-face boundary edge ids ("tap a face to select
    # all its edges" for Fillet) - dense, one entry per face in the same
    # `TopExp_Explorer(shape, TopAbs_FACE)` order `face_ids` is assigned in
    # (every face gets an entry, even one with no triangulation), each a
    # sorted list of the same dense edge ids `edge_ids` uses (degenerate
    # edges never appear, same skip `_extract_edges` already applies).
    face_edge_ids: list[list[int]] = field(default_factory=list)


def _cross(u: tuple[float, float, float], v: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        u[1] * v[2] - u[2] * v[1],
        u[2] * v[0] - u[0] * v[2],
        u[0] * v[1] - u[1] * v[0],
    )


def _normalize(v: tuple[float, float, float]) -> tuple[float, float, float]:
    length = (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5
    if length == 0:
        return (0.0, 0.0, 0.0)
    return (v[0] / length, v[1] / length, v[2] / length)


def _sub(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def tessellate_shape(shape, quality: MeshQuality = DEFAULT_MESH_QUALITY) -> MeshData:
    """Triangulate an OCCT shape into flat-shaded triangle-soup mesh data
    suitable for sending to the client. Every triangle gets its own 3
    fresh vertices (never shared with any other triangle, even within the
    same face) so each one carries its own true face normal with no
    cross-triangle vertex averaging - this is what `flutter_scene`'s
    default/built-in materials need for flat shading."""
    mesher = BRepMesh_IncrementalMesh(
        shape, quality.linear_deflection, False, quality.angular_deflection, True
    )
    mesher.Perform()

    mesh = MeshData()
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    face_id = 0
    while explorer.More():
        face = topods.Face(explorer.Current())
        _append_face_triangles(face, mesh, face_id)
        face_id += 1
        explorer.Next()

    mesh.edges, mesh.edge_ids = _extract_edges(shape)
    mesh.topology_vertices, mesh.topology_vertex_ids = _extract_topology_vertices(shape)
    mesh.face_edge_ids = _extract_face_edge_ids(shape)
    return mesh


def _dense_edge_ids(shape) -> tuple[TopTools_IndexedMapOfShape, dict[int, int]]:
    """Shared by `_extract_edges` and `_extract_face_edge_ids`: the whole-
    shape edge map (`topexp.MapShapes`, de-duplicating an edge shared
    between two faces the way a plain TopExp_Explorer wouldn't) alongside a
    `{map_index (1-based) -> dense edge id}` lookup - ids assigned in
    iteration order, skipping degenerate edges entirely (they never emit a
    segment, so they must never consume an id either), which is exactly
    the id space `edge_ids`/`face_edge_ids` both need to agree on."""
    edge_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_EDGE, edge_map)

    edge_id_by_map_index: dict[int, int] = {}
    next_edge_id = 0
    for i in range(1, edge_map.Size() + 1):
        edge = topods.Edge(edge_map.FindKey(i))
        if BRep_Tool.Degenerated(edge):
            continue
        edge_id_by_map_index[i] = next_edge_id
        next_edge_id += 1

    return edge_map, edge_id_by_map_index


def _extract_edges(shape) -> tuple[list[float], list[int]]:
    """Real-geometry edge polylines for `shape`, sampled from each edge's
    underlying OCCT curve (BRepAdaptor_Curve), not derived from the
    triangle mesh - that would show every tessellation triangle's edges
    instead of the shape's true ones.

    Returns the flat segment list alongside a parallel per-segment edge id
    list (Stage 23), using `_dense_edge_ids`' id assignment."""
    edge_map, edge_id_by_map_index = _dense_edge_ids(shape)

    segments: list[float] = []
    edge_ids: list[int] = []
    for i in range(1, edge_map.Size() + 1):
        edge_id = edge_id_by_map_index.get(i)
        if edge_id is None:
            continue
        edge = topods.Edge(edge_map.FindKey(i))
        points = _sample_edge(edge)
        segment_count = 0
        for p1, p2 in zip(points, points[1:]):
            segments.extend([p1[0], p1[1], p1[2], p2[0], p2[1], p2[2]])
            segment_count += 1
        edge_ids.extend([edge_id] * segment_count)

    return segments, edge_ids


def _extract_face_edge_ids(shape) -> list[list[int]]:
    """Fillet follow-up: per-face boundary edge ids, letting the client
    offer "tap a face to select all its edges" - a face's own edges are
    walked via a per-face `TopExp_Explorer(face, TopAbs_EDGE)` (which can
    revisit an edge shared by an inner/outer wire twice, hence the `set`),
    then each is translated to the *same* dense edge id `_extract_edges`
    assigns via `_dense_edge_ids`'s shared map, not a fresh per-face index -
    a client matching a `face_edge_ids` entry against `edge_ids`/its own
    `SubShapeRef.index` needs both to agree on one id space. Dense, one
    entry per face in the same `TopExp_Explorer(shape, TopAbs_FACE)` order
    `tessellate_shape`'s own face_id loop uses - every face gets an entry,
    even one with no triangulation."""
    edge_map, edge_id_by_map_index = _dense_edge_ids(shape)

    face_edge_ids: list[list[int]] = []
    face_explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while face_explorer.More():
        face = topods.Face(face_explorer.Current())
        ids: set[int] = set()
        edge_explorer = TopExp_Explorer(face, TopAbs_EDGE)
        while edge_explorer.More():
            edge = topods.Edge(edge_explorer.Current())
            if not BRep_Tool.Degenerated(edge):
                edge_id = edge_id_by_map_index.get(edge_map.FindIndex(edge))
                if edge_id is not None:
                    ids.add(edge_id)
            edge_explorer.Next()
        face_edge_ids.append(sorted(ids))
        face_explorer.Next()

    return face_edge_ids


def _extract_topology_vertices(shape) -> tuple[list[tuple[float, float, float]], list[int]]:
    """Real OCCT topology vertices (Stage 23) - the points where 2+ edges
    meet, de-duplicated by underlying shape identity via
    `TopTools_IndexedMapOfShape`, the same approach `_extract_edges` above
    uses for edges. Distinct from `MeshData.vertices`, which is flat
    triangle-soup data with no topology (every triangle owns 3 fresh,
    unshared vertices) - a nearest-mesh-vertex hit-test against that data
    could land on a tessellation seam that isn't a real corner, which is
    why the 3D viewport's vertex hit-testing needs this instead."""
    vertex_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_VERTEX, vertex_map)

    points: list[tuple[float, float, float]] = []
    ids: list[int] = []
    for i in range(1, vertex_map.Size() + 1):
        vertex = topods.Vertex(vertex_map.FindKey(i))
        point = BRep_Tool.Pnt(vertex)
        points.append((point.X(), point.Y(), point.Z()))
        ids.append(i - 1)

    return points, ids


def _sample_edge(edge: TopoDS_Edge) -> list[tuple[float, float, float]]:
    """Polyline points along `edge`'s real curve: exactly 2 (start/end) for
    a straight line, more for curved edges, adaptively subdivided so no
    sampled chord deviates from the true curve by more than
    EDGE_CHORD_HEIGHT_TOLERANCE - the same tangential-deflection algorithm
    OCCT's own viewer uses to discretize edges for display."""
    adaptor = BRepAdaptor_Curve(edge)
    discretizer = GCPnts_TangentialDeflection(
        adaptor, EDGE_ANGULAR_DEFLECTION, EDGE_CHORD_HEIGHT_TOLERANCE, 2
    )
    return [
        (point.X(), point.Y(), point.Z())
        for point in (discretizer.Value(i) for i in range(1, discretizer.NbPoints() + 1))
    ]


def _append_face_triangles(face: TopoDS_Face, mesh: MeshData, face_id: int) -> None:
    location = TopLoc_Location()
    triangulation = BRep_Tool.Triangulation(face, location)
    if triangulation is None:
        return

    transform = location.Transformation()
    reversed_face = face.Orientation() == TopAbs_REVERSED

    nodes: list[tuple[float, float, float]] = []
    for i in range(1, triangulation.NbNodes() + 1):
        point = triangulation.Node(i)
        point.Transform(transform)
        nodes.append((point.X(), point.Y(), point.Z()))

    for i in range(1, triangulation.NbTriangles() + 1):
        n1, n2, n3 = triangulation.Triangle(i).Get()
        if reversed_face:
            n1, n2, n3 = n1, n3, n2
        p1, p2, p3 = nodes[n1 - 1], nodes[n2 - 1], nodes[n3 - 1]
        normal = _normalize(_cross(_sub(p2, p1), _sub(p3, p1)))

        base_index = len(mesh.vertices)
        mesh.vertices.extend([p1, p2, p3])
        mesh.normals.extend([normal, normal, normal])
        mesh.triangles.append(Triangle(a=base_index, b=base_index + 1, c=base_index + 2))
        mesh.face_ids.append(face_id)
