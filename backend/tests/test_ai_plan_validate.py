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

from fastapi.testclient import TestClient

from app.main import app
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
