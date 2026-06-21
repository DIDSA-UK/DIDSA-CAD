from dataclasses import dataclass, field

from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import TopoDS_Face, topods


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
    while explorer.More():
        face = topods.Face(explorer.Current())
        _append_face_triangles(face, mesh)
        explorer.Next()

    return mesh


def _append_face_triangles(face: TopoDS_Face, mesh: MeshData) -> None:
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
