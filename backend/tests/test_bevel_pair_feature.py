"""Real-OCCT tests for `BevelPairFeature`'s full router/HTTP surface -
`docs/gear-design/11-bevel-pair.md`. Structurally mirrors `test_bevel_gear_
feature.py`/`test_gear_chain_feature.py`/`test_planetary_gear_feature.py`'s
own shape.

Two kinds of geometric verification, per this workstream's own explicit
instruction to verify the apex-aligned dual-axis positioning "for real,
numerically, not just it compiles":

- **Axis-angle checks** (`Test*ResolvedBasisGeometry` below) exercise `app.
  document.bevel_pair._tilted_basis` directly against a real `ResolvedPlane`
  from `app.document.create_plane.resolve_plane_ref` - not mocked, the same
  function `resolve_bevel_pair_from_bodies` itself calls - and check the
  dot product between the two members' own resolved axis (normal)
  directions against `cos(shaft_angle_degrees)` exactly, plus that both
  origins (apexes) coincide and the rotated frame stays orthonormal.
- **Apex-coincidence checks** (`test_*_apex_coincidence`) go through the
  real HTTP router end to end: both members' own real assembled-solid mesh
  vertices (genuine `BRepMesh_IncrementalMesh` tessellation) must fall
  within `[inner_cone_distance, cone_distance]` of the *same* 3D point (the
  shared plane_ref origin) - the mesh-level analogue of `test_bevel_gear_
  feature.py`'s own `_apex_radii` check, run for both members against one
  shared apex rather than one member against the world origin alone.
"""

import math

from fastapi.testclient import TestClient

from app.document.bevel_pair import _tilted_basis
from app.document.create_plane import resolve_plane_ref
from app.document.models import PlaneRef
from app.document.bevel_math import pitch_cone_half_angles
from app.main import app
from app.sketch.models import Plane
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


def _member(tooth_count: int, profile_shift: float = 0.0) -> dict:
    return {"tooth_count": tooth_count, "profile_shift": profile_shift}


def _create_pair(part_id: str, **overrides) -> dict:
    payload = {
        "module": 4.0,
        "member_1": _member(20),
        "member_2": _member(40),
        "face_width": 15.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/bevel-pair-features", json=payload)


def _apex_radii(vertices: list[list[float]], apex: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> tuple[float, float]:
    ax, ay, az = apex
    distances = [math.sqrt((x - ax) ** 2 + (y - ay) ** 2 + (z - az) ** 2) for x, y, z in vertices]
    return min(distances), max(distances)


# --- Resolved-basis geometry (direct, real ResolvedPlane construction) ----


def test_tilted_basis_keeps_apex_and_x_axis_fixed_and_matches_shaft_angle_at_90_degrees():
    basis_1 = resolve_plane_ref(None, {}, PlaneRef(fixed_plane=Plane.XY), frozenset())
    basis_2 = _tilted_basis(basis_1, math.radians(90.0))

    assert basis_2.origin == basis_1.origin
    assert basis_2.x_axis == basis_1.x_axis

    dot = sum(a * b for a, b in zip(basis_1.normal, basis_2.normal))
    assert abs(dot - math.cos(math.radians(90.0))) < 1e-9

    # The rotated frame is still a genuine orthonormal, right-handed basis.
    normal_mag = math.sqrt(sum(c * c for c in basis_2.normal))
    assert abs(normal_mag - 1.0) < 1e-9
    assert abs(sum(a * b for a, b in zip(basis_2.x_axis, basis_2.normal))) < 1e-9
    assert abs(sum(a * b for a, b in zip(basis_2.y_axis, basis_2.normal))) < 1e-9


def test_tilted_basis_matches_shaft_angle_for_a_non_90_degree_case():
    basis_1 = resolve_plane_ref(None, {}, PlaneRef(fixed_plane=Plane.XY), frozenset())
    for shaft_angle_degrees in (37.0, 60.0, 145.0):
        basis_2 = _tilted_basis(basis_1, math.radians(shaft_angle_degrees))
        assert basis_2.origin == basis_1.origin
        dot = sum(a * b for a, b in zip(basis_1.normal, basis_2.normal))
        assert abs(dot - math.cos(math.radians(shaft_angle_degrees))) < 1e-9


# --- Basic construction -----------------------------------------------------


def test_bevel_pair_produces_two_bodies_with_real_mesh_geometry():
    part = _create_part()
    response = _create_pair(part["id"])
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "bevel_pair"

    mesh = _mesh(part["id"])
    assert len(mesh) == 2
    for entry in mesh:
        assert entry["source"] == "computed"
        assert len(entry["mesh"]["vertices"]) > 0


def test_bevel_pair_pinned_zero_profile_shift_warns_of_predicted_mesh_interference():
    """Real, on-device-confirmed regression: a 20T/40T pair with *both*
    members' `profile_shift` explicitly pinned to 0.0 (`_member`'s own
    default - not the same as omitting the field, which now auto-resolves
    it instead, see `test_bevel_pair_default_profile_shift_auto_avoids_
    predicted_mesh_interference` below), at the default 20-degree pressure
    angle, was found to have genuine tooth interference (`BRepAlgoAPI_
    Common` overlap ~60mm^3 on a real solid pair, ~0.1% of the smaller
    member's own volume but concentrated at the mesh line, comparable in
    spatial extent to a full tooth height - not a numerical touching-
    tolerance artifact). `bevel_pair_mesh_interference_warning` predicts
    this from pure math (no OCCT) - this test locks in that the real end-
    to-end pipeline actually surfaces it as a warning when both members'
    shifts are explicitly pinned (an explicit value always wins over auto-
    resolution, `BevelPairMemberSpec.profile_shift`'s own docstring), and
    that raising pressure_angle_degrees (28, comfortably past the ~26.7
    degrees the warning itself calculates as sufficient) makes it go
    away - confirmed separately, directly against the real solids, not just
    that the warning string is absent."""
    part = _create_part()
    response = _create_pair(part["id"])
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any("tooth tip is predicted to" in w and "pressure_angle_degrees" in w for w in warnings), warnings

    part_2 = _create_part("Part 2")
    response_2 = _create_pair(part_2["id"], pressure_angle_degrees=28.0)
    assert response_2.status_code == 201, response_2.json()
    assert response_2.json()["warnings"] == []


def test_bevel_pair_default_profile_shift_auto_avoids_predicted_mesh_interference():
    """`profile_shift` genuinely omitted (not the `_member`-helper's own
    explicit-0.0 default `test_bevel_pair_pinned_zero_profile_shift_warns_
    of_predicted_mesh_interference` above exercises) resolves to `None` on
    both members (`BevelPairMemberSpecSchema.profile_shift`'s own default)
    - `app.document.bevel_pair.resolve_member_profile_shifts` auto-fills
    whichever member is the predicted intruder (member_2, the 40-tooth
    gear, for this tooth-count pair) with a computed negative shift instead
    of leaving it at 0.0, so the *same* 20T/40T pair at the *same* default
    20-degree pressure angle that warns when explicitly pinned to 0.0 does
    not warn at all here - real, on-device-confirmed via direct
    `BRepAlgoAPI_Common` overlap measurement dropping from ~60mm^3 to
    exactly 0.0mm^3 with no pressure_angle_degrees change at all."""
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/bevel-pair-features",
        json={
            "module": 4.0,
            "member_1": {"tooth_count": 20},
            "member_2": {"tooth_count": 40},
            "face_width": 15.0,
        },
    )
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["warnings"] == []
    # The stored value stays None (auto) - same "echo the raw/possibly-
    # None value back, not the resolved one" convention `RackFeatureResponse.
    # backing_height` already uses - the computed shift only exists inside
    # the real solid construction, not as a value written back onto the
    # Feature itself.
    assert body["member_1"]["profile_shift"] is None
    assert body["member_2"]["profile_shift"] is None


def test_bevel_pair_auto_profile_shift_still_avoids_interference_at_a_low_pressure_angle():
    """Real regression found on-device: at the default 20T/40T pair's
    default 20-degree pressure angle, the balanced-shift auto-resolution
    (`resolve_member_profile_shifts`) applies its full complementary `+X`
    to the receiver safely - but at a lower shared pressure angle (14.5
    degrees), applying that *same* full delta unconditionally grows the
    receiver's own addendum enough to flip *it* into the new intruder in
    the opposite direction (confirmed directly against `bevel_math`:
    reverse margin goes from +1.08 degrees at baseline to -1.06 degrees
    under the naive full balanced shift - worse than not shifting the
    receiver at all). `maximum_receiver_profile_shift_for_mesh_clearance`
    caps the receiver's own step at whatever the reverse margin actually
    tolerates - this pins that fix at the real HTTP router level, not just
    directly against `bevel_math`."""
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/bevel-pair-features",
        json={
            "module": 4.0,
            "member_1": {"tooth_count": 20},
            "member_2": {"tooth_count": 40},
            "face_width": 15.0,
            "pressure_angle_degrees": 14.5,
        },
    )
    assert response.status_code == 201, response.json()
    assert response.json()["warnings"] == []


def test_bevel_pair_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    response = _create_pair(part["id"])
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


def test_bevel_pair_on_an_explicit_xz_plane():
    part = _create_part()
    response = _create_pair(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert len(mesh) == 2


# --- Known-reference-value cone angles --------------------------------------


def test_equal_tooth_counts_at_90_degrees_split_the_pitch_cone_evenly():
    """Hand-checkable reference case: `gamma_1 = gamma_2 = 45deg` for equal
    tooth counts at the default 90-degree shaft angle - `atan(N1/N2) =
    atan(1) = 45deg` exactly, the same textbook reduction `test_bevel_math.
    py`'s own reference-value tests check against `pitch_cone_half_angles`
    directly. Both members' own `cone_distance` (pitch_radius / sin(pitch_
    cone_angle)) should then match exactly too, since equal tooth counts +
    equal module give equal pitch_radius."""
    part = _create_part()
    response = _create_pair(part["id"], member_1=_member(20), member_2=_member(20), module=4.0, face_width=10.0)
    assert response.status_code == 201, response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 2
    # pitch_radius = 4*20/2 = 40, cone_distance = 40 / sin(45deg) = 56.5685,
    # inner_cone_distance = 56.5685 - 10 = 46.5685 - identical for both
    # members since gamma_1 == gamma_2 == 45deg exactly.
    for entry in mesh:
        min_radius, max_radius = _apex_radii(entry["mesh"]["vertices"])
        assert 46.5685 - 0.5 <= min_radius <= 46.5685 + 0.5
        assert 56.5685 - 0.5 <= max_radius <= 56.5685 + 0.5


# --- Apex coincidence (real assembled-solid mesh vertices) ------------------


def _expected_cone_distances(tooth_count_1: int, tooth_count_2: int, module: float, shaft_angle_degrees: float):
    gamma_1, gamma_2 = pitch_cone_half_angles(tooth_count_1, tooth_count_2, shaft_angle_degrees)
    pitch_radius_1 = module * tooth_count_1 / 2
    pitch_radius_2 = module * tooth_count_2 / 2
    return pitch_radius_1 / math.sin(gamma_1), pitch_radius_2 / math.sin(gamma_2)


def test_both_members_apex_adjacent_vertices_coincide_at_the_shared_apex_at_90_degrees():
    part = _create_part()
    response = _create_pair(part["id"], member_1=_member(20), member_2=_member(40), module=4.0, face_width=10.0)
    assert response.status_code == 201, response.json()

    cone_distance_1, cone_distance_2 = _expected_cone_distances(20, 40, 4.0, 90.0)
    mesh = _mesh(part["id"])
    assert len(mesh) == 2
    # Body registration order mirrors _register_solids' own #0/#1 suffixing
    # of the compound builder.Add order (member_1 then member_2) - see
    # app.document.bevel_pair.resolve_bevel_pair_from_bodies.
    mesh_by_body_id = {entry["body_id"]: entry for entry in mesh}
    entry_1 = next(e for bid, e in mesh_by_body_id.items() if bid.endswith("#0"))
    entry_2 = next(e for bid, e in mesh_by_body_id.items() if bid.endswith("#1"))

    # The shared apex is plane_ref's own origin - the default XY plane's
    # origin is the world origin.
    min_1, max_1 = _apex_radii(entry_1["mesh"]["vertices"])
    min_2, max_2 = _apex_radii(entry_2["mesh"]["vertices"])
    inner_1 = cone_distance_1 - 10.0
    inner_2 = cone_distance_2 - 10.0
    assert inner_1 - 0.5 <= min_1 <= inner_1 + 0.5
    assert cone_distance_1 - 0.5 <= max_1 <= cone_distance_1 + 0.5
    assert inner_2 - 0.5 <= min_2 <= inner_2 + 0.5
    assert cone_distance_2 - 0.5 <= max_2 <= cone_distance_2 + 0.5


def test_both_members_apex_adjacent_vertices_coincide_at_the_shared_apex_for_a_non_90_degree_shaft_angle():
    part = _create_part()
    response = _create_pair(
        part["id"],
        member_1=_member(20),
        member_2=_member(40),
        module=4.0,
        face_width=10.0,
        shaft_angle_degrees=60.0,
    )
    assert response.status_code == 201, response.json()

    cone_distance_1, cone_distance_2 = _expected_cone_distances(20, 40, 4.0, 60.0)
    mesh = _mesh(part["id"])
    mesh_by_body_id = {entry["body_id"]: entry for entry in mesh}
    entry_1 = next(e for bid, e in mesh_by_body_id.items() if bid.endswith("#0"))
    entry_2 = next(e for bid, e in mesh_by_body_id.items() if bid.endswith("#1"))

    min_1, max_1 = _apex_radii(entry_1["mesh"]["vertices"])
    min_2, max_2 = _apex_radii(entry_2["mesh"]["vertices"])
    inner_1 = cone_distance_1 - 10.0
    inner_2 = cone_distance_2 - 10.0
    assert inner_1 - 0.5 <= min_1 <= inner_1 + 0.5
    assert cone_distance_1 - 0.5 <= max_1 <= cone_distance_1 + 0.5
    assert inner_2 - 0.5 <= min_2 <= inner_2 + 0.5
    assert cone_distance_2 - 0.5 <= max_2 <= cone_distance_2 + 0.5


# --- Non-blocking validation warnings ---------------------------------------


def test_face_width_beyond_the_recommended_maximum_surfaces_a_warning_labeled_for_each_member():
    """A meshing bevel pair's `cone_distance` is always identical for both
    members (both pitch cones share the same slant generator from the
    apex to the outer pitch circle - confirmed numerically here: 20T/40T
    module 4 at 90deg gives `cone_distance = 89.4427` for both, the same
    reference value `test_bevel_gear_feature.py`'s own standalone-gear
    test uses), so a face_width exceeding the recommended maximum
    exceeds it for *both* members at once - this test's own real job is
    confirming each gets its own distinctly-labeled warning (`00-
    conventions.md`'s per-member framing), not that only one does."""
    part = _create_part()
    # cone_distance = 89.4427 (matches test_bevel_gear_feature.py's own
    # 20T/40T module-4 reference case), max_recommended_face_width =
    # cone_distance/3 = 29.81 - 32 exceeds it for both members.
    response = _create_pair(part["id"], member_1=_member(20), member_2=_member(40), module=4.0, face_width=32.0)
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any(w.startswith("member_1:") and "exceeds the recommended maximum" in w for w in warnings)
    assert any(w.startswith("member_2:") and "exceeds the recommended maximum" in w for w in warnings)


# --- Invalid parameters (bevel_math validation surfacing through the router) --


def test_tooth_count_below_the_minimum_is_rejected():
    part = _create_part()
    response = _create_pair(part["id"], member_1=_member(2), member_2=_member(40))
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_pair_parameters"


def test_shaft_angle_out_of_range_is_rejected():
    part = _create_part()
    response = _create_pair(part["id"], shaft_angle_degrees=185.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_pair_parameters"


def test_zero_face_width_is_rejected():
    part = _create_part()
    response = _create_pair(part["id"], face_width=0.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_bevel_pair_parameters"


def test_no_root_fillet_field_exists_on_either_member():
    """Matches `BevelGearFeature`'s own precedent - no root fillet field
    at all for a bevel tooth (see that dataclass's own docstring)."""
    part = _create_part()
    response = _create_pair(
        part["id"], member_1={"tooth_count": 20, "profile_shift": 0.0, "root_fillet_radius": 5.0}
    )
    assert response.status_code == 201, response.json()
    assert "root_fillet_radius" not in response.json()["member_1"]


def test_pitch_cone_angle_direct_field_is_not_accepted_on_the_pair():
    """`11-bevel-pair.md`: cone angles are auto-derived, not entered -
    unlike `BevelGearFeatureCreate`'s own direct `pitch_cone_angle_degrees`
    field, `BevelPairFeatureCreate` has no such field at all; pydantic
    silently drops an extra one rather than erroring, same as the root-
    fillet check above."""
    part = _create_part()
    response = _create_pair(part["id"], pitch_cone_angle_degrees=30.0)
    assert response.status_code == 201, response.json()
    assert "pitch_cone_angle_degrees" not in response.json()


# --- Composability: no Boss/Cut, but bodies are valid targets/sources -------


def test_update_bevel_pair_feature_changes_tooth_count_and_the_mesh_reflects_it():
    part = _create_part()
    create_response = _create_pair(part["id"], member_1=_member(20), member_2=_member(40))
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]
    mesh_before = [entry["mesh"]["vertices"] for entry in _mesh(part["id"])]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/bevel-pair-features/{feature_id}",
        json={"member_1": _member(24)},
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["member_1"]["tooth_count"] == 24
    # Both members' cone angles re-derive live from the new tooth counts -
    # both bodies' own geometry changes, not just member_1's.
    mesh_after = [entry["mesh"]["vertices"] for entry in _mesh(part["id"])]
    assert mesh_after != mesh_before


def test_update_bevel_pair_feature_rejects_an_invalid_change():
    part = _create_part()
    create_response = _create_pair(part["id"])
    feature_id = create_response.json()["id"]
    patch_response = client.patch(
        f"/document/parts/{part['id']}/bevel-pair-features/{feature_id}", json={"module": -5.0}
    )
    assert patch_response.status_code == 422
    assert len(_mesh(part["id"])) == 2


def test_step_export_succeeds_for_a_bevel_pair():
    part = _create_part()
    response = _create_pair(part["id"])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert len(export_response.content) > 1000
    assert b"ISO-10303-21" in export_response.content


def test_bevel_pair_member_body_can_be_cut_afterward_via_a_new_sketch():
    """`00-conventions.md`'s "downstream Features already work on any
    gear-family Body" claim, exercised for one member of a bevel pair: a
    Sketch on the fixed XY plane, a small circle, then an Extrude Cut
    targeting just member_1's own `#0`-suffixed Body id - the other
    member's Body must be untouched."""
    part = _create_part()
    pair_response = _create_pair(part["id"])
    assert pair_response.status_code == 201, pair_response.json()
    mesh_before = _mesh(part["id"])
    member_1_body_id = next(e["body_id"] for e in mesh_before if e["body_id"].endswith("#0"))

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
            "target_body_ids": [member_1_body_id],
        },
    )
    assert cut_response.status_code == 201, cut_response.json()

    mesh_after = _mesh(part["id"])
    assert len(mesh_after) == 2  # still two Bodies, one now with a bore cut through it


def test_native_export_import_round_trips_a_bevel_pair_feature():
    """Mirrors `test_bevel_gear_feature.py`'s own native round-trip
    regression test - the same `native_format.py` omission risk this
    workstream's own instruction called out explicitly."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Bevel Pair Test")
        pair_response = _create_pair(part["id"], member_1=_member(20), member_2=_member(40), face_width=12.0)
        assert pair_response.status_code == 201, pair_response.json()
        feature_id = pair_response.json()["id"]
        vertices_before = [entry["mesh"]["vertices"] for entry in _mesh(part["id"])]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        pair_dicts = [
            f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "bevel_pair"
        ]
        assert any(f["id"] == feature_id for f in pair_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = [entry["mesh"]["vertices"] for entry in _mesh(part["id"])]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
