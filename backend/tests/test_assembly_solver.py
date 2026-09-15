"""Phase 6 (`docs/assembly-scope.md` §3): real-OCCT, real-`py_slvs` tests for
the mate solver end to end, through the actual HTTP surface (`POST /parts/
{part_id}/mates`, `POST /parts/{part_id}/occurrences/{occurrence_id}/solve`) -
mirrors `test_assembly_mesh.py`/`test_occurrence_transform_update.py`'s own
"build real geometry via the API, compose a multi-part scene via `export` +
edit + `import`" convention.

Verification strategy: rather than hand-predicting Newton's method's exact
numeric output (several mate combinations leave real DOF free - e.g. a
plane-plane COINCIDENT mate leaves 2 in-plane translations unconstrained,
so there is no single "correct" answer to assert against), every test
instead verifies the *constraint itself* is actually satisfied by the
solved transform - using `app.document.assembly.apply_transform_to_point`/
`apply_transform_to_direction` (already independently unit-tested in
`test_assembly_transform_apply.py`) to place the driven side's own local
geometry into world space via the *solved* transform, then checking the
geometric relationship the Mate was supposed to establish (coincidence,
parallelism, a specific angle/distance) holds to within a tight numeric
tolerance. This is a stronger test than matching one arbitrary numeric
answer - it fails on a genuinely wrong solve regardless of which point in
an underdetermined solution's remaining freedom Newton's method happened to
land on.

Needs a real pythonocc-core + py_slvs environment (not available in this
repo's own dev sandbox - see docs/status.md's dated entries for whether a
real on-device/CI pass has actually run by the time this is read).
"""

import math

from fastapi.testclient import TestClient

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

_TOLERANCE = 1e-4


# --- Geometry setup helpers -------------------------------------------------


def _create_part(name: str) -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> None:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201


def _make_box_part(name: str, *, size: float = 10.0, depth: float = 10.0) -> dict:
    """A Part with one real solid Body - a `size` x `size` x `depth` box,
    corner at the origin. Returns the Part dict plus `body_id`."""
    part = _create_part(name)
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    corners = [_add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    extrude_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": depth,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    return {"id": part["id"], "body_id": mesh[0]["body_id"]}


def _make_cylinder_part(name: str, *, radius: float = 5.0, depth: float = 10.0) -> dict:
    """A Part with one real solid Body - a cylinder of `radius`/`depth`,
    centered on the Z axis, base at the origin."""
    part = _create_part(name)
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    center = _add_point(sketch_id, 0.0, 0.0)
    circle_response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert circle_response.status_code == 201
    extrude_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": depth,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    return {"id": part["id"], "body_id": mesh[0]["body_id"]}


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _place_occurrence(
    root_part_id: str,
    driven_part_id: str,
    *,
    occurrence_id: str = "occ-driven",
    translation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    rotation_axis: tuple[float, float, float] = (0.0, 0.0, 1.0),
    rotation_angle_degrees: float = 0.0,
) -> None:
    """Composes `driven_part_id` as a top-level Occurrence of `root_part_id`
    (mirrors `test_assembly_mesh.py`'s own export/edit/import convention),
    with an initial `transform` - deliberately away from any mate-
    satisfying placement in every test below, so a converged solve is
    real evidence the solver actually moved something, not a no-op."""
    root_export = _export_part(root_part_id)
    driven_export = _export_part(driven_part_id)
    root_part_dict = root_export["document"]["parts"][0]
    root_part_dict["occurrences"] = [
        {
            "id": occurrence_id,
            "external_ref": f"parts/{driven_part_id}.didsa",
            "resolved_part_id": driven_part_id,
            "name_override": None,
            "transform": {
                "translation": list(translation),
                "rotation_axis": list(rotation_axis),
                "rotation_angle_degrees": rotation_angle_degrees,
            },
            "suppressed": False,
            "hidden": False,
        }
    ]
    root_part_dict["mates"] = []
    composed_payload = {
        "schema_version": root_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": root_part_id,
            "parts": [root_part_dict, driven_export["document"]["parts"][0]],
        },
        "sketches": [*root_export["sketches"], *driven_export["sketches"]],
    }
    response = client.post("/document/import/native", json=composed_payload)
    assert response.status_code == 200


def _measure_face(part_id: str, body_id: str, index: int) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/measure",
        json={"refs": [{"body_id": body_id, "shape_type": "face", "index": index}]},
    )
    assert response.status_code == 200
    return response.json()


def _vectors_close(a, b, tolerance: float = _TOLERANCE) -> bool:
    return all(abs(x - y) < tolerance for x, y in zip(a, b))


def _find_planar_face(part_id: str, body_id: str, expected_normal: tuple[float, float, float]) -> int:
    """The index of `body_id`'s own planar face whose (outward) normal
    matches `expected_normal` - found by measuring every face in turn via
    the already-tested Measure endpoint rather than assuming any fixed
    `topexp.MapShapes` ordering (this codebase's own `SubShapeRef.index`
    docstring explicitly does not guarantee a stable order across
    independently-built bodies)."""
    for index in range(12):
        result = _measure_face(part_id, body_id, index)
        if result.get("normal") is not None and _vectors_close(result["normal"], expected_normal):
            return index
    raise AssertionError(f"no planar face with normal {expected_normal} found on {part_id}/{body_id}")


def _find_cylindrical_face(part_id: str, body_id: str) -> int:
    for index in range(12):
        result = _measure_face(part_id, body_id, index)
        if result.get("axis") is not None and result.get("radius") is not None:
            return index
    raise AssertionError(f"no cylindrical face found on {part_id}/{body_id}")


def _create_mate(
    root_part_id: str,
    *,
    mate_type: str,
    driven_ref: dict,
    fixed_ref: dict,
    driven_occurrence_id: str = "occ-driven",
    value: float | None = None,
    flipped: bool = False,
) -> dict:
    payload = {
        "type": mate_type,
        "references": [
            {"occurrence_id": driven_occurrence_id, **driven_ref},
            {"occurrence_id": "", **fixed_ref},
        ],
        "flipped": flipped,
    }
    if value is not None:
        payload["value"] = value
    response = client.post(f"/document/parts/{root_part_id}/mates", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def _solve(root_part_id: str, occurrence_id: str = "occ-driven") -> dict:
    response = client.post(f"/document/parts/{root_part_id}/occurrences/{occurrence_id}/solve")
    assert response.status_code == 200, response.text
    return response.json()


def _rigid_transform_from_response(occurrence: dict):
    from app.document.models import RigidTransform

    transform = occurrence["transform"]
    return RigidTransform(
        translation=tuple(transform["translation"]),
        rotation_axis=tuple(transform["rotation_axis"]),
        rotation_angle_degrees=transform["rotation_angle_degrees"],
    )


# --- COINCIDENT --------------------------------------------------------------


def test_coincident_plane_to_plane_not_flipped_faces_the_planes_toward_each_other():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=(3.0, 3.0, 50.0), rotation_angle_degrees=0.0)

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))
    bracket_bottom = _find_planar_face(bracket["id"], bracket["body_id"], (0.0, 0.0, -1.0))

    _create_mate(
        base["id"],
        mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "face", "index": bracket_bottom}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    # Bracket's bottom face origin lands exactly on Base's top plane (z=10).
    world_point = apply_transform_to_point(transform, (0.0, 0.0, 0.0))
    assert abs(world_point[2] - 10.0) < _TOLERANCE
    # Not flipped: the two faces point opposite ways (physically touching,
    # not overlapping) - Base's own top face normal is (0,0,1), so
    # Bracket's bottom face (local normal (0,0,-1)) must end up pointing
    # (0,0,-1) in world space too (i.e. this solve needs no rotation at
    # all - the local normal already opposes Base's).
    world_normal = apply_transform_to_direction(transform, (0.0, 0.0, -1.0))
    assert _vectors_close(world_normal, (0.0, 0.0, -1.0), tolerance=1e-3)


def test_coincident_plane_to_plane_flipped_faces_the_planes_the_same_way():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=(3.0, 3.0, 50.0))

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))
    bracket_bottom = _find_planar_face(bracket["id"], bracket["body_id"], (0.0, 0.0, -1.0))

    _create_mate(
        base["id"],
        mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "face", "index": bracket_bottom}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
        flipped=True,
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    world_point = apply_transform_to_point(transform, (0.0, 0.0, 0.0))
    assert abs(world_point[2] - 10.0) < _TOLERANCE
    # Flipped: Bracket's bottom-face normal now matches Base's top-face
    # normal direction, (0,0,1) - the opposite of the not-flipped case.
    world_normal = apply_transform_to_direction(transform, (0.0, 0.0, -1.0))
    assert _vectors_close(world_normal, (0.0, 0.0, 1.0), tolerance=1e-3)


def test_coincident_point_to_point_places_the_vertex_exactly():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(99.0, -5.0, 42.0))

    _create_mate(
        base["id"],
        mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    driven_vertex = client.post(
        f"/document/parts/{pin['id']}/measure",
        json={"refs": [{"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]
    fixed_vertex = client.post(
        f"/document/parts/{base['id']}/measure",
        json={"refs": [{"body_id": base["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]

    world_point = apply_transform_to_point(transform, tuple(driven_vertex))
    assert _vectors_close(world_point, tuple(fixed_vertex))


def test_coincident_vertex_to_plane_lands_the_point_in_the_plane():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, -30.0))

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))

    _create_mate(
        base["id"],
        mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    driven_vertex = client.post(
        f"/document/parts/{pin['id']}/measure",
        json={"refs": [{"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]
    world_point = apply_transform_to_point(transform, tuple(driven_vertex))
    assert abs(world_point[2] - 10.0) < _TOLERANCE


# --- CONCENTRIC --------------------------------------------------------------


def test_concentric_aligns_two_cylinder_axes():
    base = _make_cylinder_part("BasePost", radius=10.0, depth=5.0)
    pin = _make_cylinder_part("Pin", radius=3.0, depth=20.0)
    _place_occurrence(base["id"], pin["id"], translation=(77.0, -12.0, 5.0), rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=30.0)

    base_face = _find_cylindrical_face(base["id"], base["body_id"])
    pin_face = _find_cylindrical_face(pin["id"], pin["body_id"])

    _create_mate(
        base["id"],
        mate_type="concentric",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": pin_face}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_face}},
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    pin_axis = _measure_face(pin["id"], pin["body_id"], pin_face)["axis"]
    base_axis = _measure_face(base["id"], base["body_id"], base_face)["axis"]

    world_origin = apply_transform_to_point(transform, tuple(pin_axis["origin"]))
    world_direction = apply_transform_to_direction(transform, tuple(pin_axis["direction"]))

    # The two axis directions are parallel (cross product ~= 0).
    cross = (
        world_direction[1] * base_axis["direction"][2] - world_direction[2] * base_axis["direction"][1],
        world_direction[2] * base_axis["direction"][0] - world_direction[0] * base_axis["direction"][2],
        world_direction[0] * base_axis["direction"][1] - world_direction[1] * base_axis["direction"][0],
    )
    assert math.sqrt(sum(c * c for c in cross)) < 1e-3

    # The driven axis's own origin lies exactly on the fixed axis line -
    # perpendicular distance from the fixed axis to that point is ~0.
    to_point = tuple(w - b for w, b in zip(world_origin, base_axis["origin"]))
    dot = sum(t * d for t, d in zip(to_point, base_axis["direction"]))
    perpendicular = tuple(t - dot * d for t, d in zip(to_point, base_axis["direction"]))
    assert math.sqrt(sum(p * p for p in perpendicular)) < _TOLERANCE


# --- PARALLEL ------------------------------------------------------------


def test_parallel_faces_aligns_face_normals():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=(5.0, 5.0, 60.0), rotation_axis=(1.0, 1.0, 0.0), rotation_angle_degrees=47.0)

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))
    bracket_bottom = _find_planar_face(bracket["id"], bracket["body_id"], (0.0, 0.0, -1.0))

    _create_mate(
        base["id"],
        mate_type="parallel",
        driven_ref={"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "face", "index": bracket_bottom}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    world_normal = apply_transform_to_direction(transform, (0.0, 0.0, -1.0))
    cross = (
        world_normal[1] * 1.0 - world_normal[2] * 0.0,
        world_normal[2] * 0.0 - world_normal[0] * 1.0,
        world_normal[0] * 0.0 - world_normal[1] * 0.0,
    )
    assert math.sqrt(sum(c * c for c in cross)) < 1e-3


# --- ANGLE -----------------------------------------------------------------


def test_angle_sets_the_angle_between_two_face_normals():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    # Seeded away from exactly parallel/antiparallel on purpose: `addAngle`'s
    # own equation is a cosine of the angle between the two directions,
    # whose derivative vanishes at exactly 0/180 degrees (a real, reproduced
    # Newton-solver degeneracy, not a hypothetical one - the same class of
    # issue `_direction_lock`'s own docstring documents for a different
    # constraint) - Bracket's bottom-face normal starts exactly antiparallel
    # to Base's top-face normal at the identity rotation, so this seed picks
    # a real starting rotation away from that stationary point instead.
    _place_occurrence(
        base["id"], bracket["id"], translation=(5.0, 5.0, 60.0), rotation_axis=(1.0, 0.0, 0.0), rotation_angle_degrees=45.0
    )

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))
    bracket_bottom = _find_planar_face(bracket["id"], bracket["body_id"], (0.0, 0.0, -1.0))

    _create_mate(
        base["id"],
        mate_type="angle",
        driven_ref={"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "face", "index": bracket_bottom}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
        value=60.0,
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    world_normal = apply_transform_to_direction(transform, (0.0, 0.0, -1.0))
    base_normal = (0.0, 0.0, 1.0)
    dot = sum(a * b for a, b in zip(world_normal, base_normal))
    angle_degrees = math.degrees(math.acos(max(-1.0, min(1.0, dot))))
    # addAngle's own equation is ambiguous between an angle and its
    # supplement (confirmed against DOC.txt) - either the requested 60
    # degrees or its 120-degree supplement is an acceptable, correct result.
    assert abs(angle_degrees - 60.0) < 1e-2 or abs(angle_degrees - 120.0) < 1e-2


# --- DISTANCE ----------------------------------------------------------------


def test_distance_point_to_point_sets_the_exact_separation():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(200.0, 0.0, 0.0))

    _create_mate(
        base["id"],
        mate_type="distance",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
        value=25.0,
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    driven_vertex = client.post(
        f"/document/parts/{pin['id']}/measure",
        json={"refs": [{"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]
    fixed_vertex = client.post(
        f"/document/parts/{base['id']}/measure",
        json={"refs": [{"body_id": base["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]
    world_point = apply_transform_to_point(transform, tuple(driven_vertex))
    distance = math.sqrt(sum((a - b) ** 2 for a, b in zip(world_point, fixed_vertex)))
    assert abs(distance - 25.0) < 1e-3


def test_distance_point_to_plane_sets_the_exact_offset():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, -30.0))

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))

    _create_mate(
        base["id"],
        mate_type="distance",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
        value=5.0,
    )
    occurrence = _solve(base["id"])
    transform = _rigid_transform_from_response(occurrence)

    driven_vertex = client.post(
        f"/document/parts/{pin['id']}/measure",
        json={"refs": [{"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}]},
    ).json()["point"]
    world_point = apply_transform_to_point(transform, tuple(driven_vertex))
    assert abs(abs(world_point[2] - 10.0) - 5.0) < 1e-3


# --- Validation / error handling ---------------------------------------------


def test_mate_create_rejects_wrong_reference_count():
    base = _make_box_part("Base")
    response = client.post(
        f"/document/parts/{base['id']}/mates",
        json={
            "type": "coincident",
            "references": [{"occurrence_id": "", "subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}}],
        },
    )
    assert response.status_code == 422


def test_mate_create_rejects_distance_without_a_value():
    base = _make_box_part("Base")
    pin = _make_box_part("Pin")
    _place_occurrence(base["id"], pin["id"])
    response = client.post(
        f"/document/parts/{base['id']}/mates",
        json={
            "type": "distance",
            "references": [
                {"occurrence_id": "occ-driven", "subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
                {"occurrence_id": "", "subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
            ],
        },
    )
    assert response.status_code == 422


def test_mate_create_rejects_an_unknown_occurrence_id():
    base = _make_box_part("Base")
    response = client.post(
        f"/document/parts/{base['id']}/mates",
        json={
            "type": "coincident",
            "references": [
                {"occurrence_id": "does-not-exist", "subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
                {"occurrence_id": "", "subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 1}},
            ],
        },
    )
    assert response.status_code == 422


def test_concentric_rejects_a_planar_face_pair_with_no_axis():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=(3.0, 3.0, 50.0))

    base_top = _find_planar_face(base["id"], base["body_id"], (0.0, 0.0, 1.0))
    bracket_bottom = _find_planar_face(bracket["id"], bracket["body_id"], (0.0, 0.0, -1.0))
    _create_mate(
        base["id"],
        mate_type="concentric",
        driven_ref={"subshape_ref": {"body_id": bracket["body_id"], "shape_type": "face", "index": bracket_bottom}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
    )
    response = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/solve")
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "unsupported_mate_geometry"


def test_solving_an_occurrence_with_no_mates_is_a_no_op_returning_its_current_transform():
    base = _make_box_part("Base")
    pin = _make_box_part("Pin")
    _place_occurrence(base["id"], pin["id"], translation=(11.0, 22.0, 33.0), rotation_angle_degrees=15.0)

    occurrence = _solve(base["id"])
    assert occurrence["transform"]["translation"] == [11.0, 22.0, 33.0]
    assert occurrence["transform"]["rotation_angle_degrees"] == 15.0


def test_mate_update_changes_value_and_flipped():
    base = _make_box_part("Base")
    pin = _make_box_part("Pin")
    _place_occurrence(base["id"], pin["id"])
    mate = _create_mate(
        base["id"],
        mate_type="distance",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
        value=10.0,
    )
    response = client.patch(f"/document/parts/{base['id']}/mates/{mate['id']}", json={"value": 20.0, "flipped": True})
    assert response.status_code == 200
    body = response.json()
    assert body["value"] == 20.0
    assert body["flipped"] is True


def test_mate_delete_removes_it_from_the_list():
    base = _make_box_part("Base")
    pin = _make_box_part("Pin")
    _place_occurrence(base["id"], pin["id"])
    mate = _create_mate(
        base["id"],
        mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "vertex", "index": 0}},
    )
    delete_response = client.delete(f"/document/parts/{base['id']}/mates/{mate['id']}")
    assert delete_response.status_code == 204
    mates = client.get(f"/document/parts/{base['id']}/mates").json()
    assert mates == []
