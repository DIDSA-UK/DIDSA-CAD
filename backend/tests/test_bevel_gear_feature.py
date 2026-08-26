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

import pytest
from fastapi.testclient import TestClient

import app.document.bevel as bevel_module
from app.document.bevel_math import SpiralHand, bevel_gear_geometry
from app.document.models import ResolvedPlane
from app.main import app
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.GeomAdaptor import GeomAdaptor_Surface
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopLoc import TopLoc_Location
from OCC.Core.TopoDS import topods
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
    resolving the two spikes' own previously-conflicting numbers.

    On-device feedback (CI, real pythonocc-core): this used to assert zero
    warnings outright, but this exact 6T/80T/4.29-degree geometry is also
    the one on-device-confirmed case `bevel._flatten_end_caps` itself can't
    handle (see `test_end_cap_flattening_fallback_surfaces_a_warning` -
    `_assemble_gear_solid` falls back to the un-flattened spherical cap and
    now surfaces that as a real warning, not silently). So this test now
    only asserts what it's actually named for - no *fold-risk* warning -
    same pattern as `test_a_very_tight_cone_with_extreme_face_width_
    surfaces_a_fold_risk_warning`'s own positive-control check."""
    part = _create_part()
    response = _create_bevel(
        part["id"],
        module=2.5,
        tooth_count=6,
        face_width=33.0,  # just under max_recommended_face_width(cone_distance=100.28) = 33.43
        pitch_cone_angle_degrees=_PITCH_ANGLE_6_80,
    )
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert not any("fold back on itself" in w for w in warnings)


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


# --- End-cap flattening (bevel._flatten_end_caps) ---------------------------
#
# Module-level, not HTTP+mesh-vertex-based like the tests above, and
# inspecting real face GEOMETRY, not tessellated mesh vertices: confirmed
# on-device that `BRepMesh_IncrementalMesh` never places a vertex strictly
# inside a genuinely flat face's own interior, at ANY deflection (down to
# 0.02mm tried directly) - a flat face has zero curvature deviation from
# its own boundary polygon, so no Steiner point is ever mathematically
# "needed", and OCCT correctly never adds one. That makes mesh vertices
# fundamentally unable to prove flatness here; `GeomAdaptor_Surface`
# directly on each face's own underlying surface (`GeomAbs_Plane`, plus its
# own `gp_Pln`'s location) is the reliable, mesh-independent way to check.

_XY_BASIS = ResolvedPlane(origin=(0.0, 0.0, 0.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0), normal=(0.0, 0.0, 1.0))


def _plane_faces_by_z(solid) -> dict[float, "TopoDS_Face"]:
    """Every genuinely planar face in `solid`, keyed by its own plane's Z
    (rounded to 4dp, since `_flat_root_cap_face`'s own two flat discs are
    the only planar faces this construction ever produces - every other
    face is a curved `ThruSections` loft)."""
    result: dict[float, "TopoDS_Face"] = {}
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        explorer.Next()
        surface = BRep_Tool.Surface(face)
        adaptor = GeomAdaptor_Surface(surface)
        if adaptor.GetType() != GeomAbs_Plane:
            continue
        location = adaptor.Plane().Location()
        result[round(location.Z(), 4)] = face
    return result


def test_end_caps_are_flattened_at_the_tooth_root_not_left_spherical():
    """Direct, on-the-nose regression for this session's own explicit
    request ("the convex face needs to be taken off at the outboard tooth
    root [and] the concave space needs filling in at the tooth outboard
    root"): `_assemble_gear_solid` produces exactly 2 genuinely planar
    faces (`_flat_root_cap_face`, one per end cap - every other face is a
    curved `ThruSections` loft), each at exactly its own cap's flat target
    z - not left as the true spherical dome/dish `_spherical_cap_face`
    alone would still produce."""
    geometry = bevel_gear_geometry(
        module=2.5, tooth_count=18, face_width=19.1, pitch_cone_angle_degrees=_PITCH_ANGLE_18_90
    )
    solid, warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, 18)
    assert warnings == []

    start_colatitude = max(geometry.root_cone_angle, geometry.base_cone_angle)
    outer_flat_z = geometry.cone_distance * math.cos(start_colatitude)
    inner_flat_z = geometry.inner_cone_distance * math.cos(start_colatitude)

    plane_faces = _plane_faces_by_z(solid)
    assert len(plane_faces) == 2, f"expected exactly 2 planar (flattened) end-cap faces, got {list(plane_faces)}"
    plane_zs = sorted(plane_faces)
    assert abs(plane_zs[0] - inner_flat_z) < 0.01, f"inner end-cap plane at z={plane_zs[0]}, expected {inner_flat_z}"
    assert abs(plane_zs[1] - outer_flat_z) < 0.01, f"outer end-cap plane at z={plane_zs[1]}, expected {outer_flat_z}"


def test_end_cap_flattening_never_touches_real_tooth_flank_material():
    """The other half of the same regression - flattening must be a no-op
    everywhere a tooth actually is. Every non-planar (flank/tip-land/root-
    land) face's own fine-mesh vertex must still sit AT OR BEHIND the outer
    cap's own flat target z, never past it - if flattening had eaten into
    real tooth material, some of those vertices would have been clipped
    forward past that plane instead. (Unlike the two flat cap faces, these
    ARE genuinely curved, so `BRepMesh_IncrementalMesh` does subdivide
    them - fine mesh vertices are a reliable signal here.)"""
    geometry = bevel_gear_geometry(
        module=2.5, tooth_count=18, face_width=19.1, pitch_cone_angle_degrees=_PITCH_ANGLE_18_90
    )
    solid, warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, 18)
    assert warnings == []

    start_colatitude = max(geometry.root_cone_angle, geometry.base_cone_angle)
    outer_flat_z = geometry.cone_distance * math.cos(start_colatitude)

    BRepMesh_IncrementalMesh(solid, 0.02, False, 0.1, True)
    max_excess = float("-inf")
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        explorer.Next()
        surface = BRep_Tool.Surface(face)
        if GeomAdaptor_Surface(surface).GetType() == GeomAbs_Plane:
            continue
        location = TopLoc_Location()
        triangulation = BRep_Tool.Triangulation(face, location)
        if triangulation is None:
            continue
        transform = location.Transformation()
        for i in range(1, triangulation.NbNodes() + 1):
            point = triangulation.Node(i).Transformed(transform)
            max_excess = max(max_excess, point.Z() - outer_flat_z)
    assert max_excess > float("-inf"), "expected at least one non-planar (tooth) face with mesh vertices"
    assert max_excess < 0.05, f"a tooth-region vertex sits {max_excess}mm past the outer flat cap - real material was cut"


def test_inner_cap_flattens_correctly_on_a_tilted_basis_not_just_the_untilted_one():
    """Real, on-device-confirmed regression: `_inner_cap_flattening_tool`'s
    own sphere used to be built via the 2-argument `gp_Ax2(point,
    direction)` form, which lets OCCT auto-pick an arbitrary X reference
    perpendicular to `direction` - fine when that auto-pick happens to
    match `basis.x_axis` (apparently always true for the untilted `basis.
    normal = (0, 0, 1)` case every other test in this file uses), silently
    wrong for any other basis, since `_spherical_cap_face`'s own identical
    sphere is always built with an *explicit* X (`_sphere_axis`'s `gp_Ax3`)
    - a parametrization mismatch `BRepAlgoAPI_Fuse` doesn't raise on
    (`IsDone()` still True) but also doesn't correctly merge, leaving the
    inner cap still domed. This is exactly why every `BevelPairFeature`'s
    own member 2 (which is *never* built on the untouched `plane_ref` -
    `_tilted_basis` is the entire point of a pair) came back with an open,
    un-flattened inner cap while member 1 looked correct: on-device
    testing (real pythonocc-core, not this repo's own sandbox) showed a
    default 20T/40T pair's own 40-tooth member missing one of its two flat
    end caps entirely, with no warning at all (`warnings == []`) - not the
    documented, already-covered `_flatten_end_caps`-raises-and-falls-back
    case above, a different failure this test locks in specifically.

    Verified directly: the exact same geometry, tooth count, and
    `_assemble_gear_solid` call, differing only in which `ResolvedPlane`
    basis is passed - the untilted default already exercised by every
    other end-cap test in this file, and a real 90-degree-tilted one (`x_
    axis` unchanged, `normal`/`y_axis` rotated - the same shape `bevel_
    pair._tilted_basis` produces) - must produce the identical planar-face
    count."""
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=40, face_width=15.0, pitch_cone_angle_degrees=63.43494882292201
    )
    tilted_basis = ResolvedPlane(
        origin=(0.0, 0.0, 0.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 0.0, -1.0), normal=(0.0, 1.0, 0.0)
    )

    untilted_solid, untilted_warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, 40)
    tilted_solid, tilted_warnings = bevel_module._assemble_gear_solid(tilted_basis, geometry, 40)
    assert untilted_warnings == []
    assert tilted_warnings == []

    def count_planar_faces(solid) -> int:
        n = 0
        explorer = TopExp_Explorer(solid, TopAbs_FACE)
        while explorer.More():
            face = topods.Face(explorer.Current())
            explorer.Next()
            surface = BRep_Tool.Surface(face)
            if surface is not None and GeomAdaptor_Surface(surface).GetType() == GeomAbs_Plane:
                n += 1
        return n

    untilted_planar = count_planar_faces(untilted_solid)
    tilted_planar = count_planar_faces(tilted_solid)
    assert untilted_planar == 2, f"untilted basis: expected 2 flat end caps, got {untilted_planar}"
    assert tilted_planar == 2, (
        f"tilted basis: expected 2 flat end caps (same as the untilted case), got {tilted_planar} - "
        "the inner cap flattening tool's own sphere is not correctly oriented for this basis"
    )


def test_end_cap_flattening_fallback_surfaces_a_warning():
    """The one on-device-confirmed case `bevel._flatten_end_caps` itself
    cannot handle (module 2.5, 6 teeth, face_width 33.0 - already flagged
    by `BRepCheck_Analyzer` before either boolean even runs, deep in the
    fold-risk regime `test_a_realistic_very_tight_cone_gear_has_no_fold_
    risk_warning` also exercises): `_assemble_gear_solid` falls back to the
    un-flattened spherical cap rather than raising - same face count as
    the un-flattened construction (`4*tooth_count + 2`).

    On-device feedback (real bevel-pair testing): this used to fall back
    silently (no warning), on the stated assumption this failure mode was
    rare - it wasn't confirmed rare so much as never actually tested this
    way. Now a real non-blocking warning, same convention as every other
    warning this module surfaces.

    (This case - `_flatten_end_caps` raising and falling back - is
    genuinely rare on real hardware; a *different*, silent bug turned out
    to be why a default Bevel Pair's two members looked visibly different
    from each other - see `test_inner_cap_flattens_correctly_on_a_tilted_
    basis_not_just_the_untilted_one` below for that one.)"""
    geometry = bevel_gear_geometry(module=2.5, tooth_count=6, face_width=33.0, pitch_cone_angle_degrees=_PITCH_ANGLE_6_80)
    solid, warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, 6)
    assert any("could not be flattened" in w for w in warnings), warnings

    face_count = 0
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face_count += 1
        explorer.Next()
    assert face_count == 4 * 6 + 2


# --- Spiral-aware twins of the four end-cap-flattening tests above
# (docs/gear-design/12-spiral-bevel-gear.md's own documented "end-cap
# flattening failed" table) - `bevel_math.spiral_section_count_for_twist`'s
# own real on-device calibration (see its docstring/docs/status.md) - not
# exercised at all by the four straight-only tests above (confirmed before
# this fix: none of them ever pass spiral_angle_degrees).


def test_spiral_end_caps_are_flattened_at_a_moderate_spiral_angle_safely_inside_the_smooth_regime():
    """Twin of `test_end_caps_are_flattened_at_the_tooth_root_not_left_
    spherical` above, at spiral_angle_degrees=25 - safely inside the
    "ordinary" spiral-angle range (`docs/gear-design/12-spiral-bevel-
    gear.md`'s own Spike A §3 "5-30deg main sweep" / `test_spiral_bevel_
    direct_assembly_parameter_sweep_stays_valid_and_volume_is_sane`'s own
    already-clean 10/20/30deg sweep), nowhere near the documented failing
    angles (51deg+) - flattening must succeed here exactly like the
    straight case, still 2 planar end-cap faces close to the same target z
    this geometry's own start_colatitude implies (spiral is a pure
    azimuthal rotation - `spiral_curve_offset_angle`'s own docstring - so
    it changes neither `start_colatitude` nor either cap's own nominal
    flat target z).

    **Not bit-for-bit identical to the straight case's own tolerance,
    deliberately**: `_flatten_end_caps`'s own `radius_margin` (`bevel.py`)
    is a small, real, INTENTIONAL safety margin, not zero, once spiral is
    active - it nudges the INNER cap's own tool to extend a little past
    the nominal root colatitude (`_inner_cap_flattening_tool`'s own
    docstring), which shifts that one cap's own flat plane inward by a
    small, bounded, and directly computable amount (`_END_CAP_RADIUS_
    MARGIN`-scale, not the straight case's exact zero). The OUTER cap's
    own tool only ever shrinks its own RADIUS for this margin, never its
    Z (`_outer_cap_flattening_tool`), so that cap's own flat plane stays
    exactly where the straight case's own tight tolerance already expects -
    only the inner cap's own tolerance is loosened here, and only to a
    value real on-device measurement (this session's own sweep, `docs/
    status.md`'s matching entry) confirmed comfortably covers this specific
    case's own real margin-driven shift (~0.013mm measured, `0.05` is
    real headroom above that, still two orders of magnitude tighter than
    this gear's own millimeter-scale dimensions)."""
    geometry = bevel_gear_geometry(
        module=2.5, tooth_count=18, face_width=19.1, pitch_cone_angle_degrees=_PITCH_ANGLE_18_90
    )
    solid, warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 18, spiral_angle_degrees=25.0, spiral_hand=SpiralHand.RIGHT
    )
    assert warnings == []

    start_colatitude = max(geometry.root_cone_angle, geometry.base_cone_angle)
    outer_flat_z = geometry.cone_distance * math.cos(start_colatitude)
    inner_flat_z = geometry.inner_cone_distance * math.cos(start_colatitude)

    plane_faces = _plane_faces_by_z(solid)
    assert len(plane_faces) == 2, f"expected exactly 2 planar (flattened) end-cap faces, got {list(plane_faces)}"
    plane_zs = sorted(plane_faces)
    assert abs(plane_zs[0] - inner_flat_z) < 0.05, f"inner end-cap plane at z={plane_zs[0]}, expected {inner_flat_z}"
    assert abs(plane_zs[1] - outer_flat_z) < 0.01, f"outer end-cap plane at z={plane_zs[1]}, expected {outer_flat_z}"


def test_spiral_end_cap_flattening_never_touches_real_tooth_flank_material():
    """Twin of `test_end_cap_flattening_never_touches_real_tooth_flank_
    material` above, at spiral_angle_degrees=25."""
    geometry = bevel_gear_geometry(
        module=2.5, tooth_count=18, face_width=19.1, pitch_cone_angle_degrees=_PITCH_ANGLE_18_90
    )
    solid, warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 18, spiral_angle_degrees=25.0, spiral_hand=SpiralHand.RIGHT
    )
    assert warnings == []

    start_colatitude = max(geometry.root_cone_angle, geometry.base_cone_angle)
    outer_flat_z = geometry.cone_distance * math.cos(start_colatitude)

    BRepMesh_IncrementalMesh(solid, 0.02, False, 0.1, True)
    max_excess = float("-inf")
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face = topods.Face(explorer.Current())
        explorer.Next()
        surface = BRep_Tool.Surface(face)
        if GeomAdaptor_Surface(surface).GetType() == GeomAbs_Plane:
            continue
        location = TopLoc_Location()
        triangulation = BRep_Tool.Triangulation(face, location)
        if triangulation is None:
            continue
        transform = location.Transformation()
        for i in range(1, triangulation.NbNodes() + 1):
            point = triangulation.Node(i).Transformed(transform)
            max_excess = max(max_excess, point.Z() - outer_flat_z)
    assert max_excess > float("-inf"), "expected at least one non-planar (tooth) face with mesh vertices"
    assert max_excess < 0.05, f"a tooth-region vertex sits {max_excess}mm past the outer flat cap - real material was cut"


def test_spiral_inner_cap_flattens_correctly_on_a_tilted_basis_not_just_the_untilted_one():
    """Twin of `test_inner_cap_flattens_correctly_on_a_tilted_basis_not_
    just_the_untilted_one` above, at spiral_angle_degrees=20 - the tilted-
    basis regression that motivated `_inner_cap_flattening_tool`'s own
    explicit-X-direction fix is orthogonal to spiral (a pure basis/apex
    concern, unrelated to the flank/root-land twist this workstream's own
    fix addresses), but this locks in that the two don't interact badly -
    a tilted `BevelPairFeature` member built with spiral must still flatten
    exactly like the untilted case."""
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=40, face_width=15.0, pitch_cone_angle_degrees=63.43494882292201
    )
    tilted_basis = ResolvedPlane(
        origin=(0.0, 0.0, 0.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 0.0, -1.0), normal=(0.0, 1.0, 0.0)
    )

    untilted_solid, untilted_warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 40, spiral_angle_degrees=20.0, spiral_hand=SpiralHand.RIGHT
    )
    tilted_solid, tilted_warnings = bevel_module._assemble_gear_solid(
        tilted_basis, geometry, 40, spiral_angle_degrees=20.0, spiral_hand=SpiralHand.RIGHT
    )
    assert untilted_warnings == []
    assert tilted_warnings == []

    def count_planar_faces(solid) -> int:
        n = 0
        explorer = TopExp_Explorer(solid, TopAbs_FACE)
        while explorer.More():
            face = topods.Face(explorer.Current())
            explorer.Next()
            surface = BRep_Tool.Surface(face)
            if surface is not None and GeomAdaptor_Surface(surface).GetType() == GeomAbs_Plane:
                n += 1
        return n

    untilted_planar = count_planar_faces(untilted_solid)
    tilted_planar = count_planar_faces(tilted_solid)
    assert untilted_planar == 2, f"untilted basis: expected 2 flat end caps, got {untilted_planar}"
    assert tilted_planar == 2, (
        f"tilted basis: expected 2 flat end caps (same as the untilted case), got {tilted_planar} - "
        "the inner cap flattening tool's own sphere is not correctly oriented for this basis"
    )


def test_spiral_end_cap_flattening_now_succeeds_for_every_documented_failing_case():
    """The real point of this workstream: `docs/gear-design/12-spiral-
    bevel-gear.md`'s own results table documented 4 real, on-device-
    confirmed `_flatten_end_caps` failures - 10T/10T at β=70°, and 20T/20T
    at β=68°/70°/72° (all module 4, matching that table's own parameters -
    10T/10T face_width=8, 20T/20T face_width=16, both at the shaft=90°/
    equal-tooth-count 45° pitch cone angle) - re-tested here directly
    against `_assemble_gear_solid` at its own default `spiral_section_
    count` (i.e. exactly what a real `BevelGearFeature` build does, not a
    hand-picked section count): every one of these four now succeeds
    (flattening warning absent, exactly 2 planar end-cap faces), confirmed
    on real `pythonocc-core` in this session (see `bevel_math.py`'s own
    `_SPIRAL_TWIST_PER_SECTION_BOUND` docstring and `docs/status.md`'s
    matching dated entry for the full before/after sweep this asserts a
    slice of)."""
    cases = [
        (10, 8.0, 70.0),
        (20, 16.0, 68.0),
        (20, 16.0, 70.0),
        (20, 16.0, 72.0),
    ]
    for tooth_count, face_width, beta in cases:
        pitch_cone_angle_degrees = 45.0  # equal tooth counts, 90deg shaft - atan(1) exactly
        geometry = bevel_gear_geometry(
            module=4.0, tooth_count=tooth_count, face_width=face_width, pitch_cone_angle_degrees=pitch_cone_angle_degrees
        )
        solid, warnings = bevel_module._assemble_gear_solid(
            _XY_BASIS, geometry, tooth_count, spiral_angle_degrees=beta, spiral_hand=SpiralHand.RIGHT
        )
        assert warnings == [], (tooth_count, beta, warnings)

        planar_faces = 0
        explorer = TopExp_Explorer(solid, TopAbs_FACE)
        while explorer.More():
            face = topods.Face(explorer.Current())
            explorer.Next()
            surface = BRep_Tool.Surface(face)
            if surface is not None and GeomAdaptor_Surface(surface).GetType() == GeomAbs_Plane:
                planar_faces += 1
        assert planar_faces == 2, (tooth_count, beta, planar_faces)


def test_spiral_end_cap_flattening_fallback_still_surfaces_a_warning_beyond_the_fixed_range():
    """"Still fails gracefully" - `spiral_section_count_for_twist`'s own
    docstring is explicit that per-step twist is a real, calibrated safety
    margin against the four *documented* failures above, not a guarantee
    against every conceivable one (that same docstring's own "Honest
    limitation" paragraph). This reuses `test_end_cap_flattening_fallback_
    surfaces_a_warning`'s own already-marginal straight-bevel case (module
    2.5, 6 teeth, face_width 33.0 - deep in the fold-risk regime, already
    flagged by `BRepCheck_Analyzer` before either boolean even runs, for
    reasons unrelated to spiral twist at all) with a moderate spiral angle
    layered on top: this fix only ever RAISES section count/margins, never
    lowers them, so a gear that was already marginal before any spiral
    twist is added is not expected to be rescued by a fix aimed at a
    different mechanism (surface bulge between sections, not fold risk on
    an already-degenerate flank). The fallback-with-warning safety net
    (`_assemble_gear_solid`'s own `except HTTPException` handler) must
    still produce a structurally valid, non-blocking result - same warning,
    same face count as the straight case - not an uncaught exception."""
    geometry = bevel_gear_geometry(module=2.5, tooth_count=6, face_width=33.0, pitch_cone_angle_degrees=_PITCH_ANGLE_6_80)
    solid, warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 6, spiral_angle_degrees=20.0, spiral_hand=SpiralHand.RIGHT
    )
    assert any("could not be flattened" in w for w in warnings), warnings

    face_count = 0
    explorer = TopExp_Explorer(solid, TopAbs_FACE)
    while explorer.More():
        face_count += 1
        explorer.Next()
    assert face_count == 4 * 6 + 2


# --- Spiral bevel (docs/gear-design/12-spiral-bevel-gear.md), Workstream 12 -
# single-gear construction only; BevelPairFeature's own spiral variant is a
# separate, later workstream (13).


def _solid_volume(solid) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(solid, props)
    return abs(props.Mass())


def test_spiral_angle_zero_direct_assembly_matches_the_legacy_path_exactly():
    """The real "literal no-op" contract `BevelGearFeature.spiral_angle_
    degrees`'s own docstring makes: passing `spiral_angle_degrees=0.0`
    explicitly must take the exact same code branch as omitting it
    entirely (`_assemble_gear_solid`'s own `if spiral_angle_degrees ==
    0.0:` branch) - checked here against genuine OCCT construction, not
    just `bevel_tooth_flank_sections`'s own bit-for-bit math-layer
    regression test."""
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=20, face_width=15.0, pitch_cone_angle_degrees=_PITCH_ANGLE_20_40
    )
    legacy_solid, legacy_warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, 20)
    explicit_zero_solid, explicit_zero_warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 20, spiral_angle_degrees=0.0, spiral_hand=SpiralHand.LEFT
    )
    assert explicit_zero_warnings == legacy_warnings
    assert _solid_volume(explicit_zero_solid) == _solid_volume(legacy_solid)


def test_spiral_bevel_direct_assembly_parameter_sweep_stays_valid_and_volume_is_sane():
    """`docs/gear-design/12-spiral-bevel-gear.md`'s own task instructions:
    "build real spiral gears across a real parameter sweep (multiple β,
    both hands, multiple tooth counts)" - not just one canonical case,
    mirroring `10-bevel-gear.md`'s own established "test across the
    parameter space" convention. Real, on-device-measured on this exact
    committed code: spiral is a pure rotation about the gear axis
    (`bevel_math.spiral_curve_offset_angle`'s own docstring), so it should
    change enclosed volume only slightly (the small residual from the
    per-section Tredgold flank curve's own natural shape varying a little
    with radius) - compared here directly against the β=0 straight-bevel
    volume as the sanity anchor `12-spiral-bevel-gear.md`'s own task
    instructions call for."""
    cases = [
        (20, 4.0, 15.0, _PITCH_ANGLE_20_40),  # moderate 20T/40T, module 4
        (18, 2.5, 19.1, _PITCH_ANGLE_18_90),  # tight 18T/90T, module 2.5
    ]
    for tooth_count, module, face_width, pitch_angle in cases:
        geometry = bevel_gear_geometry(
            module=module, tooth_count=tooth_count, face_width=face_width, pitch_cone_angle_degrees=pitch_angle
        )
        anchor_solid, anchor_warnings = bevel_module._assemble_gear_solid(_XY_BASIS, geometry, tooth_count)
        assert anchor_warnings == []
        anchor_volume = _solid_volume(anchor_solid)
        for spiral_angle_degrees in (10.0, 20.0, 30.0):
            for spiral_hand in (SpiralHand.RIGHT, SpiralHand.LEFT):
                solid, warnings = bevel_module._assemble_gear_solid(
                    _XY_BASIS,
                    geometry,
                    tooth_count,
                    spiral_angle_degrees=spiral_angle_degrees,
                    spiral_hand=spiral_hand,
                )
                assert warnings == [], (
                    f"tooth_count={tooth_count} beta={spiral_angle_degrees} hand={spiral_hand}: {warnings}"
                )
                volume = _solid_volume(solid)
                ratio = volume / anchor_volume
                assert 0.95 <= ratio <= 1.05, (
                    f"tooth_count={tooth_count} beta={spiral_angle_degrees} hand={spiral_hand}: "
                    f"volume ratio {ratio} strayed too far from the beta=0 anchor"
                )


def test_spiral_bevel_opposite_hands_give_mirror_symmetric_volume():
    """A real geometric invariant, not just a math-layer claim: two spiral
    gears built with opposite `SpiralHand` (otherwise identical parameters)
    are mirror images of each other across the gear's own meridian plane,
    so their enclosed volumes must match exactly - unlike
    `test_spiral_bevel_direct_assembly_parameter_sweep_stays_valid_and_
    volume_is_sane`'s own loose sanity bound, this is an exact equality."""
    geometry = bevel_gear_geometry(
        module=4.0, tooth_count=20, face_width=15.0, pitch_cone_angle_degrees=_PITCH_ANGLE_20_40
    )
    right_solid, right_warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 20, spiral_angle_degrees=25.0, spiral_hand=SpiralHand.RIGHT
    )
    left_solid, left_warnings = bevel_module._assemble_gear_solid(
        _XY_BASIS, geometry, 20, spiral_angle_degrees=25.0, spiral_hand=SpiralHand.LEFT
    )
    assert right_warnings == [] and left_warnings == []
    # rel=1e-6 (not an exact equality): two independently-built solids going
    # through different intermediate OCCT boolean/ThruSections operand
    # orderings can differ at the floating-point noise floor even for
    # genuinely mirror-symmetric geometry - measured on-device at ~3e-8
    # relative for this exact case, so 1e-6 stays a real, tight check
    # (100x the observed noise) without being flaky.
    assert _solid_volume(right_solid) == pytest.approx(_solid_volume(left_solid), rel=1e-6)


def test_spiral_bevel_gear_via_router_produces_a_valid_body_with_spiral_fields_in_the_response():
    part = _create_part()
    response = _create_bevel(part["id"], spiral_angle_degrees=20.0, spiral_hand="left")
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["spiral_angle_degrees"] == 20.0
    assert body["spiral_hand"] == "left"
    assert body["warnings"] == []

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0


def test_spiral_bevel_gear_apex_radii_match_the_straight_bevel_case():
    """Spiral is a pure rotation about the gear axis, so it must not
    change how far any point sits from the apex - the exact same `_apex_
    radii` bound `test_bevel_gear_produces_one_body_with_real_mesh_
    geometry`'s own straight-bevel case checks, unaffected by
    `spiral_angle_degrees`."""
    part = _create_part()
    response = _create_bevel(part["id"], spiral_angle_degrees=25.0, spiral_hand="right")
    assert response.status_code == 201, response.json()
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]
    min_radius, max_radius = _apex_radii(vertices)
    assert 74.4427 - 0.5 <= min_radius <= 74.4427 + 0.5
    assert 89.4427 - 0.5 <= max_radius <= 89.4427 + 0.5


def test_spiral_build_cost_warning_surfaces_through_the_router_at_high_spiral_angle():
    part = _create_part()
    response = _create_bevel(part["id"], spiral_angle_degrees=50.0)
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any("may take significantly longer" in w for w in warnings)


def test_spiral_build_cost_warning_does_not_fire_below_the_threshold():
    part = _create_part()
    response = _create_bevel(part["id"], spiral_angle_degrees=20.0)
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert not any("may take significantly longer" in w for w in warnings)


def test_update_bevel_gear_feature_can_toggle_spiral_fields():
    part = _create_part()
    create_response = _create_bevel(part["id"])
    feature_id = create_response.json()["id"]

    update_response = client.patch(
        f"/document/parts/{part['id']}/bevel-gear-features/{feature_id}",
        json={"spiral_angle_degrees": 15.0, "spiral_hand": "left"},
    )
    assert update_response.status_code == 200, update_response.json()
    body = update_response.json()
    assert body["spiral_angle_degrees"] == 15.0
    assert body["spiral_hand"] == "left"

    # Turning it back off (0.0) is a real, literal no-op per that field's
    # own docstring - the mesh should match a plain straight-bevel gear's.
    back_off_response = client.patch(
        f"/document/parts/{part['id']}/bevel-gear-features/{feature_id}",
        json={"spiral_angle_degrees": 0.0},
    )
    assert back_off_response.status_code == 200, back_off_response.json()
    min_radius, max_radius = _apex_radii(_mesh(part["id"])[0]["mesh"]["vertices"])
    assert 74.4427 - 0.5 <= min_radius <= 74.4427 + 0.5
    assert 89.4427 - 0.5 <= max_radius <= 89.4427 + 0.5


def test_native_export_import_round_trips_spiral_bevel_fields():
    """The spiral-specific extension of `test_native_export_import_
    round_trips_a_bevel_gear_feature` above - guards the same class of
    `native_format.py` omission bug specifically for `spiral_angle_
    degrees`/`spiral_hand`, which that pre-existing test's own default-
    valued (0.0/right) bevel gear would not catch."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Spiral Bevel Gear Test")
        bevel_response = _create_bevel(part["id"], spiral_angle_degrees=18.0, spiral_hand="left")
        assert bevel_response.status_code == 201, bevel_response.json()
        feature_id = bevel_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        bevel_dicts = [
            f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "bevel_gear"
        ]
        exported_feature = next(f for f in bevel_dicts if f["id"] == feature_id)
        assert exported_feature["spiral_angle_degrees"] == 18.0
        assert exported_feature["spiral_hand"] == "left"

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
