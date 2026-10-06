"""Probe, written 2026-10-06 while building the VR design table's "dimension to the part's own geometry": does a Sketch's external-reference Point
(`POST .../external-references`, a `body_id` plus a raw OCCT vertex index) still track the SAME physical corner after an upstream edit?

Findings (see docs/roadmap.md "Reference drift", and docs/reference-identity-design.md for the fix):
  * Edits that keep the Body's topology (a different extrude depth, base-Sketch dimensions, a fillet radius) were always followed: the index still names the
    same corner. Covered by the passing tests below.
  * An upstream edit that CHANGES the topology (the fillet moved to another edge, or a second edge added) renumbers the vertices. Before the overhaul the
    reference then silently resolved to a DIFFERENT corner, with `has_lost_reference` False (these tests were xfail). References now carry a geometric
    signature and OCCT-history lineage: the reference follows its corner, or is flagged lost (when the edit consumed the corner); it never silently rebinds.

Needs a real pythonocc-core environment, like every other OCCT-touching test here. Same helper conventions as test_stage_phase43_v2_external_edge_reference.py.
"""

import pytest
from fastapi.testclient import TestClient

from app.document.create_plane import _resolve_vertex_position
from app.document.models import SubShapeRef, SubShapeType
from app.document.router import compute_part_bodies, get_part_or_404
from app.main import app
from app.sketch.store import all_sketches
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _json(response):
    assert response.status_code < 300, (response.status_code, response.text[:300])
    return response.json()


def _box_with_fillet(edge_index: int):
    """A 10 x 10 x 10 box (sketch XY square, extrude 10) with one edge filleted. Returns (part id, base sketch feature, box body/extrude id, fillet id)."""
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    corners = [
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}))
        for x, y in [(0, 0), (10, 0), (10, 10), (0, 10)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    fillet = _json(
        client.post(
            f"/document/parts/{part_id}/fillet-features",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": edge_index}], "radius": 2.0},
        )
    )
    return part_id, sketch, extrude["id"], fillet["id"]


def _vertex_positions(part_id: str, body_id: str) -> dict[int, tuple[float, float, float]]:
    bodies = compute_part_bodies(get_part_or_404(part_id))
    out = {}
    for i in range(200):
        try:
            p = _resolve_vertex_position(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.VERTEX, index=i))
        except Exception:
            break
        out[i] = (round(p.X(), 3), round(p.Y(), 3), round(p.Z(), 3))
    return out


def _track_far_corner(part_id: str, body_id: str):
    """A Sketch AFTER the fillet that references the box corner at (10, 10, 10). Returns (its feature, the pinned point id, that corner's index)."""
    corner = (10.0, 10.0, 10.0)
    index = next(i for i, v in _vertex_positions(part_id, body_id).items() if v == corner)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    point = _json(
        client.post(
            f"/document/parts/{part_id}/features/sketch/{sketch['id']}/external-references",
            json={"body_id": body_id, "vertex_index": index},
        )
    )
    return sketch, point["id"], index


def _where_is_the_reference_now(part_id: str, sketch_feature: dict, point_id: str):
    """Reads the Sketch feature (which refreshes its references against the Part as it is now), then the corner its reference names. Returns
    (that corner's position or None, the feature as the API reports it)."""
    feature = next(f for f in _json(client.get(f"/document/parts/{part_id}/features")) if f["id"] == sketch_feature["id"])
    ref = all_sketches()[feature["sketch_id"]].external_references[point_id]
    return _vertex_positions(part_id, ref.body_id).get(ref.vertex_index), feature


def test_a_fillet_radius_change_keeps_the_reference_on_its_corner():
    part_id, _, body_id, fillet_id = _box_with_fillet(0)
    sketch, point_id, index = _track_far_corner(part_id, body_id)
    _json(client.patch(f"/document/parts/{part_id}/fillet-features/{fillet_id}", json={"radius": 3.0}))
    now_at, feature = _where_is_the_reference_now(part_id, sketch, point_id)
    assert now_at == (10.0, 10.0, 10.0)
    assert not feature["has_lost_reference"] and feature["followed_reference_point_ids"] == []  # same index: nothing to report


def test_an_extrude_depth_change_moves_the_reference_with_its_corner():
    part_id, _, body_id, fillet_id = _box_with_fillet(0)
    sketch, point_id, _ = _track_far_corner(part_id, body_id)
    extrude_id = body_id
    _json(client.patch(f"/document/parts/{part_id}/extrude-features/{extrude_id}", json={"end_distance": 20.0}))
    points = {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}
    assert (points[point_id]["x"], points[point_id]["y"]) == (10.0, 10.0)  # in an XY sketch the height is not seen; the corner is still the (10, 10) one
    assert (10.0, 10.0, 20.0) in _vertex_positions(part_id, body_id).values()


@pytest.mark.parametrize("new_edge", [1, 3, 5, 8])
def test_moving_the_fillet_to_another_edge_does_not_silently_rebind_the_reference(new_edge: int):
    part_id, _, body_id, fillet_id = _box_with_fillet(0)
    sketch, point_id, index = _track_far_corner(part_id, body_id)
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet_id}",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": new_edge}]},
        )
    )
    now_at, feature = _where_is_the_reference_now(part_id, sketch, point_id)
    followed = now_at == (10.0, 10.0, 10.0)
    flagged = bool(feature.get("has_lost_reference")) and point_id in feature["lost_reference_point_ids"]
    assert followed or flagged, f"the reference now sits on {now_at} and nothing says so"
