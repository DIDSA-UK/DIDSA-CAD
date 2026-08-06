"""Real-OCCT tests for PlanetaryGearFeature's full router/HTTP surface -
`docs/gear-design/05-gear-chain-and-planetary.md`. Structurally mirrors
`test_rack_feature.py`'s own shape.
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


def _create_planetary(part_id: str, **overrides) -> dict:
    # sun_tooth_count=20, ring_tooth_count=60 -> planet_tooth_count =
    # (60-20)/2 = 20; assembly condition (20+60) % 5 == 0 - a well-formed
    # default.
    payload = {
        "module": 1.0,
        "sun_tooth_count": 20,
        "ring_tooth_count": 60,
        "planet_count": 5,
        "face_width": 5.0,
        "ring_outer_diameter": 70.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/planetary-gear-features", json=payload)


def test_valid_planetary_set_produces_sun_ring_and_n_planets():
    part = _create_part()
    response = _create_planetary(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["type"] == "planetary_gear"

    mesh = _mesh(part["id"])
    # sun + ring + 5 planets = 7 Bodies.
    assert len(mesh) == 7
    for entry in mesh:
        assert entry["source"] == "computed"
        assert len(entry["mesh"]["vertices"]) > 0


def test_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    response = _create_planetary(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


# --- Blocking validation (00-conventions.md's "no valid geometry" exception) --


def test_odd_tooth_difference_is_blocked():
    """`ring_tooth_count - sun_tooth_count` must be even - an odd
    difference has no valid integer planet tooth count at all, which BLOCKS
    creation outright rather than warning (`00-conventions.md`)."""
    part = _create_part()
    response = _create_planetary(part["id"], sun_tooth_count=20, ring_tooth_count=61, planet_count=5)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_planetary_parameters"


def test_non_positive_tooth_difference_is_blocked():
    part = _create_part()
    response = _create_planetary(part["id"], sun_tooth_count=30, ring_tooth_count=30, planet_count=5)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_planetary_parameters"


def test_assembly_condition_violation_is_blocked():
    """`(sun_tooth_count + ring_tooth_count) mod planet_count == 0` must
    hold - planets must land in mesh with both sun and ring simultaneously
    when evenly spaced."""
    part = _create_part()
    # sun=20, ring=60 -> sum=80; 80 % 3 != 0.
    response = _create_planetary(part["id"], sun_tooth_count=20, ring_tooth_count=60, planet_count=3)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_planetary_parameters"


def test_degenerate_planet_gear_from_too_small_a_tooth_difference_is_blocked():
    part = _create_part()
    # sun=20, ring=24 -> planet_teeth=2, invalid gear (tooth_count < 4) -
    # exercises the gear_math validation surfacing through, not just the
    # planetary-specific checks.
    response = _create_planetary(part["id"], sun_tooth_count=20, ring_tooth_count=24, planet_count=4)
    assert response.status_code == 422


def test_too_many_planets_causing_addendum_circle_interference_is_blocked():
    part = _create_part()
    # sun=20, ring=40 -> planet_teeth=10, a perfectly valid gear on its
    # own; (20+40) % 60 == 0 satisfies the assembly condition, but 60
    # evenly-spaced planets around this small an orbit radius is far more
    # than can physically fit without their addendum circles overlapping.
    response = _create_planetary(part["id"], sun_tooth_count=20, ring_tooth_count=40, planet_count=60)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_planetary_parameters"


# --- Composability + native round-trip --------------------------------------


def test_step_export_succeeds_for_a_planetary_set():
    part = _create_part()
    response = _create_planetary(part["id"])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert b"ISO-10303-21" in export_response.content


def test_update_planetary_feature_changes_planet_count_and_the_mesh_reflects_it():
    part = _create_part()
    create_response = _create_planetary(part["id"])
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    assert len(_mesh(part["id"])) == 7

    patch_response = client.patch(
        f"/document/parts/{part['id']}/planetary-gear-features/{feature_id}", json={"planet_count": 4}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["planet_count"] == 4
    assert len(_mesh(part["id"])) == 6


def test_update_planetary_feature_rejects_an_invalid_change():
    part = _create_part()
    create_response = _create_planetary(part["id"])
    feature_id = create_response.json()["id"]
    patch_response = client.patch(
        f"/document/parts/{part['id']}/planetary-gear-features/{feature_id}", json={"ring_tooth_count": 61}
    )
    assert patch_response.status_code == 422
    # The original Feature must be untouched after a rejected update.
    assert len(_mesh(part["id"])) == 7


def test_native_export_import_round_trips_a_planetary_gear_feature():
    """Mirrors `test_rack_feature.py`'s own native round-trip regression
    test - guards against the exact `native_format.py` omission class
    `docs/status.md` flagged for GearFeature in Workstream 2."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Planetary Test")
        response = _create_planetary(part["id"])
        assert response.status_code == 201, response.json()
        feature_id = response.json()["id"]
        vertices_before = sorted(entry["body_id"] for entry in _mesh(part["id"]))

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        planetary_dicts = [
            f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "planetary_gear"
        ]
        assert any(f["id"] == feature_id for f in planetary_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = sorted(entry["body_id"] for entry in _mesh(part["id"]))
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
