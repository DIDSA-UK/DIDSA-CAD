"""Real-OCCT tests for Loft on Gordon surfaces (`app.document.loft_gordon`,
`docs/loft-gordon-and-helix-plan.md`): guides that shape the loft, one face per section edge, guides
that miss, ruled, thin lofts, the coarse preview and the native round trip. Helper conventions follow
`test_loft_feature.py`, which these tests reuse."""

import math

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepExtrema import BRepExtrema_DistShapeShape
from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods
from OCC.Core.gp import gp_Pnt

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_loft_feature import (
    _add_line,
    _add_point,
    _add_polygon,
    _create_loft,
    _create_part,
    _create_sketch_feature,
    _guide_curve_ref,
    _mesh,
    _move_sketch_feature_up,
    _section,
    _square_sketch,
    _two_squares,
    _volume,
)

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

HEIGHT = 8.0


# --- Helpers -----------------------------------------------------------------


def _guide_chain(part_id: str, plane: str, world_points: list[tuple[float, float]]) -> list[dict]:
    """One guide: a chain of connected Lines in a fixed-plane Sketch through the given points, as
    (horizontal, z) pairs in world terms: x for the XZ plane (whose local x runs the other way) and y
    for the YZ plane."""
    feature = _create_sketch_feature(part_id, plane)
    sign = -1.0 if plane == "XZ" else 1.0
    points = [_add_point(feature["sketch_id"], sign * horizontal, z) for horizontal, z in world_points]
    refs = []
    for a, b in zip(points, points[1:]):
        line = _add_line(feature["sketch_id"], a["id"], b["id"])
        refs.append(_guide_curve_ref({"sketch_id": feature["sketch_id"], "entity_id": line["id"]}))
    return refs


def _guide_world_points(plane: str, world_points: list[tuple[float, float]], per_segment: int = 8) -> list[gp_Pnt]:
    """Points along the guide polyline in world space (the chain is straight between its points)."""
    samples = []
    for (h0, z0), (h1, z1) in zip(world_points, world_points[1:]):
        for k in range(per_segment + 1):
            t = k / per_segment
            h, z = h0 + t * (h1 - h0), z0 + t * (z1 - z0)
            samples.append(gp_Pnt(h, 0.0, z) if plane == "XZ" else gp_Pnt(0.0, h, z))
    return samples


def _solid(part_id: str):
    (solid,) = compute_part_bodies(get_part_or_404(part_id)).values()
    return solid


def _distance_to(solid, point: gp_Pnt) -> float:
    vertex = BRepBuilderAPI_MakeVertex(point).Vertex()
    distance = BRepExtrema_DistShapeShape(vertex, solid)
    distance.Perform()
    return distance.Value()


def _count(shape, kind) -> int:
    explorer = TopExp_Explorer(shape, kind)
    seen = []
    while explorer.More():
        if not any(explorer.Current().IsSame(other) for other in seen):
            seen.append(explorer.Current())
        explorer.Next()
    return len(seen)


# --- Guides reshape the loft ---------------------------------------------------


def test_two_guides_pass_through_the_surface_and_bulge_the_walls():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    right_points = [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)]
    left_points = [(-5.0, 0.0), (-8.0, 4.0), (-5.0, HEIGHT)]
    right = _guide_chain(part["id"], "XZ", right_points)
    left = _guide_chain(part["id"], "XZ", left_points)

    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[right, left])
    assert response.status_code == 201, response.json()
    assert response.json()["warnings"] == []

    solid = _solid(part["id"])
    assert BRepCheck_Analyzer(solid).IsValid()
    # "On the surface within tolerance for exact builds": every sample of both guides lies on the solid.
    for plane_points in (right_points, left_points):
        for point in _guide_world_points("XZ", plane_points):
            assert _distance_to(solid, point) < 1e-4
    # Sections did not move; the walls bulge between them.
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert max(x for x, _y, _z in vertices) > 7.5
    assert min(x for x, _y, _z in vertices) < -7.5
    assert _volume(part["id"]) > 900.0


def test_a_guide_in_the_yz_plane_shapes_a_different_edge():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    points = [(5.0, 0.0), (7.0, 4.0), (5.0, HEIGHT)]
    guide = _guide_chain(part["id"], "YZ", points)
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide])
    assert response.status_code == 201, response.json()
    solid = _solid(part["id"])
    for point in _guide_world_points("YZ", points):
        assert _distance_to(solid, point) < 1e-4
    assert max(y for _x, y, _z in _mesh(part["id"])[0]["mesh"]["vertices"]) > 6.5


def test_each_section_edge_gives_one_face_and_a_corner_edge_can_be_filleted():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide])
    assert response.status_code == 201, response.json()

    solid = _solid(part["id"])
    assert _count(solid, TopAbs_FACE) == 6  # four side faces, two caps
    assert _count(solid, TopAbs_EDGE) == 12

    # A corner edge: the one running from (-5,-5,0) to (-5,-5,8) (the guide is on the other side).
    fillet = BRepFilletAPI_MakeFillet(solid)
    explorer = TopExp_Explorer(solid, TopAbs_EDGE)
    added = 0
    while explorer.More():
        edge = topods.Edge(explorer.Current())
        curve = BRepAdaptor_Curve(edge)
        start, end = curve.Value(curve.FirstParameter()), curve.Value(curve.LastParameter())
        if abs(start.X() + 5.0) < 1e-6 and abs(start.Y() + 5.0) < 1e-6 and abs(end.X() + 5.0) < 1e-6 and abs(end.Y() + 5.0) < 1e-6:
            fillet.Add(0.5, edge)
            added += 1
            break  # an edge is met once per adjoining face; one is enough
        explorer.Next()
    assert added == 1
    fillet.Build()
    assert fillet.IsDone()
    assert BRepCheck_Analyzer(fillet.Shape()).IsValid()


def test_a_guide_through_a_corner_replaces_that_corners_hidden_guide():
    """Diamond sections have corners at (+-7, 0) in the XZ plane, so a guide there runs along a corner
    edge instead of through the middle of a face."""
    part = _create_part()
    points = [(7.0, 0), (0, 7.0), (-7.0, 0), (0, -7.0)]
    bottom = _create_sketch_feature(part["id"], "XY")
    _add_polygon(bottom["sketch_id"], points)
    plane = _move_sketch_feature_up(part["id"], bottom, HEIGHT)
    top = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}).json()
    _add_polygon(top["sketch_id"], points)
    chain = [(7.0, 0.0), (9.0, 4.0), (7.0, HEIGHT)]
    guide = _guide_chain(part["id"], "XZ", chain)

    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide])
    assert response.status_code == 201, response.json()
    solid = _solid(part["id"])
    assert _count(solid, TopAbs_FACE) == 6
    for point in _guide_world_points("XZ", chain):
        assert _distance_to(solid, point) < 1e-4


def test_three_sections_with_a_guide():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    middle_plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    middle = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": middle_plane["id"]}
    ).json()
    _add_polygon(middle["sketch_id"], [(-7, -7), (7, -7), (7, 7), (-7, 7)])
    top_plane = _move_sketch_feature_up(part["id"], bottom, 10.0)
    top = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": top_plane["id"]}).json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    # Through the middle of the right edge of all three squares, with the middle one wider (x=7).
    chain = [(5.0, 0.0), (7.0, 5.0), (5.0, 10.0)]
    guide = _guide_chain(part["id"], "XZ", chain)

    response = _create_loft(part["id"], [_section(bottom), _section(middle), _section(top)], guide_curves=[guide])
    assert response.status_code == 201, response.json()
    solid = _solid(part["id"])
    assert BRepCheck_Analyzer(solid).IsValid()
    for point in _guide_world_points("XZ", chain):
        assert _distance_to(solid, point) < 1e-3


def test_circle_sections_with_a_guide_stay_one_side_face():
    part = _create_part()
    bottom = _create_sketch_feature(part["id"], "XY")
    center = _add_point(bottom["sketch_id"], 0, 0)
    rim = _add_point(bottom["sketch_id"], 5, 0)
    client.post(f"/sketch/sketches/{bottom['sketch_id']}/circles", json={"center_point_id": center["id"], "radius_point_id": rim["id"]})
    plane = _move_sketch_feature_up(part["id"], bottom, HEIGHT)
    top = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}).json()
    center = _add_point(top["sketch_id"], 0, 0)
    rim = _add_point(top["sketch_id"], 3, 0)
    client.post(f"/sketch/sketches/{top['sketch_id']}/circles", json={"center_point_id": center["id"], "radius_point_id": rim["id"]})

    plain = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert plain.status_code == 201, plain.json()
    cone_volume = _volume(part["id"])
    assert cone_volume == pytest.approx(math.pi * HEIGHT / 3 * (25 + 15 + 9), rel=2e-3)
    assert _count(_solid(part["id"]), TopAbs_FACE) == 3

    # The same loft with a guide pushing the wall out at the circle's start (x = 5 at the bottom, 3 at the top).
    other = _create_part("Guided circle")
    bottom_b = _create_sketch_feature(other["id"], "XY")
    c = _add_point(bottom_b["sketch_id"], 0, 0)
    r = _add_point(bottom_b["sketch_id"], 5, 0)
    client.post(f"/sketch/sketches/{bottom_b['sketch_id']}/circles", json={"center_point_id": c["id"], "radius_point_id": r["id"]})
    plane_b = _move_sketch_feature_up(other["id"], bottom_b, HEIGHT)
    top_b = client.post(f"/document/parts/{other['id']}/features/sketch", json={"plane_feature_id": plane_b["id"]}).json()
    c = _add_point(top_b["sketch_id"], 0, 0)
    r = _add_point(top_b["sketch_id"], 3, 0)
    client.post(f"/sketch/sketches/{top_b['sketch_id']}/circles", json={"center_point_id": c["id"], "radius_point_id": r["id"]})
    chain = [(5.0, 0.0), (7.0, 4.0), (3.0, HEIGHT)]
    guide = _guide_chain(other["id"], "XZ", chain)
    # The XZ plane's world x equals the circle's local x only at y=0; the circle point at angle 0 is (5,0,0),
    # which is where the first guide point is, so the circle sections' start is on the guide.
    guided = _create_loft(other["id"], [_section(bottom_b), _section(top_b)], guide_curves=[guide])
    assert guided.status_code == 201, guided.json()
    solid = _solid(other["id"])
    assert BRepCheck_Analyzer(solid).IsValid()
    assert _count(solid, TopAbs_FACE) == 3
    assert _volume(other["id"]) > cone_volume
    for point in _guide_world_points("XZ", chain):
        assert _distance_to(solid, point) < 1e-3


# --- Guides that miss ------------------------------------------------------------


def test_a_guide_that_misses_a_section_a_little_is_snapped_and_reported():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.4, HEIGHT)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide])
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert any("Guide 1 misses section 2" in warning for warning in warnings), warnings
    solid = _solid(part["id"])
    assert BRepCheck_Analyzer(solid).IsValid()
    # The sections still close the solid: the top face is exactly the 10 x 10 square.
    assert max(x for x, _y, z in _mesh(part["id"])[0]["mesh"]["vertices"] if abs(z - HEIGHT) < 1e-6) == pytest.approx(5.0, abs=1e-3)


def test_a_guide_far_from_the_sections_is_a_422_naming_the_guide_and_section():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    near = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)])
    far = _guide_chain(part["id"], "XZ", [(30.0, 0.0), (32.0, 4.0), (30.0, HEIGHT)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[near, far])
    assert response.status_code == 422, response.json()
    detail = response.json()["detail"]
    assert detail["type"] == "invalid_guide_curve_ref"
    assert detail["index"] == 1
    assert detail["section"] == 0


def test_a_guide_on_different_edges_of_different_sections_is_a_422():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)  # the guide meets the middle of an edge here
    plane = _move_sketch_feature_up(part["id"], bottom, HEIGHT)
    top = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}).json()
    _add_polygon(top["sketch_id"], [(7, 0), (0, 7), (-7, 0), (0, -7)])  # ...and a corner here
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (7.0, HEIGHT)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide])
    assert response.status_code == 422, response.json()
    assert response.json()["detail"]["type"] == "invalid_guide_curve_ref"


def test_ruled_with_guides_is_rejected():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[guide], ruled=True)
    assert response.status_code == 422


def test_an_empty_guide_is_rejected():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[[]])
    assert response.status_code == 422


# --- Ruled, thin and coarse --------------------------------------------------------


def test_a_ruled_three_section_loft_is_straight_between_sections():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    p1 = _move_sketch_feature_up(part["id"], bottom, 5.0)
    middle = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": p1["id"]}).json()
    _add_polygon(middle["sketch_id"], [(-10, -10), (10, -10), (10, 10), (-10, 10)])
    p2 = _move_sketch_feature_up(part["id"], bottom, 10.0)
    top = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": p2["id"]}).json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])

    response = _create_loft(part["id"], [_section(bottom), _section(middle), _section(top)], ruled=True)
    assert response.status_code == 201, response.json()
    solid = _solid(part["id"])
    assert _count(solid, TopAbs_FACE) == 10  # two spans of four side faces, two caps
    # Two frustums: (h/3)(A1 + sqrt(A1 A2) + A2) each.
    frustum = lambda a1, a2: 5.0 / 3.0 * (a1 + math.sqrt(a1 * a2) + a2)  # noqa: E731
    assert _volume(part["id"]) == pytest.approx(frustum(100, 400) + frustum(400, 100), rel=1e-6)


def test_a_thin_loft_between_closed_profiles_with_a_guide():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (7.0, 4.0), (5.0, HEIGHT)])
    response = _create_loft(
        part["id"],
        [_section(bottom), _section(top)],
        guide_curves=[guide],
        thickness=0.5,
        thin_from_closed_profile=True,
    )
    assert response.status_code == 201, response.json()
    assert BRepCheck_Analyzer(_solid(part["id"])).IsValid()
    assert _volume(part["id"]) > 0


def _l_chain_sketch(part_id: str, plane_feature_id: str | None, legs: tuple[float, float]) -> dict:
    if plane_feature_id is None:
        feature = _create_sketch_feature(part_id, "XY")
    else:
        feature = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_feature_id}).json()
    a = _add_point(feature["sketch_id"], 0, 0)
    b = _add_point(feature["sketch_id"], legs[0], 0)
    c = _add_point(feature["sketch_id"], legs[0], legs[1])
    _add_line(feature["sketch_id"], a["id"], b["id"])
    _add_line(feature["sketch_id"], b["id"], c["id"])
    return feature


def test_thin_loft_between_two_l_shaped_open_chains():
    """Two identical L chains (10 and 6 mm legs) 8 mm apart: the shape the OCCT 8 evaluation
    (`docs/occt-8-upgrade-evaluation.md` 1c) found malformed. The loft itself is right under Gordon
    (two planar faces, area (10 + 6) x 8 = 128); the thickened solid is valid but its volume is
    still the wrong ~88 mm3 instead of ~136, because `thicken_shell_to_solid` declines the shell
    (its free boundary is one non-planar loop, so there is no cap to close it with) and falls back to
    `MakeThickSolidBySimple`, which leaves the corner open. That is a thickening defect, not a loft
    one - see docs/loft-gordon-spike.md - so this test pins the loft and only the solid's validity."""
    part = _create_part()
    bottom = _l_chain_sketch(part["id"], None, (10.0, 6.0))
    plane = _move_sketch_feature_up(part["id"], bottom, HEIGHT)
    top = _l_chain_sketch(part["id"], plane["id"], (10.0, 6.0))

    surface = client.post(
        f"/document/parts/{part['id']}/loft-surface-features", json={"sections": [_section(bottom), _section(top)]}
    )
    assert surface.status_code == 201, surface.json()
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps

    (shell,) = compute_part_bodies(get_part_or_404(part["id"])).values()
    props = GProp_GProps()
    brepgprop.SurfaceProperties(shell, props)
    assert props.Mass() == pytest.approx(128.0, rel=1e-6)
    assert _count(shell, TopAbs_FACE) == 2

    thin_part = _create_part("Thin L")
    bottom = _l_chain_sketch(thin_part["id"], None, (10.0, 6.0))
    plane = _move_sketch_feature_up(thin_part["id"], bottom, HEIGHT)
    top = _l_chain_sketch(thin_part["id"], plane["id"], (10.0, 6.0))
    response = _create_loft(thin_part["id"], [_section(bottom), _section(top)], thickness=1.0)
    assert response.status_code == 201, response.json()
    assert BRepCheck_Analyzer(_solid(thin_part["id"])).IsValid()
    assert _volume(thin_part["id"]) > 80.0


def test_coarse_preview_keeps_the_guides():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    guide = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)])
    response = client.post(
        f"/document/parts/{part['id']}/loft-features/coarse-preview",
        json={"sections": [_section(bottom), _section(top)], "mode": "boss", "guide_curves": [guide]},
    )
    assert response.status_code == 200, response.json()
    vertices = response.json()[0]["mesh"]["vertices"]
    assert max(x for x, _y, _z in vertices) > 7.5


# --- Persistence and updates ---------------------------------------------------------


def test_guides_survive_the_native_round_trip_and_a_patch():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Guided native")
        bottom, top = _two_squares(part["id"])
        right = _guide_chain(part["id"], "XZ", [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)])
        left = _guide_chain(part["id"], "XZ", [(-5.0, 0.0), (-8.0, 4.0), (-5.0, HEIGHT)])
        created = _create_loft(part["id"], [_section(bottom), _section(top)], guide_curves=[right, left])
        assert created.status_code == 201, created.json()
        feature_id = created.json()["id"]
        before = _mesh(part["id"])[0]["mesh"]["vertices"]

        exported = client.get("/document/export/native").json()
        stored = next(
            f for p in exported["document"]["parts"] for f in p["features"] if f["id"] == feature_id
        )
        assert [len(guide) for guide in stored["guide_curves"]] == [2, 2]
        assert client.post("/document/import/native", json=exported).status_code == 200
        assert _mesh(part["id"])[0]["mesh"]["vertices"] == before

        # Dropping one guide through PATCH changes the shape.
        patched = client.patch(
            f"/document/parts/{part['id']}/loft-features/{feature_id}", json={"guide_curves": [right]}
        )
        assert patched.status_code == 200, patched.json()
        assert len(patched.json()["guide_curves"]) == 1
        assert min(x for x, _y, _z in _mesh(part["id"])[0]["mesh"]["vertices"]) > -5.5
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_loft_surface_takes_guides_too():
    part = _create_part()
    bottom, top = _two_squares(part["id"])
    points = [(5.0, 0.0), (8.0, 4.0), (5.0, HEIGHT)]
    guide = _guide_chain(part["id"], "XZ", points)
    response = client.post(
        f"/document/parts/{part['id']}/loft-surface-features",
        json={"sections": [_section(bottom), _section(top)], "guide_curves": [guide]},
    )
    assert response.status_code == 201, response.json()
    assert len(response.json()["guide_curves"]) == 1
    vertices = _mesh(part["id"])[0]["mesh"]["vertices"]
    assert max(x for x, _y, _z in vertices) > 7.5
    assert not (
        client.post(
            f"/document/parts/{part['id']}/loft-surface-features",
            json={"sections": [_section(bottom), _section(top)], "guide_curves": [guide], "ruled": True},
        ).status_code
        == 201
    )
