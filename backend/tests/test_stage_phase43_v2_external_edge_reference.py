"""Sketcher-roadmap Phase 4.3 v2: real-OCCT tests for the new materialize-
a-body-edge endpoint (`POST .../external-references/edge`) - needs actual
edge/vertex topology extraction (`app.document.extrude.edge_endpoint_
vertex_refs`), which the OCC-free `test_stage_phase43_external_references.py`
file has no way to exercise at all (there's no way to fake `topexp.
Vertices` without a real OCCT shape).

Needs a real pythonocc-core environment (not available in this sandbox -
see the recurring caveat in docs/status.md) since `app.main` imports OCC
directly - `python3 -m py_compile`-verified/manually reviewed only here,
same as every other OCCT-touching backend file in this project until real
CI runs it.

Same helper conventions (copy-pasted, not shared via conftest) as every
other test_stage*.py file in this directory - see test_stage_b1_subshape.py.
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_extrude_feature(part_id: str, sketch_feature_id: str, **overrides) -> dict:
    payload = {
        "sketch_feature_id": sketch_feature_id,
        "extrude_type": "boss",
        "start_distance": 0.0,
        "end_distance": 10.0,
        "target_body_ids": [],
        **overrides,
    }
    response = client.post(f"/document/parts/{part_id}/extrude-features", json=payload)
    assert response.status_code == 201
    return response.json()


def _boss_box(part_id: str) -> dict:
    """A single 10x10x10 box Body (6 faces, 12 edges, 8 vertices) - same
    deterministic-by-construction primitive test_stage_b1_subshape.py's own
    `_boss_box` uses."""
    sketch = _create_sketch_feature(part_id, plane="XY")
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    return _create_extrude_feature(part_id, sketch["id"])


def _second_sketch_feature(part_id: str) -> dict:
    """A Sketch on a plane that doesn't coincide with `_boss_box`'s own
    geometry - the on-device scenario this endpoint exists for is always a
    *different* Sketch referencing an *existing* Body, never a Sketch
    referencing its own source geometry."""
    return _create_sketch_feature(part_id, plane="XZ")


def test_materializing_an_edge_creates_two_external_points_and_a_real_line_between_them():
    part = _create_part()
    box = _boss_box(part["id"])
    sketch_feature = _second_sketch_feature(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/features/sketch/{sketch_feature['id']}/external-references/edge",
        json={"body_id": box["id"], "edge_index": 0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["line"]["start_point_id"] == body["start_point"]["id"]
    assert body["line"]["end_point_id"] == body["end_point"]["id"]
    # A boss box's edges are each exactly 10 units long, and the edge
    # endpoints must be two genuinely distinct points (a real Line, not a
    # degenerate one) at a matching length in the Sketch's own local plane.
    assert body["line"]["length"] == 10.0
    assert body["start_point"]["id"] != body["end_point"]["id"]
    assert (body["start_point"]["x"], body["start_point"]["y"]) != (
        body["end_point"]["x"],
        body["end_point"]["y"],
    )
    # On-device feedback: a materialized Body edge is a reference to
    # dimension against, not new solid geometry the user drew - it must be
    # construction so it's excluded from profile/extrude detection the same
    # way every other reference-only Line already is.
    assert body["line"]["construction"] is True


def test_the_materialized_line_is_pinned_and_survives_a_solve_unmoved():
    part = _create_part()
    box = _boss_box(part["id"])
    sketch_feature = _second_sketch_feature(part["id"])

    created = client.post(
        f"/document/parts/{part['id']}/features/sketch/{sketch_feature['id']}/external-references/edge",
        json={"body_id": box["id"], "edge_index": 0},
    ).json()

    solve_response = client.post(f"/sketch/sketches/{sketch_feature['sketch_id']}/solve")
    assert solve_response.status_code == 200

    points_response = client.get(f"/sketch/sketches/{sketch_feature['sketch_id']}/points")
    assert points_response.status_code == 200
    points_by_id = {p["id"]: p for p in points_response.json()}
    for endpoint_key in ("start_point", "end_point"):
        expected = created[endpoint_key]
        actual = points_by_id[expected["id"]]
        assert actual["x"] == expected["x"]
        assert actual["y"] == expected["y"]


def test_a_dimension_between_the_two_materialized_edge_points_works_unmodified():
    # Item 3 of the v2 scoping: once materialized, every existing
    # DistanceConstraint path already works against these Points with zero
    # new constraint machinery - assert that end to end, the same way v1's
    # own tests confirmed it for a single vertex.
    part = _create_part()
    box = _boss_box(part["id"])
    sketch_feature = _second_sketch_feature(part["id"])

    created = client.post(
        f"/document/parts/{part['id']}/features/sketch/{sketch_feature['id']}/external-references/edge",
        json={"body_id": box["id"], "edge_index": 0},
    ).json()

    constraint_response = client.post(
        f"/sketch/sketches/{sketch_feature['sketch_id']}/constraints",
        json={
            "point_a_id": created["start_point"]["id"],
            "point_b_id": created["end_point"]["id"],
            "distance": 10.0,
        },
    )
    assert constraint_response.status_code == 201

    solve_response = client.post(f"/sketch/sketches/{sketch_feature['sketch_id']}/solve")
    assert solve_response.status_code == 200
    assert solve_response.json()["converged"] is True


def test_missing_edge_index_returns_a_structured_missing_reference_422():
    part = _create_part()
    box = _boss_box(part["id"])
    sketch_feature = _second_sketch_feature(part["id"])

    response = client.post(
        f"/document/parts/{part['id']}/features/sketch/{sketch_feature['id']}/external-references/edge",
        json={"body_id": box["id"], "edge_index": 999},
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {
        "type": "missing_reference",
        "body_id": box["id"],
        "shape_type": "edge",
        "index": 999,
    }


def test_a_sketch_feature_referencing_a_now_deleted_body_reports_lost_reference():
    part = _create_part()
    box = _boss_box(part["id"])
    sketch_feature = _second_sketch_feature(part["id"])

    client.post(
        f"/document/parts/{part['id']}/features/sketch/{sketch_feature['id']}/external-references/edge",
        json={"body_id": box["id"], "edge_index": 0},
    )

    delete_response = client.delete(f"/document/parts/{part['id']}/features/{box['id']}")
    assert delete_response.status_code == 204

    features_response = client.get(f"/document/parts/{part['id']}/features")
    assert features_response.status_code == 200
    [sketch_entry] = [f for f in features_response.json() if f["id"] == sketch_feature["id"]]
    assert sketch_entry["has_lost_reference"] is True
