"""AI Modelling workstream 5: POST /document/parts/{part_id}/ai-plan/
validate - real-OCCT tests (ast.parse-verified/manually reviewed only in
this sandbox, same as every other OCCT-touching backend prompt in this
project until real CI runs it).

Covers: a fully-valid plan (every step resolves, nothing persisted against
the real Part), a plan with a structural bad reference (unknown local_id),
and a plan with a wrong-*kind* reference (03/05's own spike-found gap -
an extrude step's sketch_feature_id pointing at a sketch_point step
instead of a sketch step) - plus the short-circuit-on-failed-dependency
and edge-selector behaviors those two docs also specify.
"""

import pytest
from fastapi.testclient import TestClient

from app.document.ai_plan import _PlanValidator
from app.document.ai_plan_schemas import SketchCircleStep, SketchLineStep, SketchPointStep, SketchRectangleStep, SketchStep
from app.document.models import Part
from app.main import app
from app.sketch.constraints import DistanceConstraint
from app.sketch.solver import solve_sketch
from app.sketch.store import delete_sketch, get_sketch_or_404
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "AI Plan Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _validate(part_id: str, steps: list[dict]) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/ai-plan/validate",
        json={"version": 1, "steps": steps},
    )
    assert response.status_code == 200
    return response.json()


def _results_by_local_id(response: dict) -> dict[str, dict]:
    return {result["local_id"]: result for result in response["results"]}


def _rectangle_sketch_steps(sketch_local_id: str = "sk1") -> list[dict]:
    """sk1 -> p1..p4 -> r1: a 60x40 axis-aligned rectangle on XY, the same
    shape `_add_square`-style helpers elsewhere in this test suite build,
    just expressed as plan steps instead of direct HTTP calls."""
    return [
        {"local_id": sketch_local_id, "kind": "sketch", "plane": "XY"},
        {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 0, "y": 0},
        {"local_id": "p2", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 60, "y": 0},
        {"local_id": "p3", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 60, "y": 40},
        {"local_id": "p4", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 0, "y": 40},
        {
            "local_id": "r1",
            "kind": "sketch_rectangle",
            "sketch_feature_id": sketch_local_id,
            "corner_point_ids": ["p1", "p2", "p3", "p4"],
        },
    ]


def test_fully_valid_plan_all_steps_ok() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
        {
            "local_id": "f2",
            "kind": "fillet",
            "edges": {"selector": "top_face_edges", "of": "f1"},
            "radius": 2,
        },
    ]

    response = _validate(part["id"], steps)

    assert [r["ok"] for r in response["results"]] == [True] * len(steps)
    assert all(r["error"] is None for r in response["results"])


def test_extrude_step_reports_hole_count_for_a_square_with_a_nested_circle() -> None:
    """`02-scoping-conversation.md`'s own real end-to-end exercise (fix 3b):
    a square Sketch with one circle nested inside it (a hole, not a second
    outer profile - `detect_profile`'s own C1 nesting classification) should
    report `hole_count: 1` on the Extrude step that consumes it - mirrors
    the exact "100mm square plate ... with a 20mm hole in the middle" case
    from that exercise, at a smaller/faster scale. Real backend truth from
    `app.sketch.profile.detect_profile`, not a client-side guess."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {"local_id": "pc", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 30, "y": 20},
        {"local_id": "c1", "kind": "sketch_circle", "sketch_feature_id": "sk1", "center_point_id": "pc", "radius": 10},
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is True
    assert results["f1"]["hole_count"] == 1
    # Non-extrude/revolve/sweep steps never carry a hole_count at all.
    assert results["r1"]["hole_count"] is None


def test_extrude_step_reports_zero_hole_count_for_a_plain_rectangle() -> None:
    """A plain rectangle Extrude (no nested hole) reports `hole_count: 0`,
    not `None`/missing - `hole_count` is only ever absent for a step kind
    that isn't extrude/revolve/sweep, never merely "no holes found"."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is True
    assert results["f1"]["hole_count"] == 0


def test_valid_plan_persists_nothing_against_the_real_part() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    _validate(part["id"], steps)

    features = client.get(f"/document/parts/{part['id']}/features")
    assert features.status_code == 200
    assert features.json() == []


def test_structural_bad_reference_reports_unknown_local_id() -> None:
    part = _create_part()
    steps = [
        {"local_id": "sk1", "kind": "sketch", "plane": "XY"},
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "does_not_exist",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["sk1"]["ok"] is True
    assert results["f1"]["ok"] is False
    assert results["f1"]["error"] == {
        "type": "unknown_local_id",
        "field": "sketch_feature_id",
        "local_id": "does_not_exist",
    }


def test_wrong_kind_reference_rejected_even_though_local_id_exists() -> None:
    """The exact spike-found gap 03/05 both call out: a throwaway
    validator that only checks "does this local_id exist among earlier
    steps" would wave this through (p1 is a real, earlier local_id) - this
    endpoint must also check it's the *right kind* of step (sketch_point
    is not a sketch)."""
    part = _create_part()
    steps = [
        {"local_id": "sk1", "kind": "sketch", "plane": "XY"},
        {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 0, "y": 0},
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "p1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["p1"]["ok"] is True
    assert results["f1"]["ok"] is False
    assert results["f1"]["error"] == {
        "type": "wrong_kind_reference",
        "field": "sketch_feature_id",
        "local_id": "p1",
        "expected_kinds": ["sketch"],
        "actual_kind": "sketch_point",
    }


def test_extrude_profile_refs_reject_a_composite_entity_directly() -> None:
    """A second, distinct wrong-kind case: `profile_refs` must name a
    Line/Circle/Arc/Ellipse entity (what the real `select_profiles`
    accepts as an anchor), never the composite `sketch_rectangle` step
    itself - even though a rectangle *is* a Sketch entity in the broader
    sense, it isn't a valid profile-ref anchor on its own."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
            "profile_refs": ["r1"],
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "wrong_kind_reference"
    assert results["f1"]["error"]["actual_kind"] == "sketch_rectangle"


def test_failed_step_short_circuits_dependents() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            # Invalid: end_distance must be greater than start_distance.
            "start_distance": 10,
            "end_distance": 0,
        },
        {
            "local_id": "f2",
            "kind": "fillet",
            "edges": {"selector": "top_face_edges", "of": "f1"},
            "radius": 2,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "invalid_distances"
    assert results["f2"]["ok"] is False
    assert results["f2"]["error"] == {
        "type": "depends_on_failed_step",
        "field": "edges.of",
        "local_id": "f1",
    }


def test_cut_without_target_body_ids_is_rejected() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "cut",
            "start_distance": 0,
            "end_distance": 10,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "invalid_step_payload"


def test_gear_request_step_always_ok_but_not_edge_selectable() -> None:
    """00-conventions.md's routing rule: a `gear_request` step is never
    resolved against real geometry here (the translator hands it off to
    the Gear Design screens instead), so it always reports ok - but a
    later step naming it as a Body reference for an edge selector can't
    be dry-run validated either way, and must say so explicitly rather
    than silently passing or raising a confusing geometry error."""
    part = _create_part()
    steps = [
        {"local_id": "g1", "kind": "gear_request", "gear_type": "spur", "module": 2, "teeth": 20},
        {
            "local_id": "f2",
            "kind": "fillet",
            "edges": {"selector": "top_face_edges", "of": "g1"},
            "radius": 2,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["g1"]["ok"] is True
    assert results["f2"]["ok"] is False
    assert results["f2"]["error"]["type"] == "gear_body_not_validatable"


def test_edge_selectors_vertical_and_face_at_position() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
        {"local_id": "c1", "kind": "fillet", "edges": {"selector": "vertical_edges", "of": "f1"}, "radius": 1},
        {
            "local_id": "c2",
            "kind": "chamfer",
            "edges": {"selector": "all_edges_of_face_at_position", "direction": "+x", "of": "f1"},
            "distance": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is True
    assert results["c2"]["ok"] is True


def test_circular_pattern_axis_accepts_sketch_line_ref() -> None:
    """Bug fix found while implementing workstream 4: `PatternAxisStep`
    used to also accept `fixed_axis` (copied from `PatternDirectionStep`'s
    shape without checking `PatternAxisRef`, the real type it mirrors, has
    no such field) - would have raised an unhandled `TypeError` the moment
    a plan actually used it, rather than a structured validation error.
    `sketch_line_ref` was always the one working option; this just
    confirms it still resolves correctly now that it's the only one."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {"local_id": "ax1", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 30, "y": -20},
        {"local_id": "ax2", "kind": "sketch_point", "sketch_feature_id": "sk1", "x": 30, "y": 60},
        {
            "local_id": "axl",
            "kind": "sketch_line",
            "sketch_feature_id": "sk1",
            "start_point_id": "ax1",
            "end_point_id": "ax2",
            "construction": True,
        },
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
        {
            "local_id": "p1",
            "kind": "pattern",
            "source_body_ids": ["f1"],
            "pattern_type": "circular",
            "axis": {"sketch_line_ref": "axl"},
            "count_angular": 4,
            "angle_total": 360,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["p1"]["ok"] is True, results["p1"]


def test_fillet_step_reports_resolved_edges_keyed_by_local_id() -> None:
    """Workstream 4's own need: the translator has no client-side way to
    resolve an `EdgeSelector` (needs real OCCT topology) - it must reuse
    this dry-run's own resolution for real execution. `resolved_edges`
    must be present, non-empty, and use the plan's `edges.of` local_id as
    `body_id` (never this validator's own scratch Feature id, which the
    real translator's execution never creates and couldn't substitute)."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
        {
            "local_id": "f2",
            "kind": "fillet",
            "edges": {"selector": "top_face_edges", "of": "f1"},
            "radius": 2,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    resolved_edges = results["f2"]["resolved_edges"]
    assert resolved_edges is not None
    assert len(resolved_edges) == 4  # a rectangle's top face has 4 edges
    for edge in resolved_edges:
        assert edge["body_id"] == "f1"
        assert edge["shape_type"] == "edge"
    # No two entries should double up on the same index.
    assert len({edge["index"] for edge in resolved_edges}) == 4
    # Every other (non-fillet/chamfer) step never carries this field.
    assert results["f1"]["resolved_edges"] is None


def test_sketch_line_angle_is_degrees_not_radians() -> None:
    """Bug fix found while implementing workstream 4: 00-conventions.md
    promises "degrees for every angle" (and `ai_plan_summary.dart`'s
    Review & Generate panel already labels this field with a literal "°"),
    but the real `Sketch.add_line` this handler calls treats `angle` as
    radians. A 90-degree, length-10 line from the origin must end up
    (approximately) at (0, 10) - the old unconverted pass-through would
    have treated 90 as *radians* (~5157 degrees, wrapping to a
    direction nowhere near "straight up"), so this genuinely
    distinguishes the fix from the bug rather than passing either way.

    Uses `_PlanValidator` directly (not the HTTP endpoint) since the
    resolved Sketch is only inspectable before `_PlanValidator.run()`'s own
    scratch-sketch cleanup runs - `PlanValidateResponse` reports ok/error
    only, never resolved sketch-entity coordinates."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=0.0, y=0.0),
        SketchLineStep(local_id="l1", sketch_feature_id="sk1", start_point_id="p1", length=10.0, angle=90.0),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results

        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        line = sketch.lines()[0]
        end_point = sketch.points[line.end_point_id]
        assert end_point.x == pytest.approx(0.0, abs=1e-6)
        assert end_point.y == pytest.approx(10.0, abs=1e-6)
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)


def test_face_at_position_selector_requires_a_direction() -> None:
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        {
            "local_id": "f1",
            "kind": "extrude",
            "sketch_feature_id": "sk1",
            "extrude_type": "boss",
            "start_distance": 0,
            "end_distance": 10,
        },
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "all_edges_of_face_at_position", "of": "f1"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is False
    assert results["c1"]["error"]["type"] == "edge_selector_missing_direction"


def test_sketch_line_length_creates_a_real_non_provisional_distance_constraint() -> None:
    """AI Modelling "dimension-driven sketches" workstream (docs/ai-
    modelling/08-dimension-driven-sketches.md): a literal `length` on a
    sketch_line step must produce a real, non-provisional
    DistanceConstraint - the dry run's own mirror of what the real client-
    side translator does (`ai_plan_translator.dart`'s own
    `createDistanceConstraint` call), per 00-conventions.md's "dry-run
    matches real execution" invariant. Uses `_PlanValidator` directly (not
    the HTTP endpoint) for the same "inspect the scratch Sketch before its
    own cleanup runs" reason `test_sketch_line_angle_is_degrees_not_radians`
    above does - `PlanValidateResponse` never reports constraint state."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=0.0, y=0.0),
        SketchLineStep(local_id="l1", sketch_feature_id="sk1", start_point_id="p1", length=25.0, angle=0.0),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results

        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        line = sketch.lines()[0]
        distance_constraints = [c for c in sketch.constraints.values() if isinstance(c, DistanceConstraint)]
        assert len(distance_constraints) == 1
        constraint = distance_constraints[0]
        assert constraint.provisional is False
        assert constraint.distance == pytest.approx(25.0)
        assert constraint.orientation == "linear"
        assert {constraint.point_a_id, constraint.point_b_id} == {line.start_point_id, line.end_point_id}
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)


def test_sketch_line_without_length_creates_no_constraint() -> None:
    """The explicit-`end_point_id` path with no `length` stays exactly as
    unconstrained as it already was before this workstream - a real,
    deliberate scope limit (08's own "Line length" section: only a literal
    length becomes a real dimension), not an oversight."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=0.0, y=0.0),
        SketchPointStep(local_id="p2", sketch_feature_id="sk1", x=10.0, y=0.0),
        SketchLineStep(local_id="l1", sketch_feature_id="sk1", start_point_id="p1", end_point_id="p2"),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results
        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        assert not any(isinstance(c, DistanceConstraint) for c in sketch.constraints.values())
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)


def test_sketch_rectangle_width_height_create_real_axis_aligned_constraints() -> None:
    """A literal `width`/`height` on a sketch_rectangle step must produce
    two real, non-provisional DistanceConstraints - horizontal on
    corner0->corner1 (`width`), vertical on corner1->corner2 (`height`) -
    alongside (not instead of) the Horizontal/Vertical *direction*
    constraints `add_rectangle(axis_aligned=True)` already creates for
    those same two edges. Confirms these are genuinely orthogonal DOF (no
    over-constraint) via a real solve, in this session's own bootstrapped
    real py-slvs environment - 03's own "verify against real geometry, not
    guesswork" spike discipline."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=0.0, y=0.0),
        SketchPointStep(local_id="p2", sketch_feature_id="sk1", x=60.0, y=0.0),
        SketchPointStep(local_id="p3", sketch_feature_id="sk1", x=60.0, y=40.0),
        SketchPointStep(local_id="p4", sketch_feature_id="sk1", x=0.0, y=40.0),
        SketchRectangleStep(
            local_id="r1",
            sketch_feature_id="sk1",
            corner_point_ids=["p1", "p2", "p3", "p4"],
            width=60.0,
            height=40.0,
        ),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results

        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        distance_constraints = [c for c in sketch.constraints.values() if isinstance(c, DistanceConstraint)]
        assert len(distance_constraints) == 2
        by_orientation = {c.orientation: c for c in distance_constraints}
        assert set(by_orientation) == {"horizontal", "vertical"}
        assert by_orientation["horizontal"].distance == pytest.approx(60.0)
        assert by_orientation["horizontal"].provisional is False
        assert by_orientation["vertical"].distance == pytest.approx(40.0)
        assert by_orientation["vertical"].provisional is False

        # Real solve: confirms no over-constraint alongside the existing
        # Horizontal/Vertical direction constraints (an orthogonal concern -
        # those pin edge *direction*, these pin edge *length*).
        result = solve_sketch(sketch)
        assert result.converged, result
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)


def test_sketch_rectangle_without_width_height_creates_no_distance_constraint() -> None:
    """Omitting `width`/`height` (the pre-existing default) must not create
    any DistanceConstraint - only the Horizontal/Vertical direction
    constraints `add_rectangle` always creates."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=0.0, y=0.0),
        SketchPointStep(local_id="p2", sketch_feature_id="sk1", x=60.0, y=0.0),
        SketchPointStep(local_id="p3", sketch_feature_id="sk1", x=60.0, y=40.0),
        SketchPointStep(local_id="p4", sketch_feature_id="sk1", x=0.0, y=40.0),
        SketchRectangleStep(local_id="r1", sketch_feature_id="sk1", corner_point_ids=["p1", "p2", "p3", "p4"]),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results
        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        assert not any(isinstance(c, DistanceConstraint) for c in sketch.constraints.values())
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)


def test_sketch_circle_radius_point_confirms_a_real_non_provisional_radius_constraint() -> None:
    """Circle/Arc/Ellipse/Polygon/Slot creation always confirms its own
    auto-created *provisional* radius DistanceConstraint (`Sketch.
    add_circle`'s own doc comment) with the entity's own real, resulting
    radius - regardless of whether the plan step named a literal `radius`
    field or an explicit `radius_point_id` instead, since both already fix
    a real number via the plan's own literal Point coordinates. Without
    this, an AI-generated Circle has zero solver-enforced radius at all
    (`DistanceConstraint.provisional`'s own doc comment: skipped entirely
    by the solver until confirmed) - a real correctness gap this
    workstream closes, not just an editability nicety."""
    part = Part(id="scratch-part", name="scratch", features=[])
    validator = _PlanValidator(part)
    steps = [
        SketchStep(local_id="sk1", plane="XY"),
        SketchPointStep(local_id="p1", sketch_feature_id="sk1", x=10.0, y=10.0),
        SketchPointStep(local_id="p2", sketch_feature_id="sk1", x=15.0, y=10.0),
        SketchCircleStep(local_id="c1", sketch_feature_id="sk1", center_point_id="p1", radius_point_id="p2"),
    ]
    try:
        results = [validator._run_step(step) for step in steps]
        assert all(r.ok for r in results), results

        sketch = get_sketch_or_404(validator.resolved["sk1"].sketch_id)
        circle = sketch.circles()[0]
        constraint = sketch.constraints[circle.radius_constraint_id]
        assert isinstance(constraint, DistanceConstraint)
        assert constraint.provisional is False
        assert constraint.distance == pytest.approx(5.0)
    finally:
        for sketch_id in validator._scratch_sketch_ids:
            delete_sketch(sketch_id)
