"""Persisted mate branch (`docs/mate-solution-choice-plan.md`, Phase 2): `Mate.alignment` / `Mate.secondary_flip`.

* the tester's table-top assembly lands centred from every start used in the investigation, by Gauss-Newton alone;
* every row of the plan's F2 table: both values of each control give exactly the matching root, from 10 starts;
* F3: a drag can never move a mate to its other root;
* Closest resolves from the starting pose and is written back; legacy files keep their stored poses bit for bit;
* the native format, the deprecated `flipped` alias and negative distances.
"""

import copy
import math
from dataclasses import replace

import numpy as np
import pytest

from app.document.assembly import apply_transform_to_direction
from app.document.assembly_group import mate_world_geometries, solve_group
from app.document.assembly_solver import resolve_branch
from app.document.constraint_model import rigid_to_pose
from app.document.models import RigidTransform
from app.document.store import get_document
from tests import table_top_fixture as tt
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import (
    _find_cylindrical_face,
    _make_box_part,
    _make_cylinder_part,
    _place_occurrence,
    client,
)

_STARTS = 10


# ---- helpers ---------------------------------------------------------------------------------------------------------


def _random_poses(seed: int, count: int = _STARTS, spread: float = 30.0):
    """`count` reproducible start poses: random translation (+-spread mm) and a random rotation (any axis, any angle)."""
    rng = np.random.default_rng(seed)
    for _ in range(count):
        axis = rng.normal(size=3)
        axis /= np.linalg.norm(axis)
        yield {
            "translation": [float(x) for x in rng.uniform(-spread, spread, size=3)],
            "rotation_axis": [float(x) for x in axis],
            "rotation_angle_degrees": float(rng.uniform(0.0, 360.0)),
        }


def _set_pose(root: str, occurrence: str, transform: dict) -> None:
    response = client.patch(f"/document/parts/{root}/occurrences/{occurrence}", json={"transform": transform})
    assert response.status_code == 200, response.text


def _stored_mate(root: str, mate_id: str):
    return next(m for m in get_document().parts[root].mates if m.id == mate_id)


def _actual_branch(root: str, mate_id: str) -> tuple[str | None, bool | None]:
    """The branch a mate's two references are ACTUALLY on at the stored poses, classified from the geometry alone (the
    mate's own fields are blanked, so this never just echoes what was asked for)."""
    document = get_document()
    part = document.parts[root]
    mate = replace(_stored_mate(root, mate_id), alignment=None, secondary_flip=None)
    first, second = mate_world_geometries(document, part, mate)
    resolved = resolve_branch(mate, first, second)
    return resolved.alignment, resolved.secondary_flip


def _create(root: str, mtype: str, driven: dict, fixed: dict, **fields) -> dict:
    payload = {
        "type": mtype,
        "references": [{"occurrence_id": "occ-driven", **driven}, {"occurrence_id": "", **fixed}],
        **fields,
    }
    response = client.post(f"/document/parts/{root}/mates", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def _solve(root: str, occurrence: str = "occ-driven"):
    response = client.post(f"/document/parts/{root}/occurrences/{occurrence}/solve")
    assert response.status_code == 200, response.text
    return response.json()


def _plate_scene():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=(5.0, 5.0, 40.0))
    return base, bracket


def _pin_scene():
    base = _make_cylinder_part("BasePost", radius=10.0, depth=5.0)
    pin = _make_cylinder_part("Pin", radius=3.0, depth=20.0)
    _place_occurrence(base["id"], pin["id"], translation=(77.0, -12.0, 5.0))
    return base, pin


def _cyl(part: dict) -> dict:
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": _find_cylindrical_face(part["id"], part["body_id"])}}


def _solve_from_every_start(root: str, mate: dict, seed: int, check) -> None:
    """Solves from `_STARTS` random poses; each answer must sit on the mate's requested branch and satisfy `check`."""
    for start in _random_poses(seed):
        _set_pose(root, "occ-driven", start)
        occurrence = _solve(root)
        got = _actual_branch(root, mate["id"])
        assert got[0] == mate["alignment"] or mate["alignment"] is None, (start, got)
        if mate["secondary_flip"] is not None:
            assert got[1] == mate["secondary_flip"], (start, got)
        check(occurrence["transform"])


def _world_dir(transform: dict, local: tuple[float, float, float]) -> tuple[float, float, float]:
    return apply_transform_to_direction(
        RigidTransform(tuple(transform["translation"]), tuple(transform["rotation_axis"]), transform["rotation_angle_degrees"]), local
    )


# ---- the tester's assembly ---------------------------------------------------------------------------------------------

_TESTER_BRANCHES = [
    {"alignment": "aligned", "secondary_flip": True},  # distance, plate edge face 2 against the y = 0 bar
    {"alignment": "aligned", "secondary_flip": True},  # distance, plate edge face 3 against the x = 0 bar
    {"alignment": "anti_aligned"},  # coincident, plate underside on the frame's top
]


def _tester_starts():
    correct = np.array(tt.CORRECT_PLATE_TRANSLATION)
    yield "identity", {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
    for shift in (12.0, -12.0, 30.0, -30.0):
        for axis in range(2):
            offset = np.zeros(3)
            offset[axis] = shift
            yield f"shift {shift:+.0f} on {'xy'[axis]}", {
                "translation": [float(x) for x in correct + offset],
                "rotation_axis": [1.0, 0.0, 0.0],
                "rotation_angle_degrees": 180.0,
            }
    rng = np.random.default_rng(3)
    for index in range(8):
        axis = rng.normal(size=3)
        axis /= np.linalg.norm(axis)
        yield f"random {index}", {
            "translation": [float(x) for x in correct + rng.normal(size=3) * 150.0],
            "rotation_axis": [float(x) for x in axis],
            "rotation_angle_degrees": float(rng.uniform(0.0, 360.0)),
        }


def test_tester_assembly_with_explicit_branches_lands_centred_from_every_start_by_gauss_newton_alone():
    root = tt.import_table_top(client, keep_mates=False)
    for payload, branch in zip(tt.table_top_mate_payloads(), _TESTER_BRANCHES):
        response = client.post(f"/document/parts/{root}/mates", json={**payload, **branch})
        assert response.status_code == 201, response.text
    document = get_document()
    part = document.parts[root]
    correct = np.array(tt.CORRECT_PLATE_TRANSLATION)
    for name, start in _tester_starts():
        _set_pose(root, tt.PLATE, start)
        result = solve_group(document, part, tt.PLATE, None)
        assert result.converged, name
        assert "slvs-fallback" not in result.quality.seeded_by, (name, result.quality.seeded_by)
        pose = result.poses[tt.PLATE]
        assert np.linalg.norm(np.array(pose.translation) - correct) < 1e-5, name
        # the rotation too (compared as matrices: 180 degrees about -x is 180 degrees about +x)
        axis, angle = tt.CORRECT_PLATE_ROTATION
        want = rigid_to_pose(RigidTransform((0.0, 0.0, 0.0), axis, angle))[0]
        assert np.allclose(rigid_to_pose(pose)[0], want, atol=1e-8), name


def test_tester_assembly_every_mate_resolves_and_the_first_distance_mate_now_converges_from_the_identity_pose():
    """F4.2: the squared DISTANCE residual stalled just above tolerance on a 790 mm move; the linear signed one does not."""
    root = tt.import_table_top(client, keep_mates=False)
    _set_pose(root, tt.PLATE, {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0})
    for payload in tt.table_top_mate_payloads():
        ghost = client.post(f"/document/parts/{root}/occurrences/{tt.PLATE}/preview-mate-solve", params={"movement": "auto"}, json=payload).json()
        assert ghost["converged"], payload["type"]
        response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=payload)
        assert response.status_code == 201, response.text
        stored = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}[tt.PLATE]
        assert np.allclose(ghost["transform"]["translation"], stored["translation"], atol=1e-6)
    assert all(m["alignment"] is not None for m in client.get(f"/document/parts/{root}/mates").json())


# ---- F2: every row, both values of each control, from 10 starts ----------------------------------------------------------


@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_coincident_plane_plane_alignment(alignment):
    base, bracket = _plate_scene()
    mate = _create(base["id"], "coincident", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), alignment=alignment)
    assert mate["alignment"] == alignment and mate["flipped"] == (alignment == "aligned")
    sign = 1.0 if alignment == "aligned" else -1.0
    _solve_from_every_start(
        base["id"], mate, 11, lambda t: _assert_normal(t, (0, 0, -1), (0, 0, sign))
    )


def _assert_normal(transform, local, expected):
    got = _world_dir(transform, local)
    assert np.allclose(got, expected, atol=1e-6), (got, expected)


@pytest.mark.parametrize("mate_type", ["concentric", "coincident"])  # coincident of two axes IS a concentric (edge-edge)
@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_concentric_and_axis_coincident_alignment(mate_type, alignment):
    base, pin = _pin_scene()
    mate = _create(base["id"], mate_type, _cyl(pin), _cyl(base), alignment=alignment)
    sign = 1.0 if alignment == "aligned" else -1.0

    def check(transform):
        axis = _world_dir(transform, (0, 0, 1))
        assert abs(axis[2] - sign) < 1e-6, axis

    _solve_from_every_start(base["id"], mate, 12, check)


@pytest.mark.parametrize("secondary_flip", [False, True])
@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_concentric_with_rotation_locked_has_four_roots(alignment, secondary_flip):
    base, pin = _pin_scene()
    mate = _create(base["id"], "concentric", _cyl(pin), _cyl(base), alignment=alignment, secondary_flip=secondary_flip, allow_rotation=False)
    _solve_from_every_start(base["id"], mate, 13, lambda t: None)


@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_parallel_alignment(alignment):
    base, bracket = _plate_scene()
    mate = _create(base["id"], "parallel", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), alignment=alignment)
    sign = 1.0 if alignment == "aligned" else -1.0
    _solve_from_every_start(base["id"], mate, 14, lambda t: _assert_normal(t, (0, 0, -1), (0, 0, sign)))


@pytest.mark.parametrize("secondary_flip,expected", [(False, 60.0), (True, 120.0)])
def test_angle_supplement(secondary_flip, expected):
    base, bracket = _plate_scene()
    mate = _create(base["id"], "angle", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=60.0, secondary_flip=secondary_flip)
    assert mate["flipped"] == secondary_flip

    def check(transform):
        dot = float(np.dot(_world_dir(transform, (0, 0, -1)), (0, 0, 1)))
        assert abs(math.degrees(math.acos(max(-1.0, min(1.0, dot)))) - expected) < 1e-4

    _solve_from_every_start(base["id"], mate, 15, check)


@pytest.mark.parametrize("secondary_flip", [False, True])
def test_distance_point_plane_side(secondary_flip):
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, 40.0))
    vertex = {"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}}
    mate = _create(base["id"], "distance", vertex, _face(base, (0, 0, 1)), value=6.0, secondary_flip=secondary_flip)
    side = -1.0 if secondary_flip else 1.0

    def check(transform):
        # the pin's vertex 0 is its local origin: its world z is the translation's z
        assert abs(transform["translation"][2] - (10.0 + side * 6.0)) < 1e-6, transform

    _solve_from_every_start(base["id"], mate, 16, check)


@pytest.mark.parametrize("secondary_flip", [False, True])
@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_distance_plane_plane_has_four_roots(alignment, secondary_flip):
    base, bracket = _plate_scene()
    mate = _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0, alignment=alignment, secondary_flip=secondary_flip)
    side = -1.0 if secondary_flip else 1.0
    sign = 1.0 if alignment == "aligned" else -1.0

    def check(transform):
        _assert_normal(transform, (0, 0, -1), (0, 0, sign))
        # the bracket's bottom face (local z = 0) sits 15 mm from the base top (z = 10), on the requested side
        assert abs(transform["translation"][2] - (10.0 + side * 15.0)) < 1e-6, transform

    _solve_from_every_start(base["id"], mate, 17, check)


@pytest.mark.parametrize("alignment", ["aligned", "anti_aligned"])
def test_distance_axis_axis_alignment(alignment):
    base, pin = _pin_scene()
    mate = _create(base["id"], "distance", _cyl(pin), _cyl(base), value=25.0, alignment=alignment)
    sign = 1.0 if alignment == "aligned" else -1.0

    def check(transform):
        assert abs(_world_dir(transform, (0, 0, 1))[2] - sign) < 1e-6
        assert abs(math.hypot(transform["translation"][0], transform["translation"][1]) - 25.0) < 1e-6

    _solve_from_every_start(base["id"], mate, 18, check)


def test_distance_point_point_has_no_root_and_converges():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, 40.0))
    point = lambda part, index: {"subshape_ref": {"body_id": part["body_id"], "shape_type": "vertex", "index": index}}
    mate = _create(base["id"], "distance", point(pin, 0), point(base, 0), value=30.0)
    assert mate["alignment"] is None and mate["secondary_flip"] is None
    for start in _random_poses(19):
        _set_pose(base["id"], "occ-driven", start)
        _solve(base["id"])
        document = get_document()
        first, second = mate_world_geometries(document, document.parts[base["id"]], _stored_mate(base["id"], mate["id"]))
        assert abs(math.dist(first.point, second.point) - 30.0) < 1e-6


# ---- F3: a drag never crosses to the other root ---------------------------------------------------------------------------


def _motion(root: str, occurrence: str, wish: dict, commit: bool = False) -> dict:
    response = client.post(f"/document/parts/{root}/occurrences/{occurrence}/mate-motion", json={"transform": wish, "commit": commit})
    assert response.status_code == 200, response.text
    return response.json()


def test_dragging_a_distance_bracket_through_the_plate_stays_on_its_side():
    base, bracket = _plate_scene()
    _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0)
    _set_pose(base["id"], "occ-driven", {"translation": [5.0, 5.0, 25.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0})
    _solve(base["id"])  # Closest -> side +, stored
    for z in (5.0, -3.0, -40.0, 60.0):
        wish = {"translation": [5.0, 5.0, z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}
        body = _motion(base["id"], "occ-driven", wish)
        assert body["converged"]
        assert abs(body["members"][0]["transform"]["translation"][2] - 25.0) < 1e-6, (z, body["members"][0]["transform"])


def test_dragging_a_concentric_pin_100_degrees_does_not_turn_it_over():
    base, pin = _pin_scene()
    _create(base["id"], "concentric", _cyl(pin), _cyl(base))
    _solve(base["id"])  # Closest: stored with the axis pointing up
    stored = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{base['id']}/occurrences").json()}["occ-driven"]
    assert _world_dir(stored, (0, 0, 1))[2] > 0.99
    for axis in ((1, 0, 0), (0, 1, 0), (1, 1, 0)):
        wish = {"translation": stored["translation"], "rotation_axis": list(axis), "rotation_angle_degrees": 100.0}
        body = _motion(base["id"], "occ-driven", wish)
        assert body["converged"]
        assert _world_dir(body["members"][0]["transform"], (0, 0, 1))[2] > 0.99, axis


def test_a_drag_commit_never_changes_a_named_branch():
    base, bracket = _plate_scene()
    mate = _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0, alignment="aligned", secondary_flip=False)
    _solve(base["id"])
    wish = {"translation": [5.0, 5.0, -30.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}
    _motion(base["id"], "occ-driven", wish, commit=True)
    stored = _stored_mate(base["id"], mate["id"])
    assert (stored.alignment, stored.secondary_flip) == ("aligned", False)


# ---- Closest, persistence, the flipped alias --------------------------------------------------------------------------------


def test_closest_resolves_from_the_starting_pose_and_is_written_back_by_the_solve():
    base, bracket = _plate_scene()
    # the bracket starts BELOW the base (z = -30): the nearest side of a 15 mm distance is the -normal one
    _set_pose(base["id"], "occ-driven", {"translation": [5.0, 5.0, -30.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 180.0})
    mate = _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0, alignment=None, secondary_flip=None)
    assert mate["alignment"] is None and mate["secondary_flip"] is None
    solved = _solve(base["id"])["transform"]
    listed = client.get(f"/document/parts/{base['id']}/mates").json()[0]
    assert listed["alignment"] == "aligned" and listed["secondary_flip"] is True
    assert abs(solved["translation"][2] - (10.0 - 15.0)) < 1e-6
    # now fixed: a later solve from the other side of the base stays on the stored branch
    _set_pose(base["id"], "occ-driven", {"translation": [5.0, 5.0, 60.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 180.0})
    assert abs(_solve(base["id"])["transform"]["translation"][2] - (10.0 - 15.0)) < 1e-6


def test_preview_resolves_closest_but_never_stores_it():
    base, bracket = _plate_scene()
    payload = {
        "type": "distance",
        "references": [{"occurrence_id": "occ-driven", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": 15.0,
        "alignment": None,
        "secondary_flip": None,
    }
    ghost = client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/preview-mate-solve", json=payload).json()
    assert ghost["converged"]
    assert client.get(f"/document/parts/{base['id']}/mates").json() == []


def test_the_deprecated_flipped_flag_is_read_into_the_branch_fields():
    base, bracket = _plate_scene()
    plain = _create(base["id"], "coincident", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), flipped=False)
    assert plain["alignment"] == "anti_aligned" and plain["flipped"] is False
    flipped = _create(base["id"], "coincident", _face(bracket, (0, 0, 1)), _face(base, (0, 0, 1)), flipped=True)
    assert flipped["alignment"] == "aligned" and flipped["flipped"] is True
    angle = _create(base["id"], "angle", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=60.0, flipped=True)
    assert angle["secondary_flip"] is True and angle["alignment"] is None
    # CONCENTRIC / DISTANCE / PARALLEL never used `flipped`: it stays inert and the branch is Closest
    distance = _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=5.0, flipped=True)
    assert distance["alignment"] is None and distance["secondary_flip"] is None and distance["flipped"] is True


def test_patching_flipped_alone_moves_the_branch_and_patching_the_branch_moves_flipped():
    base, bracket = _plate_scene()
    mate = _create(base["id"], "coincident", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)))
    assert mate["alignment"] == "anti_aligned"
    patched = client.patch(f"/document/parts/{base['id']}/mates/{mate['id']}", json={"flipped": True}).json()
    assert patched["alignment"] == "aligned" and patched["flipped"] is True
    patched = client.patch(f"/document/parts/{base['id']}/mates/{mate['id']}", json={"alignment": "anti_aligned"}).json()
    assert patched["alignment"] == "anti_aligned" and patched["flipped"] is False
    patched = client.patch(f"/document/parts/{base['id']}/mates/{mate['id']}", json={"alignment": None}).json()
    assert patched["alignment"] is None  # back to Closest


def test_a_negative_distance_is_refused_with_a_hint():
    base, bracket = _plate_scene()
    payload = {
        "type": "distance",
        "references": [{"occurrence_id": "occ-driven", **_face(bracket, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}],
        "value": -5.0,
    }
    response = client.post(f"/document/parts/{base['id']}/mates", json=payload)
    assert response.status_code == 422 and "secondary_flip" in response.text
    ok = _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=5.0)
    assert client.patch(f"/document/parts/{base['id']}/mates/{ok['id']}", json={"value": -1.0}).status_code == 422
    assert client.get(f"/document/parts/{base['id']}/mates").json()[0]["value"] == 5.0


# ---- legacy files and the native format ------------------------------------------------------------------------------------


def test_the_testers_saved_assembly_keeps_its_stored_poses_bit_for_bit_after_a_solve():
    root = tt.import_table_top(client)  # mates WITHOUT the new keys (a legacy file)
    before = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}
    assert all(m["alignment"] is None for m in client.get(f"/document/parts/{root}/mates").json())
    assert client.post(f"/document/parts/{root}/occurrences/{tt.PLATE}/solve").status_code == 200
    assert {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()} == before
    resolved = {m["type"]: (m["alignment"], m["secondary_flip"]) for m in client.get(f"/document/parts/{root}/mates").json()}
    assert resolved["coincident"] == ("anti_aligned", None)
    assert resolved["distance"] == ("aligned", True)  # inside the frame
    # a drag commit of the legacy group fills the same values and moves nothing
    wish = before[tt.PLATE]
    body = _motion(root, tt.PLATE, wish, commit=True)
    assert body["converged"]
    assert {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()} == before


def test_native_format_round_trips_the_branch_and_reads_files_without_it():
    base, bracket = _plate_scene()
    _create(base["id"], "distance", _face(bracket, (0, 0, -1)), _face(base, (0, 0, 1)), value=15.0, alignment="anti_aligned", secondary_flip=True)
    _create(base["id"], "coincident", _face(bracket, (0, 0, 1)), _face(base, (0, 0, 1)), alignment=None)
    exported = client.get("/document/export/native", params={"part_id": base["id"]}).json()
    dumped = exported["document"]["parts"][0]["mates"]
    assert dumped[0]["alignment"] == "anti_aligned" and dumped[0]["secondary_flip"] is True and "flipped" in dumped[0]
    assert dumped[1]["alignment"] is None
    again = client.post("/document/import/native", json=exported)
    assert again.status_code == 200
    reexported = client.get("/document/export/native", params={"part_id": base["id"]}).json()
    assert reexported["document"]["parts"][0]["mates"] == dumped

    # new -> old: an old reader only knows `flipped`, which is still written and still means what it did
    assert dumped[0]["flipped"] in (True, False)

    # old -> new: a file without the keys imports as Closest; an ANGLE's flipped IS its supplement; a negative DISTANCE is its length
    legacy = copy.deepcopy(exported)
    mates = legacy["document"]["parts"][0]["mates"]
    for mate in mates:
        mate.pop("alignment"), mate.pop("secondary_flip")
    mates[0]["value"] = -15.0
    mates.append({**mates[1], "id": "legacy-angle", "type": "angle", "value": 60.0, "flipped": True})
    assert client.post("/document/import/native", json=legacy).status_code == 200
    listed = {m["id"]: m for m in client.get(f"/document/parts/{base['id']}/mates").json()}
    assert listed[mates[0]["id"]]["value"] == 15.0 and listed[mates[0]["id"]]["secondary_flip"] is None
    assert listed["legacy-angle"]["secondary_flip"] is True and listed["legacy-angle"]["alignment"] is None
    assert listed[mates[1]["id"]]["alignment"] is None


# ---- the side of a distance does not depend on which part happens to be the one moving ---------------------------------------


@pytest.mark.parametrize("secondary_flip,expected_a_z", [(False, 0.0), (True, 30.0)])
def test_grounding_the_other_part_never_makes_a_stored_side_mean_the_opposite_one(secondary_flip, expected_a_z):
    """A DISTANCE between two plane faces whose normals point the same way: `(a.origin - b.origin) . b.normal` is minus
    `(b.origin - a.origin) . a.normal`, so a side stored relative to "the fixed part" would flip when the roles swap and the
    part would hop across the face. The side is stored against the references' order instead."""
    root = _make_box_part("Root", size=5.0, depth=5.0)
    part_a = _make_box_part("A", size=20.0, depth=10.0)
    part_b = _make_box_part("B", size=8.0, depth=4.0)
    root_id = _compose(root, [("occ-a", part_a, (0.0, 0.0, 0.0)), ("occ-b", part_b, (5.0, 5.0, 40.0))])
    assert client.patch(f"/document/parts/{root_id}/occurrences/occ-a", json={"fixed": True}).status_code == 200
    # references [B.top, A.top], normals (0,0,1) both -> aligned; side False: B.top sits 15 mm ABOVE A.top (A.top = 10)
    mate = client.post(
        f"/document/parts/{root_id}/mates",
        json={
            "type": "distance",
            "references": [{"occurrence_id": "occ-b", **_face(part_b, (0, 0, 1))}, {"occurrence_id": "occ-a", **_face(part_a, (0, 0, 1))}],
            "value": 15.0,
            "alignment": "aligned",
            "secondary_flip": secondary_flip,
        },
    )
    assert mate.status_code == 201, mate.text
    transforms = lambda: {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root_id}/occurrences").json()}
    assert client.post(f"/document/parts/{root_id}/occurrences/occ-b/solve").status_code == 200
    b_z = transforms()["occ-b"]["translation"][2]
    assert abs(b_z - (10.0 + (-15.0 if secondary_flip else 15.0) - 4.0)) < 1e-6  # B.top = A.top +- 15
    # roles swapped: B grounded where it is, A floating and displaced; A must come back to the SAME relative placement
    assert client.patch(f"/document/parts/{root_id}/occurrences/occ-b", json={"fixed": True}).status_code == 200
    assert client.patch(f"/document/parts/{root_id}/occurrences/occ-a", json={"fixed": False}).status_code == 200
    _set_pose(root_id, "occ-a", {"translation": [0.0, 0.0, 70.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0})
    assert client.post(f"/document/parts/{root_id}/occurrences/occ-a/solve").status_code == 200
    a_z = transforms()["occ-a"]["translation"][2]
    expected = (b_z + 4.0) - (-15.0 if secondary_flip else 15.0) - 10.0  # A.top = B.top -+ 15
    assert abs(a_z - expected) < 1e-6, (a_z, expected)
    # the mate itself still names the same canonical branch
    stored = client.get(f"/document/parts/{root_id}/mates").json()[0]
    assert (stored["alignment"], stored["secondary_flip"]) == ("aligned", secondary_flip)
