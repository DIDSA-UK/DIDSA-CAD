"""Pure-Python tests for `app.document.mesh_data.
synthesize_wireframe_edges_from_triangles`/`mesh_quality_from_slider` - no
OCCT needed, same as `test_mesh_export.py`/`test_mesh_import.py`.
"""

from app.document.mesh_data import (
    DEFAULT_MESH_QUALITY,
    MeshData,
    Triangle,
    mesh_quality_from_slider,
    synthesize_wireframe_edges_from_triangles,
)


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


def test_mesh_quality_from_slider_at_midpoint_matches_the_pre_slider_default():
    quality = mesh_quality_from_slider(0.5)
    assert quality.linear_deflection == DEFAULT_MESH_QUALITY.linear_deflection
    assert quality.angular_deflection == DEFAULT_MESH_QUALITY.angular_deflection


def test_mesh_quality_from_slider_zero_is_coarsest_one_is_finest():
    coarsest = mesh_quality_from_slider(0.0)
    finest = mesh_quality_from_slider(1.0)
    default = mesh_quality_from_slider(0.5)

    # Larger deflection == coarser/fewer triangles - see MeshQuality's own
    # docstring.
    assert coarsest.linear_deflection > default.linear_deflection > finest.linear_deflection
    assert coarsest.angular_deflection > default.angular_deflection > finest.angular_deflection


def test_mesh_quality_from_slider_ties_linear_and_angular_deflection_together():
    for quality in (0.0, 0.25, 0.5, 0.75, 1.0):
        result = mesh_quality_from_slider(quality)
        assert result.linear_deflection == result.angular_deflection
