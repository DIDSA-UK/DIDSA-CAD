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
