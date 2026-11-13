"""M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`, "A better first guess"): the type suggested by the picks
(`app.document.mate_suggest`, `type: "auto"` on `preview-mate-solve`), the peg-in-hole action, `pick_points` on the wire, and the
legacy answers that must not change."""

import json

import numpy as np
import pytest

from app.document import mate_suggest
from app.document.mate_suggest import CIRCLE, FLAT, OTHER, ROUND, suggest_type
from tests import mate_first_guess_scenes as guess
from tests.m4_legacy_cases import GOLDEN, answer, cases
from tests.motion_scaling_scenes import box_part, cylinder_part, face, hole
from tests.test_assembly_solver import client


def _preview(root: str, driven: str, body: dict, movement: str = "auto"):
    return client.post(f"/document/parts/{root}/occurrences/{driven}/preview-mate-solve", params={"movement": movement}, json=body)


# ---- the rule, every row of the plan's table ---------------------------------------------------


@pytest.mark.parametrize(
    "first, second, peg_faces, expected",
    [
        (ROUND, ROUND, False, "concentric"),  # two round faces
        (CIRCLE, ROUND, False, "concentric"),  # a circular edge and a round face
        (ROUND, CIRCLE, False, "concentric"),
        (CIRCLE, CIRCLE, False, "concentric"),  # two circular edges that do not each lie on a flat face
        (CIRCLE, CIRCLE, True, "peg_in_hole"),  # a circular edge on each side, each on a flat face: Concentric + Coincident as one action
        (FLAT, FLAT, False, "coincident"),  # two flat faces
        (FLAT, ROUND, False, None),  # flat face and round face: no suggestion (Tangent is not a mate type)
        (ROUND, FLAT, False, None),
        (FLAT, CIRCLE, False, None),  # a circular edge is round: the same
        (CIRCLE, FLAT, False, None),
        (OTHER, FLAT, False, None),  # a corner, a straight edge, a mid-plane: nothing
        (ROUND, OTHER, False, None),
        (OTHER, OTHER, False, None),
    ],
)
def test_the_type_rule_table(first, second, peg_faces, expected):
    assert suggest_type(first, second, peg_faces) == expected


def test_pick_kinds_from_real_geometry():
    from app.document.models import MateEntityRef, SubShapeRef, SubShapeType
    from app.document.store import get_document

    plate = box_part("KindsPlate", 30.0, 20.0, 5.0, holes=((15.0, 10.0, 3.0),))
    document = get_document()
    part = document.parts[plate["id"]]

    def kind(shape_type: SubShapeType, index: int) -> str:
        return mate_suggest.pick_kind(document, part, MateEntityRef(occurrence_id="", subshape_ref=SubShapeRef(plate["body_id"], shape_type, index)))

    flat = face(plate, (0, 0, 1))["subshape_ref"]["index"]
    bore = hole(plate)["subshape_ref"]["index"]
    rim = guess.circle_edge(plate, 3.0, (15.0, 10.0, 5.0))["subshape_ref"]["index"]
    assert kind(SubShapeType.FACE, flat) == FLAT
    assert kind(SubShapeType.FACE, bore) == ROUND
    assert kind(SubShapeType.EDGE, rim) == CIRCLE
    straight = next(i for i in range(32) if client.post(f"/document/parts/{plate['id']}/measure", json={"refs": [{"body_id": plate["body_id"], "shape_type": "edge", "index": i}]}).json().get("radius") is None)
    assert kind(SubShapeType.EDGE, straight) == OTHER
    assert kind(SubShapeType.VERTEX, 0) == OTHER
    # the rim lies on the plate's top: that is the flat face a peg in a hole seats on
    found = mate_suggest._flat_face_of_circle(document, part, MateEntityRef(occurrence_id="", subshape_ref=SubShapeRef(plate["body_id"], SubShapeType.EDGE, rim)))
    assert found is not None and found.subshape_ref.index == flat


# ---- suggested_type on the wire ----------------------------------------------------------------


@pytest.mark.parametrize("name, expected", [("stack", "coincident"), ("pin-in-post", "concentric"), ("peg-in-hole", "peg_in_hole")])
def test_auto_answers_the_suggestion_and_its_solve(name, expected):
    scene = guess.SCENES[name]()
    guess.set_pose(scene, guess.start_pose(scene, "near", np.random.default_rng(3)))
    auto = guess.preview(scene, type="auto")
    assert auto["suggested_type"] == expected and auto["converged"]
    assert scene.correct(guess.shown_transform(auto))
    # the solve is exactly the suggested type's own preview (the answer a client gets once it has switched to the suggestion)
    explicit = guess.preview(scene, type=expected)
    assert "suggested_type" not in explicit
    assert {k: v for k, v in auto.items() if k != "suggested_type"} == explicit


def test_auto_with_no_suggestion_says_so_and_solves_nothing():
    plate, pin = box_part("NoSuggestPlate", 40.0, 30.0, 8.0), cylinder_part("NoSuggestPin", 4.0, 20.0)
    root, _fixed, _true = guess._assemble("no-suggestion", plate, pin, (10.0, 10.0, 8.0))
    body = {"type": "auto", "references": guess._refs(hole(pin), face(plate, (0, 0, 1)))}  # a round face and a flat face
    response = _preview(root, guess.DRIVEN, body)
    assert response.status_code == 200
    data = response.json()
    assert "suggested_type" in data and data["suggested_type"] is None  # present (it was asked for), and null = no suggestion
    assert data["converged"] is False and data["transform"] is None


def test_a_legacy_request_has_no_suggested_type_key():
    scene = guess.SCENES["stack"]()
    assert "suggested_type" not in guess.preview(scene)


def _same_answer(got, want, path="") -> str | None:
    """None when `got` is the answer `want` an older client got: the same keys in the same order, the same strings, booleans, nulls and
    list lengths, and numbers equal to 1e-9 (relative above 1). The recording is floating-point output of one machine (x86-64); another
    CPU (CI's arm64 runner) differs in the last digits of the same solve, so the bytes cannot be compared across machines."""
    if isinstance(want, dict):
        if not isinstance(got, dict) or list(got) != list(want):
            return f"{path}: keys {list(got) if isinstance(got, dict) else type(got).__name__} != {list(want)}"
        return next((d for k in want if (d := _same_answer(got[k], want[k], f"{path}.{k}")) is not None), None)
    if isinstance(want, list):
        if not isinstance(got, list) or len(got) != len(want):
            return f"{path}: list of {len(got) if isinstance(got, list) else type(got).__name__} != {len(want)}"
        return next((d for i, (g, w) in enumerate(zip(got, want)) if (d := _same_answer(g, w, f"{path}[{i}]")) is not None), None)
    if isinstance(want, float) and not isinstance(want, bool) and isinstance(got, (int, float)) and not isinstance(got, bool):
        return None if abs(got - want) <= 1e-9 * max(1.0, abs(want)) else f"{path}: {got!r} != {want!r}"
    return None if got == want and type(got) is type(want) else f"{path}: {got!r} != {want!r}"


def test_legacy_previews_are_unchanged():
    """Every request an older client sends (no `type: "auto"`, `peg_in_hole` or `measure_value`) gets the answer recorded before M4: the same
    keys, in the same order, the same values (numbers to 1e-9: see `_same_answer`). On the recording machine the bytes are identical too."""
    golden = json.loads(GOLDEN.read_text())
    seen = []
    for key, scene, start, body, movement in cases():
        seen.append(key)
        got = answer(scene, start, body, movement)
        problem = _same_answer(json.loads(got), json.loads(golden[key]))
        assert problem is None, f"{key}{problem}"
    assert sorted(seen) == sorted(golden)


def test_the_comparison_catches_what_an_older_client_would_see():
    want = {"converged": True, "transform": {"translation": [1.0, 2.0]}, "resolved": {"alignment": "aligned"}}
    assert _same_answer({"converged": True, "transform": {"translation": [1.0 + 1e-12, 2.0]}, "resolved": {"alignment": "aligned"}}, want) is None
    assert _same_answer({"converged": True, "transform": {"translation": [1.001, 2.0]}, "resolved": {"alignment": "aligned"}}, want) is not None
    assert _same_answer({"converged": True, "transform": {"translation": [1.0, 2.0]}, "resolved": {"alignment": "anti_aligned"}}, want) is not None
    assert _same_answer({"converged": True, "transform": {"translation": [1.0, 2.0]}, "resolved": {"alignment": "aligned"}, "suggested_type": None}, want) is not None
    assert _same_answer({"transform": {"translation": [1.0, 2.0]}, "converged": True, "resolved": {"alignment": "aligned"}}, want) is not None  # key order


# ---- pick points ----------------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["inset-10", "overhang-3", "gap-6-above", "parallel", "pin-in-post"])
@pytest.mark.parametrize("start", ["medium", "upside_down"])
def test_pick_points_break_no_tie_yet(name, start):
    """No pick-point tie-break met the M4 bench standard (zero harmed rows), so none shipped: pick points are accepted and the
    answer, alternatives included, is exactly the one without them."""
    scene = guess.SCENES[name]()
    rng = np.random.default_rng(11)
    guess.set_pose(scene, guess.start_pose(scene, start, rng))
    picks = guess.trial_picks(scene, rng)
    plain = guess.preview(scene)
    with_picks = guess.preview(scene, pick_points=[picks[guess.DRIVEN], picks[guess.FIXED]], view_direction=[0.0, -1.0, -0.5])
    assert with_picks == plain


@pytest.mark.parametrize(
    "extra",
    [
        {"pick_points": [[1.0, 2.0, 3.0]]},  # one entry per reference
        {"pick_points": [[1.0, 2.0], None]},  # three numbers each
        {"pick_points": [[1.0, 2.0, 3.0, 4.0], [0.0, 0.0, 0.0]]},
        {"view_direction": [0.0, 0.0, 0.0]},
        {"view_direction": [1.0, 0.0]},
    ],
)
def test_bad_pick_points_are_refused(extra):
    scene = guess.SCENES["stack"]()
    response = _preview(scene.root, guess.DRIVEN, {**scene.payload, **extra})
    assert response.status_code == 422


def test_a_null_pick_point_side_is_allowed():
    scene = guess.SCENES["stack"]()
    assert guess.preview(scene, pick_points=[None, [1.0, 2.0, 3.0]]) == guess.preview(scene)


# ---- peg in a hole -----------------------------------------------------------------------------------


@pytest.mark.parametrize("start", ["near", "far", "upside_down"])
def test_peg_in_hole_preview_seats_the_pin_from_any_start(start):
    scene = guess.SCENES["peg-in-hole"]()
    guess.set_pose(scene, guess.start_pose(scene, start, np.random.default_rng(5)))
    ghost = guess.preview(scene)
    assert ghost["converged"] and scene.correct(guess.shown_transform(ghost))
    # before M4 a client sent Coincident on the two edges (a plain Concentric): the pin is on the axis but not seated
    old = guess.preview(scene, **scene.notes["old_default"])
    assert old["converged"] and not scene.correct(guess.shown_transform(old))


def test_peg_in_hole_create_stores_both_mates_atomically():
    scene = guess.SCENES["peg-in-hole"]()
    guess.set_pose(scene, guess.start_pose(scene, "far", np.random.default_rng(8)))
    before = len(client.get(f"/document/parts/{scene.root}/mates").json())
    created = client.post(f"/document/parts/{scene.root}/mates", params={"solve": "auto", "occurrence_id": guess.DRIVEN}, json=scene.payload)
    assert created.status_code == 201, created.text
    assert created.json()["type"] == "concentric"
    assert created.json()["branch_source"] == "auto"  # the alignment that agrees with the touching faces was the program's choice
    mates = client.get(f"/document/parts/{scene.root}/mates").json()
    assert len(mates) == before + 2
    assert sorted(m["type"] for m in mates[-2:]) == ["coincident", "concentric"]
    coincident = next(m for m in mates[-2:] if m["type"] == "coincident")
    assert all(r["subshape_ref"]["shape_type"] == "face" for r in coincident["references"])
    from app.document.store import get_document

    stored = next(o for o in get_document().parts[scene.root].occurrences if o.id == guess.DRIVEN).transform
    assert scene.correct(guess._dict(stored))


def test_peg_in_hole_create_refused_leaves_nothing_behind():
    scene = guess.SCENES["peg-in-hole"]()
    before = client.get(f"/document/parts/{scene.root}/mates").json()
    # the pin fixed and the plate is fixed: nothing can move, so the solve target is refused and nothing is stored
    assert client.patch(f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}", json={"fixed": True}).status_code == 200
    refused = client.post(f"/document/parts/{scene.root}/mates", params={"solve": "auto", "occurrence_id": guess.DRIVEN}, json=scene.payload)
    assert refused.status_code == 422
    assert client.get(f"/document/parts/{scene.root}/mates").json() == before


def test_peg_in_hole_needs_two_circular_edges():
    scene = guess.SCENES["stack"]()  # two flat faces
    refused = client.post(f"/document/parts/{scene.root}/mates", json={**scene.payload, "type": "peg_in_hole"})
    assert refused.status_code == 422 and refused.json()["detail"]["type"] == "not_a_peg_in_hole"
    preview = guess.preview(scene, type="peg_in_hole")
    assert preview["converged"] is False and "suggested_type" not in preview


def test_auto_cannot_be_created():
    scene = guess.SCENES["stack"]()
    refused = client.post(f"/document/parts/{scene.root}/mates", json={**scene.payload, "type": "auto"})
    assert refused.status_code == 422 and refused.json()["detail"]["type"] == "auto_type_not_creatable"
