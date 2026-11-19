"""Parity follow-ups F4 / C8: the four answers the real solver gives to a redundant or contradicting constraint, pinned.

Both apps decide whether to take a just-made constraint back from `solve-and-refresh`'s flags (`converged`, `solver_reported_failed_constraint_ids`): the
VR sketcher (`SketchSession._taken_back`) and the flat app (`SketchController`'s take-back). They keep a constraint that is redundant but consistent, and take
back one the solver names as failed. That depends on these answers, so a change in py-slvs or in `solver.py` that moves one of them must show up here first.

Measured 2026-11-19 against the real solver (a local backend from `main`), each case after a `solve-and-refresh`:

| Case | converged | result_code | failed ids |
|---|---|---|---|
| a second Horizontal on the same line | true | 0 | [] |
| the same distance twice (two free points) | true | 5 | [] |
| Horizontal + horizontal distance + aligned distance of the same length | true | 5 | [] |
| distance 10, then 12 between the same points | false | 1 | [the 12] |

`result_code` is py-slvs's: 0 okay, 1 inconsistent, 5 "redundant, okay" (the solve converged with a redundant equation). The DOF the solver reports for the
duplicate-distance case is not pinned: it was seen to fall below the true figure (3 to 1) once, which is the solver's own count with a redundant row.
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

REDUNDANT_OKAY = 5
INCONSISTENT = 1


def _sketch() -> str:
    return client.post("/sketch/sketches", json={"plane": "XY"}).json()["id"]


def _point(sketch_id: str, x: float, y: float) -> str:
    return client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()["id"]


def _add(sketch_id: str, **body) -> str:
    response = client.post(f"/sketch/sketches/{sketch_id}/constraints", json=body)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def _solve(sketch_id: str) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/solve-and-refresh")
    assert response.status_code == 200, response.text
    return response.json()["solve"]


def test_a_second_horizontal_on_the_same_line_converges_and_names_nothing():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0.5)
    line = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b}).json()["id"]
    _add(sketch_id, type="horizontal", line_id=line)
    first = _solve(sketch_id)
    assert first["converged"] is True and first["solver_reported_failed_constraint_ids"] == []

    _add(sketch_id, type="horizontal", line_id=line)
    solve = _solve(sketch_id)
    assert solve["converged"] is True
    assert solve["result_code"] == 0
    assert solve["solver_reported_failed_constraint_ids"] == []


def test_the_same_distance_twice_is_redundant_but_consistent():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 3)
    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    assert _solve(sketch_id)["converged"] is True

    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    solve = _solve(sketch_id)
    assert solve["converged"] is True
    assert solve["result_code"] == REDUNDANT_OKAY
    assert solve["solver_reported_failed_constraint_ids"] == []


def test_horizontal_plus_horizontal_distance_plus_aligned_distance_of_one_length_is_redundant_but_consistent():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 0)
    line = client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b}).json()["id"]
    _add(sketch_id, type="horizontal", line_id=line)
    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10, orientation="horizontal")
    assert _solve(sketch_id)["converged"] is True

    _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    solve = _solve(sketch_id)
    assert solve["converged"] is True
    assert solve["result_code"] == REDUNDANT_OKAY
    assert solve["solver_reported_failed_constraint_ids"] == []


def test_a_contradicting_distance_fails_and_the_failed_list_names_it():
    sketch_id = _sketch()
    a, b = _point(sketch_id, 0, 0), _point(sketch_id, 10, 3)
    ten = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=10)
    assert _solve(sketch_id)["converged"] is True

    twelve = _add(sketch_id, type="distance", point_a_id=a, point_b_id=b, distance=12)
    solve = _solve(sketch_id)
    assert solve["converged"] is False
    assert solve["result_code"] == INCONSISTENT
    assert solve["solver_reported_failed_constraint_ids"] == [twelve]
    assert ten not in solve["solver_reported_failed_constraint_ids"]
