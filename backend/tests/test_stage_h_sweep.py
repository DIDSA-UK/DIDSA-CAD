"""Sweep: real-OCCT tests for Sweep's full router/HTTP surface - all touch
`app.main`/`app.document.sweep`/`app.document.extrude`, which import OCC.Core
directly, so (per the recurring caveat in docs/status.md) these are
`ast.parse`-verified/manually reviewed only in this sandbox, same as every
other OCCT-touching backend prompt in this project until real CI (or a real
device) runs it. Structurally mirrors `test_stage_f_revolve.py`'s own shape.

On-device-verification note: `BRepOffsetAPI_MakePipe`'s exact handling of a
profile whose own position doesn't already sit at the spine wire's start
point (does it auto-translate the profile there, or does the caller need
to?) could not be confirmed against a real OCCT build in this sandbox - the
fixtures below deliberately start every path at the same world point the
Profile square's own corner sits at (the origin) to sidestep the question
rather than assume an answer, but this is flagged as the first thing to
double-check once this runs somewhere with a real OCCT kernel.
"""

import math

from fastapi.testclient import TestClient
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
from OCC.Core.BRepTools import BRepTools_WireExplorer
from OCC.Core.GeomAbs import GeomAbs_Circle
from OCC.Core.TopAbs import TopAbs_FORWARD

from app.document.sweep import resolve_path_wire
from app.document.store import get_part_or_404
from app.main import app
from app.sketch.models import SketchEntityRef, SketchEntityType
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
    corners = [_add_point(sketch_id, x, y) for x, y in [
        (x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)
    ]]
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


def _create_annular_profile_sketch_feature(
    part_id: str, *, outer_radius: float = 2.0, inner_radius: float = 1.0
) -> dict:
    """A pipe-wall (annular) Profile at the origin on the XY plane - two
    concentric circles, the smaller one becoming the outer circle's own
    `inner_loops` hole (see `app.sketch.profile._classify_nesting`) - the
    common "sweep a hollow profile along a path" use case (a pipe with
    wall thickness), not an edge case."""
    feature = _create_sketch_feature(part_id, "XY")
    center = _add_point(feature["sketch_id"], 0.0, 0.0)
    outer_edge = _add_point(feature["sketch_id"], outer_radius, 0.0)
    inner_edge = _add_point(feature["sketch_id"], inner_radius, 0.0)
    _add_circle(feature["sketch_id"], center, outer_edge)
    _add_circle(feature["sketch_id"], center, inner_edge)
    return feature


def _create_profile_sketch_feature(part_id: str, *, size: float = 2.0) -> dict:
    """A small square Profile at the origin on the XY plane - deliberately
    small relative to every path fixture below, so the swept solid never
    self-intersects against a path's own corners (mirrors Revolve's own
    "offset square" reasoning for avoiding self-intersection, just applied
    to path-corner clearance instead of axis clearance)."""
    feature = _create_sketch_feature(part_id, "XY")
    _add_square(feature["sketch_id"], 0.0, 0.0, size)
    return feature


def _path_ref(sketch_id: str, entity_id: str, entity_type: str = "line") -> dict:
    return {"sketch_id": sketch_id, "entity_type": entity_type, "entity_id": entity_id}


def _add_arc(sketch_id: str, center: dict, start: dict, end_angle: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/arcs",
        json={"center_point_id": center["id"], "start_point_id": start["id"], "end_angle": end_angle},
    )
    assert response.status_code == 201
    return response.json()


def _add_ellipse(sketch_id: str, center: dict, *, major_radius: float, angle: float, minor_radius: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/ellipses",
        json={
            "center_point_id": center["id"],
            "major_radius": major_radius,
            "angle": angle,
            "minor_radius": minor_radius,
        },
    )
    assert response.status_code == 201
    return response.json()


def _add_spline(sketch_id: str, through_point_ids: list[str]) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/splines", json={"through_point_ids": through_point_ids}
    )
    assert response.status_code == 201
    return response.json()


def _create_arc_path_sketch_feature(part_id: str) -> tuple[dict, dict]:
    """On-device feedback ("unable to select an arc as the sweep path"): a
    single-segment Arc path on the XZ plane, a quarter circle starting at
    the world origin (matching the Profile square's own (0, 0) corner,
    same reasoning [_create_straight_path_sketch_feature] documents) and
    sweeping to (10, 10) - center (0, 10), radius 10, from angle -pi/2
    (the start Point, (0, 0)) to angle 0 (the new end Point, (10, 10))."""
    feature = _create_sketch_feature(part_id, "XZ")
    center = _add_point(feature["sketch_id"], 0.0, 10.0)
    start = _add_point(feature["sketch_id"], 0.0, 0.0)
    arc = _add_arc(feature["sketch_id"], center, start, end_angle=0.0)
    return feature, arc


def _create_ellipse_path_sketch_feature(part_id: str) -> tuple[dict, dict]:
    """On-device feedback ("ellipses...should also be valid targets for
    sweep paths"): a standalone (closed, unchained) Ellipse path on the XZ
    plane - major axis along +x so its own major-axis Point (the ellipse's
    natural OCCT parametrization start) sits at the world origin, same
    "start where the Profile's own corner is" reasoning as every other
    path fixture here."""
    feature = _create_sketch_feature(part_id, "XZ")
    center = _add_point(feature["sketch_id"], -5.0, 0.0)
    ellipse = _add_ellipse(feature["sketch_id"], center, major_radius=5.0, angle=0.0, minor_radius=3.0)
    return feature, ellipse


def _create_spline_path_sketch_feature(part_id: str) -> tuple[dict, dict]:
    """On-device feedback ("splines...should also be valid targets for
    sweep paths"): the simplest possible Spline path - 2 through-points (a
    single Bezier segment), starting at the world origin."""
    feature = _create_sketch_feature(part_id, "XZ")
    p0 = _add_point(feature["sketch_id"], 0.0, 0.0)
    p1 = _add_point(feature["sketch_id"], 0.0, 10.0)
    spline = _add_spline(feature["sketch_id"], [p0["id"], p1["id"]])
    return feature, spline


def _create_straight_path_sketch_feature(part_id: str, *, length: float = 10.0) -> tuple[dict, dict]:
    """A single-segment path on the XZ plane, starting at the world origin
    (coincident with the Profile square's own (0, 0) corner) and running
    straight up along +Z - the simplest possible open path."""
    feature = _create_sketch_feature(part_id, "XZ")
    p0 = _add_point(feature["sketch_id"], 0.0, 0.0)
    p1 = _add_point(feature["sketch_id"], 0.0, length)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return feature, line


def _create_bent_path_sketch_features(part_id: str) -> tuple[list[dict], list[dict]]:
    """A 2-segment path spanning *two different Sketches on two different
    planes*, chained by 3D world-space position rather than a shared Point
    id (Sweep's own confirmed decision - see `SweepFeature`'s docstring):
    segment A (XZ plane) runs from the world origin to (0, 0, 10); segment
    B (YZ plane) starts at that same world point (0, 0, 10) and runs to
    (0, 5, 10). Returns `([featureA, featureB], [lineA, lineB])`."""
    feature_a = _create_sketch_feature(part_id, "XZ")
    a0 = _add_point(feature_a["sketch_id"], 0.0, 0.0)
    a1 = _add_point(feature_a["sketch_id"], 0.0, 10.0)
    line_a = _add_line(feature_a["sketch_id"], a0["id"], a1["id"])

    feature_b = _create_sketch_feature(part_id, "YZ")
    b0 = _add_point(feature_b["sketch_id"], 0.0, 10.0)
    b1 = _add_point(feature_b["sketch_id"], 5.0, 10.0)
    line_b = _add_line(feature_b["sketch_id"], b0["id"], b1["id"])

    return [feature_a, feature_b], [line_a, line_b]


def _create_closed_path_sketch_feature(part_id: str) -> tuple[dict, list[dict]]:
    """A single-Sketch closed (looping) path on the XZ plane - a 20x20
    square well away from the origin (so the Profile's own tiny square
    never has to cross the path's own corners), confirming closed paths
    are in scope (Sweep's own confirmed decision)."""
    feature = _create_sketch_feature(part_id, "XZ")
    lines = _add_square(feature["sketch_id"], 10.0, 10.0, 20.0)
    return feature, lines


def _create_sweep(
    part_id: str,
    sketch_feature_id: str,
    path_refs: list[dict],
    *,
    mode: str = "boss",
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/sweep-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "path_refs": path_refs,
            "mode": mode,
            "target_body_ids": target_body_ids or [],
        },
    )


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


# --- Success -------------------------------------------------------------------


def test_boss_sweep_along_a_single_straight_segment_creates_a_new_body():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )
    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "sweep"
    assert body["mode"] == "boss"
    assert body["produces"] == "body"

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "computed"


def test_boss_sweep_along_a_path_spanning_two_different_sketches_succeeds():
    """The path's two segments live in different Sketches on different
    planes, chained only by 3D world-space position - Sweep's own confirmed
    "cross-Sketch path segments" decision."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_features, path_lines = _create_bent_path_sketch_features(part["id"])

    path_refs = [
        _path_ref(path_features[0]["sketch_id"], path_lines[0]["id"]),
        _path_ref(path_features[1]["sketch_id"], path_lines[1]["id"]),
    ]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 201
    assert response.json()["path_refs"] == path_refs

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_boss_sweep_along_a_closed_path_succeeds():
    """A path whose last segment's endpoint coincides with its first
    segment's start produces a continuous, non-open solid - Sweep's own
    confirmed "closed paths are in scope" decision."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_lines = _create_closed_path_sketch_feature(part["id"])

    path_refs = [_path_ref(path_feature["sketch_id"], line["id"]) for line in path_lines]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_boss_sweep_of_an_annular_pipe_wall_profile_succeeds():
    """A Profile with a hole (the pipe-wall/annular case - see
    `_create_annular_profile_sketch_feature`) is a common Sweep use case,
    not an edge case - `resolve_sweep_from_bodies` sweeps the outer circle
    and the inner (hole) circle independently, then boolean-cuts the inner
    solid out of the outer one, rather than handing a single compound
    outer+hole section to `BRepOffsetAPI_MakePipeShell`."""
    part = _create_part()
    profile = _create_annular_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"], length=20.0)

    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_boss_sweep_along_a_single_arc_segment_succeeds():
    """On-device feedback ("unable to select an arc as the sweep path...
    can select the arc but it doesn't allow confirming") - confirms the
    fix all the way through: an Arc path_ref actually produces a real
    swept body, not just that the client can now select one."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_arc = _create_arc_path_sketch_feature(part["id"])

    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_arc["id"], "arc")]
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_boss_sweep_along_a_standalone_ellipse_path_succeeds():
    """On-device feedback ("ellipses...should also be valid targets for
    sweep paths") - an Ellipse is always closed/standalone (see
    `app.sketch.models.Ellipse`'s own doc comment), so it's the entire
    path on its own, not one link in a chain."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_ellipse = _create_ellipse_path_sketch_feature(part["id"])

    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_ellipse["id"], "ellipse")]
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_boss_sweep_along_a_single_spline_segment_succeeds():
    """On-device feedback ("splines...should also be valid targets for
    sweep paths")."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_spline = _create_spline_path_sketch_feature(part["id"])

    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_spline["id"], "spline")]
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1


def test_an_ellipse_path_ref_mixed_with_a_line_is_rejected():
    """An Ellipse has no endpoints to chain with anything else - mixing
    one into a multi-segment path_refs list must be rejected, not silently
    treated as if it had a start/end somewhere."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    ellipse_feature, path_ellipse = _create_ellipse_path_sketch_feature(part["id"])
    line_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    path_refs = [
        _path_ref(ellipse_feature["sketch_id"], path_ellipse["id"], "ellipse"),
        _path_ref(line_feature["sketch_id"], path_line["id"]),
    ]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_path_ref"


def test_path_segments_given_out_of_geometric_order_are_still_connected_correctly():
    """`path_refs`' own list order is what the user picked in, which need
    not already trace start-to-end in one consistent direction per segment
    - `_resolve_path_wire` must work out each segment's actual orientation
    from where its endpoints land, not assume `path_refs[i]`'s "first"
    point already continues from `path_refs[i-1]`'s "second" one."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_features, path_lines = _create_bent_path_sketch_features(part["id"])

    # Reversed relative to creation order - segment B first, then segment A.
    # Still a single connected chain (their shared point is (0, 0, 10)
    # either way), just listed back-to-front.
    path_refs = [
        _path_ref(path_features[1]["sketch_id"], path_lines[1]["id"]),
        _path_ref(path_features[0]["sketch_id"], path_lines[0]["id"]),
    ]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 201


def test_a_pick_that_extends_the_first_segments_front_rather_than_its_back_is_accepted():
    """On-device regression: `_resolve_path_wire` used to track only a
    single running `chain_end`, seeded from the *first* segment's own
    arbitrary `(start, end)` order - so once one segment was picked, only
    taps connecting to that one fixed endpoint extended the path; a second
    pick connecting to the *other* endpoint of that same first segment (a
    perfectly valid, common way to build a path - nothing fixes which end
    is "the start" until a second segment actually commits to a direction)
    was wrongly rejected as `disconnected_path`. Three segments sharing a
    single Sketch, picked in a middle-out order (the middle segment first,
    then a segment extending its front, then one extending its back) -
    this exact shape is what a real on-device path build looks like."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature = _create_sketch_feature(part["id"], "XZ")
    p0 = _add_point(path_feature["sketch_id"], 0.0, 0.0)
    p1 = _add_point(path_feature["sketch_id"], 0.0, 10.0)
    p2 = _add_point(path_feature["sketch_id"], 0.0, 20.0)
    p3 = _add_point(path_feature["sketch_id"], 5.0, 25.0)
    middle_line = _add_line(path_feature["sketch_id"], p1["id"], p2["id"])
    front_line = _add_line(path_feature["sketch_id"], p0["id"], p1["id"])
    back_line = _add_line(path_feature["sketch_id"], p2["id"], p3["id"])

    # Middle segment picked first; the second pick extends its *front*
    # (shares p1, the middle segment's own start_point_id) rather than its
    # back - exactly the tap the on-device repro found unresponsive.
    path_refs = [
        _path_ref(path_feature["sketch_id"], middle_line["id"]),
        _path_ref(path_feature["sketch_id"], front_line["id"]),
        _path_ref(path_feature["sketch_id"], back_line["id"]),
    ]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 201


def test_cut_sweep_merges_into_a_target_and_preserves_body_id():
    """Body-identity parity with Extrude/Revolve/Fillet/Chamfer: Cut must
    subtract from the named target Body, keeping its id."""
    part = _create_part()
    box_sketch_feature = _create_sketch_feature(part["id"])
    _add_square(box_sketch_feature["sketch_id"], -50.0, -50.0, 100.0)
    boss_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": box_sketch_feature["id"],
            "extrude_type": "boss",
            "start_distance": -50.0,
            "end_distance": 50.0,
            "target_body_ids": [],
        },
    )
    assert boss_response.status_code == 201
    body_id = _mesh(part["id"])[0]["body_id"]

    profile = _create_profile_sketch_feature(part["id"], size=1.0)
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"], length=20.0)
    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])],
        mode="cut", target_body_ids=[body_id],
    )
    assert response.status_code == 201

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["body_id"] == body_id


def test_list_features_includes_the_sweep():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    created = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    ).json()

    features = client.get(f"/document/parts/{part['id']}/features").json()
    sweep_entries = {f["id"]: f for f in features if f["type"] == "sweep"}
    assert created["id"] in sweep_entries


# --- Rejections ------------------------------------------------------------


def test_an_empty_path_refs_is_rejected():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    response = _create_sweep(part["id"], profile["id"], [])
    assert response.status_code == 422


def test_a_path_ref_pointing_to_a_point_instead_of_a_line_is_rejected():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    point = _add_point(profile["sketch_id"], 5.0, 5.0)
    bad_ref = {"sketch_id": profile["sketch_id"], "entity_type": "point", "entity_id": point["id"]}
    response = _create_sweep(part["id"], profile["id"], [bad_ref])
    assert response.status_code == 422


def test_a_path_ref_with_an_unknown_entity_id_is_rejected_as_invalid_path_ref():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    bad_ref = {"sketch_id": profile["sketch_id"], "entity_type": "line", "entity_id": "no-such-line"}
    response = _create_sweep(part["id"], profile["id"], [bad_ref])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_path_ref"


def test_disconnected_path_segments_are_rejected():
    """Two path segments whose endpoints never coincide anywhere in 3D
    world space - the position-based connectivity check `_resolve_path_
    wire` needs precisely because cross-Sketch entries have no shared Point
    id to fall back on."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature_a, path_line_a = _create_straight_path_sketch_feature(part["id"])

    path_feature_b = _create_sketch_feature(part["id"], "YZ")
    b0 = _add_point(path_feature_b["sketch_id"], 100.0, 100.0)
    b1 = _add_point(path_feature_b["sketch_id"], 100.0, 110.0)
    line_b = _add_line(path_feature_b["sketch_id"], b0["id"], b1["id"])

    path_refs = [
        _path_ref(path_feature_a["sketch_id"], path_line_a["id"]),
        _path_ref(path_feature_b["sketch_id"], line_b["id"]),
    ]
    response = _create_sweep(part["id"], profile["id"], path_refs)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "disconnected_path"


def test_cut_with_an_empty_target_body_ids_is_rejected():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])],
        mode="cut", target_body_ids=[],
    )
    assert response.status_code == 422


def test_a_target_body_ids_entry_naming_an_unknown_feature_is_rejected():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])],
        mode="cut", target_body_ids=["no-such-feature"],
    )
    assert response.status_code == 400


# --- Editing / rollback ------------------------------------------------------


def test_patch_updates_the_path_refs_and_the_mesh_reflects_it():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    short_path_feature, short_path_line = _create_straight_path_sketch_feature(part["id"], length=5.0)
    created = _create_sweep(
        part["id"], profile["id"], [_path_ref(short_path_feature["sketch_id"], short_path_line["id"])]
    ).json()
    mesh_short = _mesh(part["id"])[0]["mesh"]

    long_path_feature, long_path_line = _create_straight_path_sketch_feature(part["id"], length=20.0)
    patch_response = client.patch(
        f"/document/parts/{part['id']}/sweep-features/{created['id']}",
        json={"path_refs": [_path_ref(long_path_feature["sketch_id"], long_path_line["id"])]},
    )
    assert patch_response.status_code == 200

    mesh_long = _mesh(part["id"])[0]["mesh"]
    assert mesh_long["vertices"] != mesh_short["vertices"]


def test_patch_re_validates_the_merged_candidate_and_rejects_a_disconnected_path():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    created = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    ).json()

    bad_ref = {"sketch_id": path_feature["sketch_id"], "entity_type": "line", "entity_id": "gone"}
    patch_response = client.patch(
        f"/document/parts/{part['id']}/sweep-features/{created['id']}",
        json={"path_refs": [bad_ref]},
    )
    assert patch_response.status_code == 422

    # A rejected PATCH must never leave the Feature half-updated.
    features = client.get(f"/document/parts/{part['id']}/features").json()
    sweep_entry = next(f for f in features if f["id"] == created["id"])
    assert sweep_entry["path_refs"][0]["entity_id"] == path_line["id"]


# --- Cascade delete ------------------------------------------------------------


def test_cascade_deleting_the_profile_sketch_takes_the_sweep_with_it():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    sweep = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{profile['id']}/cascade")
    assert response.status_code == 200
    assert sweep["id"] in response.json()["deleted_feature_ids"]


def test_cascade_deleting_a_path_sketch_takes_the_sweep_with_it():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
    sweep = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{path_feature['id']}/cascade")
    assert response.status_code == 200
    assert sweep["id"] in response.json()["deleted_feature_ids"]


# --- Sweep direction (on-device feedback: "went in the wrong direction... ---
# ...not always the case") --------------------------------------------------


def test_resolve_path_wire_reverses_an_arc_segment_walked_back_to_front():
    """On-device feedback ("sweep around an arc guide curve went the wrong
    direction ... not always the case"): `_resolve_path_segment` always
    builds an Arc's edge in the fixed sense its own stored start/end point
    give it, regardless of which way the path is actually being walked -
    `resolve_path_wire` must reverse that edge (`_reversed_edge`, a real
    `Geom_Curve.Reversed()`) whenever the chain walks it back-to-front, not
    leave it in its arbitrary drawn sense.

    Verified directly against the wire's own edges (not just "the sweep
    didn't 500") - a bare `TopoDS_Shape.Reversed()` flag flip is NOT
    sufficient here (confirmed on-device this session:
    `BRepBuilderAPI_MakeWire.Add` already re-derives each edge's own
    Orientation flag from real connectivity regardless of what the caller
    passed in, silently discarding a flag-only reversal) - the real
    signature of a correct fix is that every edge's own RAW curve
    parametrization (`BRepAdaptor_Curve`, ignoring Orientation) already
    matches the wire's connected walk direction, so `MakeWire` never needs
    to store any edge as `TopAbs_REVERSED` at all.

    Same Line/Arc pair for both cases, only `path_refs`' own list order
    swapped (exactly what picking the same two path segments in the
    opposite order in the UI would produce) - the Line is built with its
    own natural direction *opposite* of how the chain needs it walked when
    placed second, so whichever segment ends up second is the one that
    must flip."""
    part = _create_part()
    path_feature = _create_sketch_feature(part["id"], "XZ")
    p_origin = _add_point(path_feature["sketch_id"], 0.0, 0.0)
    p_mid = _add_point(path_feature["sketch_id"], 10.0, 10.0)
    p_far = _add_point(path_feature["sketch_id"], 20.0, 10.0)
    center = _add_point(path_feature["sketch_id"], 0.0, 10.0)
    # Quarter-circle Arc, always stored p_origin -> p_mid (end_angle=0.0
    # places the computed end Point at (10, 10), mirroring
    # _create_arc_path_sketch_feature's own convention).
    arc = _add_arc(path_feature["sketch_id"], center, p_origin, end_angle=0.0)
    # The Line's own natural (start -> end) direction is p_far -> p_mid -
    # the opposite of how it needs to be walked once it's chained after
    # the Arc (which ends at p_mid).
    line = _add_line(path_feature["sketch_id"], p_far["id"], p_mid["id"])

    part_obj = get_part_or_404(part["id"])
    arc_ref = SketchEntityRef(
        sketch_id=path_feature["sketch_id"], entity_type=SketchEntityType.ARC, entity_id=arc["id"]
    )
    line_ref = SketchEntityRef(
        sketch_id=path_feature["sketch_id"], entity_type=SketchEntityType.LINE, entity_id=line["id"]
    )

    def wire_edges(path_refs):
        wire = resolve_path_wire(part_obj, path_refs, {}, frozenset())
        explorer = BRepTools_WireExplorer(wire)
        edges = []
        while explorer.More():
            edges.append(explorer.Current())
            explorer.Next()
        return edges

    def arc_edge_world_span(edges):
        """The one CIRCLE-type edge's own raw (Orientation-ignoring)
        first/last 3D points - `.Value(first)`/`.Value(last)`."""
        for edge in edges:
            adaptor = BRepAdaptor_Curve(edge)
            if adaptor.GetType() == GeomAbs_Circle:
                a = adaptor.Value(adaptor.FirstParameter())
                b = adaptor.Value(adaptor.LastParameter())
                return edge, (a.X(), a.Y(), a.Z()), (b.X(), b.Y(), b.Z())
        raise AssertionError("no circle-type edge found in the resolved path wire")

    # Arc first (segment 0, never reversed) - its raw curve keeps its own
    # natural (p_origin -> p_mid) direction.
    edges_arc_first = wire_edges([arc_ref, line_ref])
    arc_edge_1, first_span_a, first_span_b = arc_edge_world_span(edges_arc_first)
    assert arc_edge_1.Orientation() == TopAbs_FORWARD

    # Arc second (segment 1) - now walked back-to-front (the chain arrives
    # at p_mid via the Line first, so the Arc must be traversed p_mid ->
    # p_origin) - its raw curve span must be the exact reverse of the
    # arc-first case's, not the entity's own fixed drawn direction.
    edges_line_first = wire_edges([line_ref, arc_ref])
    arc_edge_2, second_span_a, second_span_b = arc_edge_world_span(edges_line_first)
    assert arc_edge_2.Orientation() == TopAbs_FORWARD

    tolerance = 1e-6
    assert math.dist(first_span_a, second_span_b) < tolerance
    assert math.dist(first_span_b, second_span_a) < tolerance


def test_sweep_along_an_arc_guide_drawn_in_either_direction_still_produces_a_body():
    """The end-to-end regression the on-device report itself describes: a
    sweep along a 2-segment (Line + Arc) path succeeds and produces a
    single body regardless of which of the two segments happens to be
    picked (listed in `path_refs`) first - exercising the exact
    back-to-front Arc-reversal path `test_resolve_path_wire_reverses_an_
    arc_segment_walked_back_to_front` verifies directly at the wire level,
    through the full HTTP create + mesh surface."""
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature = _create_sketch_feature(part["id"], "XZ")
    p_origin = _add_point(path_feature["sketch_id"], 0.0, 0.0)
    p_mid = _add_point(path_feature["sketch_id"], 10.0, 10.0)
    p_far = _add_point(path_feature["sketch_id"], 20.0, 10.0)
    center = _add_point(path_feature["sketch_id"], 0.0, 10.0)
    arc = _add_arc(path_feature["sketch_id"], center, p_origin, end_angle=0.0)
    line = _add_line(path_feature["sketch_id"], p_far["id"], p_mid["id"])

    arc_ref = _path_ref(path_feature["sketch_id"], arc["id"], "arc")
    line_ref = _path_ref(path_feature["sketch_id"], line["id"])

    for path_refs in ([arc_ref, line_ref], [line_ref, arc_ref]):
        response = _create_sweep(part["id"], profile["id"], path_refs)
        assert response.status_code == 201, response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 2
