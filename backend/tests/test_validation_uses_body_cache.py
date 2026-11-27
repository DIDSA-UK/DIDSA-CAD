"""AI plan validation must not rebuild a Part's whole history for every solid step.

Validating a plan used to pass `frozenset({feature_id})` to `compute_part_bodies` for each extrude/sweep/revolve/loft step. Any non-empty
exclusion set takes the uncached path, and the Feature being validated was not even in the Part yet, so the exclusion changed nothing: N sweeps
cost N(N+1)/2 sweep builds (a 13-wire harness took 6.4 s, the last sweep alone 0.86 s against 0.09 s for the first). These tests pin the fix:
`excluded_with_own_id` only adds the id of a Feature that is really in the Part, and a plan's solid steps never reach `compute_part_bodies`
with a non-empty exclusion set. The helper tests need no pythonocc; the plan test does."""

from fastapi.testclient import TestClient

from app.document import ai_plan, sweep
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
