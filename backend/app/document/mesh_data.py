"""The plain-data half of `app.document.mesh` - `MeshQuality`/`Triangle`/
`MeshData` have zero OCCT dependency of their own (only `tessellate_shape`
and its helpers, which stay in `mesh.py`, actually touch pythonocc-core).
Split out so anything that only needs the *data shape* (e.g.
`app.document.mesh_export`'s hand-rolled STL/OBJ/glb encoders, and their
tests) can import it without dragging in OCC.Core, which has no install in
this project's sandbox - `mesh.py` re-exports these same names unchanged,
so every existing `from app.document.mesh import MeshData` call site keeps
working exactly as before.
"""

from dataclasses import dataclass, field


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


def synthesize_wireframe_edges_from_triangles(mesh: MeshData) -> tuple[list[float], list[int]]:
    """On-device feedback: a shape with a triangulation but no real B-rep
    edge topology at all (an `ImportFeature`'s own mesh-format Body - see
    `app.document.import_geometry._shape_from_mesh_data` - a bare,
    surface-less face has zero `TopoDS_Edge`s to walk) rendered with no
    wireframe whatsoever in any render mode, since `app.document.mesh.
    _extract_edges` only ever samples real OCCT curves and had nothing to
    sample. `app.document.mesh.tessellate_shape` falls back to this
    whenever that real-edge extraction comes back empty (only reachable
    for exactly this kind of shape - every other Feature's own OCCT-
    constructed geometry always has real edges) - each triangle's own 3
    sides become one segment apiece, giving the client's existing edge-
    rendering pipeline something to draw.

    Deliberately not deduplicated across triangles that share a side (this
    bare mesh has no other topology to look a shared side up by) - two
    triangles sharing an edge draw over the same segment twice, which is
    harmless for a wireframe overlay. One dense edge id per triangle (not
    per side) is enough for this to slot into the same `edges`/`edge_ids`
    parallel-array shape every other consumer already expects; nothing
    downstream keys `ImportFeature` edges by individual side anyway."""
    edges: list[float] = []
    edge_ids: list[int] = []
    for i, triangle in enumerate(mesh.triangles):
        a, b, c = mesh.vertices[triangle.a], mesh.vertices[triangle.b], mesh.vertices[triangle.c]
        for p1, p2 in ((a, b), (b, c), (c, a)):
            edges.extend([p1[0], p1[1], p1[2], p2[0], p2[1], p2[2]])
            edge_ids.append(i)
    return edges, edge_ids
