import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.sketch.models import NoIntersectionFoundError, Plane, Sketch
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_extend_a_line_to_a_farther_line_moves_the_unshared_endpoint_in_place():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    a = sketch.add_point(15.0, -5.0)
    b = sketch.add_point(15.0, 5.0)
    sketch.add_line(a.id, b.id)

    result_line, moved_point, created_new_point = sketch.trim_or_extend_line(line.id, p1.id)

    assert created_new_point is False
    assert moved_point.id == p1.id, "unshared endpoint is moved in place, not replaced"
    assert moved_point.x == pytest.approx(15.0)
    assert moved_point.y == pytest.approx(0.0)
    assert result_line.end_point_id == p1.id


def test_trim_a_line_back_to_the_nearest_crossing_line():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    a = sketch.add_point(4.0, -5.0)
    b = sketch.add_point(4.0, 5.0)
    sketch.add_line(a.id, b.id)

    _, moved_point, created_new_point = sketch.trim_or_extend_line(line.id, p1.id)

    assert created_new_point is False
    assert moved_point.x == pytest.approx(4.0)
    assert moved_point.y == pytest.approx(0.0)


def test_nearest_candidate_wins_among_several_crossing_lines_on_either_side():
    """Trim/extend picks the crossing nearest the Line's *current* end,
    regardless of whether that candidate shortens (trim) or lengthens
    (extend) the Line - see `trim_or_extend_line`'s own doc comment for why
    this is a single, direction-agnostic search rather than two modes."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    for x in (2.0, 4.0, 12.0, 20.0):
        a = sketch.add_point(x, -5.0)
        b = sketch.add_point(x, 5.0)
        sketch.add_line(a.id, b.id)

    _, moved_point, _ = sketch.trim_or_extend_line(line.id, p1.id)

    assert moved_point.x == pytest.approx(12.0), "nearest to the current end (10.0), not the closest overall"


def test_trim_extend_against_a_circle():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    center = sketch.add_point(20.0, 0.0)
    sketch.add_circle(center.id, radius=5.0, angle=0.0)

    _, moved_point, _ = sketch.trim_or_extend_line(line.id, p1.id)

    assert moved_point.x == pytest.approx(15.0), "nearest circle crossing, the near edge at x=20-5"
    assert moved_point.y == pytest.approx(0.0)


def test_trim_extend_against_an_arc_respects_its_own_sweep():
    """A quarter-circle Arc from (25, 0) [angle 0] CCW to (20, 5) [angle 90]
    around center (20, 0) - the base Line's own extension crosses the full
    underlying circle at both (25, 0) and (15, 0), but only (25, 0) sits on
    the Arc's actual swept portion."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    center = sketch.add_point(20.0, 0.0)
    start = sketch.add_point(25.0, 0.0)
    sketch.add_arc(center.id, start.id, end_angle=math.pi / 2)

    _, moved_point, _ = sketch.trim_or_extend_line(line.id, p1.id)

    assert moved_point.x == pytest.approx(25.0)
    assert moved_point.y == pytest.approx(0.0)


def test_a_shared_endpoint_creates_a_fresh_point_leaving_the_original_untouched():
    """The moved endpoint is also the corner of an unrelated chain (shared
    with `other_line`) - moving it in place would silently drag that other
    Line too, so a fresh Point is created instead and only the trimmed
    Line's own end is repointed to it."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    corner = sketch.add_point(10.0, 10.0)
    other_line = sketch.add_line(p1.id, corner.id)
    a = sketch.add_point(15.0, -5.0)
    b = sketch.add_point(15.0, 5.0)
    sketch.add_line(a.id, b.id)

    result_line, moved_point, created_new_point = sketch.trim_or_extend_line(line.id, p1.id)

    assert created_new_point is True
    assert moved_point.id != p1.id
    assert moved_point.x == pytest.approx(15.0)
    assert result_line.end_point_id == moved_point.id
    original = sketch.points[p1.id]
    assert original.x == pytest.approx(10.0) and original.y == pytest.approx(0.0), "untouched"
    assert other_line.start_point_id == p1.id, "the other Line still points at the original corner"


def test_an_endpoint_constrained_by_a_dimension_also_creates_a_fresh_point():
    """A Point referenced only by a Constraint (not another entity) still
    counts as shared - any constraint reference is a conservative "don't
    move this in place" signal (see `_point_deletion_blocker`'s own doc
    comment on `exclude_entity_id`)."""
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    sketch.add_distance_constraint(p0.id, p1.id, 10.0)
    a = sketch.add_point(15.0, -5.0)
    b = sketch.add_point(15.0, 5.0)
    sketch.add_line(a.id, b.id)

    _, moved_point, created_new_point = sketch.trim_or_extend_line(line.id, p1.id)

    assert created_new_point is True


def test_the_sketch_origin_is_never_moved_in_place():
    sketch = Sketch(id="s", plane=Plane.XY)
    origin = sketch.origin_point()
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(origin.id, p1.id)
    a = sketch.add_point(-5.0, -5.0)
    b = sketch.add_point(-5.0, 5.0)
    sketch.add_line(a.id, b.id)

    _, moved_point, created_new_point = sketch.trim_or_extend_line(line.id, origin.id)

    assert created_new_point is True
    assert sketch.points[origin.id].x == pytest.approx(0.0)
    assert sketch.points[origin.id].y == pytest.approx(0.0)


def test_rejects_a_point_that_is_not_one_of_the_lines_own_endpoints():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    unrelated = sketch.add_point(50.0, 50.0)

    with pytest.raises(ValueError):
        sketch.trim_or_extend_line(line.id, unrelated.id)


def test_rejects_trimming_a_polygons_own_edge():
    sketch = Sketch(id="s", plane=Plane.XY)
    center = sketch.add_point(20.0, 20.0)
    first_vertex = sketch.add_point(30.0, 20.0)
    polygon = sketch.add_polygon(center.id, first_vertex.id, 5)
    edge_id = polygon.line_ids[2]
    edge = sketch.entities[edge_id]

    with pytest.raises(ValueError, match="polygon"):
        sketch.trim_or_extend_line(edge_id, edge.start_point_id)


def test_raises_a_distinct_error_type_when_nothing_to_trim_or_extend_to():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)

    with pytest.raises(NoIntersectionFoundError):
        sketch.trim_or_extend_line(line.id, p1.id)


def test_a_far_but_real_crossing_beyond_the_max_distance_is_not_a_valid_candidate():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(1.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    a = sketch.add_point(50000.0, -5.0)
    b = sketch.add_point(50000.0, 5.0)
    sketch.add_line(a.id, b.id)

    with pytest.raises(NoIntersectionFoundError):
        sketch.trim_or_extend_line(line.id, p1.id)


def test_a_line_parallel_to_every_other_entity_finds_nothing():
    sketch = Sketch(id="s", plane=Plane.XY)
    p0 = sketch.add_point(0.0, 0.0)
    p1 = sketch.add_point(10.0, 0.0)
    line = sketch.add_line(p0.id, p1.id)
    a = sketch.add_point(0.0, 5.0)
    b = sketch.add_point(10.0, 5.0)
    sketch.add_line(a.id, b.id)

    with pytest.raises(NoIntersectionFoundError):
        sketch.trim_or_extend_line(line.id, p1.id)


# --- HTTP router tests --------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _create_line(sketch_id: str, start_id: str, end_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_id, "end_point_id": end_id},
    )
    assert response.status_code == 201
    return response.json()


def test_trim_line_over_the_api():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)
    p1 = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], p0["id"], p1["id"])
    a = _create_point(sketch["id"], 4.0, -5.0)
    b = _create_point(sketch["id"], 4.0, 5.0)
    _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{line['id']}/trim",
        json={"moved_point_id": p1["id"]},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["created_new_point"] is False
    assert body["moved_point"]["id"] == p1["id"]
    assert body["moved_point"]["x"] == pytest.approx(4.0)
    assert body["line"]["end_point_id"] == p1["id"]


def test_trim_line_over_the_api_creates_a_new_point_for_a_shared_endpoint():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)
    p1 = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], p0["id"], p1["id"])
    corner = _create_point(sketch["id"], 10.0, 10.0)
    _create_line(sketch["id"], p1["id"], corner["id"])
    a = _create_point(sketch["id"], 4.0, -5.0)
    b = _create_point(sketch["id"], 4.0, 5.0)
    _create_line(sketch["id"], a["id"], b["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{line['id']}/trim",
        json={"moved_point_id": p1["id"]},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["created_new_point"] is True
    assert body["moved_point"]["id"] != p1["id"]
    assert body["line"]["end_point_id"] == body["moved_point"]["id"]

    points_response = client.get(f"/sketch/sketches/{sketch['id']}/points")
    assert any(p["id"] == p1["id"] and p["x"] == pytest.approx(10.0) for p in points_response.json())


def test_trim_line_not_found_over_the_api():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/does-not-exist/trim",
        json={"moved_point_id": p0["id"]},
    )

    assert response.status_code == 404


def test_trim_line_moved_point_not_found_over_the_api():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)
    p1 = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], p0["id"], p1["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{line['id']}/trim",
        json={"moved_point_id": "does-not-exist"},
    )

    assert response.status_code == 404


def test_trim_line_rejects_a_non_endpoint_point_over_the_api():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)
    p1 = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], p0["id"], p1["id"])
    unrelated = _create_point(sketch["id"], 50.0, 50.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{line['id']}/trim",
        json={"moved_point_id": unrelated["id"]},
    )

    assert response.status_code == 400


def test_trim_line_rejects_a_polygon_edge_over_the_api():
    sketch = _create_sketch()
    center = _create_point(sketch["id"], 20.0, 20.0)
    first_vertex = _create_point(sketch["id"], 30.0, 20.0)
    polygon_response = client.post(
        f"/sketch/sketches/{sketch['id']}/polygons",
        json={"center_point_id": center["id"], "first_vertex_point_id": first_vertex["id"], "sides": 5},
    )
    assert polygon_response.status_code == 201
    polygon = polygon_response.json()

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{polygon['line_ids'][0]}/trim",
        json={"moved_point_id": polygon["vertex_point_ids"][0]},
    )

    assert response.status_code == 400


def test_trim_line_no_intersection_found_over_the_api():
    sketch = _create_sketch()
    p0 = _create_point(sketch["id"], 0.0, 0.0)
    p1 = _create_point(sketch["id"], 10.0, 0.0)
    line = _create_line(sketch["id"], p0["id"], p1["id"])

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/lines/{line['id']}/trim",
        json={"moved_point_id": p1["id"]},
    )

    assert response.status_code == 422
