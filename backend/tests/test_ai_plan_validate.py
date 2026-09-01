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
from app.document.ai_plan_schemas import (
    ExtrudeStep,
    SketchCircleStep,
    SketchLineStep,
    SketchPointStep,
    SketchRectangleStep,
    SketchStep,
)
from app.document.models import ExtrudeType, Part
from app.document.store import get_part_or_404
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


def _quad_sketch_steps(sketch_local_id: str = "sk1") -> list[dict]:
    """sk1 -> p1..p4 -> l1..l4: the same 60x40 axis-aligned rectangle
    `_rectangle_sketch_steps` builds, but via explicit sketch_line steps
    instead of the sketch_rectangle shorthand - needed for
    edge_from_sketch_line tests specifically, since a sketch_rectangle
    step's own internal Lines never get their own plan-local_id (only the
    corner sketch_point steps do) - see Workstream 12's own disclosed
    "only works with an explicit sketch_line step" limitation
    (docs/ai-modelling/12-provenance-edge-selectors.md)."""
    return [
        {"local_id": sketch_local_id, "kind": "sketch", "plane": "XY"},
        {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 0, "y": 0},
        {"local_id": "p2", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 60, "y": 0},
        {"local_id": "p3", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 60, "y": 40},
        {"local_id": "p4", "kind": "sketch_point", "sketch_feature_id": sketch_local_id, "x": 0, "y": 40},
        {"local_id": "l1", "kind": "sketch_line", "sketch_feature_id": sketch_local_id, "start_point_id": "p1", "end_point_id": "p2"},
        {"local_id": "l2", "kind": "sketch_line", "sketch_feature_id": sketch_local_id, "start_point_id": "p2", "end_point_id": "p3"},
        {"local_id": "l3", "kind": "sketch_line", "sketch_feature_id": sketch_local_id, "start_point_id": "p3", "end_point_id": "p4"},
        {"local_id": "l4", "kind": "sketch_line", "sketch_feature_id": sketch_local_id, "start_point_id": "p4", "end_point_id": "p1"},
    ]


def _extrude_step(local_id: str = "f1", sketch_feature_id: str = "sk1") -> dict:
    return {
        "local_id": local_id,
        "kind": "extrude",
        "sketch_feature_id": sketch_feature_id,
        "extrude_type": "boss",
        "start_distance": 0,
        "end_distance": 10,
    }


def test_edge_from_sketch_point_selects_one_specific_corner_edge() -> None:
    """Workstream 12 (docs/ai-modelling/12-provenance-edge-selectors.md):
    the safe, primary provenance selector - a corner's own sketch_point
    local_id names exactly the one vertical edge generated there."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_point", "of": "f1", "sketch_point_ref": "p1"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is True, results["c1"]
    resolved_edges = results["c1"]["resolved_edges"]
    assert len(resolved_edges) == 1
    assert resolved_edges[0]["body_id"] == "f1"
    assert resolved_edges[0]["shape_type"] == "edge"


def test_edge_from_sketch_point_discriminates_between_different_corners() -> None:
    """The real point of Workstream 12 over the four heuristics: two
    different corners must resolve to two different real edges, not the
    same fixed answer regardless of which sketch_point_ref was named."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_point", "of": "f1", "sketch_point_ref": "p1"},
            "radius": 1,
        },
        {
            "local_id": "c2",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_point", "of": "f1", "sketch_point_ref": "p3"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is True, results["c1"]
    assert results["c2"]["ok"] is True, results["c2"]
    index1 = results["c1"]["resolved_edges"][0]["index"]
    index2 = results["c2"]["resolved_edges"][0]["index"]
    assert index1 != index2


def test_edge_from_sketch_line_near_and_far_select_different_edges() -> None:
    """Workstream 12's more powerful selector - far=False (the edge as
    originally drawn, on the base face) and far=True (its generated
    counterpart on the extruded end) for the *same* sketch_line_ref must
    resolve to two different real edges."""
    part = _create_part()
    steps = _quad_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_line", "of": "f1", "sketch_line_ref": "l1", "far": False},
            "radius": 1,
        },
        {
            "local_id": "c2",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_line", "of": "f1", "sketch_line_ref": "l1", "far": True},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is True, results["c1"]
    assert results["c2"]["ok"] is True, results["c2"]
    near_index = results["c1"]["resolved_edges"][0]["index"]
    far_index = results["c2"]["resolved_edges"][0]["index"]
    assert near_index != far_index


def test_edge_from_sketch_line_requires_sketch_line_ref() -> None:
    part = _create_part()
    steps = _quad_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_line", "of": "f1"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is False
    assert results["c1"]["error"]["type"] == "invalid_step_payload"


def test_edge_from_sketch_point_wrong_kind_reference_rejected() -> None:
    """`sketch_point_ref` naming a sketch_line step (wrong kind, but a real
    local_id) must be rejected the same structural way every other
    kind-checked field in this schema already is - never an uncaught
    AttributeError from reading a sketch_line's `_Resolved.point_id`
    (always None for that kind)."""
    part = _create_part()
    steps = _quad_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_point", "of": "f1", "sketch_point_ref": "l1"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is False
    assert results["c1"]["error"]["type"] == "wrong_kind_reference"


def test_edge_from_sketch_point_works_against_a_sketch_rectangle_shorthand_profile() -> None:
    """Real, disclosed limitation (docs/ai-modelling/12-provenance-edge-
    selectors.md): a sketch_rectangle step's own internal Lines never get
    their own plan-local_id, so there is no sketch_line_ref a plan could
    even name for one of its sides - edge_from_sketch_line only works with
    an explicit sketch_line step (see `_quad_sketch_steps`'s own doc
    comment above). This confirms the *point*-based selector still works
    fine against a sketch_rectangle profile instead (the corner points
    always have their own local_id regardless of which shorthand built the
    rectangle)."""
    part = _create_part()
    steps = _rectangle_sketch_steps() + [
        _extrude_step(),
        {
            "local_id": "c1",
            "kind": "fillet",
            "edges": {"selector": "edge_from_sketch_point", "of": "f1", "sketch_point_ref": "p2"},
            "radius": 1,
        },
    ]

    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["c1"]["ok"] is True, results["c1"]


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


# --- Existing-Part editing (docs/ai-modelling/09-existing-part-editing.md) --


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    """Draws a closed `size` x `size` square, bottom-left at (x0, y0), into
    an existing (empty) real Sketch via the real /sketch API - mirrors
    `test_stage9_extrude.py`'s own identically-named helper."""
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_extrude_feature(part_id: str, sketch_feature_id: str, **overrides) -> dict:
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "extrude_type": "boss",
        "start_distance": 0,
        "end_distance": 10,
        "target_body_ids": [],
        **overrides,
    }
    response = client.post(f"/document/parts/{part_id}/extrude-features", json=payload)
    assert response.status_code == 201, response.json()
    return response.json()


def test_existing_body_feature_referenced_as_fillet_target() -> None:
    """A real, already-built Extrude Feature (created via the ordinary real
    endpoint, not this plan's own steps) is a valid `edges.of` target when
    named `existing:<real_id>` - the plan itself contains nothing but the
    fillet step."""
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 60.0)
    extrude = _create_extrude_feature(part["id"], sketch["id"], end_distance=10.0)

    response = _validate(
        part["id"],
        [
            {
                "local_id": "f1",
                "kind": "fillet",
                "edges": {"selector": "top_face_edges", "of": f"existing:{extrude['id']}"},
                "radius": 2,
            },
        ],
    )
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is True, results["f1"]
    resolved_edges = results["f1"]["resolved_edges"]
    assert resolved_edges is not None and len(resolved_edges) == 4
    for edge in resolved_edges:
        assert edge["body_id"].startswith(f"existing:{extrude['id']}")


def test_existing_body_feature_mixed_with_new_local_ids_as_cut_target() -> None:
    """A plan mixing `existing:` references with brand-new plan-local steps
    in the same plan: a fresh Sketch/Rectangle/Extrude(cut) targets the real
    pre-existing Body via `target_body_ids: ["existing:<real_id>"]` -
    confirms the cut is actually resolved against the real geometry (not
    just structurally accepted) by giving it a smaller profile fully inside
    the existing body's own footprint, which only extrude-resolves cleanly
    if the real body is genuinely there to cut into."""
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 60.0)
    extrude = _create_extrude_feature(part["id"], sketch["id"], end_distance=10.0)

    steps = _rectangle_sketch_steps("sk2") + [
        {
            "local_id": "f2",
            "kind": "extrude",
            "sketch_feature_id": "sk2",
            "extrude_type": "cut",
            "start_distance": 0,
            "end_distance": 10,
            "target_body_ids": [f"existing:{extrude['id']}"],
        },
    ]
    # `_rectangle_sketch_steps` always builds a 0,0 -> 60,40 rectangle -
    # already fully inside the existing 60x60 square above, so the cut
    # resolves without needing a second, differently-sized helper.
    response = _validate(part["id"], steps)
    results = _results_by_local_id(response)

    assert results["f2"]["ok"] is True, results["f2"]


def test_existing_sketch_feature_anchors_new_sketch_entity_steps() -> None:
    """A whole existing Sketch, named `existing:<real_sketch_feature_id>` as
    a `sketch_feature_id`, anchors brand-new sketch_point/sketch_rectangle/
    extrude steps - new geometry added into an already-existing Sketch,
    exactly like `03`'s own scope note describes. Runs `_PlanValidator`
    directly (not the HTTP endpoint) so the real Sketch's own state is
    inspectable both before and after - confirming the dry run's mutation
    of it is fully undone afterward (this module's own "never mutates real
    stored state" invariant), not just that the plan validated ok."""
    part_dict = _create_part()
    sketch = _create_sketch_feature(part_dict["id"])
    sketch_id = sketch["sketch_id"]

    before_point_count = len(get_sketch_or_404(sketch_id).points)

    real_part = get_part_or_404(part_dict["id"])
    existing_sketch_ref = f"existing:{sketch['id']}"
    steps = [
        SketchPointStep(local_id="p1", sketch_feature_id=existing_sketch_ref, x=0.0, y=0.0),
        SketchPointStep(local_id="p2", sketch_feature_id=existing_sketch_ref, x=60.0, y=0.0),
        SketchPointStep(local_id="p3", sketch_feature_id=existing_sketch_ref, x=60.0, y=40.0),
        SketchPointStep(local_id="p4", sketch_feature_id=existing_sketch_ref, x=0.0, y=40.0),
        SketchRectangleStep(
            local_id="r1", sketch_feature_id=existing_sketch_ref, corner_point_ids=["p1", "p2", "p3", "p4"]
        ),
        ExtrudeStep(
            local_id="f1",
            sketch_feature_id=existing_sketch_ref,
            extrude_type=ExtrudeType.BOSS,
            start_distance=0,
            end_distance=10,
        ),
    ]
    results = _PlanValidator(real_part).run(steps)

    assert all(r.ok for r in results), results
    # The real Sketch is restored to exactly its pre-dry-run state - the
    # new scratch points/rectangle must not have leaked into real storage.
    after_point_count = len(get_sketch_or_404(sketch_id).points)
    assert after_point_count == before_point_count


def test_existing_id_on_a_wrong_kind_field_is_rejected() -> None:
    """An existing SketchFeature (produces `sketch`, not `body`) is not a
    valid `target_body_ids` entry - the same "right kind, not just any
    reference" discipline `wrong_kind_reference` already enforces for
    plan-local references, reported under its own `existing_id_not_
    allowed_here` type since there's no plan-local `_Resolved.kind` to name
    an "actual_kind" from."""
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])

    response = _validate(
        part["id"],
        _rectangle_sketch_steps("sk2")
        + [
            {
                "local_id": "f1",
                "kind": "extrude",
                "sketch_feature_id": "sk2",
                "extrude_type": "cut",
                "start_distance": 0,
                "end_distance": 10,
                "target_body_ids": [f"existing:{sketch['id']}"],
            },
        ],
    )
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "existing_id_not_allowed_here"
    assert results["f1"]["error"]["field"] == "target_body_ids"
    assert results["f1"]["error"]["actual_produces"] == "sketch"


def test_existing_id_wrong_kind_reported_directly() -> None:
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 60.0)
    extrude = _create_extrude_feature(part["id"], sketch["id"], end_distance=10.0)

    response = _validate(
        part["id"],
        [
            {
                "local_id": "f1",
                "kind": "fillet",
                "edges": {"selector": "top_face_edges", "of": f"existing:{sketch['id']}"},
                "radius": 2,
            },
        ],
    )
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "existing_id_not_allowed_here"
    assert results["f1"]["error"]["actual_produces"] == "sketch"
    # Confirms the real extrude Feature above was never itself the problem -
    # it's specifically the sketch that's the wrong produces-kind here.
    assert extrude["produces"] == "body"


def test_unknown_existing_id_is_rejected() -> None:
    part = _create_part()

    response = _validate(
        part["id"],
        [
            {
                "local_id": "f1",
                "kind": "fillet",
                "edges": {"selector": "top_face_edges", "of": "existing:not-a-real-feature-id"},
                "radius": 2,
            },
        ],
    )
    results = _results_by_local_id(response)

    assert results["f1"]["ok"] is False
    assert results["f1"]["error"]["type"] == "unknown_existing_id"


def test_step_local_id_cannot_itself_use_the_existing_prefix() -> None:
    part = _create_part()

    response = _validate(
        part["id"],
        [{"local_id": "existing:sneaky", "kind": "sketch", "plane": "XY"}],
    )
    results = _results_by_local_id(response)

    assert results["existing:sneaky"]["ok"] is False
    assert results["existing:sneaky"]["error"]["type"] == "reserved_local_id_prefix"
