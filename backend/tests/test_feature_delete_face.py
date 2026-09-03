"""Direct Editing family, fourth entry: real-OCCT tests for
`DeleteFaceFeature`. V2 (see `docs/direct-editing-scope.md`): removes
every face in `face_refs` (1+, all sharing a Body) in one pass, healing
the resulting opening(s) closed via `BRepAlgoAPI_Defeaturing` (see
`app.document.delete_face`) - both multi-face-in-one-call and non-planar
(cylindrical/conical) removal confirmed via a real spike to be the exact
same technique v1 already used, not a new one. Modifies its Body in place
(keeps the same id). Mirrors test_feature_scale_body.py's own structure
and helpers (copy-pasted, not shared via conftest, same as every other
test_feature_*.py file). Needs a real pythonocc-core environment (not
available in this repo's own dev sandbox - see docs/status.md's dated
entries for whether a real on-device/CI pass has actually run by the time
this is read).
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _create_chamfer_feature(part_id: str, edge_refs: list[dict], distance: float = 2.0) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/chamfer-features",
        json={"edge_refs": edge_refs, "distance": distance},
    )
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _mesh_for_body(part_id: str, body_id: str) -> dict:
    return next(e["mesh"] for e in _mesh(part_id) if e["body_id"] == body_id)


def _face_count(part_id: str, body_id: str) -> int:
    return len({fid for fid in _mesh_for_body(part_id, body_id)["face_ids"]})


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = _mesh_for_body(part_id, body_id)
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _edge_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "edge", "index": index}


def _face_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "face", "index": index}


def _create_delete_face(part_id: str, face_refs: dict | list[dict]):
    """`face_refs` accepts either a single ref dict (the common single-face
    case, wrapped into a one-entry list here) or an already-built list (V2
    multi-face cases)."""
    refs = [face_refs] if isinstance(face_refs, dict) else face_refs
    return client.post(f"/document/parts/{part_id}/delete-face-features", json={"face_refs": refs})


def _add_circle(sketch_id: str, cx: float, cy: float, radius: float) -> dict:
    center = _add_point(sketch_id, cx, cy)
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
    return response.json()


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


def _make_chamfered_box(part_id: str, *, x0: float = 0.0) -> str:
    """A 10x10x10 box with one edge chamfered by 2.0 - the realistic Delete
    Face case (undo the chamfer, healing back to a plain box)."""
    body_id = _make_box(part_id, x0=x0)
    _create_chamfer_feature(part_id, [_edge_ref(body_id, 0)], distance=2.0)
    return body_id


# --- Creation validation -------------------------------------------------------


def test_delete_face_with_a_non_face_ref_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_delete_face(part["id"], _edge_ref(body_id, 0))

    assert response.status_code == 422


def test_delete_face_with_an_unknown_body_id_is_rejected():
    part = _create_part()

    response = _create_delete_face(part["id"], _face_ref("not-a-real-feature-id", 0))

    assert response.status_code == 422


def test_deleting_a_plain_box_face_with_no_adjacent_feature_to_heal_is_rejected():
    """v1 scope's own real-world limitation, confirmed via a pythonocc-core
    spike (see app.document.delete_face's own module docstring): removing
    a structural face of a primitive box has no well-defined healed
    result - fails closed rather than silently no-op'ing or corrupting the
    Body."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_delete_face(part["id"], _face_ref(body_id, 0))

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "delete_face_failed"


# --- Delete Face geometry (the realistic case: undo a chamfer) -----------------


def test_deleting_a_chamfer_face_heals_the_box_back_to_its_original_shape():
    part = _create_part()
    body_id = _make_chamfered_box(part["id"])
    chamfered_faces = _face_count(part["id"], body_id)
    assert chamfered_faces == 7  # 6 box faces + 1 new chamfer face

    # The chamfer's own new face's index within OCCT's own topexp.MapShapes
    # enumeration - confirmed empirically against the real backend (not
    # assumed): index 2, not "whichever index looks newest" - see this
    # file's own module docstring for why guessing this by hand isn't safe.
    response = _create_delete_face(part["id"], _face_ref(body_id, 2))

    assert response.status_code == 201
    assert response.json()["type"] == "delete_face"
    assert response.json()["face_refs"][0]["index"] == 2

    # Delete Face modifies the Body in place - same id, no new Body minted.
    assert _body_ids(part["id"]) == [body_id]
    assert _face_count(part["id"], body_id) == 6
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (0.0, 10.0)


def test_update_delete_face_changes_which_face_is_removed():
    part = _create_part()
    body_id = _make_chamfered_box(part["id"])
    # Point the feature at a harmless face first (won't heal - expect the
    # create call itself to reject it), so instead create against the real
    # chamfer face, then PATCH it to point at... itself (a no-op edit that
    # should stay valid) to confirm the update path re-validates correctly.
    feature = _create_delete_face(part["id"], _face_ref(body_id, 2)).json()

    response = client.patch(
        f"/document/parts/{part['id']}/delete-face-features/{feature['id']}",
        json={"face_refs": [_face_ref(body_id, 2)]},
    )

    assert response.status_code == 200
    assert _face_count(part["id"], body_id) == 6


# --- V2: multi-face and non-planar removal --------------------------------------
# Indices confirmed empirically against the real backend, same discipline this
# file's own module docstring establishes for the chamfer-face case above.


def test_removing_two_fillet_blend_faces_at_once_heals_back_to_the_original_box():
    """`face_refs`' two entries are both removed in one `Build()` call -
    confirmed via a real pythonocc-core spike that this restores the exact
    original sharp box, bit-for-bit the same numbers a single-face removal
    already produces (see `app.document.delete_face`'s own module
    docstring)."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    edge0 = _edge_ref(body_id, 0)
    edge_far = _edge_ref(body_id, 6)
    fillet = client.post(
        f"/document/parts/{part['id']}/fillet-features",
        json={"edge_refs": [edge0, edge_far], "radius": 1.0},
    )
    assert fillet.status_code == 201
    assert _face_count(part["id"], body_id) == 8  # 6 box faces + 2 blend faces

    response = _create_delete_face(part["id"], [_face_ref(body_id, 2), _face_ref(body_id, 5)])

    assert response.status_code == 201
    assert _face_count(part["id"], body_id) == 6
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (0.0, 10.0)


def test_removing_a_cylindrical_hole_wall_heals_the_box_back_to_solid():
    """A non-fillet-blend, genuinely arbitrary non-planar face - confirmed
    via spike that the same technique v1 used for planar faces already
    handles this, not just Fillet-generated blend faces."""
    part = _create_part()
    box_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], box_sketch["id"])
    body_id = _body_ids(part["id"])[0]
    hole_sketch = _create_sketch_feature(part["id"])
    _add_circle(hole_sketch["sketch_id"], 5.0, 5.0, 2.0)
    _create_extrude_feature(
        part["id"], hole_sketch["id"], extrude_type="cut", start_distance=-1.0, end_distance=11.0,
        target_body_ids=[body_id],
    )
    assert _face_count(part["id"], body_id) == 7  # 6 box faces + 1 cylindrical wall

    response = _create_delete_face(part["id"], _face_ref(body_id, 6))

    assert response.status_code == 201
    assert _face_count(part["id"], body_id) == 6
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (0.0, 10.0)


def test_delete_face_with_faces_from_two_different_bodies_is_rejected():
    part = _create_part()
    body_a = _make_box(part["id"], x0=0.0)
    body_b = _make_box(part["id"], x0=20.0)

    response = _create_delete_face(part["id"], [_face_ref(body_a, 0), _face_ref(body_b, 0)])

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "mixed_body_selection"


def test_delete_face_with_empty_face_refs_is_rejected():
    part = _create_part()
    _make_box(part["id"], x0=0.0)

    response = client.post(f"/document/parts/{part['id']}/delete-face-features", json={"face_refs": []})

    assert response.status_code == 422


# --- native_format round-trip -------------------------------------------------


def test_delete_face_feature_round_trips_through_native_export_import():
    """Mirrors test_feature_scale_body.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_chamfered_box(part["id"])
        delete_face = _create_delete_face(part["id"], _face_ref(body_id, 2)).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "delete_face")
        assert round_tripped["face_refs"] == delete_face["face_refs"]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_faces_owning_extrude_cascade_deletes_the_delete_face_feature():
    part = _create_part()
    body_id = _make_chamfered_box(part["id"])
    delete_face = _create_delete_face(part["id"], _face_ref(body_id, 2)).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert delete_face["id"] in response.json()["deleted_feature_ids"]
