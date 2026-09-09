"""Real-OCCT tests for the Thicken-Surface corner-defect fix (second-round
testing feedback, screenshot attached: "surface lofted between an arc and a
profile of lines then thickened using thicken surface. Note the
inconsistent thickness, untrimmed lines and bad corners").

`BRepOffsetAPI_ThruSections` between sections with mismatched edge counts
(a 1-edge Arc vs an N-edge line-chain) collapses into a single smooth
BSpline face with none of the line-chain's own sharp corners carried into
the result - `app.document.loft._harmonize_section_wire_edge_counts` is the
fix (splits each lower-edge-count section's own currently-longest edge at
its curve-parameter midpoint, repeatedly, until every section wire has the
same edge count, before `ThruSections` ever sees them).

Two layers of coverage: a direct, no-HTTP unit test of the harmonization
helper itself (exact edge counts, and that no length is gained or lost by
splitting), and an HTTP round-trip test through Loft Surface + Thicken
using the exact reported repro shape, checking the resulting shell/solid's
own face count reflects the line-chain's real corners (multiple side
faces) rather than one single warped face."""

import math

from fastapi.testclient import TestClient
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepTools import BRepTools_WireExplorer
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import topods

from app.document.extrude import compute_part_bodies
from app.document.loft import _harmonize_section_wire_edge_counts
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Direct unit test of the harmonization helper ---------------------------


def _wire_edge_count(wire) -> int:
    count = 0
    explorer = BRepTools_WireExplorer(wire)
    while explorer.More():
        count += 1
        explorer.Next()
    return count


def _wire_total_length(wire) -> float:
    total = 0.0
    explorer = BRepTools_WireExplorer(wire)
    while explorer.More():
        props = GProp_GProps()
        brepgprop.LinearProperties(topods.Edge(explorer.Current()), props)
        total += props.Mass()
        explorer.Next()
    return total


def _quarter_circle_arc_wire(radius: float = 5.0):
    """A single-edge open wire - a quarter-circle arc, radius 5, centered
    at the origin in the XY plane."""
    circ = gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), radius)
    edge = BRepBuilderAPI_MakeEdge(circ, 0.0, math.pi / 2).Edge()
    wire_maker = BRepBuilderAPI_MakeWire()
    wire_maker.Add(edge)
    return wire_maker.Wire()


def _three_segment_open_wire():
    """A 3-edge open wire - the "profile of lines" side of the reported
    repro, a simple zigzag with 3 real, independently-controllable corners."""
    points = [gp_Pnt(0, 0, 10), gp_Pnt(5, 0, 10), gp_Pnt(5, 5, 10), gp_Pnt(0, 5, 10)]
    wire_maker = BRepBuilderAPI_MakeWire()
    for a, b in zip(points, points[1:]):
        wire_maker.Add(BRepBuilderAPI_MakeEdge(a, b).Edge())
    return wire_maker.Wire()


def test_harmonize_brings_a_1_edge_arc_wire_up_to_a_3_edge_wires_own_count():
    arc_wire = _quarter_circle_arc_wire()
    line_wire = _three_segment_open_wire()
    assert _wire_edge_count(arc_wire) == 1
    assert _wire_edge_count(line_wire) == 3

    harmonized = _harmonize_section_wire_edge_counts([arc_wire, line_wire])

    assert _wire_edge_count(harmonized[0]) == 3
    assert _wire_edge_count(harmonized[1]) == 3


def test_harmonize_preserves_each_wires_own_total_length():
    arc_wire = _quarter_circle_arc_wire()
    line_wire = _three_segment_open_wire()
    original_arc_length = _wire_total_length(arc_wire)
    original_line_length = _wire_total_length(line_wire)

    harmonized = _harmonize_section_wire_edge_counts([arc_wire, line_wire])

    assert abs(_wire_total_length(harmonized[0]) - original_arc_length) < 1e-6
    assert abs(_wire_total_length(harmonized[1]) - original_line_length) < 1e-6


def test_harmonize_is_a_no_op_when_every_wire_already_matches():
    line_wire_a = _three_segment_open_wire()
    line_wire_b = _three_segment_open_wire()

    harmonized = _harmonize_section_wire_edge_counts([line_wire_a, line_wire_b])

    assert harmonized == [line_wire_a, line_wire_b]


def test_harmonize_is_a_no_op_for_two_1_edge_wires():
    arc_wire_a = _quarter_circle_arc_wire()
    arc_wire_b = _quarter_circle_arc_wire(radius=8.0)

    harmonized = _harmonize_section_wire_edge_counts([arc_wire_a, arc_wire_b])

    assert harmonized == [arc_wire_a, arc_wire_b]


# --- HTTP round-trip: the exact reported repro -------------------------------


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


def _add_arc(sketch_id: str, center: dict, start: dict, end_angle: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": end_angle},
    )
    assert response.status_code == 201
    return response.json()


def _arc_section_sketch_feature(part_id: str) -> dict:
    """A single open Arc (quarter circle, radius 5) on the XY plane - the
    "an arc" side of the reported repro, exactly 1 edge."""
    feature = _create_sketch_feature(part_id, "XY")
    center = _add_point(feature["sketch_id"], 0.0, 0.0)
    start = _add_point(feature["sketch_id"], 5.0, 0.0)
    _add_arc(feature["sketch_id"], center, start, end_angle=math.pi / 2)
    return feature


def _line_profile_section_sketch_feature(part_id: str) -> dict:
    """An open 3-segment line chain (a simple zigzag, 3 real corners) on
    the XZ plane, moved up so it's a real 3D section at a different
    height than the Arc section - the "profile of lines" side of the
    reported repro."""
    feature = _create_sketch_feature(part_id, "XZ")
    a = _add_point(feature["sketch_id"], 0.0, 10.0)
    b = _add_point(feature["sketch_id"], 5.0, 10.0)
    c = _add_point(feature["sketch_id"], 5.0, 15.0)
    d = _add_point(feature["sketch_id"], 0.0, 15.0)
    _add_line(feature["sketch_id"], a["id"], b["id"])
    _add_line(feature["sketch_id"], b["id"], c["id"])
    _add_line(feature["sketch_id"], c["id"], d["id"])
    return feature


def _create_loft_surface(part_id: str, sections: list[dict]) -> dict:
    return client.post(f"/document/parts/{part_id}/loft-surface-features", json={"sections": sections})


def _create_thicken(part_id: str, surface_feature_id: str, thickness: float):
    return client.post(
        f"/document/parts/{part_id}/thicken-features",
        json={"surface_feature_id": surface_feature_id, "thickness": thickness},
    )


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _surface_area(part_id: str, body_id: str) -> float:
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    props = GProp_GProps()
    brepgprop.SurfaceProperties(bodies[body_id], props)
    return props.Mass()


def _face_count(part_id: str, body_id: str) -> int:
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    shape = bodies[body_id]
    count = 0
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    while explorer.More():
        count += 1
        explorer.Next()
    return count


def test_loft_surface_between_an_arc_and_a_line_profile_keeps_the_lines_own_corners():
    """The core regression check: before the harmonization fix, `ThruSections`
    between a 1-edge Arc section and a 3-edge line-chain section collapsed
    into one single smooth face with none of the line-chain's own 3 real
    corners surviving as real face boundaries - post-fix, the Arc section's
    own wire is split up to 3 edges first, so the lofted shell has (at
    least) 3 distinct side faces, one per real line-chain edge."""
    part = _create_part()
    arc_feature = _arc_section_sketch_feature(part["id"])
    line_feature = _line_profile_section_sketch_feature(part["id"])

    response = _create_loft_surface(
        part["id"],
        [{"sketch_feature_id": arc_feature["id"]}, {"sketch_feature_id": line_feature["id"]}],
    )

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "surface"
    mesh = _mesh(part["id"])
    surface_body_id = mesh[0]["body_id"]
    assert BRepCheck_Analyzer(
        compute_part_bodies(get_part_or_404(part["id"]))[surface_body_id]
    ).IsValid()
    assert _face_count(part["id"], surface_body_id) >= 3


def test_thicken_surface_between_an_arc_and_a_line_profile_produces_a_valid_solid_with_preserved_corners():
    """`ThickenFeature` keeps the surface Feature's own shell registered
    in `bodies` (as its own, separate mesh entry) alongside the new solid
    it produces - the solid is registered under the Thicken Feature's own
    id (`_register_solids`' single-solid case), not the surface's, so it
    must be looked up by id rather than assumed to be `mesh[0]`."""
    part = _create_part()
    arc_feature = _arc_section_sketch_feature(part["id"])
    line_feature = _line_profile_section_sketch_feature(part["id"])
    loft_surface = _create_loft_surface(
        part["id"],
        [{"sketch_feature_id": arc_feature["id"]}, {"sketch_feature_id": line_feature["id"]}],
    ).json()
    surface_area = _surface_area(part["id"], loft_surface["id"])

    response = _create_thicken(part["id"], loft_surface["id"], thickness=0.5)

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "body"
    part_obj = get_part_or_404(part["id"])
    bodies = compute_part_bodies(part_obj)
    solid = bodies[body["id"]]
    assert BRepCheck_Analyzer(solid).IsValid()

    volume_props = GProp_GProps()
    brepgprop.VolumeProperties(solid, volume_props)
    volume = volume_props.Mass()
    # The pre-fix bug ("inconsistent thickness... bad corners") comes from
    # a badly-warped single face rather than a genuinely uniform 0.5-thick
    # shell - a real 0.5-thick shell's volume should track surface_area *
    # thickness reasonably closely (some slack for the Arc side's own
    # curvature), not be wildly undersized (a symptom of self-intersecting
    # overlap at a bad corner) or negative (an inverted/inconsistent solid).
    expected_volume = surface_area * 0.5
    assert volume > 0
    assert abs(volume - expected_volume) / expected_volume < 0.25
