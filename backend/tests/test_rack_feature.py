"""Real-OCCT tests for RackFeature's full router/HTTP surface -
`docs/gear-design/03-rack.md`. Structurally mirrors `test_gear_feature.py`'s
own shape - see that file for the same helper-function conventions this
reuses.
"""

import math

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _create_rack(part_id: str, **overrides) -> dict:
    payload = {
        "rack_type": "boss",
        "module": 2.0,
        "tooth_count": 10,
        "face_width": 5.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/rack-features", json=payload)


# --- Basic construction --------------------------------------------------


def test_rack_produces_one_body_with_real_mesh_geometry():
    part = _create_part()
    response = _create_rack(part["id"])
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "rack"

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "computed"
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0
    # module=2, tooth_count=10 -> tooth_pitch = pi*2, length = 10*pitch (the
    # actual outline is very slightly wider: the outermost teeth's own
    # dedendum-flank points extend a bit past the nominal half-length, since
    # there's no neighbouring tooth there to share the root land with).
    expected_length = 10 * math.pi * 2.0
    x_values = [x for x, y, z in vertices]
    assert abs((max(x_values) - min(x_values)) - expected_length) < 2.0
    # addendum_height=2 above the pitch line, dedendum_height=2.5 below it,
    # plus the default backing_height of 2*module=4 further below that.
    y_values = [y for x, y, z in vertices]
    assert abs((max(y_values) - min(y_values)) - 8.5) < 0.5
    z_values = {round(z, 3) for x, y, z in vertices}
    assert min(z_values) == 0.0
    assert max(z_values) == 5.0


def test_rack_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    response = _create_rack(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


def test_rack_on_an_explicit_xz_plane():
    part = _create_part()
    response = _create_rack(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    vertices = mesh[0]["mesh"]["vertices"]
    y_values = {round(y, 3) for x, y, z in vertices}
    assert len(y_values) >= 2
    assert (max(y_values) - min(y_values)) == 5.0


def test_custom_backing_height_changes_the_mesh():
    part_default = _create_part("Default backing")
    default_response = _create_rack(part_default["id"])
    assert default_response.status_code == 201, default_response.json()
    default_vertices = _mesh(part_default["id"])[0]["mesh"]["vertices"]

    part_custom = _create_part("Custom backing")
    custom_response = _create_rack(part_custom["id"], backing_height=10.0)
    assert custom_response.status_code == 201, custom_response.json()
    custom_vertices = _mesh(part_custom["id"])[0]["mesh"]["vertices"]

    assert default_vertices != custom_vertices


# --- Invalid parameters (gear_math validation surfacing through the router) --


def test_negative_module_is_rejected():
    part = _create_part()
    response = _create_rack(part["id"], module=-1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_rack_parameters"


def test_zero_tooth_count_is_rejected():
    part = _create_part()
    response = _create_rack(part["id"], tooth_count=0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_rack_parameters"


def test_zero_face_width_is_rejected():
    part = _create_part()
    response = _create_rack(part["id"], face_width=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_rack_parameters"


def test_zero_backing_height_is_rejected():
    part = _create_part()
    response = _create_rack(part["id"], backing_height=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_rack_parameters"


# --- Composability: Boss/Cut, and being a valid target/source for other Features --


def test_cut_rack_requires_a_target_body():
    part = _create_part()
    response = _create_rack(part["id"], rack_type="cut")
    assert response.status_code == 422


def test_boss_rack_can_target_an_existing_rack_body():
    part = _create_part()
    first = _create_rack(part["id"])
    assert first.status_code == 201, first.json()
    first_body_id = _mesh(part["id"])[0]["body_id"]

    second = _create_rack(part["id"], plane_ref={"fixed_plane": "XY"}, target_body_ids=[first_body_id])
    assert second.status_code == 201, second.json()
    # Fused into the same target - still exactly one Body.
    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_update_rack_feature_changes_tooth_count_and_the_mesh_reflects_it():
    part = _create_part()
    create_response = _create_rack(part["id"], tooth_count=10)
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    mesh_at_10 = _mesh(part["id"])[0]["mesh"]["vertices"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/rack-features/{feature_id}", json={"tooth_count": 15}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["tooth_count"] == 15

    mesh_at_15 = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert mesh_at_15 != mesh_at_10


def test_update_rack_feature_rejects_an_invalid_change():
    part = _create_part()
    create_response = _create_rack(part["id"])
    feature_id = create_response.json()["id"]
    patch_response = client.patch(
        f"/document/parts/{part['id']}/rack-features/{feature_id}", json={"module": -5.0}
    )
    assert patch_response.status_code == 422
    # The original Feature must be untouched after a rejected update.
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_step_export_succeeds_for_a_rack_body():
    part = _create_part()
    response = _create_rack(part["id"])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert len(export_response.content) > 1000
    assert b"ISO-10303-21" in export_response.content


def test_rack_body_can_be_cut_afterward_via_a_new_sketch():
    """`00-conventions.md`'s "downstream Features already work on any
    gear-family Body" claim, exercised for a rack: a Sketch on the rack's
    own top face, a small circle, then an Extrude Cut targeting the rack's
    Body id."""
    part = _create_part()
    rack_response = _create_rack(part["id"])
    assert rack_response.status_code == 201, rack_response.json()
    rack_body_id = _mesh(part["id"])[0]["body_id"]

    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]

    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0})
    assert center.status_code == 201
    radius_point = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 1.0, "y": 0.0})
    assert radius_point.status_code == 201
    circle = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center.json()["id"], "radius_point_id": radius_point.json()["id"]},
    )
    assert circle.status_code == 201

    cut_response = client.post(
        "/document/parts/" + part["id"] + "/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "cut",
            "start_distance": -1.0,
            "end_distance": 10.0,
            "target_body_ids": [rack_body_id],
        },
    )
    assert cut_response.status_code == 201, cut_response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 1  # still one Body, now with a hole cut into it


def test_native_export_import_round_trips_a_rack_feature():
    """Mirrors `test_gear_feature.py`'s own native round-trip regression
    test - the exact same native_format.py omission bug found for
    GearFeature (missing `_feature_to_dict`/`_feature_from_dict` branches)
    was deliberately guarded against for RackFeature from the start; this
    test is the regression guard that would have caught it."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Rack Test")
        rack_response = _create_rack(part["id"], tooth_count=12, backing_height=6.0)
        assert rack_response.status_code == 201, rack_response.json()
        feature_id = rack_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        rack_dicts = [f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "rack"]
        assert any(f["id"] == feature_id for f in rack_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
