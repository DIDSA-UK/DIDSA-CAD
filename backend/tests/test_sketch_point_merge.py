"""Point Merge (docs/point-merge-and-vr-sketcher-plan.md, M1): `app.sketch.point_merge`, `POST /sketch/sketches/{id}/points/merge` and
`PUT /sketch/sketches/{id}/state`.

The logic is tested on `Sketch` objects directly (fast, no HTTP); the routes get their own tests at the end. `_collapse` has one test per row of the plan's
collapse table, built from hand-made constraint objects so rows the API cannot reach in v1 (a PointOnEllipse over an ellipse tip is a refused quadrant
merge) are still covered."""

import json
import uuid

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import sketch_to_dict
from app.main import app
from app.sketch.constraints import (
    AtMidpointConstraint,
    CoincidentConstraint,
    ConcentricConstraint,
    CurveTangentConstraint,
    DistanceConstraint,
    EqualRadiusConstraint,
    FixedConstraint,
    ParallelConstraint,
    PointLineDistanceConstraint,
    PointOnCircleConstraint,
    PointOnEllipseConstraint,
    PointOnLineConstraint,
    SplineTangentConstraint,
    TangentConstraint,
)
from app.sketch.models import Plane, Sketch
from app.sketch.text_fonts import DEFAULT_FONT
from app.sketch.point_merge import MergeRefused, _collapse, merge_keep_order, merge_points
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _new_id() -> str:
    return str(uuid.uuid4())


def _sketch() -> Sketch:
    sketch = Sketch(id=_new_id(), plane=Plane.XY)
    sketch.origin_point()  # creates the origin
    return sketch


def _p(sketch: Sketch, x: float, y: float) -> str:
    return sketch.add_point(x, y).id


def _refused(sketch: Sketch, ids: list[str], reason: str, **kwargs) -> MergeRefused:
    before = json.dumps(sketch_to_dict(sketch))
    with pytest.raises(MergeRefused) as raised:
        merge_points(sketch, ids, **kwargs)
    assert raised.value.reason == reason
    assert json.dumps(sketch_to_dict(sketch)) == before  # a refusal changes nothing
    return raised.value


# --- the basic merge -------------------------------------------------------------------------------------------------------------------------------------


def test_two_loose_line_ends_merge_and_the_lines_share_the_kept_point():
    sketch = _sketch()
    a, b, c, b2 = _p(sketch, 0, 0), _p(sketch, 10, 0), _p(sketch, 10, 10), _p(sketch, 10, 0)
    first = sketch.add_line(a, b)
    second = sketch.add_line(b2, c)
    result = merge_points(sketch, [b, b2])
    assert result.kept_id == b and result.absorbed_ids == [b2]
    assert b2 not in sketch.points
    assert first.end_point_id == b and second.start_point_id == b
    assert result.converged


def test_merging_the_gap_in_four_separate_lines_closes_the_profile():
    from app.sketch.profile import ProfileStatus, detect_profile

    sketch = _sketch()
    corners = [_p(sketch, 0, 0), _p(sketch, 10, 0), _p(sketch, 10, 10), _p(sketch, 0, 10)]
    extra = _p(sketch, 0, 10)  # the last line starts on a point stacked on the third line's end, with no constraint between them
    sketch.add_line(corners[0], corners[1])
    sketch.add_line(corners[1], corners[2])
    sketch.add_line(corners[2], corners[3])
    sketch.add_line(extra, corners[0])
    assert detect_profile(sketch).status == ProfileStatus.NO_LOOP
    merge_points(sketch, [corners[3], extra])
    assert detect_profile(sketch).status == ProfileStatus.CLOSED_LOOP


def test_three_points_in_one_call_make_one_corner():
    sketch = _sketch()
    ends = [_p(sketch, 5, 5) for _ in range(3)]
    far = [_p(sketch, 20, 5), _p(sketch, 5, 20), _p(sketch, -10, 5)]
    lines = [sketch.add_line(e, f) for e, f in zip(ends, far)]
    result = merge_points(sketch, ends)
    assert result.kept_id == ends[0] and set(result.absorbed_ids) == set(ends[1:])
    assert all(line.start_point_id == ends[0] for line in lines)
    assert not set(ends[1:]) & set(sketch.points)


# --- which point is kept ---------------------------------------------------------------------------------------------------------------------------------


def test_a_fixed_point_is_kept_even_when_listed_second():
    sketch = _sketch()
    loose, pinned = _p(sketch, 1, 1), _p(sketch, 1, 1)
    sketch.add_fixed_constraint(pinned)
    assert merge_keep_order(sketch, [loose, pinned], set())[0] == pinned
    assert merge_points(sketch, [loose, pinned]).kept_id == pinned


def test_an_external_reference_point_is_kept():
    from app.sketch.models import ExternalVertexReference

    sketch = _sketch()
    loose = _p(sketch, 3, 3)
    reference = sketch.add_external_vertex_reference(3, 3, ExternalVertexReference(body_id="b", vertex_index=1)).id
    assert merge_points(sketch, [loose, reference]).kept_id == reference


def test_a_point_a_feature_references_is_kept_via_anchored_ids():
    sketch = _sketch()
    loose, referenced = _p(sketch, 3, 3), _p(sketch, 3, 3)
    assert merge_points(sketch, [loose, referenced], anchored_ids={referenced}).kept_id == referenced


def test_two_anchored_points_are_refused():
    sketch = _sketch()
    a, b = _p(sketch, 1, 1), _p(sketch, 2, 2)
    sketch.add_fixed_constraint(a)
    sketch.add_fixed_constraint(b)
    error = _refused(sketch, [a, b], "two_anchored")
    assert set(error.ids) == {a, b}
    c = _p(sketch, 9, 9)
    _refused(sketch, [c, b], "two_anchored", anchored_ids={c})


def test_a_rectangle_corner_is_kept_over_a_loose_line_end_whatever_the_order():
    for rectangle_first in (True, False):
        sketch = _sketch()
        rectangle = sketch.add_rectangle([_p(sketch, 0, 0), _p(sketch, 10, 0), _p(sketch, 10, 5), _p(sketch, 0, 5)])
        corner = rectangle.corner_point_ids[1]
        loose = _p(sketch, 10, 0)
        sketch.add_line(loose, _p(sketch, 30, 30))
        ids = [corner, loose] if rectangle_first else [loose, corner]
        assert merge_points(sketch, ids).kept_id == corner


def test_a_provisional_dimension_and_a_coincident_between_the_pair_do_not_count():
    sketch = _sketch()
    a, b, other = _p(sketch, 0, 0), _p(sketch, 5, 0), _p(sketch, 0, 7)
    sketch.add_distance_constraint(a, other, 7.0, provisional=True)
    sketch.add_coincident_constraint(a, b)
    # b has one real constraint (a vertical dimension), a only the provisional one and the Coincident with b: b wins
    sketch.add_distance_constraint(b, _p(sketch, 5, 9), 9.0, "vertical")
    assert merge_keep_order(sketch, [a, b], set()) == [b, a]
    # Without b's real constraint it is a tie, and the first selected stays
    sketch2 = _sketch()
    c, d, e = _p(sketch2, 0, 0), _p(sketch2, 5, 0), _p(sketch2, 0, 7)
    sketch2.add_distance_constraint(c, e, 7.0, provisional=True)
    sketch2.add_coincident_constraint(c, d)
    assert merge_keep_order(sketch2, [d, c], set()) == [d, c]
    assert merge_keep_order(sketch2, [c, d], set()) == [c, d]


def test_a_tie_keeps_the_first_selected_point():
    sketch = _sketch()
    a, b = _p(sketch, 0, 0), _p(sketch, 0, 0)
    assert merge_points(sketch, [b, a]).kept_id == b


# --- refusals --------------------------------------------------------------------------------------------------------------------------------------------


def test_too_few_points():
    sketch = _sketch()
    a = _p(sketch, 1, 1)
    _refused(sketch, [a], "too_few")
    _refused(sketch, [a, a], "too_few")


def test_the_origin_is_refused():
    sketch = _sketch()
    a = _p(sketch, 0, 0)
    error = _refused(sketch, [sketch.origin_point_id, a], "origin")
    assert error.ids == [sketch.origin_point_id]


def test_two_points_of_one_entity_are_refused():
    sketch = _sketch()
    a, b = _p(sketch, 0, 0), _p(sketch, 5, 0)
    line = sketch.add_line(a, b)
    error = _refused(sketch, [a, b], "same_entity")
    assert line.id in error.ids
    rectangle = sketch.add_rectangle([_p(sketch, 20, 0), _p(sketch, 30, 0), _p(sketch, 30, 5), _p(sketch, 20, 5)])
    _refused(sketch, [rectangle.corner_point_ids[0], rectangle.corner_point_ids[2]], "same_entity")


def test_a_circle_quadrant_point_is_refused():
    sketch = _sketch()
    circle = sketch.add_circle(_p(sketch, 50, 50), radius=5.0, angle=0.0)
    loose = _p(sketch, 50, 55)
    error = _refused(sketch, [loose, circle.cardinal_point_ids[0]], "quadrant")
    assert error.ids == [circle.cardinal_point_ids[0]]


def test_an_ellipse_axis_tip_is_refused():
    sketch = _sketch()
    ellipse = sketch.add_ellipse(_p(sketch, 50, 50), major_radius=8.0, angle=0.0, minor_radius=4.0)
    _refused(sketch, [_p(sketch, 58, 50), ellipse.major_point_neg_id], "quadrant")


def test_a_dimension_between_the_points_is_refused_and_named():
    sketch = _sketch()
    a, b = _p(sketch, 0, 0), _p(sketch, 12, 0)
    dimension = sketch.add_distance_constraint(a, b, 12.0)
    error = _refused(sketch, [a, b], "dimension_between")
    assert error.ids == [dimension.id]
    assert "12" in error.message


def test_a_degenerate_constraint_is_refused():
    sketch = _sketch()
    line = sketch.add_line(_p(sketch, 0, 0), _p(sketch, 10, 0))
    middle = _p(sketch, 5, 0)
    midpoint = sketch.add_at_midpoint_constraint(middle, line.id)
    error = _refused(sketch, [middle, line.start_point_id], "degenerate_constraint")
    assert error.ids == [midpoint.id]


def test_two_lines_that_would_end_up_on_top_of_each_other_are_refused():
    sketch = _sketch()
    a, b, b2 = _p(sketch, 0, 0), _p(sketch, 10, 0), _p(sketch, 10, 0)
    first, second = sketch.add_line(a, b), sketch.add_line(a, b2)
    error = _refused(sketch, [b, b2], "stacked_entities")
    assert set(error.ids) == {first.id, second.id}


def test_a_stack_that_was_already_there_does_not_block_an_unrelated_merge():
    sketch = _sketch()
    a, b = _p(sketch, 0, 0), _p(sketch, 10, 0)
    sketch.add_line(a, b)
    sketch.add_line(b, a)
    x, y = _p(sketch, 50, 50), _p(sketch, 50, 50)
    sketch.add_line(x, _p(sketch, 60, 60))
    sketch.add_line(y, _p(sketch, 70, 70))
    assert merge_points(sketch, [x, y]).kept_id == x


def test_a_merge_that_contradicts_the_other_constraints_is_rolled_back():
    sketch = _sketch()
    a, c, x = _p(sketch, 0, 0), _p(sketch, 0, 5), _p(sketch, 10, 0)
    sketch.add_distance_constraint(a, x, 10.0)
    sketch.add_distance_constraint(c, x, 20.0)
    _refused(sketch, [a, c], "conflict")
    assert a in sketch.points and c in sketch.points


def test_a_sketch_that_did_not_converge_before_still_merges_and_says_so():
    sketch = _sketch()
    a, c, x = _p(sketch, 0, 0), _p(sketch, 0, 5), _p(sketch, 10, 0)
    sketch.add_distance_constraint(a, x, 10.0)
    sketch.add_distance_constraint(c, x, 20.0)
    sketch.add_distance_constraint(a, c, 5.0)  # already contradictory with the two above? a-x=10, c-x=20 needs a-c>=10
    result = merge_points(sketch, [_p(sketch, 90, 90), _p(sketch, 91, 91)])
    assert c in sketch.points and result.converged is False


# --- the collapse table: one test per row -----------------------------------------------------------------------------------------------------------------


def test_collapse_coincident_drops():
    assert _collapse(CoincidentConstraint(_new_id(), "k", "k")) == "drop"
    assert _collapse(CoincidentConstraint(_new_id(), "k", "j")) == "keep"


def test_collapse_concentric_drops():
    assert _collapse(ConcentricConstraint(_new_id(), "e1", "e2", "k", "k")) == "drop"


def test_collapse_point_on_line_drops():
    assert _collapse(PointOnLineConstraint(_new_id(), "k", "l", "k", "e")) == "drop"
    assert _collapse(PointOnLineConstraint(_new_id(), "k", "l", "s", "k")) == "drop"
    assert _collapse(PointOnLineConstraint(_new_id(), "k", "l", "s", "e")) == "keep"


def test_collapse_point_on_circle_drops_on_the_radius_point_and_refuses_on_the_centre():
    assert _collapse(PointOnCircleConstraint(_new_id(), "k", "c", "centre", "k")) == "drop"
    with pytest.raises(MergeRefused) as raised:
        _collapse(PointOnCircleConstraint(_new_id(), "k", "c", "k", "rim"))
    assert raised.value.reason == "degenerate_constraint"


def test_collapse_point_on_ellipse():
    assert _collapse(PointOnEllipseConstraint(_new_id(), "k", "e", "centre", "k", "minor")) == "drop"
    assert _collapse(PointOnEllipseConstraint(_new_id(), "k", "e", "centre", "major", "k")) == "drop"
    with pytest.raises(MergeRefused) as raised:
        _collapse(PointOnEllipseConstraint(_new_id(), "k", "e", "k", "major", "minor"))
    assert raised.value.reason == "degenerate_constraint"


def test_collapse_fixed_deduplicates():
    fixed = FixedConstraint(_new_id(), ["k", "x", "k"])
    assert _collapse(fixed) == "keep"
    assert fixed.fixed_point_ids == ["k", "x"]


@pytest.mark.parametrize("orientation", ["linear", "horizontal", "vertical"])
def test_collapse_distance_between_the_pair_is_refused(orientation):
    with pytest.raises(MergeRefused) as raised:
        _collapse(DistanceConstraint(_new_id(), "k", "k", 4.0, orientation))
    assert raised.value.reason == "dimension_between"


def test_collapse_a_provisional_distance_is_dropped():
    assert _collapse(DistanceConstraint(_new_id(), "k", "k", 4.0, provisional=True)) == "drop"


def test_collapse_point_line_distance_is_refused():
    with pytest.raises(MergeRefused) as raised:
        _collapse(PointLineDistanceConstraint(_new_id(), "k", "l", 3.0, "k", "e"))
    assert raised.value.reason == "dimension_between"
    assert _collapse(PointLineDistanceConstraint(_new_id(), "k", "l", 3.0, "s", "e")) == "keep"


def test_collapse_at_midpoint_is_refused():
    with pytest.raises(MergeRefused) as raised:
        _collapse(AtMidpointConstraint(_new_id(), "k", "l", "k", "e"))
    assert raised.value.reason == "degenerate_constraint"


def test_collapse_tangent_family_is_refused():
    with pytest.raises(MergeRefused):
        _collapse(TangentConstraint(_new_id(), "k", "k", "l", "s", "e"))
    with pytest.raises(MergeRefused):
        _collapse(TangentConstraint(_new_id(), "k", "r", "l", "k", "e"))
    with pytest.raises(MergeRefused):
        _collapse(CurveTangentConstraint(_new_id(), "a1", "a2", "k", "k", "s"))
    with pytest.raises(MergeRefused):
        _collapse(CurveTangentConstraint(_new_id(), "a1", "a2", "k", "c2", "k"))
    with pytest.raises(MergeRefused):
        _collapse(EqualRadiusConstraint(_new_id(), "k", "k", "c2", "r2"))


def test_collapse_two_lines_sharing_the_kept_point_is_just_two_connected_lines():
    parallel = ParallelConstraint(_new_id(), "l1", "l2", "k", "e1", "k", "e2")
    assert _collapse(parallel) == "keep"


# --- duplicates, sketch-level state ----------------------------------------------------------------------------------------------------------------------


def test_constraints_that_become_identical_are_reduced_to_one():
    sketch = _sketch()
    a, b, shared = _p(sketch, 0, 0), _p(sketch, 0, 0), _p(sketch, 9, 9)
    sketch.add_coincident_constraint(a, shared)
    sketch.add_coincident_constraint(shared, b)  # both were coincident with the third point
    result = merge_points(sketch, [a, b])
    coincidents = [c for c in sketch.constraints.values() if isinstance(c, CoincidentConstraint)]
    assert len(coincidents) == 1 and len(result.dropped_constraint_ids) == 1


def test_a_reference_dimension_that_measures_the_pair_is_dropped_and_others_follow():
    from app.sketch import reference_dimensions

    sketch = _sketch()
    a, b, far = _p(sketch, 0, 0), _p(sketch, 1, 0), _p(sketch, 30, 0)
    between = reference_dimensions.add(sketch, "distance", [("point", a), ("point", b)])
    to_far = reference_dimensions.add(sketch, "distance", [("point", b), ("point", far)])
    result = merge_points(sketch, [a, b])
    assert result.dropped_reference_dimension_ids == [between.id]
    assert sketch.reference_dimensions[to_far.id].refs == (("point", a), ("point", far))


def test_the_absorbed_point_leaves_every_sketch_level_collection():
    sketch = _sketch()
    a, b = _p(sketch, 0, 0), _p(sketch, 0, 0)
    sketch.reference_ids.add(b)
    merge_points(sketch, [a, b])
    assert b not in sketch.points and b not in sketch.reference_ids and b not in sketch.external_references


# --- the generic safety net -------------------------------------------------------------------------------------------------------------------------------


def _sketch_with_everything() -> Sketch:
    """One of every entity type and every constraint type that names a Point, built far from the origin so nothing is pinned by accident."""
    sketch = _sketch()
    sketch.add_line(_p(sketch, 100, 0), _p(sketch, 120, 0))
    sketch.add_line(_p(sketch, 100, 10), _p(sketch, 120, 12))
    sketch.add_circle(_p(sketch, 100, 50), radius=5.0, angle=0.0)
    sketch.add_circle(_p(sketch, 130, 50), radius=5.0, angle=0.0)
    first_arc = sketch.add_arc(_p(sketch, 100, 80), _p(sketch, 105, 80), end_angle=90.0)
    sketch.add_arc(_p(sketch, 100, 90), first_arc.end_point_id, end_angle=90.0)  # shares an end, for the curve tangent
    sketch.add_ellipse(_p(sketch, 100, 110), major_radius=8.0, angle=0.0, minor_radius=4.0)
    sketch.add_ellipse_arc(_p(sketch, 140, 110), _p(sketch, 148, 110), 4.0, 0.0, 90.0)
    sketch.add_polygon(_p(sketch, 100, 140), _p(sketch, 106, 140), 5)
    sketch.add_slot(_p(sketch, 100, 170), _p(sketch, 120, 170), 3.0)
    sketch.add_rectangle([_p(sketch, 100, 200), _p(sketch, 120, 200), _p(sketch, 120, 210), _p(sketch, 100, 210)])
    spline = sketch.add_spline([_p(sketch, 100, 230), _p(sketch, 110, 240), _p(sketch, 120, 230), _p(sketch, 130, 240)])
    sketch.add_text("Hi", DEFAULT_FONT, 5.0, _p(sketch, 100, 260))
    lines = sketch.lines()
    circles, arcs = sketch.circles(), sketch.arcs()
    sketch.add_distance_constraint(_p(sketch, 200, 0), _p(sketch, 210, 0), 10.0)
    sketch.add_distance_constraint(_p(sketch, 200, 5), _p(sketch, 210, 15), 10.0, "horizontal")
    sketch.add_horizontal_constraint(lines[0].id)
    sketch.add_angle_constraint(lines[0].id, lines[1].id, 10.0)
    sketch.add_coincident_constraint(_p(sketch, 220, 0), _p(sketch, 221, 0))
    sketch.add_parallel_constraint(lines[0].id, lines[1].id)
    sketch.add_perpendicular_constraint(lines[0].id, lines[1].id)
    sketch.add_equal_length_constraint(lines[0].id, lines[1].id)
    sketch.add_line_distance_constraint(lines[0].id, lines[1].id, 10.0)
    sketch.add_collinear_constraint(lines[0].id, lines[1].id)
    sketch.add_tangent_constraint(circles[0].id, lines[0].id)
    sketch.add_curve_tangent_constraint(arcs[0].id, arcs[1].id, arcs[0].end_point_id)
    sketch.add_equal_radius_constraint(circles[0].id, circles[1].id)
    sketch.add_concentric_constraint(circles[0].id, circles[1].id)
    sketch.add_point_line_distance_constraint(_p(sketch, 230, 5), lines[0].id, 5.0)
    sketch.add_point_on_line_constraint(_p(sketch, 235, 0), lines[0].id)
    sketch.add_point_on_circle_constraint(_p(sketch, 235, 55), circles[0].id)
    sketch.add_point_on_ellipse_constraint(_p(sketch, 240, 110), sketch.ellipses()[0].id)
    sketch.add_at_midpoint_constraint(_p(sketch, 240, 0), lines[0].id)
    sketch.add_fixed_constraint(_p(sketch, 250, 250))
    segments = spline.segments()
    first, second = segments[0], segments[1]
    tangent = SplineTangentConstraint(_new_id(), spline.id, *first, *second)
    sketch.constraints[tangent.id] = tangent
    return sketch


def test_no_absorbed_id_is_left_anywhere_in_sketch_to_dict():
    """The net under the generic rewrite: for every Point an entity or a constraint holds, merge a fixed free Point into it (so the held Point is the absorbed one)
    and check its id is nowhere in the serialised Sketch. A field the rewrite missed, now or when a new entity / constraint type is added, fails here."""
    base = _sketch_with_everything()
    held: set[str] = set()
    for entity in base.entities.values():
        held.update(base._entity_defining_point_ids(entity))
    for constraint in base.constraints.values():
        held.update(constraint.point_ids())
    held.discard(base.origin_point_id)
    assert len(held) > 60

    import copy

    merged = 0
    for point_id in sorted(held):
        sketch = copy.deepcopy(base)
        if sketch.is_point_locked(point_id):
            continue
        spot = sketch.points[point_id]
        anchor = sketch.add_point(spot.x, spot.y).id
        sketch.add_fixed_constraint(anchor)  # an anchored point is kept, so the held one is absorbed
        try:
            merge_points(sketch, [anchor, point_id])
        except MergeRefused:
            continue  # a quadrant point, a same-entity pair, a conflict: the refusals have their own tests
        merged += 1
        assert point_id not in sketch.points
        assert point_id not in json.dumps(sketch_to_dict(sketch)), f"{point_id} survived a merge"
    assert merged > 25, f"only {merged} of {len(held)} held points could be merged: the net is not testing enough"


# --- the routes -------------------------------------------------------------------------------------------------------------------------------------------


def _create_sketch() -> str:
    response = client.post("/sketch/sketches", json={"plane": "XY"})
    assert response.status_code == 201
    return response.json()["id"]


def _point(sketch_id: str, x: float, y: float) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()["id"]


def _line(sketch_id: str, a: str, b: str) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b})
    assert response.status_code == 201
    return response.json()


def _merge(sketch_id: str, ids: list[str]):
    return client.post(f"/sketch/sketches/{sketch_id}/points/merge", json={"point_ids": ids})


def _export(sketch_id: str) -> dict:
    return client.get(f"/sketch/sketches/{sketch_id}/export").json()


def test_route_merges_and_returns_the_before_snapshot_as_a_string():
    sketch_id = _create_sketch()
    a, b, c = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0), _point(sketch_id, 10, 0)
    d = _point(sketch_id, 10, 10)
    _line(sketch_id, a, b)
    _line(sketch_id, c, d)
    snapshot = _export(sketch_id)
    response = _merge(sketch_id, [b, c])
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body["kept_id"] == b and body["absorbed_ids"] == [c] and body["converged"] is True
    assert isinstance(body["before"], str)
    assert json.loads(body["before"]) == snapshot
    assert client.get(f"/sketch/sketches/{sketch_id}/points/{c}").status_code == 404


def test_route_404_for_an_unknown_sketch_or_point():
    assert _merge("no-such-sketch", ["a", "b"]).status_code == 404
    sketch_id = _create_sketch()
    a = _point(sketch_id, 1, 1)
    assert _merge(sketch_id, [a, "no-such-point"]).status_code == 404


def test_route_refusal_is_400_with_a_structured_detail_and_changes_nothing():
    sketch_id = _create_sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 5, 0)
    line = _line(sketch_id, a, b)
    snapshot = _export(sketch_id)
    response = _merge(sketch_id, [a, b])
    assert response.status_code == 400
    detail = response.json()["detail"]
    assert detail["type"] == "merge_refused" and detail["reason"] == "same_entity"
    assert line["id"] in detail["ids"] and detail["message"]
    assert _export(sketch_id) == snapshot
    origin = client.get(f"/sketch/sketches/{sketch_id}").json()["origin_point_id"]
    assert _merge(sketch_id, [origin, a]).json()["detail"]["reason"] == "origin"


def test_restore_round_trip_puts_everything_back_with_the_same_ids():
    sketch_id = _create_sketch()
    a, b, c, d = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0), _point(sketch_id, 10, 0), _point(sketch_id, 10, 10)
    _line(sketch_id, a, b)
    _line(sketch_id, c, d)
    original = _export(sketch_id)
    before = _merge(sketch_id, [b, c]).json()["before"]
    assert _export(sketch_id) != original
    response = client.put(f"/sketch/sketches/{sketch_id}/state", content=before, headers={"Content-Type": "application/json"})
    assert response.status_code == 200, response.json()
    assert response.json()["id"] == sketch_id
    assert _export(sketch_id) == original


def test_restore_keeps_the_sketch_feature_pointing_at_its_sketch():
    part = client.post("/document/parts", json={"name": "P"}).json()
    feature = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    sketch_id = feature["sketch_id"]
    a, b, c, d = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0), _point(sketch_id, 10, 0), _point(sketch_id, 10, 10)
    _line(sketch_id, a, b)
    _line(sketch_id, c, d)
    before = _merge(sketch_id, [b, c]).json()["before"]
    assert client.put(f"/sketch/sketches/{sketch_id}/state", content=before, headers={"Content-Type": "application/json"}).status_code == 200
    assert client.get(f"/sketch/sketches/{sketch_id}").status_code == 200
    assert client.get(f"/sketch/sketches/{sketch_id}/points/{c}").status_code == 200  # the absorbed point is back
    fetched = client.get(f"/document/parts/{part['id']}/features/{feature['id']}")
    assert fetched.status_code == 200 and fetched.json()["sketch_id"] == sketch_id


def test_restore_with_the_wrong_id_or_junk_is_422():
    sketch_id = _create_sketch()
    other = _create_sketch()
    wrong = client.put(f"/sketch/sketches/{sketch_id}/state", json=_export(other))
    assert wrong.status_code == 422 and wrong.json()["detail"].startswith("Invalid sketch file")
    assert client.put(f"/sketch/sketches/{sketch_id}/state", json={"nonsense": True}).status_code == 422
    assert client.put("/sketch/sketches/no-such-sketch/state", json=_export(sketch_id)).status_code == 404


def test_route_keeps_a_point_a_loft_references():
    """A Loft's `reference_point` is a feature reference to a sketch Point: it is never absorbed."""
    part = client.post("/document/parts", json={"name": "Loft"}).json()

    def square(plane_feature_id=None):
        payload = {"plane_feature_id": plane_feature_id} if plane_feature_id else {"plane": "XY"}
        feature = client.post(f"/document/parts/{part['id']}/features/sketch", json=payload).json()
        corners = [_point(feature["sketch_id"], x, y) for x, y in ((-5, -5), (5, -5), (5, 5), (-5, 5))]
        for first, second in zip(corners, corners[1:] + corners[:1]):
            _line(feature["sketch_id"], first, second)
        return feature, corners

    bottom, bottom_corners = square()
    plane = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={"plane_type": "offset_face", "face_refs": [{"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}], "offset": 8.0},
    ).json()
    top, _ = square(plane["id"])

    def ref(feature, point_id):
        return {"sketch_feature_id": feature["id"], "reference_point": {"sketch_id": feature["sketch_id"], "entity_type": "point", "entity_id": point_id}}

    loft = client.post(
        f"/document/parts/{part['id']}/loft-features",
        json={"sections": [ref(bottom, bottom_corners[0]), {"sketch_feature_id": top["id"]}], "mode": "boss"},
    )
    assert loft.status_code == 201, loft.json()

    sketch_id = bottom["sketch_id"]
    stray = _point(sketch_id, -5, -5)
    other_end = _point(sketch_id, -20, -20)
    _line(sketch_id, stray, other_end)
    # Listed first, and it has fewer constraints: only the feature reference makes the corner win.
    response = _merge(sketch_id, [stray, bottom_corners[0]])
    assert response.status_code == 200, response.json()
    assert response.json()["kept_id"] == bottom_corners[0]
