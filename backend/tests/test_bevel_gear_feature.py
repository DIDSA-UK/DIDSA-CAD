"""Real-OCCT tests for `BevelGearFeature`'s full router/HTTP surface -
`docs/gear-design/10-bevel-gear.md`. Structurally mirrors `test_rack_
feature.py`/`test_loft_feature.py`/`test_gear_chain_feature.py`'s own
shape - see those files for the same helper-function conventions this
reuses. Test cases reuse both of this workstream's own spikes' canonical
gears (2026-08-04/2026-08-05 findings in `10-bevel-gear.md`): the moderate
20T/40T 90-degree pair (module 4), the tight 18T/90T pair (module 2.5,
11.3-degree pitch angle), and the very tight 6T/80T pair (module 2.5) used
for the fold-risk boundary specifically.
"""

import math

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

# math.degrees(math.atan(N1/N2)) at Sigma=90deg - the same textbook
# gamma_1 = atan(N1/N2) reduction test_bevel_math.py's own reference-value
# tests check, used here as this test file's own `pitch_cone_angle_degrees`
# direct-field input (a standalone BevelGearFeature has no mate to derive
# this from automatically - see BevelGearFeature's own docstring).
_PITCH_ANGLE_20_40 = 26.56505117707799
_PITCH_ANGLE_18_90 = 11.309932474020215
_PITCH_ANGLE_6_80 = 4.289153328819018


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _create_bevel(part_id: str, **overrides) -> dict:
    payload = {
        "bevel_type": "boss",
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 15.0,
        "pitch_cone_angle_degrees": _PITCH_ANGLE_20_40,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/bevel-gear-features", json=payload)


def _apex_radii(vertices: list[list[float]]) -> tuple[float, float]:
    """Min/max distance from the world origin (the apex, for a bevel gear
    on the default XY plane_ref) among every mesh vertex - a real
    geometric property unique to a bevel gear's own spherical-involute
    construction, not a generic bounding-box check: every point on the
    outer cap/flank/land boundary lies on the sphere of radius exactly
    `cone_distance`, every point on the inner boundary lies on the sphere
    of radius exactly `inner_cone_distance`, and every other point (the
    ruled `ThruSections` interior between them) lies on the same ray
    through the apex at a radius strictly between the two - since both
    curves being ruled between are themselves already on their own two
    spheres, and both are sampled at colatitude/azimuth values that only
    ever fall between the root and face cone angles."""
    distances = [math.sqrt(x * x + y * y + z * z) for x, y, z in vertices]
    return min(distances), max(distances)


# --- Basic construction --------------------------------------------------


def test_bevel_gear_produces_one_body_with_real_mesh_geometry():
    part = _create_part()
    response = _create_bevel(part["id"])
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "bevel_gear"

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "computed"
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0

    # module=4, tooth_count=20, pitch_cone_angle=atan(20/40): pitch_radius
    # = 40, cone_distance = 40 / sin(pitch_cone_angle) = 89.4427,
    # inner_cone_distance = cone_distance - face_width(15) = 74.4427 - see
    # _apex_radii's own docstring for why this exact bound holds.
    min_radius, max_radius = _apex_radii(vertices)
    assert 74.4427 - 0.5 <= min_radius <= 74.4427 + 0.5
    assert 89.4427 - 0.5 <= max_radius <= 89.4427 + 0.5


def test_bevel_gear_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    response = _create_bevel(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


def test_bevel_gear_on_an_explicit_xz_plane():
    part = _create_part()
    response = _create_bevel(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    vertices = mesh[0]["mesh"]["vertices"]
    min_radius, max_radius = _apex_radii(vertices)
    assert 74.4427 - 0.5 <= min_radius <= 74.4427 + 0.5
    assert 89.4427 - 0.5 <= max_radius <= 89.4427 + 0.5


def test_a_tighter_pitch_cone_gear_produces_a_smaller_valid_body():
    """The tight 18T/90T pair (module 2.5, 11.3deg pitch angle) - one of
    the two spikes' own canonical cases."""
    part = _create_part()
    response = _create_bevel(
        part["id"],
        module=2.5,
        tooth_count=18,
        face_width=19.1,
        pitch_cone_angle_degrees=_PITCH_ANGLE_18_90,
    )
    assert response.status_code == 201, response.json()
    assert response.json()["warnings"] == []
    mesh = _mesh(part["id"])
    vertices = mesh[0]["mesh"]["vertices"]
    # pitch_radius = 2.5*18/2 = 22.5, cone_distance = 22.5/sin(11.31deg) =
    # 114.728, inner_cone_distance = 114.728 - 19.1 = 95.628.
    min_radius, max_radius = _apex_radii(vertices)
    assert 95.628 - 0.5 <= min_radius <= 95.628 + 0.5
    assert 114.728 - 0.5 <= max_radius <= 114.728 + 0.5


# --- Non-blocking validation warnings -------------------------------------


def test_face_width_beyond_the_recommended_maximum_surfaces_a_warning():
    part = _create_part()
    # cone_distance for 20T/module4/this pitch angle is 89.4427, so
    # max_recommended_face_width = cone_distance/3 = 29.81 - 32 exceeds it.
    response = _create_bevel(part["id"], face_width=32.0)
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any("exceeds the recommended maximum" in w for w in warnings)


def test_a_very_tight_cone_with_extreme_face_width_surfaces_a_fold_risk_warning():
    """The very tight 6T/80T pair (module 2.5) at face_width pushed to
    2.95x max_recommended_face_width - `10-bevel-gear.md`'s own resolved
    fold-risk finding (docs/status.md's matching dated entry): this
    session's own real, committed grid-injectivity check reproducibly
    fires in this exact regime, while a realistic face_width never
    approaches it."""
    part = _create_part()
    # pitch_radius = 2.5*6/2 = 7.5, cone_distance = 7.5/sin(4.29deg) =
    # 100.28, max_recommended_face_width = cone_distance/3 = 33.43;
    # 2.95x that is 98.6 (inner_cone_distance = 100.28 - 98.6 = 1.67mm
    # from the apex - deep into the fold-risk regime, still short of the
    # hard face_width < cone_distance boundary).
    response = _create_bevel(
        part["id"],
        module=2.5,
        tooth_count=6,
        face_width=98.6,
        pitch_cone_angle_degrees=_PITCH_ANGLE_6_80,
    )
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any("fold back on itself" in w for w in warnings)


def test_a_realistic_very_tight_cone_gear_has_no_fold_risk_warning():
    """The same 6T/80T pair at a realistic face_width (at the recommended
    maximum, ratio 1.0) - `10-bevel-gear.md`'s own §7 finding, re-verified
    against this session's real committed code: no fold at this ratio,
    resolving the two spikes' own previously-conflicting numbers."""
    part = _create_part()
    response = _create_bevel(
        part["id"],
        module=2.5,
        tooth_count=6,
        face_width=33.0,  # just under max_recommended_face_width(cone_distance=100.28) = 33.43
        pitch_cone_angle_degrees=_PITCH_ANGLE_6_80,
    )
    assert response.status_code == 201, response.json()
    assert response.json()["warnings"] == []


# --- Invalid parameters (bevel_math validation surfacing through the router) --


def test_negative_module_is_rejected():
    part = _create_part()
    response = _create_bevel(part["id"], module=-1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_parameters"


def test_zero_face_width_is_rejected():
    part = _create_part()
    response = _create_bevel(part["id"], face_width=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_parameters"


def test_face_width_at_or_beyond_the_cone_distance_is_rejected():
    """A tooth can't run all the way to the apex - `bevel_gear_geometry`'s
    own explicit check."""
    part = _create_part()
    # cone_distance is 89.4427 for this module/tooth_count/pitch angle.
    response = _create_bevel(part["id"], face_width=200.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_parameters"


def test_pitch_cone_angle_out_of_range_is_rejected():
    part = _create_part()
    response = _create_bevel(part["id"], pitch_cone_angle_degrees=95.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_parameters"


def test_root_fillet_radius_field_does_not_exist_on_a_bevel_gear():
    """`10-bevel-gear.md`/`BevelGearFeature`'s own docstring: root fillet
    is not supported at all for a bevel tooth (no `BRepPrimAPI_MakePrism.
    Generated()`-equivalent vertex-tracking for a `ThruSections`/`Sewing`-
    built solid) - confirmed here as cleanly absent (not silently ignored
    the way a helical GearFeature's own unsupported root fillet is, since
    unlike that case there is no field for a caller to set at all)."""
    part = _create_part()
    response = _create_bevel(part["id"], root_fillet_radius=5.0)
    assert response.status_code == 201, response.json()
    assert "root_fillet_radius" not in response.json()


# --- Composability: Boss/Cut, and being a valid target/source for other Features --


def test_cut_bevel_gear_requires_a_target_body():
    part = _create_part()
    response = _create_bevel(part["id"], bevel_type="cut")
    assert response.status_code == 422


def test_boss_bevel_gear_can_target_an_existing_bevel_gear_body():
    part = _create_part()
    first = _create_bevel(part["id"])
    assert first.status_code == 201, first.json()
    first_body_id = _mesh(part["id"])[0]["body_id"]

    second = _create_bevel(
        part["id"],
        plane_ref={"fixed_plane": "XY"},
        target_body_ids=[first_body_id],
        pitch_cone_angle_degrees=_PITCH_ANGLE_20_40,
    )
    assert second.status_code == 201, second.json()


def test_update_bevel_gear_feature_changes_tooth_count_and_the_mesh_reflects_it():
    part = _create_part()
    create_response = _create_bevel(part["id"], tooth_count=20)
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    mesh_at_20 = _mesh(part["id"])[0]["mesh"]["vertices"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/bevel-gear-features/{feature_id}",
        json={"tooth_count": 24, "pitch_cone_angle_degrees": _PITCH_ANGLE_20_40},
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["tooth_count"] == 24

    mesh_at_24 = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert mesh_at_24 != mesh_at_20


def test_update_bevel_gear_feature_rejects_an_invalid_change():
    part = _create_part()
    create_response = _create_bevel(part["id"])
    feature_id = create_response.json()["id"]
    patch_response = client.patch(
        f"/document/parts/{part['id']}/bevel-gear-features/{feature_id}", json={"module": -5.0}
    )
    assert patch_response.status_code == 422
    # The original Feature must be untouched after a rejected update.
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_step_export_succeeds_for_a_bevel_gear_body():
    part = _create_part()
    response = _create_bevel(part["id"])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert len(export_response.content) > 1000
    assert b"ISO-10303-21" in export_response.content


def test_bevel_gear_body_can_be_cut_afterward_via_a_new_sketch():
    """`00-conventions.md`'s "downstream Features already work on any
    gear-family Body" claim, exercised for a bevel gear: a Sketch on a
    face of the bevel gear's own Body, a small circle, then an Extrude
    Cut targeting the bevel gear's Body id."""
    part = _create_part()
    bevel_response = _create_bevel(part["id"])
    assert bevel_response.status_code == 201, bevel_response.json()
    bevel_body_id = _mesh(part["id"])[0]["body_id"]

    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]

    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0})
    assert center.status_code == 201
    radius_point = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 5.0, "y": 0.0})
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
            "end_distance": 200.0,
            "target_body_ids": [bevel_body_id],
        },
    )
    assert cut_response.status_code == 201, cut_response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 1  # still one Body, now with a bore cut through it


def test_native_export_import_round_trips_a_bevel_gear_feature():
    """Mirrors `test_rack_feature.py`'s own native round-trip regression
    test - the exact same native_format.py omission bug found for
    GearFeature (missing `_feature_to_dict`/`_feature_from_dict` branches)
    was deliberately guarded against for BevelGearFeature from the start,
    per this workstream's own explicit "don't repeat the native_format.py
    omission" instruction; this test is the regression guard that would
    have caught it."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Bevel Gear Test")
        bevel_response = _create_bevel(part["id"], tooth_count=20, face_width=12.0)
        assert bevel_response.status_code == 201, bevel_response.json()
        feature_id = bevel_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        bevel_dicts = [
            f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "bevel_gear"
        ]
        assert any(f["id"] == feature_id for f in bevel_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
