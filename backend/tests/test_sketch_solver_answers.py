"""The take-back contract: what `solve-and-refresh` must say for both apps to keep or take back a just-made constraint correctly.

Both sketchers decide from two fields of the solve, never from py-slvs's raw `result_code`:

- VR: `SketchSession._taken_back` (DIDSA-VR `scripts/design_table/sketch_session.gd`).
- Flat app: the take-back in `SketchController` (`client/lib/sketch/sketch_controller.dart`, the `wasConverged` rule).

The rule in both:

1. If the solve converged, the constraint is kept.
2. If the sketch had converged before the constraint was added and no longer does, it is taken back.
3. If the sketch was already not converged (a conflict the user kept), the constraint is kept unless
   `solver_reported_failed_constraint_ids` names it.

So the backend owes the apps four answers, one test each below:

- A redundant but consistent constraint converges and names nothing (kept).
- A contradiction added to a converged sketch does not converge and names the new constraint (taken back).
- While a conflict is kept, a constraint on unrelated geometry is not named (kept), and a further contradiction is (taken back).
- Deleting the refused constraint, which is what a take-back does, leaves the sketch converged again.

Nothing here pins `result_code` or the whole failed list: py-slvs gives different codes for the same redundant sketch on amd64 and arm64,
and once on amd64 between two runs of the same code; arm64 also names every constraint of a conflict where amd64 names only the newest
(DIDSA-CAD `docs/status.md`, 2026-11-20). The redundant cases converge only because `solver.py`'s own checks accept what py-slvs reports
as code 1 or 5, so these tests also guard those checks. Every test runs on both CI architectures; arm64 is the Pi 5 server's.
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _sketch() -> str:
    return client.post("/sketch/sketches", json={"plane": "XY"}).json()["id"]


def _point(sketch_id: str, x: float, y: float) -> str:
    return client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()["id"]


def _line(sketch_id: str, a: str, b: str) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b})
    assert response.status_code == 201, response.text
    return response.json()["id"]


def _add(sketch_id: str, **body) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/constraints", json=body)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def _delete(sketch_id: str, constraint_id: str) -> None:
    response = client.delete(f"/sketch/sketches/{sketch_id}/constraints/{constraint_id}")
    assert response.status_code == 204, response.text


def _solve(sketch_id: str) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/solve-and-refresh")
    assert response.status_code == 200, response.text
    return response.json()["solve"]


def _failed(solve: dict) -> list[str]:
    return solve["solver_reported_failed_constraint_ids"]


# Each builds a sketch that converges, then returns (sketch id, the body of a constraint that restates what is already there).
def _second_horizontal():
    sketch_id = _sketch()
    line = _line(sketch_id, _point(sketch_id, 0, 0), _point(sketch_id, 10, 0.5))
    _add(sketch_id, type="horizontal", line_id=line)
    return sketch_id, {"type": "horizontal", "line_id": line}


def _same_distance_twice():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 3)
    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    return sketch_id, {"type": "distance", "point_a_id": a, "point_b_id": b, "distance": 10}


def _aligned_distance_over_horizontal_and_horizontal_distance():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0)
    line = _line(sketch_id, a, b)
    _add(sketch_id, type="horizontal", line_id=line)
    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10, orientation="horizontal")
    return sketch_id, {"type": "distance", "point_a_id": a, "point_b_id": b, "distance": 10}


@pytest.mark.parametrize(
    "build",
    [_second_horizontal, _same_distance_twice, _aligned_distance_over_horizontal_and_horizontal_distance],
    ids=["second-horizontal", "same-distance-twice", "aligned-over-horizontal-and-horizontal-distance"],
)
def test_a_redundant_but_consistent_constraint_converges_and_is_not_named(build):
    sketch_id, restatement = build()
    assert _solve(sketch_id)["converged"] is True

    _add(sketch_id, **restatement)
    solve = _solve(sketch_id)
    assert solve["converged"] is True, "rule 1: a redundant but consistent constraint must be kept"
    assert _failed(solve) == []


def _converged_ten(sketch_id: str) -> tuple[str, str, str]:
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 3)
    ten = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    assert _solve(sketch_id)["converged"] is True
    return a, b, ten


def test_a_contradiction_added_to_a_converged_sketch_does_not_converge_and_names_the_new_constraint():
    sketch_id = _sketch()
    a, b, _ten = _converged_ten(sketch_id)

    twelve = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=12)
    solve = _solve(sketch_id)
    assert solve["converged"] is False, "rule 2: the contradiction must be taken back"
    assert twelve in _failed(solve)


def _kept_conflict() -> tuple[str, str, str, str]:
    """A sketch holding a conflict the user kept (10 and 12 between the same two points), plus a separate line with no constraints."""
    sketch_id = _sketch()
    a, b, _ten = _converged_ten(sketch_id)
    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=12)
    c, d = _point(sketch_id, 30, 0), _point(sketch_id, 40, 2)
    unrelated_line = _line(sketch_id, c, d)
    assert _solve(sketch_id)["converged"] is False
    return sketch_id, a, b, unrelated_line


def test_while_a_conflict_is_kept_a_constraint_on_unrelated_geometry_is_not_named():
    sketch_id, _a, _b, unrelated_line = _kept_conflict()

    horizontal = _add(sketch_id, type="horizontal", line_id=unrelated_line)
    solve = _solve(sketch_id)
    assert solve["converged"] is False
    assert horizontal not in _failed(solve), "rule 3: an unrelated constraint must be kept while a conflict is"


def test_while_a_conflict_is_kept_a_further_contradiction_is_named():
    sketch_id, a, b, _unrelated_line = _kept_conflict()

    fifteen = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=15)
    solve = _solve(sketch_id)
    assert solve["converged"] is False
    assert fifteen in _failed(solve), "rule 3: a further contradiction must be taken back"


def test_taking_back_the_contradiction_leaves_the_sketch_converged():
    sketch_id = _sketch()
    a, b, _ten = _converged_ten(sketch_id)
    twelve = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=12)
    assert _solve(sketch_id)["converged"] is False

    _delete(sketch_id, twelve)
    solve = _solve(sketch_id)
    assert solve["converged"] is True
    assert _failed(solve) == []
