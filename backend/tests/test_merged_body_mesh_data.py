"""Real-OCCT test for `app.document.router._merged_body_mesh_data`'s
Milestone 4 addition: `face_ids`/`body_ids` threading across a merge of
several Bodies. `assembly-mesh.glb` needs `(body_ids[i], face_ids[i])` to
reconstruct a real `SubShapeRef{body_id, shape_type: "face", index}` for
whichever triangle a VR ray hit - this only works if `face_ids` stays each
Body's own dense 0-based `TopExp_Explorer` order (not offset the way
`triangles`' vertex indices are) and `body_ids` correctly says which Body
each triangle came from. Two same-shaped boxes are enough to prove both:
if `face_ids` were wrongly offset, the second box's ids would start past 5
instead of repeating 0-5; if `body_ids` were wrong, the two boxes'
triangles couldn't be told apart at all.
"""

from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document.router import _merged_body_mesh_data


def test_merged_body_mesh_data_keeps_face_ids_per_body_and_tags_body_ids():
    box_a = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    box_b = BRepPrimAPI_MakeBox(5.0, 5.0, 5.0).Shape()

    merged = _merged_body_mesh_data({"body-a": box_a, "body-b": box_b})

    # Every parallel array covers every triangle, nothing dropped or padded.
    assert len(merged.face_ids) == len(merged.triangles)
    assert len(merged.body_ids) == len(merged.triangles)

    body_a_faces = {fid for fid, bid in zip(merged.face_ids, merged.body_ids) if bid == "body-a"}
    body_b_faces = {fid for fid, bid in zip(merged.face_ids, merged.body_ids) if bid == "body-b"}

    # A box has 6 faces - each body's own dense ids are 0..5, NOT offset
    # past the other body's range (the bug this test guards against: naively
    # reusing the same offset the vertex-index merge already applies would
    # push body-b's ids to 6..11 instead).
    assert body_a_faces == {0, 1, 2, 3, 4, 5}
    assert body_b_faces == {0, 1, 2, 3, 4, 5}

    # Every triangle is tagged with exactly one of the two real body ids.
    assert set(merged.body_ids) == {"body-a", "body-b"}


def test_merged_body_mesh_data_of_a_single_body_matches_tessellate_shape_directly():
    from app.document.mesh import tessellate_shape

    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    solo = tessellate_shape(box)

    merged = _merged_body_mesh_data({"only-body": box})

    assert merged.face_ids == solo.face_ids
    assert merged.body_ids == ["only-body"] * len(solo.triangles)


# ---- VR Measure tool: per-Body edge / vertex / face-boundary data (`MeshData.body_topology`) ----


def _edge_end_points(shape):
    from OCC.Core.BRep import BRep_Tool
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopoDS import topods

    edge = topods.Edge(shape)
    first = BRep_Tool.Pnt(topexp.FirstVertex(edge))
    last = BRep_Tool.Pnt(topexp.LastVertex(edge))
    return (first.X(), first.Y(), first.Z()), (last.X(), last.Y(), last.Z())


def test_merged_body_mesh_data_keeps_each_bodys_edges_vertices_and_face_boundaries():
    box_a = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    box_b = BRepPrimAPI_MakeBox(5.0, 5.0, 5.0).Shape()

    merged = _merged_body_mesh_data({"body-a": box_a, "body-b": box_b})

    assert set(merged.body_topology) == {"body-a", "body-b"}
    for body_id in ("body-a", "body-b"):
        topo = merged.body_topology[body_id]
        assert sorted(set(topo.edge_ids)) == list(range(12))  # a box has 12 edges
        assert sorted(topo.edge_ref_indices) == list(range(12))  # no degenerate edge: dense id == ref index
        assert len(topo.topology_vertices) == 8
        assert topo.topology_vertex_ids == list(range(8))
        assert len(topo.face_edge_ids) == 6
        assert all(len(ids) == 4 for ids in topo.face_edge_ids)  # every box face is bounded by 4 edges


def test_edge_ref_indices_name_the_edge_the_resolver_would_find_even_past_a_degenerate_edge():
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeSphere

    from app.document.extrude import resolve_subshape_from_bodies
    from app.document.models import SubShapeRef, SubShapeType

    sphere = BRepPrimAPI_MakeSphere(10.0).Shape()
    merged = _merged_body_mesh_data({"ball": sphere})
    topo = merged.body_topology["ball"]

    # A sphere's poles are degenerate edges: the drawing ids skip them, so dense ids and raw indices diverge...
    assert topo.edge_ref_indices != list(range(len(topo.edge_ref_indices)))
    # ...and the translation lands every drawn edge on the same real edge the resolver finds for that index.
    segments_by_edge: dict[int, list[float]] = {}
    for segment_index, dense_id in enumerate(topo.edge_ids):
        segments_by_edge.setdefault(dense_id, []).extend(topo.edges[segment_index * 6 : segment_index * 6 + 6])
    assert segments_by_edge
    for dense_id, segments in segments_by_edge.items():
        resolved = resolve_subshape_from_bodies(
            {"ball": sphere}, SubShapeRef(body_id="ball", shape_type=SubShapeType.EDGE, index=topo.edge_ref_indices[dense_id])
        )
        start, end = _edge_end_points(resolved)
        drawn_start, drawn_end = tuple(segments[0:3]), tuple(segments[-3:])
        # an edge may be traversed either way round, and a closed edge starts where it ends
        close = lambda a, b: all(abs(x - y) < 1e-6 for x, y in zip(a, b))  # noqa: E731
        assert (close(start, drawn_start) and close(end, drawn_end)) or (close(start, drawn_end) and close(end, drawn_start))

