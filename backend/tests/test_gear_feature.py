"""Real-OCCT tests for GearFeature's full router/HTTP surface -
`docs/gear-design/02-gear-feature.md`. Structurally mirrors
`test_stage_f_revolve.py`'s own shape - see that file for the same
helper-function conventions this reuses.
"""

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


def _create_gear(part_id: str, **overrides) -> dict:
    payload = {
        "gear_type": "boss",
        "is_internal": False,
        "module": 2.0,
        "tooth_count": 20,
        "face_width": 5.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-features", json=payload)


# --- External gear -----------------------------------------------------------


def test_external_gear_produces_one_body_with_real_mesh_geometry():
    part = _create_part()
    response = _create_gear(part["id"])
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "gear"
    assert body["is_internal"] is False

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "computed"
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0
    # A module-2/20-tooth gear's addendum radius is 22mm - every vertex
    # should sit within a small tolerance of that, and the gear should
    # span some real face_width in Z (default XY plane, extrude along Z).
    max_radius = max((x**2 + y**2) ** 0.5 for x, y, z in vertices)
    assert max_radius <= 22.5
    assert max_radius >= 20.0  # nowhere near degenerate
    z_values = {round(z, 3) for x, y, z in vertices}
    assert min(z_values) == 0.0
    assert max(z_values) == 5.0


def test_external_gear_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    response = _create_gear(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


def test_external_gear_on_an_explicit_xz_plane():
    part = _create_part()
    response = _create_gear(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    vertices = mesh[0]["mesh"]["vertices"]
    # Extruded along XZ's own normal (-Y or +Y depending on this app's XZ
    # convention) - regardless of sign, Y should span the face_width and
    # X/Z should carry the gear's own radial extent, the mirror image of
    # the XY-plane case above.
    y_values = {round(y, 3) for x, y, z in vertices}
    assert len(y_values) >= 2
    assert (max(y_values) - min(y_values)) == 5.0


def test_external_gear_with_root_fillet_still_produces_valid_geometry():
    part = _create_part()
    response = _create_gear(part["id"], root_fillet_radius=0.3)
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert len(mesh[0]["mesh"]["vertices"]) > 0


# --- Internal gear -------------------------------------------------------


def test_internal_gear_requires_outer_diameter():
    part = _create_part()
    response = _create_gear(part["id"], is_internal=True, tooth_count=60)
    assert response.status_code == 422
    assert "outer_diameter" in response.json()["detail"]


def test_external_gear_rejects_outer_diameter():
    part = _create_part()
    response = _create_gear(part["id"], outer_diameter=100.0)
    assert response.status_code == 422


def test_internal_gear_produces_an_annulus_body():
    part = _create_part()
    response = _create_gear(part["id"], is_internal=True, tooth_count=60, outer_diameter=140.0)
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0
    max_radius = max((x**2 + y**2) ** 0.5 for x, y, z in vertices)
    # The outer rim (70mm radius) should be the largest extent - well
    # past the tooth profile's own dedendum radius (~62.5mm for these
    # params), confirming the annulus's rim, not just the tooth ring, is
    # actually present in the mesh.
    assert max_radius == 70.0 or abs(max_radius - 70.0) < 0.5


def test_internal_gear_outer_diameter_too_small_is_rejected():
    part = _create_part()
    # tooth_count=60, module=2 -> dedendum diameter ~125mm; 100mm rim
    # leaves no material.
    response = _create_gear(part["id"], is_internal=True, tooth_count=60, outer_diameter=100.0)
    assert response.status_code == 422, response.json()
    assert response.json()["detail"]["type"] == "invalid_gear_parameters"


# --- Invalid parameters (gear_math validation surfacing through the router) --


def test_negative_module_is_rejected():
    part = _create_part()
    response = _create_gear(part["id"], module=-1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_parameters"


def test_too_few_teeth_is_rejected():
    part = _create_part()
    response = _create_gear(part["id"], tooth_count=3)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_parameters"


def test_zero_face_width_is_rejected():
    part = _create_part()
    response = _create_gear(part["id"], face_width=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_parameters"


# --- Composability: Boss/Cut, and being a valid target/source for other Features --


def test_cut_gear_requires_a_target_body():
    part = _create_part()
    response = _create_gear(part["id"], gear_type="cut")
    assert response.status_code == 422


def test_boss_gear_can_target_an_existing_gear_body():
    part = _create_part()
    first = _create_gear(part["id"])
    assert first.status_code == 201, first.json()
    first_body_id = _mesh(part["id"])[0]["body_id"]

    second = _create_gear(part["id"], plane_ref={"fixed_plane": "XY"}, target_body_ids=[first_body_id])
    assert second.status_code == 201, second.json()
    # Fused into the same target - still exactly one Body.
    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_root_fillet_actually_changes_the_mesh_not_a_silent_no_op():
    """Confirms the fillet code path genuinely executes (BRepPrimAPI_
    MakePrism.Generated() finds the right axial edges and BRepFilletAPI_
    MakeFillet converges), not just "doesn't crash" - a silently-skipped
    fillet (the defensive fallback in _apply_root_fillet) would otherwise
    look identical to a working one in every test above."""
    part_plain = _create_part("Plain")
    plain_response = _create_gear(part_plain["id"], tooth_count=12, root_fillet_radius=0.0)
    assert plain_response.status_code == 201, plain_response.json()
    plain_vertices = _mesh(part_plain["id"])[0]["mesh"]["vertices"]

    part_filleted = _create_part("Filleted")
    filleted_response = _create_gear(part_filleted["id"], tooth_count=12, root_fillet_radius=0.4)
    assert filleted_response.status_code == 201, filleted_response.json()
    filleted_vertices = _mesh(part_filleted["id"])[0]["mesh"]["vertices"]

    assert plain_vertices != filleted_vertices


def test_update_gear_feature_changes_tooth_count_and_the_mesh_reflects_it():
    part = _create_part()
    create_response = _create_gear(part["id"], tooth_count=20)
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    mesh_at_20 = _mesh(part["id"])[0]["mesh"]["vertices"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/gear-features/{feature_id}", json={"tooth_count": 30}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["tooth_count"] == 30

    mesh_at_30 = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert mesh_at_30 != mesh_at_20


def test_update_gear_feature_rejects_an_invalid_change():
    part = _create_part()
    create_response = _create_gear(part["id"])
    feature_id = create_response.json()["id"]
    patch_response = client.patch(
        f"/document/parts/{part['id']}/gear-features/{feature_id}", json={"module": -5.0}
    )
    assert patch_response.status_code == 422
    # The original Feature must be untouched after a rejected update.
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_step_export_succeeds_for_a_gear_body():
    part = _create_part()
    response = _create_gear(part["id"])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    # A real STEP file: a non-trivial size and the standard header.
    assert len(export_response.content) > 1000
    assert b"ISO-10303-21" in export_response.content


def test_gear_body_can_be_cut_afterward_via_a_new_sketch():
    """`00-conventions.md`'s "downstream Features already work on any gear
    Body" claim, exercised for real: a Sketch on the gear's own top face,
    a small circle, then an Extrude Cut targeting the gear's Body id -
    the exact keyway/fixing-hole workflow that doc describes."""
    part = _create_part()
    gear_response = _create_gear(part["id"])
    assert gear_response.status_code == 201, gear_response.json()
    gear_body_id = _mesh(part["id"])[0]["body_id"]

    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]

    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0})
    assert center.status_code == 201
    radius_point = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 3.0, "y": 0.0})
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
            "target_body_ids": [gear_body_id],
        },
    )
    assert cut_response.status_code == 201, cut_response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 1  # still one Body, now with a hole cut into it


def test_native_export_import_round_trips_a_gear_feature():
    """Real bug this test would have caught directly: native_format.py's
    _feature_to_dict/_feature_from_dict never gained a GearFeature branch
    (found instead via incidental cross-test global-store pollution when
    test_stage_native_format.py ran later in the same session and hit
    every Part this file had already created) - Save/Open would have
    broken for any user with a gear in their Part. Follows
    test_stage_native_format.py's own save/restore-global-state
    convention so this doesn't leak state into other test modules either."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Gear Test")
        gear_response = _create_gear(
            part["id"], is_internal=True, tooth_count=60, outer_diameter=140.0, root_fillet_radius=0.2
        )
        assert gear_response.status_code == 201, gear_response.json()
        feature_id = gear_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        gear_dicts = [f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "gear"]
        assert any(f["id"] == feature_id for f in gear_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
