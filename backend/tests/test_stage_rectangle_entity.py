import math

import pytest
from fastapi.testclient import TestClient

from app.document.native_format import _entity_from_dict, _entity_to_dict
from app.main import app
from app.sketch.models import Plane, Rectangle, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _make_corners(sketch: Sketch) -> list[str]:
    corner0 = sketch.add_point(0.0, 0.0)
    corner1 = sketch.add_point(10.0, 0.0)
    corner2 = sketch.add_point(10.0, 5.0)
    corner3 = sketch.add_point(0.0, 5.0)
    return [corner0.id, corner1.id, corner2.id, corner3.id]


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_rectangle_axis_aligned_creates_the_full_constraint_chain_atomically():
    """4 edge Lines, 2 diagonal construction Lines, 1 real centre Point, 4
    axis (Horizontal/Vertical) constraints, 1 AtMidpointConstraint (on
    just the first diagonal) - see the Rectangle class docstring for why
    each exists."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    points_before = len(sketch.points)

    rectangle = sketch.add_rectangle(corner_ids)

    assert isinstance(rectangle, Rectangle)
    assert rectangle.axis_aligned is True
    assert rectangle.corner_point_ids == corner_ids
    assert len(rectangle.line_ids) == 4
    assert len(rectangle.axis_constraint_ids) == 4
    assert rectangle.center_point_id is not None
    assert rectangle.diagonal_line_id is not None
    assert rectangle.diagonal2_line_id is not None
    assert rectangle.diagonal_line_id != rectangle.diagonal2_line_id
    assert rectangle.midpoint_constraint_id in sketch.constraints
    assert len(sketch.points) == points_before + 1, "only the new centre Point"
    center = sketch.points[rectangle.center_point_id]
    assert center.x == pytest.approx(5.0)
    assert center.y == pytest.approx(2.5)


def test_add_rectangle_free_has_no_centre_point_and_uses_perpendicular_constraints():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    points_before = len(sketch.points)

    rectangle = sketch.add_rectangle(corner_ids, axis_aligned=False)

    assert rectangle.axis_aligned is False
    assert rectangle.center_point_id is None
    assert rectangle.diagonal_line_id is None
    assert rectangle.diagonal2_line_id is None
    assert rectangle.midpoint_constraint_id is None
    assert len(rectangle.axis_constraint_ids) == 3
    assert len(sketch.points) == points_before, "no new Points for the free/rotated chain"


def test_add_rectangle_rejects_fewer_or_more_than_4_corners():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    with pytest.raises(ValueError):
        sketch.add_rectangle(corner_ids[:3])


def test_add_rectangle_rejects_duplicate_corners():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    corner_ids[1] = corner_ids[0]
    with pytest.raises(ValueError):
        sketch.add_rectangle(corner_ids)


def test_add_rectangle_rejects_an_unknown_corner_point_id():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    corner_ids[2] = "does-not-exist"
    with pytest.raises(KeyError):
        sketch.add_rectangle(corner_ids)


def test_delete_rectangle_removes_its_own_lines_and_constraints_and_prunes_orphaned_corners():
    """Mirrors `Sketch._prune_orphaned_points`'s own contract (see
    `delete_polygon`/`delete_slot`): every corner/centre Point this
    Rectangle referenced is removed too, once deleting the Rectangle
    itself (and its Lines/constraints) leaves nothing else referencing
    them - except a corner still shared with unrelated geometry, which
    survives exactly like any other still-referenced Point would."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    # An unrelated Line sharing corner0 - the only Point that should
    # survive the Rectangle's own deletion below.
    other_point = sketch.add_point(20.0, 20.0)
    sketch.add_line(corner_ids[0], other_point.id)
    rectangle = sketch.add_rectangle(corner_ids)

    sketch.delete_rectangle(rectangle.id)

    assert rectangle.id not in sketch.entities
    for line_id in rectangle.line_ids:
        assert line_id not in sketch.entities
    assert rectangle.diagonal_line_id not in sketch.entities
    assert rectangle.diagonal2_line_id not in sketch.entities
    assert sketch.constraints == {}
    assert corner_ids[0] in sketch.points, "still referenced by the unrelated Line"
    for orphaned_corner_id in corner_ids[1:]:
        assert orphaned_corner_id not in sketch.points
    assert rectangle.center_point_id not in sketch.points


def test_delete_rectangle_line_already_gone_is_a_silent_no_op():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    rectangle = sketch.add_rectangle(corner_ids)
    sketch.delete_line(rectangle.line_ids[0])

    sketch.delete_rectangle(rectangle.id)  # must not raise

    assert rectangle.id not in sketch.entities


def test_point_deletion_is_blocked_while_referenced_by_a_rectangle():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    rectangle = sketch.add_rectangle(corner_ids)

    with pytest.raises(ValueError):
        sketch.delete_point(corner_ids[0])
    with pytest.raises(ValueError):
        sketch.delete_point(rectangle.center_point_id)


def test_rectangle_native_format_round_trip_preserves_every_field():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    rectangle = sketch.add_rectangle(corner_ids, construction=True)

    round_tripped = _entity_from_dict(_entity_to_dict(rectangle))

    assert isinstance(round_tripped, Rectangle)
    assert round_tripped == rectangle


def test_free_rectangle_native_format_round_trip_preserves_every_field():
    sketch = Sketch(id="s", plane=Plane.XY)
    corner_ids = _make_corners(sketch)
    rectangle = sketch.add_rectangle(corner_ids, axis_aligned=False)

    round_tripped = _entity_from_dict(_entity_to_dict(rectangle))

    assert isinstance(round_tripped, Rectangle)
    assert round_tripped == rectangle


# --- HTTP router tests --------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_corners(sketch_id: str) -> list[str]:
    return [
        _create_point(sketch_id, 0.0, 0.0)["id"],
        _create_point(sketch_id, 10.0, 0.0)["id"],
        _create_point(sketch_id, 10.0, 5.0)["id"],
        _create_point(sketch_id, 0.0, 5.0)["id"],
    ]


def test_create_rectangle_over_the_api():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "rectangle"
    assert body["corner_point_ids"] == corner_ids
    assert len(body["line_ids"]) == 4
    assert body["axis_aligned"] is True
    assert body["center_point_id"] is not None
    assert body["diagonal_line_id"] is not None
    assert body["diagonal2_line_id"] is not None
    assert body["construction"] is False


def test_create_rectangle_rejects_other_than_4_corners_over_the_api():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids[:3]},
    )

    assert response.status_code == 422


def test_create_rectangle_rejects_duplicate_corners_over_the_api():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])
    corner_ids[1] = corner_ids[0]

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids},
    )

    assert response.status_code == 400


def test_get_rectangle_not_found():
    sketch = _create_sketch()
    response = client.get(f"/sketch/sketches/{sketch['id']}/rectangles/does-not-exist")
    assert response.status_code == 404


def test_list_rectangles_returns_every_rectangle_in_the_sketch():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])
    rectangle = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids},
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/rectangles")

    assert response.status_code == 200
    assert [r["id"] for r in response.json()] == [rectangle["id"]]


def test_update_rectangle_construction_flag_over_the_api():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])
    rectangle = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids},
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/rectangles/{rectangle['id']}", json={"construction": True}
    )

    assert response.status_code == 200
    assert response.json()["construction"] is True


def test_delete_rectangle_over_the_api():
    sketch = _create_sketch()
    corner_ids = _create_corners(sketch["id"])
    rectangle = client.post(
        f"/sketch/sketches/{sketch['id']}/rectangles",
        json={"corner_point_ids": corner_ids},
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/rectangles/{rectangle['id']}")

    assert response.status_code == 200
    assert rectangle["center_point_id"] in response.json()["pruned_point_ids"]
    get_response = client.get(f"/sketch/sketches/{sketch['id']}/rectangles/{rectangle['id']}")
    assert get_response.status_code == 404
