"""Real-OCCT tests for `GearFeature.points_per_flank` (herringbone/complex-
gear timeout investigation) - lets a caller trade tooth-flank smoothness for
a cheaper OCCT build (fewer `GeomAPI_Interpolate` sample points per flank,
and for a helical/herringbone gear specifically, a smaller wire for the
`BRepOffsetAPI_ThruSections`/`BRepAlgoAPI_Fuse` pair that dominates its own
build cost). Structurally mirrors `test_helical_herringbone_gear.py`'s own
shape (same helper-function conventions, same native-round-trip pattern) -
this file only covers what's new here: the field's default/validation/
update/native-round-trip behaviour. Doesn't assert on tessellated vertex
counts or timing (the actual OCCT cost/output shape of a smoothing
parameter like this isn't a safe thing to pin exactly in a test - see
inline notes below), only that the field is correctly threaded through and
that a real gear still builds at both ends of its accepted range.
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
        "face_width": 20.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-features", json=payload)


def test_default_points_per_flank_is_twelve():
    part = _create_part("Default points_per_flank")
    response = _create_gear(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["points_per_flank"] == 12


def test_omitting_points_per_flank_is_byte_identical_to_explicit_twelve():
    part_implicit = _create_part("Implicit 12")
    implicit_response = _create_gear(part_implicit["id"])
    assert implicit_response.status_code == 201, implicit_response.json()
    implicit_vertices = _mesh(part_implicit["id"])[0]["mesh"]["vertices"]

    part_explicit = _create_part("Explicit 12")
    explicit_response = _create_gear(part_explicit["id"], points_per_flank=12)
    assert explicit_response.status_code == 201, explicit_response.json()
    explicit_vertices = _mesh(part_explicit["id"])[0]["mesh"]["vertices"]

    assert implicit_vertices == explicit_vertices


def test_low_points_per_flank_still_builds_a_valid_gear():
    """A draft-precision gear (well below the 12-point default) must still
    be a real, meshable solid - this is the whole point of exposing the
    field (trading smoothness for speed, not trading correctness away)."""
    part = _create_part("Draft precision gear")
    response = _create_gear(part["id"], points_per_flank=4)
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert mesh[0]["mesh"]["vertices"]


def test_minimum_points_per_flank_of_two_still_builds():
    """The floor `sample_involute_flank`/gear.py's own validation accepts -
    exactly 2 (start/end of each flank, no interior curvature refinement) -
    still a valid, if visibly faceted, gear."""
    part = _create_part("Minimum points_per_flank")
    response = _create_gear(part["id"], points_per_flank=2)
    assert response.status_code == 201, response.json()
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_points_per_flank_below_two_is_rejected():
    part = _create_part("Invalid points_per_flank")
    response = _create_gear(part["id"], points_per_flank=1)
    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["type"] == "invalid_gear_parameters"


def test_low_points_per_flank_also_builds_for_a_herringbone_gear():
    """The case this field was actually added for - a herringbone gear's
    own two `ThruSections` lofts (`app.document.gear._helical_or_
    herringbone_solid`) are the most expensive path this parameter can
    cheapen."""
    part = _create_part("Draft herringbone gear")
    response = _create_gear(
        part["id"], helix_angle_degrees=18.0, herringbone=True, points_per_flank=4
    )
    assert response.status_code == 201, response.json()
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_update_gear_feature_can_change_points_per_flank():
    part = _create_part("Update points_per_flank")
    created = _create_gear(part["id"]).json()
    assert created["points_per_flank"] == 12

    response = client.patch(
        f"/document/parts/{part['id']}/gear-features/{created['id']}",
        json={"points_per_flank": 6},
    )
    assert response.status_code == 200, response.json()
    assert response.json()["points_per_flank"] == 6

    # Omitting the field on a further update leaves the just-set value
    # alone - the same omitted-vs-current convention every other
    # GearFeatureUpdate field already follows.
    response = client.patch(
        f"/document/parts/{part['id']}/gear-features/{created['id']}",
        json={"module": 2.5},
    )
    assert response.status_code == 200, response.json()
    assert response.json()["points_per_flank"] == 6


def test_native_export_import_round_trips_points_per_flank():
    """Mirrors `test_helical_herringbone_gear.py`'s own regression test for
    the same "native_format.py's export/import branches silently missing a
    new field" bug class this codebase has already hit more than once."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native points_per_flank Test")
        gear_response = _create_gear(part["id"], points_per_flank=6)
        assert gear_response.status_code == 201, gear_response.json()
        feature_id = gear_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        gear_dicts = [f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "gear"]
        matching = [f for f in gear_dicts if f["id"] == feature_id]
        assert matching
        assert matching[0]["points_per_flank"] == 6

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_native_import_of_a_pre_points_per_flank_gear_defaults_to_twelve():
    """A native file saved before this field existed has no
    `points_per_flank` key at all - must default to 12, not KeyError."""
    from app.document.native_format import import_native

    legacy_gear_dict = {
        "type": "gear",
        "id": "legacy-gear-1",
        "plane_ref": {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None},
        "gear_type": "boss",
        "is_internal": False,
        "module": 2.0,
        "tooth_count": 20,
        "face_width": 5.0,
        # No points_per_flank key - pre-existing shape.
    }
    document_dict = {
        "schema_version": 1,
        "document": {
            "id": "legacy-doc",
            "parts": [{"id": "legacy-part", "name": "Legacy Part", "features": [legacy_gear_dict]}],
        },
        "sketches": [],
    }
    document, _sketches = import_native(document_dict)
    part = document.parts["legacy-part"]
    feature = part.get_feature("legacy-gear-1")
    assert feature.points_per_flank == 12
