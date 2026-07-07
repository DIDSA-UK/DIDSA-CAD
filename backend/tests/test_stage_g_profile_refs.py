"""Prompt G: real-OCCT tests for Extrude/Revolve's new `profile_refs`
selection - all touch `app.main`/`app.document.extrude`/`app.document.
revolve`, which import OCC.Core directly, so (per the recurring caveat in
docs/status.md) these are `ast.parse`-verified/manually reviewed only in
this sandbox, same as every other OCCT-touching backend prompt in this
project until real CI runs it. Mirrors `test_stage_f_revolve.py`'s own
helper conventions.
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
    return [_add_line(sketch_id, a["id"], b["id"]) for a, b in zip(corners, corners[1:] + corners[:1])]


def _add_open_chain(sketch_id: str, x0: float, y0: float) -> None:
    a = _add_point(sketch_id, x0, y0)
    b = _add_point(sketch_id, x0 + 10.0, y0)
    c = _add_point(sketch_id, x0 + 10.0, y0 + 10.0)
    _add_line(sketch_id, a["id"], b["id"])
    _add_line(sketch_id, b["id"], c["id"])


def _profile_ref(sketch_id: str, line_id: str) -> dict:
    return {"sketch_id": sketch_id, "entity_type": "line", "entity_id": line_id}


def _create_extrude(part_id: str, sketch_feature_id: str, *, profile_refs=None, **kwargs) -> dict:
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "extrude_type": kwargs.get("extrude_type", "boss"),
        "start_distance": kwargs.get("start_distance", 0.0),
        "end_distance": kwargs.get("end_distance", 10.0),
        "target_body_ids": kwargs.get("target_body_ids", []),
        "profile_refs": profile_refs or [],
    }
    return client.post(f"/document/parts/{part_id}/extrude-features", json=payload)


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


# --- Success -------------------------------------------------------------------


def test_a_sketch_with_a_closed_loop_and_an_open_chain_extrudes_successfully():
    """The core Prompt G fix: a sketch that used to fail as NO_LOOP now
    extrudes the usable closed loop, ignoring the open chain."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_open_chain(sketch_feature["sketch_id"], 100.0, 0.0)

    response = _create_extrude(part["id"], sketch_feature["id"])
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_profile_refs_narrows_a_multi_profile_sketch_to_the_named_loop():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    lines_a = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)

    ref = _profile_ref(sketch_feature["sketch_id"], lines_a[0]["id"])
    response = _create_extrude(part["id"], sketch_feature["id"], profile_refs=[ref])
    assert response.status_code == 201
    assert response.json()["profile_refs"] == [ref]

    mesh = _mesh(part["id"])
    # Only the one named loop was extruded - a single Body, not two.
    assert len(mesh) == 1


def test_empty_profile_refs_extrudes_every_outer_profile_same_as_before():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)

    response = _create_extrude(part["id"], sketch_feature["id"])
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 2


# --- Rejections ------------------------------------------------------------


def test_a_profile_ref_pointing_at_a_point_is_rejected_as_invalid_profile_ref():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    point = _add_point(sketch_feature["sketch_id"], 50.0, 50.0)

    bad_ref = {"sketch_id": sketch_feature["sketch_id"], "entity_type": "point", "entity_id": point["id"]}
    response = _create_extrude(part["id"], sketch_feature["id"], profile_refs=[bad_ref])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_profile_ref"


def test_a_profile_ref_belonging_to_a_hole_is_rejected_as_invalid_profile_ref():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 20.0)
    hole_lines = _add_square(sketch_feature["sketch_id"], 5.0, 5.0, 5.0)

    ref = _profile_ref(sketch_feature["sketch_id"], hole_lines[0]["id"])
    response = _create_extrude(part["id"], sketch_feature["id"], profile_refs=[ref])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_profile_ref"


def test_a_profile_ref_belonging_to_an_open_chain_is_rejected_as_invalid_profile_ref():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    a = _add_point(sketch_feature["sketch_id"], 100.0, 0.0)
    b = _add_point(sketch_feature["sketch_id"], 110.0, 0.0)
    open_line = _add_line(sketch_feature["sketch_id"], a["id"], b["id"])

    ref = _profile_ref(sketch_feature["sketch_id"], open_line["id"])
    response = _create_extrude(part["id"], sketch_feature["id"], profile_refs=[ref])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_profile_ref"


def test_an_unknown_profile_ref_entity_id_is_rejected_as_invalid_profile_ref():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)

    ref = _profile_ref(sketch_feature["sketch_id"], "no-such-line")
    response = _create_extrude(part["id"], sketch_feature["id"], profile_refs=[ref])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_profile_ref"


# --- Editing -----------------------------------------------------------------


def test_patch_can_narrow_profile_refs_on_an_existing_extrude():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    lines_a = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)

    created = _create_extrude(part["id"], sketch_feature["id"]).json()
    assert len(_mesh(part["id"])) == 2

    ref = _profile_ref(sketch_feature["sketch_id"], lines_a[0]["id"])
    patch_response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{created['id']}",
        json={"profile_refs": [ref]},
    )
    assert patch_response.status_code == 200
    assert len(_mesh(part["id"])) == 1


# --- Revolve mirrors the same behaviour -------------------------------------


def test_revolve_profile_refs_narrows_a_multi_profile_sketch():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    lines_a = _add_square(sketch_feature["sketch_id"], 10.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)
    axis = _profile_ref(sketch_feature["sketch_id"], lines_a[0]["id"])

    response = client.post(
        f"/document/parts/{part['id']}/revolve-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "axis_ref": axis,
            "angle": 180.0,
            "mode": "boss",
            "target_body_ids": [],
            "profile_refs": [axis],
        },
    )
    assert response.status_code == 201
    assert len(_mesh(part["id"])) == 1
