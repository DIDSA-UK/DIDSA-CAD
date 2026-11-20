"""Parity follow-ups F4 / C8: the answers the real solver gives to a redundant or contradicting constraint, pinned.

Both apps decide whether to take a just-made constraint back from `solve-and-refresh`'s flags (`converged`, `solver_reported_failed_constraint_ids`): the
VR sketcher (`SketchSession._taken_back`) and the flat app (`SketchController`'s take-back). They keep a constraint that is redundant but consistent; after a
converged sketch they take back any constraint that stops it converging; on a sketch that was already not converged they take one back only when the failed
list names it. So a change in py-slvs or in `solver.py` that moves `converged` or drops the new constraint from the failed list must show up here first.

Each case after a `solve-and-refresh`, as seen in CI (py-slvs 1.0.6's prebuilt wheel for each architecture; arm64 is the Pi 5 server's), 2026-11-19/20:

| Case | converged | result_code amd64 / arm64 | failed ids amd64 / arm64 |
|---|---|---|---|
| a second Horizontal on the same line | true | 0 / 0 | [] / [] |
| the same distance twice (two free points) | true | 5 / 1 | [] / [] |
| Horizontal + horizontal distance + aligned distance of the same length | true | 5, once 1 / 5 | [] / [] |
| distance 10, then 12 between the same points | false | 1 / 1 | [the 12] / [the 10, the 12] |

`result_code` is py-slvs's: 0 okay, 1 inconsistent, 5 "redundant, okay" (the solve converged with a redundant equation). Neither app reads it. Its verdict
on a redundant equation is not stable: arm64 gave 1 for the duplicate distance in every run, and amd64 gave 1 once for the Horizontal triple (PR #386's
pull_request run, 44725693905) where it gave 5 in seven other runs of the same code (`solver.py`'s residual check reports both converged either way).
arm64's failed list also names every constraint of the conflict, not only the newest. Why is not known: an amd64 machine with the same wheels (cp311 and
cp313) gave the table's amd64 answers in every one of over 2 000 solves (repeated, in fresh processes, after larger solves, through the routes). So no
redundant case pins a code (the stable 0 and 1 stay pinned), and the contradiction's failed list must name the 12 and nothing outside the conflict. The DOF
the solver reports for the duplicate-distance case is not pinned: it was seen to fall below the true figure (3 to 1) once, which is the solver's own count
with a redundant row.
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

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
    # No result_code: 5 on amd64, 1 on arm64 (see the module docstring). Both apps read only these two.
    assert solve["converged"] is True
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
    # No result_code: 5 in all but one run, 1 once on amd64 (see the module docstring). Both apps read only these two.
    assert solve["converged"] is True
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
    failed = solve["solver_reported_failed_constraint_ids"]
    # amd64 names only the 12; arm64 names the 10 as well (see the module docstring). Both name the new one, which is what the take-back reads.
    assert twelve in failed
    assert set(failed) <= {ten, twelve}
