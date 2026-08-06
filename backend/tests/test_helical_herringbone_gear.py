"""Real-OCCT tests for Workstream 4a (helical/herringbone teeth on
`GearFeature`) - `docs/gear-design/04-helical-herringbone-loft.md`.
Structurally mirrors `test_gear_feature.py`'s own shape (see that file for
the same helper-function conventions this reuses) - this file only covers
what's new: `helix_angle_degrees`/`herringbone`, backward compatibility
with the pre-Workstream-4a straight-tooth path, and the native round-trip
of the two new fields.
"""

import math

from fastapi.testclient import TestClient

from app.document.gear_math import helical_twist_angle
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


# --- Backward compatibility --------------------------------------------------


def test_helix_angle_zero_is_byte_identical_to_a_plain_straight_gear():
    """`GearFeature.helix_angle_degrees`'s own docstring's central claim:
    the default (0.0, herringbone=False) must reproduce the exact original
    `BRepPrimAPI_MakePrism` straight-tooth path, unchanged."""
    part_implicit = _create_part("Implicit default")
    implicit_response = _create_gear(part_implicit["id"])
    assert implicit_response.status_code == 201, implicit_response.json()
    assert implicit_response.json()["helix_angle_degrees"] == 0.0
    assert implicit_response.json()["herringbone"] is False
    implicit_vertices = _mesh(part_implicit["id"])[0]["mesh"]["vertices"]

    part_explicit = _create_part("Explicit zero")
    explicit_response = _create_gear(part_explicit["id"], helix_angle_degrees=0.0, herringbone=False)
    assert explicit_response.status_code == 201, explicit_response.json()
    explicit_vertices = _mesh(part_explicit["id"])[0]["mesh"]["vertices"]

    assert implicit_vertices == explicit_vertices


def test_root_fillet_still_works_when_helix_angle_is_zero():
    part = _create_part()
    response = _create_gear(part["id"], root_fillet_radius=0.3, helix_angle_degrees=0.0)
    assert response.status_code == 201, response.json()
    assert len(_mesh(part["id"])[0]["mesh"]["vertices"]) > 0


# --- Helical teeth -------------------------------------------------------


def _angle_diff(a: float, b: float) -> float:
    """The signed difference `a - b`, wrapped into `(-pi, pi]` - so
    "near angle X" comparisons work correctly across the -pi/+pi wrap."""
    return (a - b + math.pi) % (2 * math.pi) - math.pi


def _max_radius_near(
    vertices: list[tuple[float, float, float]], z: float, angle: float, *, angle_tolerance: float = 0.05
) -> float:
    """The largest radius among the front-cap (z close to `z`) vertices
    whose angular position is close to `angle` - 0.0 if none qualify.
    Every one of a spur/helical gear's teeth shares the *identical*
    addendum radius, so "the single overall max-radius vertex at height z"
    (this file's own first-draft measurement) can't actually tell *which*
    tooth it belongs to - this instead checks a specific, predicted
    angular position (from `helical_twist_angle`), which stays correct
    even when the predicted twist exceeds half the angular tooth pitch (a
    real case here - a 20deg helix over this file's own 20mm face width/
    20-tooth module-2 gear twists further than one full tooth spacing)."""
    candidates = [
        math.hypot(x, y)
        for x, y, vz in vertices
        if abs(vz - z) < 1e-3 and abs(_angle_diff(math.atan2(y, x), angle)) < angle_tolerance
    ]
    return max(candidates, default=0.0)


# module=2, tooth_count=20 -> pitch_radius=20, addendum_radius=22 - every
# radius-near-an-angle check below uses this same reference gear.
_PITCH_RADIUS = 20.0
_NEAR_TIP_THRESHOLD = 21.0  # strictly between dedendum (17.5) and addendum (22)


def test_helical_gear_tooth_is_twisted_between_its_two_end_faces():
    part = _create_part()
    # face_width=8 (not this file's usual 20) deliberately keeps the
    # expected twist (~8.3deg) safely away from this gear's own 18deg
    # angular tooth pitch - a twist too close to a multiple of the pitch
    # would let a *neighbouring* tooth's tip drift into the "near angle 0"
    # check's own tolerance window, producing a false positive.
    helix_angle_degrees, face_width = 20.0, 8.0
    response = _create_gear(
        part["id"], helix_angle_degrees=helix_angle_degrees, tooth_count=20, face_width=face_width
    )
    assert response.status_code == 201, response.json()
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]

    z_values = sorted({round(z, 3) for _, _, z in vertices})
    assert z_values[0] == 0.0
    assert z_values[-1] == face_width

    expected_twist = helical_twist_angle(_PITCH_RADIUS, face_width, helix_angle_degrees)

    # Tooth 0's own tip sits near angle 0 on the untwisted bottom face...
    assert _max_radius_near(vertices, 0.0, 0.0) > _NEAR_TIP_THRESHOLD
    # ...and at the *predicted* twisted angle, not angle 0, on the top face.
    assert _max_radius_near(vertices, face_width, expected_twist) > _NEAR_TIP_THRESHOLD
    assert _max_radius_near(vertices, face_width, 0.0) < _NEAR_TIP_THRESHOLD


def test_helical_gear_mid_height_cross_section_matches_interpolated_twist_at_a_large_helix_angle():
    """Regression test for a real reported bug (see `docs/gear-design/
    04-helical-herringbone-loft.md`'s own dated addendum for the full
    root-cause writeup): at a large helix angle, `BRepOffsetAPI_
    ThruSections`' default `CheckCompatibility(True)` behaviour searches
    for its own vertex-to-vertex correspondence between the two end
    sections, explicitly trying to *minimise* the resulting surface's
    apparent twist - for this gear's own highly repetitive, near-symmetric
    tooth profile (every tooth looks almost identical to its neighbour,
    just rotated by one angular tooth pitch), that search can converge on
    an entirely wrong correspondence once the true twist exceeds roughly
    half an angular tooth pitch: a tooth's own tip vertex connected to a
    *different* tooth's root vertex, not its own twisted counterpart.
    `_twisted_tooth_loft`'s `CheckCompatibility(False)` call is the fix.

    Unlike this file's other helical tests (which only ever check the two
    *end* sections - the loft's own inputs, unaffected by which
    correspondence `ThruSections` chooses to connect them with), this
    samples a genuine *interior* cross-section - the actual lofted lateral
    surface a wrong correspondence would visibly corrupt - and confirms
    the tooth-tip vertex sits at the linearly-interpolated twist angle
    there, not at 0deg (the untwisted bottom's own angle) or at a
    neighbouring tooth's own angular position (18deg away for this
    20-tooth gear)."""
    part = _create_part()
    # 45deg: the real angle a user reported this bug at, and (at this
    # gear's 20mm pitch radius/20mm face width) well past the 18deg
    # angular tooth pitch a wrong correspondence would alias onto.
    helix_angle_degrees, face_width = 45.0, 20.0
    response = _create_gear(
        part["id"], helix_angle_degrees=helix_angle_degrees, tooth_count=20, face_width=face_width
    )
    assert response.status_code == 201, response.json()
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]

    total_twist = helical_twist_angle(_PITCH_RADIUS, face_width, helix_angle_degrees)
    mid_z = face_width / 2

    # The mesher doesn't guarantee an exact z=mid_z sample on a smooth
    # lofted surface (unlike z=0/z=face_width, which are the loft's own
    # input wires and always present) - use whichever sampled height is
    # actually closest to it, and require it to be close enough (within
    # 1/10 of the face width) for the interpolated-twist comparison below
    # to still be meaningful.
    z_values = sorted({z for _, _, z in vertices})
    sampled_mid_z = min(z_values, key=lambda z: abs(z - mid_z))
    assert abs(sampled_mid_z - mid_z) < face_width / 10

    expected_mid_twist = total_twist * (sampled_mid_z / face_width)
    angular_pitch = 2 * math.pi / 20

    # The tip sits at the interpolated twist angle for this height...
    assert _max_radius_near(vertices, sampled_mid_z, expected_mid_twist, angle_tolerance=0.15) > _NEAR_TIP_THRESHOLD
    # ...not still at the untwisted bottom's own angle...
    assert _max_radius_near(vertices, sampled_mid_z, 0.0, angle_tolerance=0.15) < _NEAR_TIP_THRESHOLD
    # ...and not wrapped onto a neighbouring tooth's own angular position.
    assert (
        _max_radius_near(vertices, sampled_mid_z, expected_mid_twist - angular_pitch, angle_tolerance=0.15)
        < _NEAR_TIP_THRESHOLD
    )
    assert (
        _max_radius_near(vertices, sampled_mid_z, expected_mid_twist + angular_pitch, angle_tolerance=0.15)
        < _NEAR_TIP_THRESHOLD
    )


def test_helical_gear_twist_direction_flips_with_the_sign_of_helix_angle():
    # face_width=5 keeps the expected twist (~5.2deg) small enough that
    # +expected_twist and -expected_twist are clearly separated from each
    # other *and* from this gear's neighbouring teeth (at +-18deg) - same
    # "avoid the check windows colliding with a real neighbouring tooth"
    # reasoning as the test above, applied to both signs at once here.
    face_width = 5.0
    for helix_angle_degrees, name in ((20.0, "Positive helix"), (-20.0, "Negative helix")):
        part = _create_part(name)
        response = _create_gear(
            part["id"], helix_angle_degrees=helix_angle_degrees, tooth_count=20, face_width=face_width
        )
        assert response.status_code == 201, response.json()
        vertices = _mesh(part["id"])[0]["mesh"]["vertices"]
        expected_twist = helical_twist_angle(_PITCH_RADIUS, face_width, helix_angle_degrees)

        # The tip is near the *predicted-sign* twisted angle...
        assert _max_radius_near(vertices, face_width, expected_twist) > _NEAR_TIP_THRESHOLD
        # ...and specifically not near the opposite-signed angle - proves
        # the sign of helix_angle_degrees genuinely drives twist direction,
        # not just twist magnitude.
        assert _max_radius_near(vertices, face_width, -expected_twist) < _NEAR_TIP_THRESHOLD


def test_helix_angle_out_of_bounds_is_rejected():
    part = _create_part()
    response = _create_gear(part["id"], helix_angle_degrees=90.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_gear_parameters"


def test_internal_helical_gear_still_produces_an_annulus():
    part = _create_part()
    response = _create_gear(
        part["id"],
        is_internal=True,
        tooth_count=60,
        outer_diameter=140.0,
        helix_angle_degrees=15.0,
        face_width=20.0,
    )
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    vertices = mesh[0]["mesh"]["vertices"]
    max_radius = max((x**2 + y**2) ** 0.5 for x, y, z in vertices)
    assert abs(max_radius - 70.0) < 0.5


def test_root_fillet_is_attempted_for_a_helical_gear():
    """`_apply_root_fillet_to_loft` (`app.document.gear`): root fillet is no
    longer unconditionally unsupported for a helical tooth - this confirms
    the Feature still builds successfully with a non-zero
    `root_fillet_radius` set (best-effort: a real fillet if
    `BRepFilletAPI_MakeFillet` converges via `ThruSections.Generated()`'s
    own root-corner edges, an unfilleted-but-still-valid gear with a
    `warnings` entry otherwise - either way, never a hard failure) rather
    than checking log/warning content, which needs a real on-device/CI
    `pythonocc-core` pass to verify either way (see this module's own
    top-of-file docstring)."""
    part = _create_part()
    response = _create_gear(part["id"], helix_angle_degrees=15.0, root_fillet_radius=0.3)
    assert response.status_code == 201, response.json()
    assert len(_mesh(part["id"])[0]["mesh"]["vertices"]) > 0


def test_root_fillet_is_attempted_for_a_herringbone_gear():
    """Same as `test_root_fillet_is_attempted_for_a_helical_gear`, but for
    the herringbone path (`_helical_or_herringbone_solid` fillets each half
    - bottom and top - before fusing them together)."""
    part = _create_part()
    response = _create_gear(
        part["id"], helix_angle_degrees=15.0, herringbone=True, root_fillet_radius=0.3
    )
    assert response.status_code == 201, response.json()
    assert len(_mesh(part["id"])[0]["mesh"]["vertices"]) > 0


# --- Herringbone teeth -----------------------------------------------------


def test_herringbone_gear_mirrors_at_the_midplane_not_twice_as_tall():
    part = _create_part()
    face_width = 20.0
    response = _create_gear(
        part["id"], helix_angle_degrees=20.0, herringbone=True, tooth_count=20, face_width=face_width
    )
    assert response.status_code == 201, response.json()
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]

    z_values = sorted({round(z, 3) for _, _, z in vertices})
    # "Mirrored, not simply twice as tall": the overall height is still the
    # requested face_width (20mm), not double it.
    assert z_values[0] == 0.0
    assert z_values[-1] == face_width

    # Both end faces return to zero *relative* twist (mirrored halves
    # meeting at the shared midplane) - tooth 0's own tip is near angle 0
    # at *both* z=0 and z=face_width.
    assert _max_radius_near(vertices, 0.0, 0.0) > _NEAR_TIP_THRESHOLD
    assert _max_radius_near(vertices, face_width, 0.0) > _NEAR_TIP_THRESHOLD


def test_herringbone_midplane_is_twisted_relative_to_both_end_faces():
    part = _create_part()
    helix_angle_degrees, face_width = 20.0, 20.0
    response = _create_gear(
        part["id"], helix_angle_degrees=helix_angle_degrees, herringbone=True, tooth_count=20, face_width=face_width
    )
    assert response.status_code == 201, response.json()
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]

    half_twist = helical_twist_angle(_PITCH_RADIUS, face_width / 2, helix_angle_degrees)
    mid_z = face_width / 2
    # The midplane cross-section sits at the predicted half-twist angle,
    # not angle 0 - genuinely twisted relative to both end faces.
    assert _max_radius_near(vertices, mid_z, half_twist) > _NEAR_TIP_THRESHOLD
    assert _max_radius_near(vertices, mid_z, 0.0) < _NEAR_TIP_THRESHOLD


def test_herringbone_gear_produces_a_single_fused_solid():
    part = _create_part()
    response = _create_gear(
        part["id"], helix_angle_degrees=20.0, herringbone=True, tooth_count=20, face_width=20.0
    )
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    # The two halves must be fused into one Body, not left as two disjoint
    # solids from the Fuse's own compound.
    assert len(mesh) == 1


# --- Update ------------------------------------------------------------


def test_update_gear_feature_can_add_helix_angle():
    part = _create_part()
    create_response = _create_gear(part["id"], face_width=20.0)
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    straight_vertices = _mesh(part["id"])[0]["mesh"]["vertices"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/gear-features/{feature_id}", json={"helix_angle_degrees": 25.0}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["helix_angle_degrees"] == 25.0

    helical_vertices = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert helical_vertices != straight_vertices


# --- Native round-trip ---------------------------------------------------


def test_native_export_import_round_trips_helix_angle_and_herringbone():
    """Mirrors `test_gear_feature.py`'s own native round-trip regression
    test - the exact "native_format.py's export/import branches silently
    missing a new field" bug class this codebase has already hit twice
    (GearFeature itself in Workstream 2, guarded against for RackFeature
    since) - this is the regression guard for Workstream 4a's own two new
    GearFeature fields specifically."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Helical Gear Test")
        gear_response = _create_gear(
            part["id"], helix_angle_degrees=18.0, herringbone=True, tooth_count=20, face_width=20.0
        )
        assert gear_response.status_code == 201, gear_response.json()
        feature_id = gear_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        gear_dicts = [f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "gear"]
        matching = [f for f in gear_dicts if f["id"] == feature_id]
        assert matching
        assert matching[0]["helix_angle_degrees"] == 18.0
        assert matching[0]["herringbone"] is True

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_native_import_of_a_pre_workstream_4a_gear_defaults_to_straight_teeth():
    """A native file saved before Workstream 4a's fields existed has no
    `helix_angle_degrees`/`herringbone` keys at all - must default to
    0.0/False (straight teeth), not KeyError."""
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
        # No helix_angle_degrees/herringbone keys - pre-Workstream-4a shape.
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
    assert feature.helix_angle_degrees == 0.0
    assert feature.herringbone is False
