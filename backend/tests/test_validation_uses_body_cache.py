"""AI plan validation must not rebuild a Part's whole history for every solid step.

Validating a plan used to pass `frozenset({feature_id})` to `compute_part_bodies` for each extrude/sweep/revolve/loft step. Any non-empty
exclusion set takes the uncached path, and the Feature being validated was not even in the Part yet, so the exclusion changed nothing: N sweeps
cost N(N+1)/2 sweep builds (a 13-wire harness took 6.4 s, the last sweep alone 0.86 s against 0.09 s for the first). These tests pin the fix:
`excluded_with_own_id` only adds the id of a Feature that is really in the Part, and a plan's solid steps never reach `compute_part_bodies`
with a non-empty exclusion set. The helper tests need no pythonocc; the plan test does."""

from fastapi.testclient import TestClient

from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps

from app.document import ai_plan, extrude, revolve, sweep
from app.document.extrude import excluded_with_own_id
from app.document.models import ExtrudeFeature, ExtrudeType, Part
from app.main import app
from tests.conftest import TEST_API_KEY


def _part_with(*ids: str) -> Part:
    return Part(
        id="p",
        name="p",
        features=[
            ExtrudeFeature(id=i, sketch_feature_id="s", extrude_type=ExtrudeType.BOSS, start_distance=0.0, end_distance=1.0)
            for i in ids
        ],
    )


def test_an_id_not_in_the_part_is_not_added():
    assert excluded_with_own_id(_part_with("a", "b"), "new", frozenset()) == frozenset()


def test_an_id_not_in_the_part_keeps_the_callers_own_exclusions():
    assert excluded_with_own_id(_part_with("a"), "new", frozenset({"x"})) == frozenset({"x"})


def test_an_id_already_in_the_part_is_added():
    assert excluded_with_own_id(_part_with("a", "b"), "b", frozenset({"x"})) == frozenset({"x", "b"})


def _plan(n_wires: int) -> dict:
    steps = [{"local_id": "skp", "kind": "sketch", "plane": "XY"}]
    for i in range(n_wires):
        y = 10 * i
        steps += [
            {"local_id": f"a{i}", "kind": "sketch_point", "sketch_feature_id": "skp", "x": 0, "y": y},
            {"local_id": f"b{i}", "kind": "sketch_point", "sketch_feature_id": "skp", "x": 30, "y": y},
            {"local_id": f"l{i}", "kind": "sketch_line", "sketch_feature_id": "skp", "start_point_id": f"a{i}", "end_point_id": f"b{i}"},
            {"local_id": f"pl{i}", "kind": "create_plane", "plane_type": "normal_to_line_at_point", "line_ref": f"l{i}", "point_ref": f"a{i}"},
            {"local_id": f"sk{i}", "kind": "sketch", "plane_feature_id": f"pl{i}"},
            {"local_id": f"c{i}", "kind": "sketch_point", "sketch_feature_id": f"sk{i}", "x": 0, "y": 0},
            {"local_id": f"w{i}", "kind": "sketch_circle", "sketch_feature_id": f"sk{i}", "center_point_id": f"c{i}", "radius": 1},
            {"local_id": f"s{i}", "kind": "sweep", "sketch_feature_id": f"sk{i}", "path_refs": [f"l{i}"], "mode": "boss"},
        ]
    return {"version": 1, "steps": steps}


def test_validating_several_sweeps_never_uses_the_uncached_exclusion_path(monkeypatch):
    seen: list[frozenset] = []
    real = ai_plan.compute_part_bodies

    def spy(part, excluded=frozenset()):
        seen.append(excluded)
        return real(part, excluded)

    monkeypatch.setattr(ai_plan, "compute_part_bodies", spy)
    monkeypatch.setattr(sweep, "compute_part_bodies", spy)

    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    part_id = client.post("/document/parts", json={"name": "wires"}).json()["id"]
    response = client.post(f"/document/parts/{part_id}/ai-plan/validate", json=_plan(4))
    assert response.status_code == 200
    results = response.json()["results"]
    assert all(r["ok"] for r in results), [r for r in results if not r["ok"]]
    assert seen, "the validator should have computed bodies for the sweeps"
    assert all(not excluded for excluded in seen), [sorted(e) for e in seen if e]


def _client() -> TestClient:
    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    return client


def _validate(plan: dict) -> tuple[str, list[dict]]:
    client = _client()
    part_id = client.post("/document/parts", json={"name": "p"}).json()["id"]
    response = client.post(f"/document/parts/{part_id}/ai-plan/validate", json=plan)
    assert response.status_code == 200
    return part_id, response.json()["results"]


def _extrude_steps() -> list[dict]:
    return [
        {"local_id": "ske", "kind": "sketch", "plane": "XY"},
        {"local_id": "e1", "kind": "sketch_point", "sketch_feature_id": "ske", "x": 50, "y": 50},
        {"local_id": "e2", "kind": "sketch_point", "sketch_feature_id": "ske", "x": 60, "y": 50},
        {"local_id": "e3", "kind": "sketch_point", "sketch_feature_id": "ske", "x": 60, "y": 60},
        {"local_id": "e4", "kind": "sketch_point", "sketch_feature_id": "ske", "x": 50, "y": 60},
        {"local_id": "er", "kind": "sketch_rectangle", "sketch_feature_id": "ske", "corner_point_ids": ["e1", "e2", "e3", "e4"]},
        {"local_id": "ex", "kind": "extrude", "sketch_feature_id": "ske", "extrude_type": "boss", "start_distance": 0, "end_distance": 5},
    ]


def _mixed_plan(with_extrude: bool = True) -> dict:
    """Sweeps (with their own plane-anchored profile Sketches), an extrude and a revolve - every solid step kind the validator replays."""
    steps = _plan(2)["steps"]
    steps += _extrude_steps() if with_extrude else []
    steps += [
        {"local_id": "skr", "kind": "sketch", "plane": "XY"},
        {"local_id": "a1", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 0, "y": 100},
        {"local_id": "a2", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 15, "y": 100},
        {"local_id": "axis", "kind": "sketch_line", "sketch_feature_id": "skr", "start_point_id": "a1", "end_point_id": "a2", "construction": True},
        {"local_id": "r1", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 0, "y": 106},
        {"local_id": "r2", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 15, "y": 106},
        {"local_id": "r3", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 15, "y": 110},
        {"local_id": "r4", "kind": "sketch_point", "sketch_feature_id": "skr", "x": 0, "y": 110},
        {"local_id": "rr", "kind": "sketch_rectangle", "sketch_feature_id": "skr", "corner_point_ids": ["r1", "r2", "r3", "r4"]},
        {"local_id": "rv", "kind": "revolve", "sketch_feature_id": "skr", "axis_ref": "axis", "angle": 360, "mode": "boss"},
    ]
    return {"version": 1, "steps": steps}


def test_extrude_revolve_and_sweep_steps_all_use_the_cached_path(monkeypatch):
    seen: dict[str, list[frozenset]] = {"ai_plan": [], "sweep": [], "revolve": [], "extrude": []}
    for name, module in (("ai_plan", ai_plan), ("sweep", sweep), ("revolve", revolve), ("extrude", extrude)):
        real = module.compute_part_bodies

        def spy(part, excluded=frozenset(), _real=real, _name=name):
            seen[_name].append(excluded)
            return _real(part, excluded)

        monkeypatch.setattr(module, "compute_part_bodies", spy)

    _part_id, results = _validate(_mixed_plan())
    assert all(r["ok"] for r in results), [r for r in results if not r["ok"]]
    for name in ("ai_plan", "sweep", "revolve"):
        assert seen[name], f"{name} never computed bodies - the plan no longer exercises it"
    # (`extrude` itself legitimately uses exclusion sets when it resolves a tool shape or a rollback; only the validator's own steps are pinned)
    for name in ("ai_plan", "sweep", "revolve"):
        assert all(not excluded for excluded in seen[name]), (name, [sorted(e) for e in seen[name] if e])


def test_validating_sweeps_and_a_revolve_records_no_edge_provenance():
    """The non-empty self-exclusion the resolvers get is also what keeps a validation out of the provenance cache (`_record_feature_edge_provenance`:
    'a create/update entry point's own self-exclusion validation must never overwrite this cache's real current state'). Only the bodies
    computation may use the cache; the sweep and revolve resolvers must not start recording for Features that were only validated. (The
    extrude validator step has always recorded - it passes an empty set to resolve_feature_tool_shape - so no extrude is in this plan.)"""
    extrude.clear_feature_edge_provenance_cache()
    part_id, results = _validate(_mixed_plan(with_extrude=False))
    assert all(r["ok"] for r in results)
    assert extrude._feature_edge_provenance_cache.get(part_id, {}) == {}, "validation recorded provenance for features that were never created"


def _volume(bodies: dict) -> float:
    total = 0.0
    for shape in bodies.values():
        props = GProp_GProps()
        brepgprop.VolumeProperties(shape, props)
        total += props.Mass()
    return round(total, 6)


def test_cached_bodies_equal_uncached_bodies_even_when_a_sketch_is_edited_mid_plan(monkeypatch):
    """The cache fingerprints each Feature together with the content of every Sketch it references, so a plan that adds geometry to a Sketch
    an earlier extrude already used must not be answered from the Bodies built before the edit."""
    compared: list[tuple[float, float]] = []
    real = ai_plan.compute_part_bodies

    def spy(part, excluded=frozenset()):
        cached = real(part, excluded)
        if not excluded:
            uncached = real(part, frozenset({"__never_a_feature__"}))  # a non-empty set always takes the from-scratch path
            compared.append((_volume(cached), _volume(uncached)))
        return cached

    monkeypatch.setattr(ai_plan, "compute_part_bodies", spy)
    steps = [
        {"local_id": "sk", "kind": "sketch", "plane": "XY"},
        {"local_id": "p1", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 0, "y": 0},
        {"local_id": "p2", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 10, "y": 0},
        {"local_id": "p3", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 10, "y": 10},
        {"local_id": "p4", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 0, "y": 10},
        {"local_id": "r", "kind": "sketch_rectangle", "sketch_feature_id": "sk", "corner_point_ids": ["p1", "p2", "p3", "p4"]},
        {"local_id": "x1", "kind": "extrude", "sketch_feature_id": "sk", "extrude_type": "boss", "start_distance": 0, "end_distance": 5},
        # the edit: a second, separate rectangle in the SAME Sketch x1 already used, then two more extrudes that replay the history
        {"local_id": "q1", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 20, "y": 0},
        {"local_id": "q2", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 40, "y": 0},
        {"local_id": "q3", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 40, "y": 20},
        {"local_id": "q4", "kind": "sketch_point", "sketch_feature_id": "sk", "x": 20, "y": 20},
        {"local_id": "r2", "kind": "sketch_rectangle", "sketch_feature_id": "sk", "corner_point_ids": ["q1", "q2", "q3", "q4"]},
        {"local_id": "x2", "kind": "extrude", "sketch_feature_id": "sk", "extrude_type": "boss", "start_distance": 0, "end_distance": 3},
        {"local_id": "x3", "kind": "extrude", "sketch_feature_id": "sk", "extrude_type": "boss", "start_distance": 10, "end_distance": 12},
    ]
    _part_id, results = _validate({"version": 1, "steps": steps})
    assert all(r["ok"] for r in results), [r for r in results if not r["ok"]]
    assert len(compared) >= 3
    assert all(c == u for c, u in compared), compared
