from app.sketch.models import Plane, Sketch
from app.sketch.profile import ProfileStatus, detect_profile


def _square_sketch() -> tuple[Sketch, dict]:
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    d = sketch.add_point(0.0, 10.0)
    points = {"a": a, "b": b, "c": c, "d": d}
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    sketch.add_line(c.id, d.id)
    sketch.add_line(d.id, a.id)
    return sketch, points


def _add_square_loop(
    sketch: Sketch, x0: float, y0: float, size: float, *, construction: bool = False
) -> None:
    """Draws a closed `size` x `size` square, bottom-left at (x0, y0), as
    four Lines - the shared helper every C1/C2 nesting test below builds
    its outer/inner/disjoint loops out of."""
    corners = [
        sketch.add_point(x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        sketch.add_line(a.id, b.id, construction=construction)


def test_empty_sketch_has_no_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    result = detect_profile(sketch)
    assert result.status == ProfileStatus.NO_LOOP


def test_valid_closed_loop_is_detected():
    sketch, points = _square_sketch()

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert set(result.profile.point_ids) == {p.id for p in points.values()}
    assert len(result.profile.line_ids) == 4
    assert len(result.profile.point_ids) == 4


def test_open_chain_is_not_a_closed_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(10.0, 0.0)
    c = sketch.add_point(10.0, 10.0)
    sketch.add_line(a.id, b.id)
    sketch.add_line(b.id, c.id)
    # No line closing c back to a - this is an open 3-point chain.

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP


def test_branch_point_is_detected():
    """A T-junction: a point used as an endpoint by three lines."""
    sketch = Sketch(id="s", plane=Plane.XY)
    centre = sketch.add_point(0.0, 0.0)
    a = sketch.add_point(10.0, 0.0)
    b = sketch.add_point(-10.0, 0.0)
    c = sketch.add_point(0.0, 10.0)
    sketch.add_line(centre.id, a.id)
    sketch.add_line(centre.id, b.id)
    sketch.add_line(centre.id, c.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.BRANCH
    assert result.branch_point_ids == [centre.id]


def test_multiple_disjoint_loops_are_detected():
    sketch, _ = _square_sketch()
    # A second, independent triangle in the same sketch.
    p = sketch.add_point(100.0, 0.0)
    q = sketch.add_point(110.0, 0.0)
    r = sketch.add_point(105.0, 10.0)
    sketch.add_line(p.id, q.id)
    sketch.add_line(q.id, r.id)
    sketch.add_line(r.id, p.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2
    loop_sizes = sorted(len(loop.point_ids) for loop in result.loops)
    assert loop_sizes == [3, 4]


def test_sketches_with_only_unconnected_lines_have_no_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    a = sketch.add_point(0.0, 0.0)
    b = sketch.add_point(1.0, 1.0)
    sketch.add_line(a.id, b.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.NO_LOOP


def test_profile_detection_over_the_api():
    from fastapi.testclient import TestClient

    from app.main import app
    from tests.conftest import TEST_API_KEY

    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()
    points = [
        client.post(f"/sketch/sketches/{sketch['id']}/points", json={"x": x, "y": y}).json()
        for x, y in [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    ]
    for start, end in zip(points, points[1:] + points[:1]):
        client.post(
            f"/sketch/sketches/{sketch['id']}/lines",
            json={"start_point_id": start["id"], "end_point_id": end["id"]},
        )

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["point_ids"]) == 4


# --- C1: nested profiles (a hole in a plate) --------------------------------


def test_a_smaller_square_inside_a_bigger_one_is_a_hole_not_two_loops():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    _add_square_loop(sketch, 5.0, 5.0, 5.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.point_ids) == 4
    assert len(result.profile.inner_loops) == 1
    assert len(result.profile.inner_loops[0].point_ids) == 4


def test_a_circle_inside_a_square_is_a_hole():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    center = sketch.add_point(10.0, 10.0)
    sketch.add_circle(center.id, radius=3.0, angle=0.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.inner_loops) == 1


def test_inner_loop_sharing_a_whole_edge_with_the_outer_loop_is_rejected():
    """On-device bug: a "hole" flush against one side of its container
    (sharing that whole edge, not just overlapping) has its centroid
    clearly inside the outer loop, so the centroid test alone would call
    it a valid hole - _loop_fully_contains's segment-intersection check is
    what actually catches this."""
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    _add_square_loop(sketch, 5.0, 0.0, 5.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.OVERLAPPING_LOOPS


def test_inner_loop_touching_the_outer_loop_at_a_single_corner_is_rejected():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    _add_square_loop(sketch, 10.0, 10.0, 10.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.OVERLAPPING_LOOPS


def test_construction_only_inner_loop_is_ignored():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    _add_square_loop(sketch, 5.0, 5.0, 5.0, construction=True)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert result.profile.inner_loops == []


def test_hole_inside_a_hole_is_rejected_as_invalid_nesting():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 30.0)
    _add_square_loop(sketch, 5.0, 5.0, 20.0)
    _add_square_loop(sketch, 10.0, 10.0, 5.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.INVALID_NESTING


def test_nested_profile_over_the_api_includes_inner_loops():
    from fastapi.testclient import TestClient

    from app.main import app
    from tests.conftest import TEST_API_KEY

    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}).json()

    def _square(x0, y0, size):
        points = [
            client.post(f"/sketch/sketches/{sketch['id']}/points", json={"x": x, "y": y}).json()
            for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
        ]
        for a, b in zip(points, points[1:] + points[:1]):
            client.post(
                f"/sketch/sketches/{sketch['id']}/lines",
                json={"start_point_id": a["id"], "end_point_id": b["id"]},
            )

    _square(0.0, 0.0, 20.0)
    _square(5.0, 5.0, 5.0)

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "closed_loop"
    assert len(body["profile"]["inner_loops"]) == 1


# --- C2: multiple disjoint closed profiles (MultiProfile) -------------------


def test_two_disjoint_rectangles_are_a_multi_profile():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 10.0)
    _add_square_loop(sketch, 100.0, 0.0, 10.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2
    assert all(loop.inner_loops == [] for loop in result.loops)


def test_multi_profile_sub_profile_can_have_its_own_hole():
    sketch = Sketch(id="s", plane=Plane.XY)
    _add_square_loop(sketch, 0.0, 0.0, 20.0)
    _add_square_loop(sketch, 5.0, 5.0, 5.0)
    _add_square_loop(sketch, 100.0, 0.0, 10.0)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 2
    holed = next(loop for loop in result.loops if loop.inner_loops)
    plain = next(loop for loop in result.loops if not loop.inner_loops)
    assert len(holed.inner_loops) == 1
    assert plain is not holed
