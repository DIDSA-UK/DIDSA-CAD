"""Prompt F: real-OCCT tests for Revolve's full router/HTTP surface - all
touch `app.main`/`app.document.revolve`/`app.document.extrude`, which import
OCC.Core directly, so (per the recurring caveat in docs/status.md) these are
`ast.parse`-verified/manually reviewed only in this sandbox, same as every
other OCCT-touching backend prompt in this project until real CI runs it.
Structurally mirrors `test_stage_d_fillet.py`'s own shape - see that file for
the same helper-function conventions this reuses.
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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> list[dict]:
    corners = [_add_point(sketch_id, x, y) for x, y in [
        (x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)
    ]]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return lines


def _create_offset_square_sketch_feature(
    part_id: str, *, x0=10.0, y0=0.0, size=10.0, plane="XY"
) -> tuple[dict, list[dict]]:
    """A square offset away from the origin along X (so it never straddles
    the Y axis) - the standard "ring/tube" revolve setup, and small enough
    that its own left edge (x=x0) is a valid, non-self-intersecting axis."""
    feature = _create_sketch_feature(part_id, plane)
    lines = _add_square(feature["sketch_id"], x0, y0, size)
    return feature, lines


def _axis_ref(sketch_id: str, line_id: str) -> dict:
    return {"sketch_id": sketch_id, "entity_type": "line", "entity_id": line_id}


def _create_standalone_axis_line(part_id: str, *, x: float, y0: float, y1: float, plane="XY") -> dict:
    """A Sketch containing just one Line, usable as a Revolve axis
    independent of any Profile - exercises the "axis Line lives in a
    different Sketch than the Profile" confirmed decision."""
    feature = _create_sketch_feature(part_id, plane)
    p0 = _add_point(feature["sketch_id"], x, y0)
    p1 = _add_point(feature["sketch_id"], x, y1)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return {"sketch_id": feature["sketch_id"], "line_id": line["id"]}


def _create_revolve(
    part_id: str,
    sketch_feature_id: str,
    axis_ref: dict,
    *,
    angle: float = 180.0,
    mode: str = "boss",
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/revolve-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "axis_ref": axis_ref,
            "angle": angle,
            "mode": mode,
            "target_body_ids": target_body_ids or [],
        },
    )


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _ring_part_sketch_and_axis() -> tuple[dict, dict, list[dict], dict]:
    """A Part with an offset-square Sketch (never straddling the Y axis) and
    its own left edge available as a same-Sketch axis Line, ready for a
    Revolve of either mode."""
    part = _create_part()
    sketch_feature, lines = _create_offset_square_sketch_feature(part["id"])
    left_edge = lines[0]  # the (x0, y0) -> (x0, y0+size) edge, at x=x0
    axis = _axis_ref(sketch_feature["sketch_id"], left_edge["id"])
    return part, sketch_feature, lines, axis


# --- Success -------------------------------------------------------------------


def test_boss_revolve_at_a_partial_angle_creates_a_new_body():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=180.0, mode="boss")
    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "revolve"
    assert body["angle"] == 180.0
    assert body["mode"] == "boss"
    assert body["produces"] == "body"

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "computed"


def test_boss_revolve_at_a_full_360_degrees_succeeds():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=360.0, mode="boss")
    assert response.status_code == 201
    assert response.json()["angle"] == 360.0

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_cut_revolve_merges_into_a_target_and_preserves_body_id():
    """Body-identity parity with Extrude/Fillet/Chamfer: Cut must subtract
    from the named target Body, keeping its id."""
    part = _create_part()
    box_sketch_feature = _create_sketch_feature(part["id"])
    _add_square(box_sketch_feature["sketch_id"], 0.0, 0.0, 100.0)
    boss_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": box_sketch_feature["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 100.0,
            "target_body_ids": [],
        },
    )
    assert boss_response.status_code == 201
    body_id = _mesh(part["id"])[0]["body_id"]

    cut_sketch_feature, lines = _create_offset_square_sketch_feature(
        part["id"], x0=10.0, y0=10.0, size=5.0
    )
    axis = _axis_ref(cut_sketch_feature["sketch_id"], lines[0]["id"])
    response = _create_revolve(
        part["id"], cut_sketch_feature["id"], axis, angle=360.0, mode="cut",
        target_body_ids=[body_id],
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["body_id"] == body_id


def test_axis_line_from_a_different_sketch_than_the_profile_is_allowed():
    """Confirmed decision: the axis Line need not belong to the Profile's own
    Sketch."""
    part = _create_part()
    sketch_feature, _lines = _create_offset_square_sketch_feature(part["id"])
    axis_sketch = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)
    axis = _axis_ref(axis_sketch["sketch_id"], axis_sketch["line_id"])

    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=270.0, mode="boss")
    assert response.status_code == 201


def test_axis_line_that_is_one_of_the_profiles_own_edges_is_allowed():
    """Confirmed decision: no special-case rejection for a self-referencing
    axis - `_ring_part_sketch_and_axis` already exercises exactly this, this
    test just names the decision explicitly."""
    part, sketch_feature, lines, axis = _ring_part_sketch_and_axis()
    assert axis["sketch_id"] == sketch_feature["sketch_id"]
    assert axis["entity_id"] == lines[0]["id"]
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=90.0, mode="boss")
    assert response.status_code == 201


def test_list_features_includes_the_revolve():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    created = _create_revolve(part["id"], sketch_feature["id"], axis, angle=120.0).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    revolve_entries = {f["id"]: f for f in features if f["type"] == "revolve"}
    assert created["id"] in revolve_entries
    assert revolve_entries[created["id"]]["angle"] == 120.0


# --- Rejections ------------------------------------------------------------


def test_an_angle_of_zero_is_rejected():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=0.0)
    assert response.status_code == 400


def test_a_negative_angle_is_rejected():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=-10.0)
    assert response.status_code == 400


def test_an_angle_over_360_is_rejected():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(part["id"], sketch_feature["id"], axis, angle=361.0)
    assert response.status_code == 400


def test_an_axis_ref_pointing_to_a_point_instead_of_a_line_is_rejected_as_invalid_axis_ref():
    part, sketch_feature, _lines, _axis = _ring_part_sketch_and_axis()
    point = _add_point(sketch_feature["sketch_id"], 10.0, 0.0)
    bad_axis = {
        "sketch_id": sketch_feature["sketch_id"],
        "entity_type": "point",
        "entity_id": point["id"],
    }
    response = _create_revolve(part["id"], sketch_feature["id"], bad_axis, angle=180.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_axis_ref"


def test_an_axis_ref_with_an_unknown_entity_id_is_rejected_as_invalid_axis_ref():
    part, sketch_feature, _lines, _axis = _ring_part_sketch_and_axis()
    bad_axis = {
        "sketch_id": sketch_feature["sketch_id"],
        "entity_type": "line",
        "entity_id": "no-such-line",
    }
    response = _create_revolve(part["id"], sketch_feature["id"], bad_axis, angle=180.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_axis_ref"


def test_cut_with_an_empty_target_body_ids_is_rejected():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(
        part["id"], sketch_feature["id"], axis, angle=180.0, mode="cut", target_body_ids=[]
    )
    assert response.status_code == 422


def test_a_target_body_ids_entry_naming_an_unknown_feature_is_rejected():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    response = _create_revolve(
        part["id"], sketch_feature["id"], axis, angle=180.0, mode="cut",
        target_body_ids=["no-such-feature"],
    )
    assert response.status_code == 400


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_the_angle_and_the_mesh_reflects_it():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    created = _create_revolve(part["id"], sketch_feature["id"], axis, angle=90.0).json()
    mesh_at_90 = _mesh(part["id"])[0]["mesh"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/revolve-features/{created['id']}",
        json={"angle": 270.0},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["angle"] == 270.0

    mesh_at_270 = _mesh(part["id"])[0]["mesh"]
    assert mesh_at_270["vertices"] != mesh_at_90["vertices"]


def test_patch_re_validates_the_merged_candidate_and_rejects_an_invalid_axis_ref():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    created = _create_revolve(part["id"], sketch_feature["id"], axis, angle=90.0).json()

    bad_axis = {"sketch_id": sketch_feature["sketch_id"], "entity_type": "line", "entity_id": "gone"}
    patch_response = client.patch(
        f"/document/parts/{part['id']}/revolve-features/{created['id']}",
        json={"axis_ref": bad_axis},
    )
    assert patch_response.status_code == 422
    assert patch_response.json()["detail"]["type"] == "invalid_axis_ref"

    # A rejected PATCH must never leave the Feature half-updated.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    revolve_entry = next(f for f in features if f["id"] == created["id"])
    assert revolve_entry["axis_ref"]["entity_id"] == axis["entity_id"]


def test_patch_can_edit_an_earlier_revolve_via_rollback_style_editing():
    """B4: any Feature can be edited, not just the last one - editing this
    Revolve's angle after a later, unrelated Extrude has been added must
    still resolve correctly, re-validated against its own pre-effect state
    (see `app.document.revolve.resolve_revolve`'s own doc comment)."""
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    created = _create_revolve(part["id"], sketch_feature["id"], axis, angle=90.0).json()

    other_sketch = _create_sketch_feature(part["id"])
    _add_square(other_sketch["sketch_id"], 100.0, 100.0, 10.0)
    client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": other_sketch["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 10.0,
            "target_body_ids": [],
        },
    )

    patch_response = client.patch(
        f"/document/parts/{part['id']}/revolve-features/{created['id']}",
        json={"angle": 180.0},
    )
    assert patch_response.status_code == 200
    assert patch_response.json()["angle"] == 180.0


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_profile_sketch_takes_the_revolve_with_it():
    part, sketch_feature, _lines, axis = _ring_part_sketch_and_axis()
    revolve = _create_revolve(part["id"], sketch_feature["id"], axis, angle=180.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{sketch_feature['id']}/cascade")
    assert response.status_code == 200
    assert revolve["id"] in response.json()["deleted_feature_ids"]

    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert all(f["id"] != revolve["id"] for f in features)


def test_cascade_deleting_a_different_sketch_axis_feature_takes_the_revolve_with_it():
    part = _create_part()
    sketch_feature, _lines = _create_offset_square_sketch_feature(part["id"])
    axis_sketch = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)
    axis_sketch_feature_id = client.get(f"/document/parts/{part['id']}/features").json()[-1]["id"]
    axis = _axis_ref(axis_sketch["sketch_id"], axis_sketch["line_id"])

    revolve = _create_revolve(part["id"], sketch_feature["id"], axis, angle=180.0).json()

    response = client.delete(
        f"/document/parts/{part['id']}/features/{axis_sketch_feature_id}/cascade"
    )
    assert response.status_code == 200
    assert revolve["id"] in response.json()["deleted_feature_ids"]
