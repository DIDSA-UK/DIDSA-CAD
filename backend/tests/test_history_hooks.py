"""OCCT history hooks (docs/reference-identity-design.md, "OCCT history"): every operation that modifies an existing Body in place reports what became of each
vertex / edge / face, so a reference can be carried through it. These tests replay small Parts with recording on and check the mapping GEOMETRICALLY (where the
sub-shape of the input ended up), plus the safety rule that a step with no history of its own says "unknown", never "consumed". Needs a real pythonocc-core
environment."""

import math

import pytest

from app.document.models import SubShapeRef, SubShapeType
from app.document.reference_history import HistoryTrace, ReferenceHistory, compute_history_trace
from app.document.reference_signature import measurer_for
from app.document.router import get_part_or_404
from tests.test_feature_delete_face import _create_delete_face, _face_ref, _make_chamfered_box
from tests.test_reference_identity import _box, _json, _polygon_extrude, client

KINDS = ("vertex", "edge", "face")


def _trace(part_id: str) -> HistoryTrace:
    return compute_history_trace(get_part_or_404(part_id), frozenset())


def _step(trace: HistoryTrace, feature_id: str, body_id: str | None = None):
    return next(s for s in trace.steps if s.feature_id == feature_id and (body_id is None or s.body_id == body_id))


def _where(shape, kind: str, index: int):
    return measurer_for(shape, kind).signature(index)


def _count(shape, kind: str) -> int:
    return measurer_for(shape, kind).count


def _assert_every_sub_shape_is_carried_to_its_transformed_twin(trace, step, transform, kinds=KINDS):
    """For every vertex / edge / face of the step's input: exactly one survivor, at transform(old position)."""
    assert step.covered
    for kind in kinds:
        for i in range(_count(step.before, kind)):
            old = _where(step.before, kind, i)
            survivors = trace.forward(step, i, kind)
            assert len(survivors) == 1, (kind, i, survivors)
            new = _where(step.after, kind, survivors[0])
            expected = transform(old.position)
            assert new.position == pytest.approx(expected, abs=1e-6), (kind, i)


# --- in-place transforms ---------------------------------------------------------------------------------------------


def test_move_body_carries_every_sub_shape_to_where_the_body_went():
    part_id, _, extrude, _ = _box()
    feature = _json(client.post(f"/document/parts/{part_id}/move-body-features", json={"body_id": extrude["id"], "delta": [5.0, -2.0, 3.0]}))
    trace = _trace(part_id)
    _assert_every_sub_shape_is_carried_to_its_transformed_twin(trace, _step(trace, feature["id"]), lambda p: (p[0] + 5.0, p[1] - 2.0, p[2] + 3.0))


def test_scale_body_carries_every_sub_shape_to_its_scaled_twin():
    part_id, _, extrude, _ = _box()
    feature = _json(client.post(f"/document/parts/{part_id}/scale-body-features", json={"body_id": extrude["id"], "factor": 2.0}))
    trace = _trace(part_id)
    # scaled about the bounding-box centre (5, 5, 5)
    _assert_every_sub_shape_is_carried_to_its_transformed_twin(trace, _step(trace, feature["id"]), lambda p: tuple(5.0 + 2.0 * (c - 5.0) for c in p))


# --- Shell ---------------------------------------------------------------------------------------------------------------


def test_shell_keeps_every_original_face_and_turns_the_opened_one_into_the_rim():
    part_id, _, extrude, _ = _box()
    from app.document.extrude import compute_part_bodies

    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    top = next(i for i in range(_count(body, "face")) if _where(body, "face", i).direction[2] > 0.99)
    feature = _json(
        client.post(
            f"/document/parts/{part_id}/shell-features",
            json={"body_id": extrude["id"], "faces_to_remove": [{"body_id": extrude["id"], "shape_type": "face", "index": top}], "thickness": 1.0},
        )
    )
    trace = _trace(part_id)
    step = _step(trace, feature["id"])
    assert step.covered
    for i in range(_count(step.before, "face")):
        old = _where(step.before, "face", i)
        survivors = trace.forward(step, i, "face")
        if i == top:
            # the opened face is not gone: OCCT reports it Modified into the rim (the ring that now closes the wall's top), in the same plane
            assert len(survivors) == 1
            rim = _where(step.after, "face", survivors[0])
            assert rim.surface_kind == "plane" and rim.position[2] == pytest.approx(old.position[2], abs=1e-6) and rim.area < old.area
            continue
        assert len(survivors) == 1
        new = _where(step.after, "face", survivors[0])
        # the SAME geometric face (a Shell grows the Body outward, so the original faces become the cavity walls and their outward normal flips): it is carried
        # to itself, not to the new offset face that sits a thickness away
        assert abs(sum(a * b for a, b in zip(new.direction, old.direction))) == pytest.approx(1.0, abs=1e-6) and new.surface_kind == old.surface_kind
        assert new.position == pytest.approx(old.position, abs=1e-6)


# --- Boolean ---------------------------------------------------------------------------------------------------------------


def _add_box(part_id: str, x0: float, size: float = 10.0) -> str:
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    points = [
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}))
        for x, y in [(x0, 0), (x0 + size, 0), (x0 + size, size), (x0, size)]
    ]
    for a, b in zip(points, points[1:] + points[:1]):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": size, "target_body_ids": []},
        )
    )
    return extrude["id"]


def test_a_boolean_subtract_keeps_an_untouched_face_and_modifies_a_cut_one():
    part_id, _, target_extrude, _ = _box()
    target = target_extrude["id"]
    tool = _add_box(part_id, x0=6.0)  # overlaps x in [6, 10]
    feature = _json(
        client.post(
            f"/document/parts/{part_id}/boolean-features",
            json={"operation": "subtract", "target_body_ids": [target], "tool_body_ids": [tool]},
        )
    )
    trace = _trace(part_id)
    step = _step(trace, feature["id"], target)
    assert step.covered
    far_wall_survivors = 0
    for i in range(_count(step.before, "face")):
        old = _where(step.before, "face", i)
        survivors = trace.forward(step, i, "face")
        if old.direction[0] < -0.99:  # the x = 0 wall is nowhere near the tool
            assert len(survivors) == 1 and _where(step.after, "face", survivors[0]).position == pytest.approx(old.position, abs=1e-6)
            far_wall_survivors += 1
        if old.direction[2] > 0.99:  # the top face is cut by the tool: still reported, as the (smaller) top face
            assert len(survivors) == 1
            new = _where(step.after, "face", survivors[0])
            assert new.direction == pytest.approx(old.direction, abs=1e-6) and new.area < old.area
    assert far_wall_survivors == 1


# --- Delete Face -----------------------------------------------------------------------------------------------------------


def test_delete_face_consumes_the_removed_face_and_keeps_the_rest():
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    body_id = _make_chamfered_box(part_id)
    response = _create_delete_face(part_id, _face_ref(body_id, 2))
    assert response.status_code == 201
    feature = response.json()
    trace = _trace(part_id)
    step = _step(trace, feature["id"])
    assert step.covered
    assert trace.forward(step, 2, "face") == ()  # the chamfer face the user deleted
    for i in range(_count(step.before, "face")):
        if i == 2:
            continue
        old = _where(step.before, "face", i)
        survivors = trace.forward(step, i, "face")
        assert len(survivors) == 1, i
        assert _where(step.after, "face", survivors[0]).direction == pytest.approx(old.direction, abs=1e-6) or old.surface_kind != "plane"


# --- the safety rule -----------------------------------------------------------------------------------------------------


def test_a_step_with_no_history_of_its_own_cannot_say_consumed():
    """Simulate an operation nobody hooked: strip the authoritative operation off a step. The step must then answer "unavailable" for a sub-shape it cannot place,
    never "consumed by <feature>" (which would flag, and fail closed on, a reference that merely passed through an unhooked Feature)."""
    from app.document.reference_history import HistoryOp, StepRecord

    part_id, _, extrude, _ = _box()
    feature = _json(client.post(f"/document/parts/{part_id}/move-body-features", json={"body_id": extrude["id"], "delta": [5.0, 0.0, 0.0]}))
    trace = _trace(part_id)
    step = _step(trace, feature["id"])
    assert step.covered
    # an unhooked version of the same step: no operations, so nothing can be carried across it (and nothing sits "at the same place")
    unhooked = StepRecord(step.feature_id, step.body_id, step.before, step.after, ())
    assert not unhooked.covered
    index = 0
    kind = "face"
    trace2 = HistoryTrace([s if s is not step else unhooked for s in trace.steps], trace.bodies, trace.inputs)
    origin = trace2.lineage_for(extrude["id"], index, kind)
    assert origin is not None
    outcome = trace2.forward_from_origin(origin, final_body_id=extrude["id"])
    assert outcome.kind in ("unavailable", "found") and outcome.kind != "consumed"


def test_unify_silence_is_not_evidence_of_consumption():
    """Every step runs the unify pass, which only merges faces: a step whose ONLY recorded operation is unify is uncovered."""
    from app.document.reference_history import HistoryOp, StepRecord

    only_unify = StepRecord("f", "b", None, None, (HistoryOp(object(), authoritative=False),))  # type: ignore[arg-type]
    assert not only_unify.covered
    assert StepRecord("f", "b", None, None, (HistoryOp(object(), authoritative=True),)).covered


# --- Move Face ---------------------------------------------------------------------------------------------------------------


def _faces_with_normal(shape, x=None, y=None, z=None):
    out = []
    for i in range(_count(shape, "face")):
        d = _where(shape, "face", i).direction
        if all(v is None or abs(d[k] - v) < 1e-6 for k, v in enumerate((x, y, z))):
            out.append(i)
    return out


@pytest.mark.parametrize("mode", [{"offset_distance": 3.0}, {"delta": [3.0, 0.0, 0.0]}])
def test_move_face_carries_the_moved_face_and_its_neighbours_through(mode):
    part_id, _, extrude, _ = _box()
    from app.document.extrude import compute_part_bodies

    body = compute_part_bodies(get_part_or_404(part_id))[extrude["id"]]
    east = _faces_with_normal(body, x=1.0)[0]  # the x = 10 wall
    west = _faces_with_normal(body, x=-1.0)[0]
    top = _faces_with_normal(body, z=1.0)[0]
    response = client.post(
        f"/document/parts/{part_id}/move-face-features",
        json={"face_refs": [{"body_id": extrude["id"], "shape_type": "face", "index": east}], **mode},
    )
    assert response.status_code == 201, response.text[:300]
    trace = _trace(part_id)
    step = _step(trace, response.json()["id"])
    assert not step.covered  # recorded non-authoritatively: it can place faces, but never claims a sub-shape it cannot place was consumed
    moved = trace.forward(step, east, "face")
    assert len(moved) == 1
    assert _where(step.after, "face", moved[0]).position[0] == pytest.approx(13.0, abs=1e-6)  # the east wall is now at x = 13
    for index, normal_axis in ((west, 0), (top, 2)):
        survivors = trace.forward(step, index, "face")
        if "offset_distance" in mode and not survivors:
            continue  # BRepOffset_MakeOffset does not report the neighbours it re-cuts: "unknown" to history, the signature search takes over
        assert len(survivors) == 1, (index, survivors)
        old, new = _where(step.before, "face", index), _where(step.after, "face", survivors[0])
        assert new.direction == pytest.approx(old.direction, abs=1e-6)
        assert new.position[normal_axis] == pytest.approx(old.position[normal_axis], abs=1e-6)


# --- Split -----------------------------------------------------------------------------------------------------------------


def test_split_carries_a_face_that_straddles_the_tool_into_both_pieces():
    part_id, _, extrude, _ = _polygon_extrude([(-5, -5), (5, -5), (5, 5), (-5, 5)])
    response = client.post(f"/document/parts/{part_id}/split-features", json={"target_body_id": extrude["id"], "tool": {"plane_ref": {"fixed_plane": "XZ"}}})
    assert response.status_code == 201, response.text[:300]
    trace = _trace(part_id)
    steps = [s for s in trace.steps if s.feature_id == response.json()["id"]]
    assert len(steps) == 2 and all(s.covered for s in steps)
    before = steps[0].before
    east = next(i for i in range(_count(before, "face")) if _where(before, "face", i).direction[0] > 0.99)  # the x = 5 wall spans y in [-5, 5]
    halves = []
    for step in steps:
        survivors = trace.forward(step, east, "face")
        assert len(survivors) == 1
        halves.append(_where(step.after, "face", survivors[0]).position[1])
    assert sorted(halves) == pytest.approx([-2.5, 2.5], abs=1e-6)  # one half in each piece
    # a vertex on the cut plane's far side survives only in its own piece
    far = next(i for i in range(_count(before, "vertex")) if _where(before, "vertex", i).position[1] > 4.9)
    placed = [trace.forward(step, far, "vertex") for step in steps]
    assert sorted(len(p) for p in placed) == [0, 1]


# --- Bezier conversion ----------------------------------------------------------------------------------------------------


def test_the_reshape_adapter_reports_a_replaced_sub_shape_and_is_silent_about_an_untouched_one():
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCC.Core.ShapeBuild import ShapeBuild_ReShape
    from OCC.Core.TopAbs import TopAbs_FACE
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape

    from app.document.reference_history import HistoryOp, ReShapeHistory

    first, second = BRepPrimAPI_MakeBox(1, 1, 1).Shape(), BRepPrimAPI_MakeBox(2, 2, 2).Shape()
    faces_a, faces_b = TopTools_IndexedMapOfShape(), TopTools_IndexedMapOfShape()
    topexp.MapShapes(first, TopAbs_FACE, faces_a)
    topexp.MapShapes(second, TopAbs_FACE, faces_b)
    context = ShapeBuild_ReShape()
    context.Replace(faces_a.FindKey(1), faces_b.FindKey(1))
    op = HistoryOp(ReShapeHistory(context))
    assert [s.IsSame(faces_b.FindKey(1)) for s in op.successors(faces_a.FindKey(1))] == [True]
    assert op.successors(faces_a.FindKey(2)) == []


# --- end to end: a reference's lineage reaches back THROUGH the hooked operation ---------------------------------------------


def _vertical_edge(part_id: str, body_id: str, x: float, y: float) -> int:
    from tests.test_subshape_history import _edge_at

    return _edge_at(part_id, body_id, x, y)


def test_an_edge_reference_made_after_a_move_body_traces_back_through_the_move_to_the_extrude():
    part_id, _, extrude, _ = _box()
    _json(client.post(f"/document/parts/{part_id}/move-body-features", json={"body_id": extrude["id"], "delta": [5.0, 0.0, 0.0]}))
    from tests.test_reference_identity import _fillet

    fillet = _fillet(part_id, extrude["id"], _vertical_edge(part_id, extrude["id"], 15.0, 10.0), radius=1.0)
    ref = get_part_or_404(part_id).get_feature(fillet["id"]).edge_refs[0]
    # without the Move Body hook the walk stopped at the move step (its sub-shapes were new TShapes at a new place); with it, it reaches the extrude
    assert ref.lineage is not None and ref.lineage.feature_id == extrude["id"] and ref.lineage.signature.position[0] == pytest.approx(10.0)


def test_an_edge_reference_made_after_a_scale_body_traces_back_through_the_scale_to_the_extrude():
    part_id, _, extrude, _ = _box()
    _json(client.post(f"/document/parts/{part_id}/scale-body-features", json={"body_id": extrude["id"], "factor": 2.0}))
    from tests.test_reference_identity import _fillet

    fillet = _fillet(part_id, extrude["id"], _vertical_edge(part_id, extrude["id"], 15.0, 15.0), radius=1.0)
    ref = get_part_or_404(part_id).get_feature(fillet["id"]).edge_refs[0]
    assert ref.lineage is not None and ref.lineage.feature_id == extrude["id"]


def test_a_reference_downstream_of_a_move_body_follows_an_upstream_edit_of_the_extrude():
    part_id, base, extrude, base_points = _box()
    _json(client.post(f"/document/parts/{part_id}/move-body-features", json={"body_id": extrude["id"], "delta": [5.0, 0.0, 0.0]}))
    from tests.test_reference_identity import _feature, _fillet

    fillet = _fillet(part_id, extrude["id"], _vertical_edge(part_id, extrude["id"], 15.0, 10.0), radius=1.0)
    # the base sketch's far edge moves: the box is wider, the vertical edge is now at x = 5 + 14
    for pid, (x, y) in [(base_points[1], (14.0, 0.0)), (base_points[2], (14.0, 10.0))]:
        _json(client.patch(f"/sketch/sketches/{base['sketch_id']}/points/{pid}", json={"x": x, "y": y}))
    feature = _feature(part_id, fillet["id"])
    assert not feature["has_lost_reference"], feature
    ref = get_part_or_404(part_id).get_feature(fillet["id"]).edge_refs[0]
    from app.document.subshape_identity import bodies_before_feature

    sig = _where(bodies_before_feature(get_part_or_404(part_id), fillet["id"])[ref.body_id], "edge", ref.index)
    assert (round(sig.position[0], 6), round(sig.position[1], 6)) == (19.0, 10.0)
