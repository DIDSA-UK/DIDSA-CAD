"""Curve features (Helix/Intersection curve), the NORMAL_TO_CURVE_FEATURE_AT_
PARAMETER plane type, and Fill Surface - real-OCCT tests for their full
router/HTTP surface, mirroring test_stage_h_sweep.py's own shape.

Covers the three "curves as valid targets" requirements directly:
- a Helix as a Sweep path (`test_sweep_along_helix`),
- a Helix as the curve source for a plane construction
  (`test_plane_normal_to_curve_feature_at_parameter`),
- Sketch lines as Fill Surface boundaries (`test_fill_surface_basic`).
"""

import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> list[dict]:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return lines


def _add_circle(sketch_id: str, center: dict, radius_point: dict) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius_point_id": radius_point["id"]},
    )
    assert response.status_code == 201
    return response.json()


def _create_helix(part_id: str, **overrides) -> dict:
    payload = {
        "curve_type": "helix",
        "axis_ref": {"fixed_plane": "XY"},
        "radius": 5.0,
        "segments": [{"pitch": 2.0, "turns": 3.0}],
        "right_handed": True,
    }
    payload.update(overrides)
    response = client.post(f"/document/parts/{part_id}/curve-features", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


# --- Helix ---------------------------------------------------------------


def _helix_wire(part_id: str, curve_id: str):
    """The resolved wire of a Curve feature, for checking its geometry directly."""
    from app.document.curve import resolve_curve
    from app.document.store import get_part_or_404

    part = get_part_or_404(part_id)
    return resolve_curve(part, part.get_feature(curve_id)).wire


def _point_at_fraction(part_id: str, curve_id: str, fraction: float):
    from app.document.curve import point_and_tangent_at_fraction, resolve_curve
    from app.document.store import get_part_or_404

    part = get_part_or_404(part_id)
    resolved = resolve_curve(part, part.get_feature(curve_id))
    point, tangent = point_and_tangent_at_fraction(resolved.wire, resolved.length, fraction)
    return (point.X(), point.Y(), point.Z()), (tangent.X(), tangent.Y(), tangent.Z())


def test_create_helix_curve_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    expected_length = math.sqrt((2 * math.pi * 5.0) ** 2 + 2.0**2) * 3.0
    assert curve["length"] == pytest.approx(expected_length, rel=1e-6)
    assert curve["closed"] is False
    assert curve["produces"] == "curve"
    assert curve["segments"] == [{"pitch": 2.0, "turns": 3.0}]
    assert curve["total_height"] == pytest.approx(6.0)
    assert curve["end_radius"] is None and curve["taper_angle_degrees"] is None


def test_constant_helix_starts_and_ends_where_the_old_construction_did():
    """The 7.9 construction started at angle 0 on the axis plane's x axis and wound counterclockwise
    while rising; the end is one `turns` later at the same angle, `pitch x turns` higher."""
    part = _create_part()
    curve = _create_helix(part["id"])
    start, start_tangent = _point_at_fraction(part["id"], curve["id"], 0.0)
    end, _ = _point_at_fraction(part["id"], curve["id"], 1.0)
    assert start == pytest.approx((5.0, 0.0, 0.0), abs=1e-4)
    assert end == pytest.approx((5.0, 0.0, 6.0), abs=1e-4)
    assert start_tangent[1] > 0 and start_tangent[2] > 0  # counterclockwise and rising


def test_helix_requires_positive_radius():
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "helix",
            "axis_ref": {"fixed_plane": "XY"},
            "radius": -1.0,
            "segments": [{"pitch": 2.0, "turns": 3.0}],
        },
    )
    assert response.status_code == 422


def test_helix_requires_nonzero_pitch_positive_turns_and_a_segment():
    part = _create_part()
    base = {"curve_type": "helix", "axis_ref": {"fixed_plane": "XY"}, "radius": 5.0}
    for segments in ([{"pitch": 0.0, "turns": 3.0}], [{"pitch": 2.0, "turns": 0.0}], [], [{"pitch": 2.0, "turns": 3.0}, {"pitch": -1.0, "turns": 1.0}]):
        response = client.post(f"/document/parts/{part['id']}/curve-features", json={**base, "segments": segments})
        assert response.status_code == 422, segments


def test_helix_left_handed_winds_opposite_direction():
    part = _create_part()
    right = _create_helix(part["id"], right_handed=True)
    left = _create_helix(part["id"], right_handed=False)
    assert right["length"] == pytest.approx(left["length"], rel=1e-9)
    (_, y_right, _) = _point_at_fraction(part["id"], right["id"], 0.01)[0]
    (_, y_left, _) = _point_at_fraction(part["id"], left["id"], 0.01)[0]
    assert y_right > 0 > y_left
    # Both start at the same point and end at the same height.
    assert _point_at_fraction(part["id"], left["id"], 0.0)[0] == pytest.approx((5.0, 0.0, 0.0), abs=1e-4)
    assert _point_at_fraction(part["id"], left["id"], 1.0)[0][2] == pytest.approx(6.0, abs=1e-4)


def test_negative_pitch_advances_the_other_way_along_the_axis():
    part = _create_part()
    down = _create_helix(part["id"], segments=[{"pitch": -2.0, "turns": 3.0}])
    start, tangent = _point_at_fraction(part["id"], down["id"], 0.0)
    end, _ = _point_at_fraction(part["id"], down["id"], 1.0)
    assert start == pytest.approx((5.0, 0.0, 0.0), abs=1e-4)
    assert end == pytest.approx((5.0, 0.0, -6.0), abs=1e-4)
    assert tangent[1] > 0 and tangent[2] < 0  # still counterclockwise, falling
    assert down["total_height"] == pytest.approx(-6.0)


def test_tapered_helix_by_end_radius_and_by_angle_are_the_same_curve():
    part = _create_part()
    by_radius = _create_helix(part["id"], end_radius=8.0)
    # Height 6, widening 3 mm: atan(3 / 6) degrees.
    angle = math.degrees(math.atan(3.0 / 6.0))
    by_angle = _create_helix(part["id"], taper_angle_degrees=angle)
    for curve in (by_radius, by_angle):
        assert curve["end_radius"] == pytest.approx(8.0)
        assert curve["taper_angle_degrees"] == pytest.approx(angle)
    assert by_angle["length"] == pytest.approx(by_radius["length"], rel=1e-9)
    end, _ = _point_at_fraction(part["id"], by_radius["id"], 1.0)
    assert math.hypot(end[0], end[1]) == pytest.approx(8.0, abs=1e-3)
    assert end[2] == pytest.approx(6.0, abs=1e-3)
    mid, _ = _point_at_fraction(part["id"], by_radius["id"], 0.5)
    assert math.hypot(mid[0], mid[1]) == pytest.approx(5.0 + 3.0 * mid[2] / 6.0, abs=0.05)  # radius grows with height


def test_a_taper_can_narrow_and_must_not_be_given_twice():
    part = _create_part()
    narrowing = _create_helix(part["id"], end_radius=2.0)
    assert narrowing["taper_angle_degrees"] < 0
    both = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={"curve_type": "helix", "axis_ref": {"fixed_plane": "XY"}, "radius": 5.0,
              "segments": [{"pitch": 2.0, "turns": 3.0}], "end_radius": 8.0, "taper_angle_degrees": 10.0},
    )
    assert both.status_code == 422
    too_far = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={"curve_type": "helix", "axis_ref": {"fixed_plane": "XY"}, "radius": 5.0,
              "segments": [{"pitch": 2.0, "turns": 3.0}], "end_radius": -1.0},
    )
    assert too_far.status_code == 422


def test_segments_give_the_right_height_and_pitch_each():
    """A spring with tight end coils: 2 turns at 2 mm, 3 turns at 6 mm, 2 turns at 2 mm = 26 mm."""
    part = _create_part()
    spring = _create_helix(
        part["id"],
        segments=[{"pitch": 2.0, "turns": 2.0}, {"pitch": 6.0, "turns": 3.0}, {"pitch": 2.0, "turns": 2.0}],
    )
    assert spring["total_height"] == pytest.approx(26.0)
    expected_length = sum(
        math.sqrt((2 * math.pi * 5.0) ** 2 + pitch**2) * turns for pitch, turns in ((2.0, 2.0), (6.0, 3.0), (2.0, 2.0))
    )
    assert spring["length"] == pytest.approx(expected_length, rel=1e-3)  # the builder approximates to ~2e-5 mm
    # The axis position at each segment boundary (by arc length, so compare against the heights).
    heights = []
    fractions = []
    travelled = 0.0
    for pitch, turns in ((2.0, 2.0), (6.0, 3.0), (2.0, 2.0)):
        travelled += math.sqrt((2 * math.pi * 5.0) ** 2 + pitch**2) * turns
        fractions.append(travelled / expected_length)
    for fraction, height in zip(fractions, (4.0, 22.0, 26.0)):
        heights.append((_point_at_fraction(part["id"], spring["id"], fraction)[0][2], height))
    for got, expected in heights:
        assert got == pytest.approx(expected, abs=1e-3)


def test_taper_runs_through_all_segments_by_height():
    part = _create_part()
    curve = _create_helix(
        part["id"],
        end_radius=9.0,
        segments=[{"pitch": 2.0, "turns": 2.0}, {"pitch": 6.0, "turns": 3.0}],
    )  # height 4 + 18 = 22; the radius is 5 + 4 * z / 22
    for fraction in (0.2, 0.5, 0.8, 1.0):
        (x, y, z), _ = _point_at_fraction(part["id"], curve["id"], fraction)
        assert math.hypot(x, y) == pytest.approx(5.0 + 4.0 * z / 22.0, abs=0.02)


def test_update_helix_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.patch(
        f"/document/parts/{part['id']}/curve-features/{curve['id']}", json={"segments": [{"pitch": 2.0, "turns": 5.0}]}
    )
    assert response.status_code == 200, response.text
    updated = response.json()
    expected_length = math.sqrt((2 * math.pi * 5.0) ** 2 + 2.0**2) * 5.0
    assert updated["length"] == pytest.approx(expected_length, rel=1e-6)


def test_update_can_add_and_clear_a_taper():
    part = _create_part()
    curve = _create_helix(part["id"])
    url = f"/document/parts/{part['id']}/curve-features/{curve['id']}"
    tapered = client.patch(url, json={"taper_angle_degrees": 10.0}).json()
    assert tapered["end_radius"] == pytest.approx(5.0 + 6.0 * math.tan(math.radians(10.0)))
    assert tapered["taper_angle_degrees"] == pytest.approx(10.0)
    kept = client.patch(url, json={"radius": 6.0}).json()  # omitted end_radius: kept as stored
    assert kept["end_radius"] == pytest.approx(tapered["end_radius"])
    cleared = client.patch(url, json={"end_radius": None}).json()
    assert cleared["end_radius"] is None and cleared["taper_angle_degrees"] is None


def test_helix_survives_the_native_round_trip():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native helix")
        curve = _create_helix(
            part["id"],
            end_radius=7.0,
            right_handed=False,
            segments=[{"pitch": 2.0, "turns": 1.0}, {"pitch": 4.0, "turns": 2.0}],
        )
        exported = client.get("/document/export/native").json()
        stored = next(f for p in exported["document"]["parts"] for f in p["features"] if f["id"] == curve["id"])
        assert stored["end_radius"] == 7.0
        assert stored["segments"] == [{"pitch": 2.0, "turns": 1.0}, {"pitch": 4.0, "turns": 2.0}]
        assert client.post("/document/import/native", json=exported).status_code == 200
        features = client.get(f"/document/parts/{part['id']}/features").json()
        again = next(f for f in features if f["id"] == curve["id"])
        assert again["segments"] == curve["segments"]
        assert again["end_radius"] == 7.0 and again["right_handed"] is False
        assert again["length"] == pytest.approx(curve["length"], rel=1e-9)
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_delete_curve_feature():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.delete(f"/document/parts/{part['id']}/features/{curve['id']}")
    assert response.status_code == 204


# --- Sweep along a Helix (curve as a Sweep path) ---------------------------


def test_sweep_along_helix():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    sketch_id = sketch_feature["sketch_id"]
    center = _add_point(sketch_id, 5.0, 0.0)
    radius_point = _add_point(sketch_id, 5.5, 0.0)
    _add_circle(sketch_id, center, radius_point)

    curve = _create_helix(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/sweep-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "path_refs": [{"curve_feature_id": curve["id"]}],
            "mode": "boss",
        },
    )
    assert response.status_code == 201, response.text

    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh.status_code == 200
    bodies = mesh.json()
    # Both the standalone Helix curve (registered for its own display, see
    # test_standalone_curve_feature_appears_in_mesh) and the swept solid
    # Body appear here - two entries, not one.
    assert len(bodies) == 2
    solid = next(b for b in bodies if not b["is_curve"])
    assert solid["is_surface"] is False
    assert len(solid["mesh"]["vertices"]) > 0


def test_sweep_a_circle_along_a_tapered_variable_pitch_helix_is_a_valid_solid_of_the_right_volume():
    """A 0.5 mm circle swept along a spring that widens and has tight end coils: `pi r^2 L` (Pappus,
    for a path whose curvature radius is far larger than the profile)."""
    from OCC.Core.BRepCheck import BRepCheck_Analyzer
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps

    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XZ")
    center = _add_point(sketch_feature["sketch_id"], -10.0, 0.0)  # XZ's local x runs opposite to world x: world (10, 0, 0)
    radius_point = _add_point(sketch_feature["sketch_id"], -10.5, 0.0)
    _add_circle(sketch_feature["sketch_id"], center, radius_point)
    curve = _create_helix(
        part["id"],
        radius=10.0,
        end_radius=14.0,
        segments=[{"pitch": 3.0, "turns": 1.0}, {"pitch": 8.0, "turns": 3.0}, {"pitch": 3.0, "turns": 1.0}],
    )
    response = client.post(
        f"/document/parts/{part['id']}/sweep-features",
        json={"sketch_feature_id": sketch_feature["id"], "path_refs": [{"curve_feature_id": curve["id"]}], "mode": "boss"},
    )
    assert response.status_code == 201, response.text
    solids = [shape for shape in compute_part_bodies(get_part_or_404(part["id"])).values() if shape.ShapeType() == 2]
    assert len(solids) == 1
    assert BRepCheck_Analyzer(solids[0]).IsValid()
    props = GProp_GProps()
    brepgprop.VolumeProperties(solids[0], props, 1e-6)
    assert props.Mass() == pytest.approx(math.pi * 0.5**2 * curve["length"], rel=0.02)


def test_standalone_curve_feature_appears_in_mesh():
    part = _create_part()
    curve = _create_helix(part["id"])
    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh.status_code == 200
    bodies = mesh.json()
    assert len(bodies) == 1
    assert bodies[0]["body_id"] == curve["id"]
    assert bodies[0]["is_curve"] is True
    assert bodies[0]["is_surface"] is False
    assert len(bodies[0]["mesh"]["edges"]) > 0


# --- Intersection curve ------------------------------------------------------


def test_intersection_curve_from_two_open_chains():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    a1 = _add_point(sketch_a["sketch_id"], -10, -10)
    a2 = _add_point(sketch_a["sketch_id"], 10, 10)
    _add_line(sketch_a["sketch_id"], a1["id"], a2["id"])

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    b1 = _add_point(sketch_b["sketch_id"], -10, -10)
    b2 = _add_point(sketch_b["sketch_id"], 10, 10)
    _add_line(sketch_b["sketch_id"], b1["id"], b2["id"])

    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    )
    assert response.status_code == 201, response.text
    curve = response.json()
    assert curve["length"] > 0
    assert curve["closed"] is False


def test_intersection_curve_requires_existing_sketch_features():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": "does-not-exist",
        },
    )
    assert response.status_code == 422


def test_intersection_curve_rejects_disjoint_result():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    _add_square(sketch_a["sketch_id"], -10, -10, 20)

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    _add_square(sketch_b["sketch_id"], -3, 2, 6)

    response = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "curve_construction_failed"


# --- Plane normal to a curve feature at a parameter -------------------------


def test_plane_normal_to_curve_feature_at_parameter():
    part = _create_part()
    curve = _create_helix(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_curve_feature_at_parameter",
            "curve_feature_id": curve["id"],
            "curve_parameter": 0.5,
        },
    )
    assert response.status_code == 201, response.text
    plane = response.json()
    assert plane["origin"] is not None
    radial = math.hypot(plane["origin"][0], plane["origin"][1])
    assert radial == pytest.approx(5.0, rel=1e-6)
    assert plane["origin"][2] == pytest.approx(3.0, rel=1e-6)
    normal = plane["normal"]
    magnitude = math.sqrt(sum(c**2 for c in normal))
    assert magnitude == pytest.approx(1.0, rel=1e-6)


def test_plane_normal_to_a_tapered_helix_at_half_its_length():
    part = _create_part()
    curve = _create_helix(part["id"], end_radius=9.0)
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={"plane_type": "normal_to_curve_feature_at_parameter", "curve_feature_id": curve["id"], "curve_parameter": 0.5},
    )
    assert response.status_code == 201, response.text
    plane = response.json()
    x, y, z = plane["origin"]
    # Half the arc length is a little past half the height (the wide end is longer per turn).
    assert 3.0 < z < 3.5
    assert math.hypot(x, y) == pytest.approx(5.0 + 4.0 * z / 6.0, abs=0.02)
    # The plane is normal to the tangent, which is unit and not horizontal or vertical.
    assert math.sqrt(sum(c**2 for c in plane["normal"])) == pytest.approx(1.0, rel=1e-6)
    assert 0.0 < abs(plane["normal"][2]) < 1.0


def test_plane_normal_to_curve_feature_rejects_out_of_range_parameter():
    part = _create_part()
    curve = _create_helix(part["id"])
    response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_curve_feature_at_parameter",
            "curve_feature_id": curve["id"],
            "curve_parameter": 1.5,
        },
    )
    assert response.status_code == 422


# --- Fill Surface -------------------------------------------------------------


def test_fill_surface_basic():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    lines = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)

    boundary_refs = [
        {"sketch_id": sketch_feature["sketch_id"], "entity_type": "line", "entity_id": line["id"]}
        for line in lines
    ]
    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features", json={"boundary_refs": boundary_refs}
    )
    assert response.status_code == 201, response.text

    mesh = client.get(f"/document/parts/{part['id']}/mesh")
    bodies = mesh.json()
    assert len(bodies) == 1
    assert bodies[0]["is_surface"] is True
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_fill_surface_requires_at_least_two_boundaries():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"], plane="XY")
    lines = _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    boundary_refs = [
        {"sketch_id": sketch_feature["sketch_id"], "entity_type": "line", "entity_id": lines[0]["id"]}
    ]
    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features", json={"boundary_refs": boundary_refs}
    )
    assert response.status_code == 422


def test_fill_surface_from_curve_feature_boundary():
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"], plane="XY")
    a1 = _add_point(sketch_a["sketch_id"], -10, -10)
    a2 = _add_point(sketch_a["sketch_id"], 10, 10)
    _add_line(sketch_a["sketch_id"], a1["id"], a2["id"])

    sketch_b = _create_sketch_feature(part["id"], plane="XZ")
    b1 = _add_point(sketch_b["sketch_id"], -10, -10)
    b2 = _add_point(sketch_b["sketch_id"], 10, 10)
    _add_line(sketch_b["sketch_id"], b1["id"], b2["id"])

    curve = client.post(
        f"/document/parts/{part['id']}/curve-features",
        json={
            "curve_type": "intersection",
            "sketch_feature_id_a": sketch_a["id"],
            "sketch_feature_id_b": sketch_b["id"],
        },
    ).json()

    # A second, parallel line (offset in Z) alongside the curve so
    # MakeFilling has more than one boundary constraint to work with.
    sketch_c = _create_sketch_feature(part["id"], plane="XY")
    c1 = _add_point(sketch_c["sketch_id"], -10, -9)
    c2 = _add_point(sketch_c["sketch_id"], 10, 11)
    line_c = _add_line(sketch_c["sketch_id"], c1["id"], c2["id"])

    response = client.post(
        f"/document/parts/{part['id']}/fill-surface-features",
        json={
            "boundary_refs": [
                {"curve_feature_id": curve["id"]},
                {
                    "sketch_id": sketch_c["sketch_id"],
                    "entity_type": "line",
                    "entity_id": line_c["id"],
                },
            ]
        },
    )
    assert response.status_code == 201, response.text
