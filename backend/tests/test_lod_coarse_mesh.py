"""Real-OCCT tests for the LOD coarse-mesh mechanism -
`docs/lod-strategy/01-design.md` chunk 2 (SS8, item 2): the new coarse
builders in `app.document.gear`/`bevel`/`bevel_pair`/`gear_chain`/
`planetary_gear`, `GET /parts/{id}/mesh`'s new `tier=coarse` query
parameter, and the new coarse-preview endpoints for a not-yet-created
Feature payload. Structurally mirrors `test_gear_feature.py`/`test_bevel_
pair_feature.py`'s own HTTP-level shape.

Every coarse-builder assertion here is deliberately loose ("roughly
matches", "within a generous factor") - a coarse stand-in is meant to be a
low-fidelity proxy, not a byte-identical (or even close-fidelity) copy of
the real geometry, per the design doc's own explicit instruction.

**Timing note, stated honestly** (matching this repo's own established
convention of flagging measurement caveats rather than glossing over them,
e.g. `docs/status.md`'s dated bevel-pair/gear-feature entries): the wall-
clock ceilings asserted below are generous and sandbox-relative - measured
against this session's own 4-core x86_64 conda env, not calibrated against
the app's real Pi 5/phone target hardware. They are wide enough to have
real margin on much slower hardware too (a coarse build is a single
primitive OCCT call, not a multi-second tooth-by-tooth construction), but a
future session with real on-device numbers should tighten them if it ever
matters.
"""

import time

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

# Generous, sandbox-relative wall-clock ceiling - see this module's own
# top-level docstring. A coarse build is one BRepPrimAPI_MakeCylinder/
# MakeCone call (plus, for the not-yet-created preview endpoints, one
# `resolve_plane_ref` against an otherwise-empty Part) - genuinely
# millisecond-scale, so even a generous factor of safety over that leaves
# comfortable margin.
_COARSE_WALL_CLOCK_CEILING_SECONDS = 1.0


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str, **params) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh", params=params)
    assert response.status_code == 200, response.json()
    return response.json()


def _bbox(vertices: list[list[float]]) -> tuple[float, float, float, float, float, float]:
    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    zs = [v[2] for v in vertices]
    return min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)


def _radial_extent(vertices: list[list[float]]) -> float:
    """Max distance from the Z axis - the natural "size" proxy for a gear-
    family Body extruded/built along Z (this app's default plane), used to
    compare a coarse cylinder/cone's own radius against the real gear's own
    addendum radius."""
    return max((x**2 + y**2) ** 0.5 for x, y, z in vertices)


# --- GearFeature -------------------------------------------------------------


def _create_gear(part_id: str, **overrides) -> dict:
    payload = {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 5.0}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-features", json=payload)


def test_gear_tier_coarse_is_a_fast_real_cylinder_roughly_matching_the_full_gear():
    part = _create_part()
    response = _create_gear(part["id"])
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 1
    assert full_mesh[0]["source"] == "computed"
    full_radius = _radial_extent(full_mesh[0]["mesh"]["vertices"])
    full_z = _bbox(full_mesh[0]["mesh"]["vertices"])[4:]

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 1
    assert coarse_mesh[0]["source"] == "coarse"
    coarse_radius = _radial_extent(coarse_mesh[0]["mesh"]["vertices"])
    coarse_z = _bbox(coarse_mesh[0]["mesh"]["vertices"])[4:]

    # Deliberately loose - a cylinder is not the real tooth envelope, just a
    # reasonable proxy for it (module-2/20-tooth: addendum radius 22mm).
    assert 0.5 * full_radius <= coarse_radius <= 1.5 * full_radius
    assert coarse_z == full_z  # face_width is honored exactly either way


def test_gear_coarse_preview_returns_a_real_solid_and_persists_nothing():
    part = _create_part()
    payload = {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 5.0}

    start = time.perf_counter()
    response = client.post(f"/document/parts/{part['id']}/gear-features/coarse-preview", json=payload)
    elapsed = time.perf_counter() - start
    assert response.status_code == 200, response.json()
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    bodies = response.json()
    assert len(bodies) == 1
    assert bodies[0]["source"] == "coarse"
    assert len(bodies[0]["mesh"]["vertices"]) > 0

    # Nothing persisted: no Feature was created, and the Part's own /mesh
    # still reports the empty-Part placeholder.
    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.status_code == 200
    assert features.json() == []
    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "placeholder"


def test_internal_gear_coarse_uses_outer_diameter_as_its_radius():
    part = _create_part()
    response = _create_gear(part["id"], is_internal=True, outer_diameter=60.0)
    assert response.status_code == 201, response.json()

    coarse_mesh = _mesh(part["id"], tier="coarse")
    assert len(coarse_mesh) == 1
    coarse_radius = _radial_extent(coarse_mesh[0]["mesh"]["vertices"])
    assert 25.0 <= coarse_radius <= 30.5  # ~ outer_diameter / 2, well within tessellation tolerance


# --- BevelGearFeature ---------------------------------------------------------

_PITCH_ANGLE_20_40 = 26.56505117707799


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


def test_bevel_gear_tier_coarse_is_a_fast_real_cone_roughly_matching_the_full_gear():
    part = _create_part()
    response = _create_bevel(part["id"])
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 1
    full_radius = _radial_extent(full_mesh[0]["mesh"]["vertices"])

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 1
    assert coarse_mesh[0]["source"] == "coarse"
    coarse_radius = _radial_extent(coarse_mesh[0]["mesh"]["vertices"])
    assert 0.5 * full_radius <= coarse_radius <= 1.5 * full_radius


def test_bevel_gear_coarse_preview_returns_a_real_solid_and_persists_nothing():
    part = _create_part()
    payload = {
        "bevel_type": "boss",
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 15.0,
        "pitch_cone_angle_degrees": _PITCH_ANGLE_20_40,
    }
    response = client.post(f"/document/parts/{part['id']}/bevel-gear-features/coarse-preview", json=payload)
    assert response.status_code == 200, response.json()
    bodies = response.json()
    assert len(bodies) == 1
    assert bodies[0]["source"] == "coarse"

    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.json() == []


# --- BevelPairFeature ----------------------------------------------------------


def _bevel_pair_member(tooth_count: int, profile_shift: float = 0.0) -> dict:
    return {"tooth_count": tooth_count, "profile_shift": profile_shift}


def _create_bevel_pair(part_id: str, **overrides) -> dict:
    payload = {
        "module": 4.0,
        "member_1": _bevel_pair_member(20),
        "member_2": _bevel_pair_member(40),
        "face_width": 15.0,
    }
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/bevel-pair-features", json=payload)


def test_bevel_pair_tier_coarse_returns_two_cones_without_a_phase_search():
    part = _create_part()
    response = _create_bevel_pair(part["id"])
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 2

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    # The single biggest win this chunk claims: no per-build meshing-phase
    # ProcessPoolExecutor search at all for the coarse pass.
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 2
    assert all(entry["source"] == "coarse" for entry in coarse_mesh)
    for entry in coarse_mesh:
        assert len(entry["mesh"]["vertices"]) > 0


def test_bevel_pair_coarse_preview_returns_two_solids_and_persists_nothing():
    part = _create_part()
    payload = {
        "module": 4.0,
        "member_1": _bevel_pair_member(20),
        "member_2": _bevel_pair_member(40),
        "face_width": 15.0,
    }
    start = time.perf_counter()
    response = client.post(f"/document/parts/{part['id']}/bevel-pair-features/coarse-preview", json=payload)
    elapsed = time.perf_counter() - start
    assert response.status_code == 200, response.json()
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    bodies = response.json()
    assert len(bodies) == 2
    assert all(entry["source"] == "coarse" for entry in bodies)

    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.json() == []


# --- GearChainFeature ----------------------------------------------------------


def _group(group_id: str, module: float, pressure_angle_degrees: float = 20.0) -> dict:
    return {"id": group_id, "module": module, "pressure_angle_degrees": pressure_angle_degrees}


def _chain_member(member_type: str, group_id: str, tooth_count: int, face_width: float = 5.0) -> dict:
    return {"member_type": member_type, "group_id": group_id, "tooth_count": tooth_count, "face_width": face_width}


def _stage(member: dict) -> dict:
    return {
        "turn_angle_degrees": 0.0,
        "member": member,
        "compound_member_a": None,
        "compound_member_b": None,
        "compound_axial_offset": 0.0,
        "compound_merge": "fuse_into_one",
    }


def _create_gear_chain(part_id: str, groups: list[dict], stages: list[dict], **overrides) -> dict:
    payload = {"groups": groups, "stages": stages}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-chain-features", json=payload)


def test_gear_chain_tier_coarse_returns_one_cylinder_per_member():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(_chain_member("external", "g1", 20)),
        _stage(_chain_member("external", "g1", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 2

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 2
    assert all(entry["source"] == "coarse" for entry in coarse_mesh)


def test_gear_chain_coarse_preview_returns_one_body_per_member_and_persists_nothing():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(_chain_member("external", "g1", 20)),
        _stage(_chain_member("external", "g1", 15)),
    ]
    payload = {"groups": groups, "stages": stages}
    response = client.post(f"/document/parts/{part['id']}/gear-chain-features/coarse-preview", json=payload)
    assert response.status_code == 200, response.json()

    bodies = response.json()
    assert len(bodies) == 2
    assert all(entry["source"] == "coarse" for entry in bodies)

    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.json() == []


# --- PlanetaryGearFeature -------------------------------------------------------


def _create_planetary(part_id: str, **overrides) -> dict:
    # sun_tooth_count=20, ring_tooth_count=60 -> planet_tooth_count = 20;
    # assembly condition (20+60) % 5 == 0 - the same well-formed default
    # test_planetary_gear_feature.py itself uses.
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


def test_planetary_tier_coarse_returns_sun_ring_and_every_planet():
    part = _create_part()
    response = _create_planetary(part["id"])
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 7  # sun + ring + 5 planets

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 7
    assert all(entry["source"] == "coarse" for entry in coarse_mesh)
    for entry in coarse_mesh:
        assert len(entry["mesh"]["vertices"]) > 0


def test_planetary_coarse_preview_returns_seven_bodies_and_persists_nothing():
    part = _create_part()
    payload = {
        "module": 1.0,
        "sun_tooth_count": 20,
        "ring_tooth_count": 60,
        "planet_count": 5,
        "face_width": 5.0,
        "ring_outer_diameter": 70.0,
    }
    response = client.post(f"/document/parts/{part['id']}/planetary-gear-features/coarse-preview", json=payload)
    assert response.status_code == 200, response.json()

    bodies = response.json()
    assert len(bodies) == 7
    assert all(entry["source"] == "coarse" for entry in bodies)

    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.json() == []


# --- Cross-cutting: tier=coarse is filtered to coarse-eligible Bodies only ----


def test_tier_coarse_excludes_bodies_from_non_coarse_eligible_features():
    """`docs/lod-strategy/01-design.md` SS4: `tier=coarse` returns only the
    Bodies a coarse-eligible Feature type produced - an ordinary Extrude
    (no coarse builder of its own) sitting alongside a Gear in the same
    Part should not appear in a `tier=coarse` response at all."""
    part = _create_part()
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201, sketch_response.json()
    sketch_feature_id = sketch_response.json()["id"]
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

    extrude_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 5.0,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201, extrude_response.json()

    gear_response = _create_gear(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert gear_response.status_code == 201, gear_response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 2  # the Extrude Body and the Gear Body

    coarse_mesh = _mesh(part["id"], tier="coarse")
    assert len(coarse_mesh) == 1
    assert coarse_mesh[0]["source"] == "coarse"


# --- Regression: coarse-preview validation gaps (fix-up pass) ----------------
#
# A follow-up code review against `docs/lod-strategy/01-design.md` found the
# coarse builders above skip three validity checks their own real-
# construction counterparts already enforce - each one letting a rejected
# parameter combination either 500 on an unhandled OCCT failure, or (the
# too-small-outer_diameter case) silently build a plausible-looking coarse
# solid for a gear the real endpoint would refuse to create at all. Every
# test below asserts the coarse-preview endpoint now gives the *same*
# structured 422 (`detail["type"]`) the real create endpoint already gives
# for the identical payload - not just "some 4xx", the same failure mode.


def test_bevel_gear_coarse_preview_crown_gear_returns_same_422_as_create():
    """`pitch_cone_angle_degrees=90` (a crown gear) passes `bevel_gear_
    geometry`'s own `0 < angle <= 90` range check but fails the Tredgold
    degeneracy guard (`TREDGOLD_MAX_PITCH_CONE_ANGLE_DEGREES = 89.5`) that
    `_assemble_gear_solid` (the real path) enforces via `tredgold_base_
    colatitude` - `coarse_bevel_cone_solid` used to skip that guard
    entirely and hand `axial_height = cone_distance * cos(90deg) = 0.0` to
    `BRepPrimAPI_MakeCone`, which OCCT rejects as an unhandled 500."""
    part = _create_part()
    payload = {
        "bevel_type": "boss",
        "module": 4.0,
        "tooth_count": 20,
        "face_width": 15.0,
        "pitch_cone_angle_degrees": 90.0,
    }

    create_response = _create_bevel(part["id"], pitch_cone_angle_degrees=90.0)
    assert create_response.status_code == 422, create_response.json()
    assert create_response.json()["detail"]["type"] == "invalid_bevel_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/bevel-gear-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == "invalid_bevel_parameters"


def test_bevel_pair_coarse_preview_crown_gear_returns_same_422_as_create():
    """`bevel_pair.py`'s coarse path reuses `bevel.coarse_bevel_cone_solid`
    per member - the same Tredgold guard gap, reachable here via a
    `shaft_angle_degrees`/tooth-count combination that drives one member's
    own `pitch_cone_half_angles` result to a crown gear (40/20 teeth at a
    120-degree shaft angle: `gamma_1 = atan(sin(120deg) / (20/40 +
    cos(120deg))) = atan(sin(120deg) / 0) -> 90 degrees exactly, up to
    floating point)."""
    part = _create_part()
    payload = {
        "module": 4.0,
        "member_1": _bevel_pair_member(40),
        "member_2": _bevel_pair_member(20),
        "face_width": 15.0,
        "shaft_angle_degrees": 120.0,
    }

    create_response = _create_bevel_pair(
        part["id"],
        member_1=_bevel_pair_member(40),
        member_2=_bevel_pair_member(20),
        shaft_angle_degrees=120.0,
    )
    assert create_response.status_code == 422, create_response.json()
    assert create_response.json()["detail"]["type"] == "invalid_bevel_pair_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/bevel-pair-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == "invalid_bevel_pair_parameters"


def test_internal_gear_coarse_preview_nonpositive_outer_diameter_returns_same_422_as_create():
    """`outer_diameter <= 0` reaches `BRepPrimAPI_MakeCylinder` with a non-
    positive radius in the coarse path and 500s - the real path's own
    `_gear_face` rejects it first via its `outer_radius <= dedendum_radius`
    check (module=2/tooth_count=20 internal: dedendum diameter is 45mm, so
    any non-positive `outer_diameter` is far below it)."""
    part = _create_part()
    payload = {
        "gear_type": "boss",
        "is_internal": True,
        "module": 2.0,
        "tooth_count": 20,
        "face_width": 5.0,
        "outer_diameter": 0.0,
    }

    create_response = _create_gear(part["id"], is_internal=True, outer_diameter=0.0)
    assert create_response.status_code == 422, create_response.json()
    assert create_response.json()["detail"]["type"] == "invalid_gear_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/gear-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == "invalid_gear_parameters"


def test_internal_gear_coarse_preview_too_small_outer_diameter_returns_same_422_as_create():
    """A positive but too-small `outer_diameter` (here 30mm, below the
    45mm dedendum diameter for module=2/tooth_count=20 internal) used to
    build a plausible-looking coarse cylinder for a parameter combination
    the real endpoint rejects outright as "no rim material left" -
    silently misleading rather than crashing."""
    part = _create_part()
    payload = {
        "gear_type": "boss",
        "is_internal": True,
        "module": 2.0,
        "tooth_count": 20,
        "face_width": 5.0,
        "outer_diameter": 30.0,
    }

    create_response = _create_gear(part["id"], is_internal=True, outer_diameter=30.0)
    assert create_response.status_code == 422, create_response.json()
    assert create_response.json()["detail"]["type"] == "invalid_gear_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/gear-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == "invalid_gear_parameters"


def test_gear_chain_internal_member_coarse_preview_nonpositive_outer_diameter_returns_same_422_as_create():
    """The same `outer_diameter <= 0` gap, reached through `gear_chain.py`'s
    own reuse of `gear.py`'s coarse radius helper for an INTERNAL chain
    member. An INTERNAL member is only valid as the chain's *last* stage,
    and must have a strictly larger tooth_count than the meshing external
    member before it (`_validate_gear_chain_stages`/`gear_chain_math`'s own
    meshing check) - a 2-stage 20/40-tooth chain clears both of those so
    the outer_diameter/dedendum_radius check under test is what actually
    fires."""
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(_chain_member("external", "g1", 20)),
        _stage({**_chain_member("internal", "g1", 40), "outer_diameter": 0.0}),
    ]
    payload = {"groups": groups, "stages": stages}

    create_response = _create_gear_chain(part["id"], groups, stages)
    assert create_response.status_code == 422, create_response.json()
    # The real path's `_build_member_solid` reuses `app.document.gear.
    # _gear_face` directly for this exact check, so its error `type` is
    # `gear.py`'s own `invalid_gear_parameters`, not this module's `invalid_
    # gear_chain_parameters` - the coarse path mirrors that exactly.
    assert create_response.json()["detail"]["type"] == "invalid_gear_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/gear-chain-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == create_response.json()["detail"]["type"]


def test_gear_chain_internal_member_coarse_preview_too_small_outer_diameter_returns_same_422_as_create():
    """The same too-small-but-positive `outer_diameter` gap, reached
    through `gear_chain.py`'s own reuse of `gear.py`'s coarse radius
    helper for an INTERNAL chain member (module=2/tooth_count=40 internal:
    85mm dedendum diameter, 50mm outer_diameter is below it)."""
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(_chain_member("external", "g1", 20)),
        _stage({**_chain_member("internal", "g1", 40), "outer_diameter": 50.0}),
    ]
    payload = {"groups": groups, "stages": stages}

    create_response = _create_gear_chain(part["id"], groups, stages)
    assert create_response.status_code == 422, create_response.json()
    assert create_response.json()["detail"]["type"] == "invalid_gear_parameters"

    coarse_response = client.post(f"/document/parts/{part['id']}/gear-chain-features/coarse-preview", json=payload)
    assert coarse_response.status_code == 422, coarse_response.json()
    assert coarse_response.json()["detail"]["type"] == create_response.json()["detail"]["type"]
