"""Pure-Python tests for `app.document.mesh_data.
synthesize_wireframe_edges_from_triangles` - no OCCT needed, same as
`test_mesh_export.py`/`test_mesh_import.py`.
"""

from app.document.mesh_data import MeshData, Triangle, synthesize_wireframe_edges_from_triangles


def test_a_single_triangle_produces_its_own_three_sides():
    mesh = MeshData()
    mesh.vertices = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    mesh.triangles = [Triangle(a=0, b=1, c=2)]

    edges, edge_ids = synthesize_wireframe_edges_from_triangles(mesh)

    assert len(edges) == 18  # 3 sides * 6 floats each
    assert edge_ids == [0, 0, 0]
    segments = [tuple(edges[i : i + 6]) for i in range(0, len(edges), 6)]
    assert segments == [
        (0.0, 0.0, 0.0, 1.0, 0.0, 0.0),
        (1.0, 0.0, 0.0, 0.0, 1.0, 0.0),
        (0.0, 1.0, 0.0, 0.0, 0.0, 0.0),
    ]


def test_two_triangles_each_get_their_own_dense_edge_id():
    mesh = MeshData()
    mesh.vertices = [
        (0.0, 0.0, 0.0),
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (1.0, 0.0, 0.0),
        (1.0, 1.0, 0.0),
        (0.0, 1.0, 0.0),
    ]
    mesh.triangles = [Triangle(a=0, b=1, c=2), Triangle(a=3, b=4, c=5)]

    edges, edge_ids = synthesize_wireframe_edges_from_triangles(mesh)

    assert edge_ids == [0, 0, 0, 1, 1, 1]
    assert len(edges) == 36


def test_an_empty_mesh_produces_no_edges():
    edges, edge_ids = synthesize_wireframe_edges_from_triangles(MeshData())
    assert edges == []
    assert edge_ids == []
