"""B1 (docs/assembly-perf-mates-and-ui-plan.md): near-redundant mates. A solve that misses only by a tiny, bounded amount (in
physical units: 0.01 mm at the far end of the parts, 1e-4 rad) is accepted and the mates flagged `near`; anything beyond still
fails, an exact model stays `ok`, and nothing stored is ever changed."""
import math

import pytest

from app.document.mate_tolerance import (
    ANGULAR_LIMIT_RAD,
    FAR_END_LIMIT_MM,
    LINEAR_LIMIT_MM,
    PhysicalResidual,
    angular_limit_rad,
    is_within_tolerance,
)
from tests.test_assembly_group import _face
from tests.test_assembly_solver import _export_part, _make_box_part, client


# --- the pure limits ----------------------------------------------------------------------------------------------------


def test_the_angular_limit_keeps_the_far_end_within_the_linear_limit_and_never_exceeds_1e_4():
    assert angular_limit_rad(0.0) == ANGULAR_LIMIT_RAD
    assert angular_limit_rad(10.0) == ANGULAR_LIMIT_RAD  # 0.01 / 10 = 1e-3 rad would be looser than the cap
    assert angular_limit_rad(100.0) == pytest.approx(1e-4)  # exactly where the two meet
    assert angular_limit_rad(1800.0) == pytest.approx(FAR_END_LIMIT_MM / 1800.0)  # the 3.6 m brace: 5.6e-6 rad
    assert angular_limit_rad(6000.0) * 6000.0 == pytest.approx(FAR_END_LIMIT_MM)


def test_1e_4_rad_alone_would_move_a_6_m_part_by_0_6_mm_and_is_refused():
    residual = PhysicalResidual(linear_mm=0.0, angular_rad=1e-4)
    assert not is_within_tolerance(residual, 6000.0)
    assert is_within_tolerance(residual, 50.0)


def test_the_owners_brace_is_inside_and_a_millimetre_is_outside():
    # 3.5e-6 rad of disagreement between two mates, about 1.8 m from the pivot: about 0.006 mm
    assert is_within_tolerance(PhysicalResidual(0.0, 3.5e-6), 1800.0)
    assert not is_within_tolerance(PhysicalResidual(1.0, 0.0), 1800.0)  # 191 instead of 190
    assert is_within_tolerance(PhysicalResidual(LINEAR_LIMIT_MM, 0.0), 1800.0)
    assert not is_within_tolerance(PhysicalResidual(LINEAR_LIMIT_MM * 1.01, 0.0), 1800.0)


# --- through the API: a plate between two fixed blocks whose top faces disagree by `epsilon` ------------------------------


def _scene(epsilon: float, plate_size: float = 2000.0):
    """A root with two fixed blocks - A1 tilted by `epsilon` rad about x, A2 not - and a free plate. Mating the plate's underside
    at the same distance from both tops fixes its tilt twice, `epsilon` apart (over-defined)."""
    root = _make_box_part("Root", size=10.0, depth=10.0)
    block = _make_box_part("Block", size=100.0, depth=10.0)
    plate = _make_box_part("Plate", size=plate_size, depth=10.0)
    root_export = _export_part(root["id"])
    root_dict = root_export["document"]["parts"][0]

    def occurrence(oid, part, translation, angle=0.0):
        return {
            "id": oid,
            "external_ref": f"parts/{part['id']}.didsa",
            "resolved_part_id": part["id"],
            "name_override": None,
            "transform": {"translation": list(translation), "rotation_axis": [1, 0, 0], "rotation_angle_degrees": angle},
            "suppressed": False,
            "hidden": False,
        }

    root_dict["occurrences"] = [
        occurrence("a1", block, (0.0, 0.0, 0.0), math.degrees(epsilon)),
        occurrence("a2", block, (200.0, 0.0, 0.0)),
        occurrence("plate", plate, (-300.0, -300.0, 20.0)),
    ]
    root_dict["mates"] = []
    exports = [_export_part(p["id"]) for p in (block, plate)]
    payload = {
        "schema_version": root_export["schema_version"],
        "document": {"id": "tol-doc", "root_part_id": root["id"], "parts": [root_dict, *[e["document"]["parts"][0] for e in exports]]},
        "sketches": [*root_export["sketches"], *[s for e in exports for s in e["sketches"]]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    for oid in ("a1", "a2"):
        assert client.patch(f"/document/parts/{root['id']}/occurrences/{oid}", json={"fixed": True}).status_code == 200
    return root, block, plate


def _gap(root, block, plate, block_occurrence, value):
    return {
        "type": "distance",
        "value": value,
        "references": [
            {"occurrence_id": "plate", **_face(plate, (0, 0, -1))},
            {"occurrence_id": block_occurrence, **_face(block, (0, 0, 1))},
        ],
    }


def _create(root, payload):
    return client.post(f"/document/parts/{root['id']}/mates", params={"solve": "auto", "occurrence_id": "plate"}, json=payload)


def _statuses(root):
    return {m["id"]: m for m in client.get(f"/document/parts/{root['id']}/mates").json()}


def test_an_exact_model_stays_ok_everywhere_and_says_nothing_about_tolerance():
    root, block, plate = _scene(0.0)
    first = _create(root, _gap(root, block, plate, "a1", 5.0))
    second = _create(root, _gap(root, block, plate, "a2", 5.0))
    assert first.status_code == second.status_code == 201, second.text
    assert "x-mate-tolerance" not in {k.lower() for k in second.headers}
    listing = _statuses(root)
    assert {m["status"] for m in listing.values()} == {"ok"}
    assert all(m["status_residual_mm"] is None and m["status_residual_deg"] is None for m in listing.values())


def test_a_tiny_disagreement_between_two_mates_is_accepted_and_both_are_flagged_near():
    # 3.5e-6 rad between the two tops, a 2 m plate: each mate sits about 1.75e-6 x 1414 mm = 0.0025 mm from exact
    root, block, plate = _scene(3.5e-6)
    first = _create(root, _gap(root, block, plate, "a1", 5.0))
    assert first.status_code == 201, first.text
    second = _create(root, _gap(root, block, plate, "a2", 5.0))
    assert second.status_code == 201, second.text
    assert second.headers["X-Mate-Tolerance"] == "near"
    assert 0 < float(second.headers["X-Mate-Residual-Mm"]) <= FAR_END_LIMIT_MM
    listing = _statuses(root)
    assert {m["status"] for m in listing.values()} == {"near"}
    for m in listing.values():
        assert 0 < m["status_residual_mm"] <= FAR_END_LIMIT_MM
        assert 0 < m["status_residual_deg"] < math.degrees(ANGULAR_LIMIT_RAD)
    # nothing stored was changed: the values are the ones typed
    assert [m["value"] for m in listing.values()] == [5.0, 5.0]


def test_the_same_disagreement_on_a_6_m_part_is_over_the_far_end_limit_and_is_refused():
    # 1e-4 rad is the angular cap, but across a 6 m plate it would move the far end by about 0.4 mm: refused, nothing stored
    root, block, plate = _scene(1e-4, plate_size=6000.0)
    assert _create(root, _gap(root, block, plate, "a1", 5.0)).status_code == 201
    refused = _create(root, _gap(root, block, plate, "a2", 5.0))
    assert refused.status_code == 422, refused.text
    assert refused.json()["detail"]["type"] in ("mate_solve_did_not_converge", "mate_conflict")
    assert len(_statuses(root)) == 1


def test_a_wrong_dimension_still_fails_one_millimetre_is_not_tolerance():
    root, block, plate = _scene(0.0)
    assert _create(root, _gap(root, block, plate, "a1", 190.0)).status_code == 201
    refused = _create(root, _gap(root, block, plate, "a2", 191.0))
    assert refused.status_code == 422, refused.text
    assert len(_statuses(root)) == 1


def test_a_stored_pose_that_drifted_is_near_then_broken_by_how_far():
    """`status` is computed from the stored poses, never stored: nudge the plate and the same mate reads near, then broken."""
    root, block, plate = _scene(0.0)
    created = _create(root, _gap(root, block, plate, "a1", 5.0))
    assert created.status_code == 201
    mate_id = created.json()["id"]
    pose = client.get(f"/document/parts/{root['id']}/occurrences").json()
    plate_pose = next(o for o in pose if o["id"] == "plate")["transform"]

    def nudge(dz):
        t = list(plate_pose["translation"])
        t[2] += dz
        body = {"transform": {**plate_pose, "translation": t}}
        assert client.patch(f"/document/parts/{root['id']}/occurrences/plate", json=body).status_code == 200
        return _statuses(root)[mate_id]

    assert nudge(0.0)["status"] == "ok"
    near = nudge(0.005)
    assert near["status"] == "near" and near["status_residual_mm"] == pytest.approx(0.005, abs=1e-4)
    assert nudge(0.5)["status"] == "broken"
