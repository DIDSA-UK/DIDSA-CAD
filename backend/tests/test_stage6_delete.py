import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import Plane, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_delete_line_prunes_a_now_orphaned_endpoint_but_leaves_one_still_shared():
    # Bug fix (pre-existing stale test - predates `_prune_orphaned_points`,
    # added later to auto-remove a deleted entity's own defining Points once
    # nothing else needs them; see that method's own doc comment): a Line's
    # endpoints no longer unconditionally survive its own deletion - only if
    # something else still references them. `a` stays shared with a second
    # Line here; `b` is genuinely orphaned once `line` is gone.
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    c = sketch.add_point(5.0, 5.0)
    line = sketch.add_line(a.id, b.id)
    sketch.add_line(a.id, c.id)

    sketch.delete_line(line.id)

    assert line.id not in sketch.entities
    assert a.id in sketch.points
    assert b.id not in sketch.points


def test_delete_line_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_line("does-not-exist")


def test_delete_circle_removes_its_radius_constraint_and_prunes_now_orphaned_points_but_leaves_a_still_shared_one():
    # Bug fix - see test_delete_line_prunes_a_now_orphaned_endpoint's own
    # comment: the centre/radius/cardinal Points no longer unconditionally
    # survive a Circle's own deletion. The centre stays shared with an
    # unrelated Line here; the radius Point is genuinely orphaned.
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)
    radius_point_id = circle.radius_point_id
    other = sketch.add_point(20.0, 20.0)
    sketch.add_line(center.id, other.id)
    assert circle.radius_constraint_id in sketch.constraints

    sketch.delete_circle(circle.id)

    assert circle.id not in sketch.entities
    assert circle.radius_constraint_id not in sketch.constraints
    assert center.id in sketch.points
    assert radius_point_id not in sketch.points


def test_delete_circle_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_circle("does-not-exist")


def test_delete_unreferenced_point_succeeds():
    sketch = Sketch(id="s", plane=Plane.XY)
    point = sketch.add_point(1.0, 1.0)

    sketch.delete_point(point.id)

    assert point.id not in sketch.points


def test_delete_point_with_unknown_id_raises_key_error():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_point("does-not-exist")


def test_delete_point_still_referenced_by_a_line_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    sketch.add_line(a.id, b.id)

    with pytest.raises(ValueError):
        sketch.delete_point(a.id)
    assert a.id in sketch.points


def test_delete_point_still_referenced_by_a_circles_center_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    sketch.add_circle(center.id, radius=5.0, angle=0.0)

    with pytest.raises(ValueError):
        sketch.delete_point(center.id)


def test_delete_point_still_referenced_by_a_circles_radius_point_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(0.0, 0.0)
    circle = sketch.add_circle(center.id, radius=5.0, angle=0.0)

    with pytest.raises(ValueError):
        sketch.delete_point(circle.radius_point_id)


def test_delete_point_referenced_by_a_distance_constraint_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(5.0, 0.0)
    sketch.add_distance_constraint(a.id, b.id, 5.0)

    with pytest.raises(ValueError):
        sketch.delete_point(a.id)
    with pytest.raises(ValueError):
        sketch.delete_point(b.id)


def test_delete_origin_point_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()

    with pytest.raises(ValueError):
        sketch.delete_point(origin.id)
    assert origin.id in sketch.points


def test_deleting_a_lines_last_remaining_reference_unblocks_its_former_endpoint():
    # Bug fix - see test_delete_line_prunes_a_now_orphaned_endpoint's own
    # comment. Original intent preserved (dependency-checking is live, not
    # cached): `a` survives deleting `line1` since `line2` still needs it,
    # then is auto-pruned the moment `line2` goes too - already gone by the
    # time an explicit delete would run, proving the check re-evaluates
    # fresh each time rather than trusting a stale "still referenced" verdict.
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(3.0, 4.0)
    c = sketch.add_point(5.0, 5.0)
    line1 = sketch.add_line(a.id, b.id)
    line2 = sketch.add_line(a.id, c.id)

    sketch.delete_line(line1.id)
    assert a.id in sketch.points

    sketch.delete_line(line2.id)
    assert a.id not in sketch.points

    with pytest.raises(KeyError):
        sketch.delete_point(a.id)


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_delete_line_over_the_api():
    # Bug fix (pre-existing stale test - predates `DeleteEntityResponse`,
    # which replaced a bare 204 with a 200 + `pruned_point_ids` body once
    # `Sketch.delete_line` started auto-pruning now-orphaned endpoints; see
    # that schema's own doc comment): `a` stays shared with a second Line to
    # prove it still survives when something else needs it; `b` is
    # genuinely orphaned and reported via `pruned_point_ids`.
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    c = _create_point(sketch["id"], 5.0, 5.0)
    line = client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    ).json()
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": c["id"]},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}")

    assert response.status_code == 200
    assert response.json()["pruned_point_ids"] == [b["id"]]
    assert client.get(f"/sketch/sketches/{sketch['id']}/lines/{line['id']}").status_code == 404
    # `a` still shared with the other Line; `b` was pruned above.
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").status_code == 200
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{b['id']}").status_code == 404


def test_delete_line_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/lines/does-not-exist")
    assert response.status_code == 404


def test_delete_circle_over_the_api():
    # Bug fix - see test_delete_line_over_the_api's own comment. The centre
    # stays shared with an unrelated Line to prove it survives; the radius
    # and cardinal Points are genuinely orphaned and reported via
    # `pruned_point_ids`.
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    other = _create_point(sketch["id"], 20.0, 20.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": center["id"], "end_point_id": other["id"]},
    )
    circle = client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 5.0, "angle": 0.0},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/circles/{circle['id']}")

    assert response.status_code == 200
    assert set(response.json()["pruned_point_ids"]) == {circle["radius_point_id"], *circle["cardinal_point_ids"]}
    assert client.get(f"/sketch/sketches/{sketch['id']}/circles/{circle['id']}").status_code == 404
    # The center point, still shared with the Line, survives.
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{center['id']}").status_code == 200


def test_delete_circle_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/circles/does-not-exist")
    assert response.status_code == 404


def test_delete_unreferenced_point_over_the_api():
    sketch = _create_sketch()
    point = _create_point(sketch["id"], 1.0, 1.0)

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{point['id']}")

    assert response.status_code == 204
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{point['id']}").status_code == 404


def test_delete_point_not_found_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/does-not-exist")
    assert response.status_code == 404


def test_delete_point_referenced_by_a_line_is_rejected_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 3.0, 4.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/lines",
        json={"start_point_id": a["id"], "end_point_id": b["id"]},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{a['id']}")

    assert response.status_code == 400
    assert "line" in response.json()["detail"].lower()
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{a['id']}").status_code == 200


def test_delete_point_referenced_by_a_circle_is_rejected_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 0.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/circles",
        json={"center_point_id": center["id"], "radius": 5.0, "angle": 0.0},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{center['id']}")

    assert response.status_code == 400
    assert "circle" in response.json()["detail"].lower()


def test_delete_point_referenced_by_a_constraint_is_rejected_over_the_api():
    sketch = _create_sketch()
    a = _create_point(sketch["id"], 0.0, 0.0)
    b = _create_point(sketch["id"], 5.0, 0.0)
    client.post(
        f"/sketch/sketches/{sketch['id']}/constraints",
        json={"point_a_id": a["id"], "point_b_id": b["id"], "distance": 5.0},
    )

    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{a['id']}")

    assert response.status_code == 400
    assert "constraint" in response.json()["detail"].lower()


def test_delete_origin_point_is_rejected_over_the_api():
    sketch = _create_sketch()
    response = client.delete(f"/sketch/sketches/{sketch['id']}/points/{sketch['origin_point_id']}")

    assert response.status_code == 400
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{sketch['origin_point_id']}").status_code == 200
