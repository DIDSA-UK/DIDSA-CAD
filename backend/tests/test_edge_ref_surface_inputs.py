"""Real-OCCT tests for "surface tools should support edges... as inputs"
(second-round testing feedback): `SweepFeature`/`SweptSurfaceFeature.
path_refs` and `LoftSection.edge_ref` (used by `LoftFeature`/
`LoftSurfaceFeature`/`RuledSurfaceFeature`) can now each accept a plain
Body edge (`SubShapeRef`) alongside the existing Sketch-entity references -
see `app.document.models.SketchOrEdgeRef`/`LoftSection.edge_ref`'s own
docstrings. All touch `app.main`/`app.document.sweep`/`app.document.loft`/
`app.document.loft_surface`/`app.document.ruled_surface`, which import
OCC.Core directly - run against the real `didsa-cad` conda OCCT
environment, not just reviewed.

Every fixture below builds a 10x10x10 cube (a square Sketch extruded 0-10)
first, purely as a source of real Body edges - every edge on this cube is a
straight length-10 segment, so which of its 12 edges gets picked by index
never needs to be known ahead of time for any of these tests to make sense
geometrically."""

from fastapi.testclient import TestClient
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
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
    return [_add_line(sketch_id, a["id"], b["id"]) for a, b in zip(corners, corners[1:] + corners[:1])]


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201, response.json()
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _cube_part_and_body() -> tuple[dict, str]:
    """A 10x10x10 cube - every one of its 12 edges is a straight, length-10
    segment, so `_edge_ref(body_id, i)` never needs a known-in-advance index
    for any test below to be geometrically sound."""
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _edge_ref(body_id: str, index: int) -> dict:
    return {"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": index}}


def _small_square_profile_sketch_feature(part_id: str, *, size: float = 2.0) -> dict:
    """A small square Profile at the origin on the XY plane - small enough
    relative to the cube-edge paths used below that the swept solid never
    self-intersects against a path's own length."""
    feature = _create_sketch_feature(part_id, "XY")
    _add_square(feature["sketch_id"], 0.0, 0.0, size)
    return feature


def _create_sweep(part_id: str, sketch_feature_id: str, path_refs: list[dict], *, mode: str = "boss") -> dict:
    return client.post(
        f"/document/parts/{part_id}/sweep-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "path_refs": path_refs,
            "mode": mode,
            "target_body_ids": [],
        },
    )


def _create_swept_surface(part_id: str, sketch_feature_id: str, path_refs: list[dict]) -> dict:
    return client.post(
        f"/document/parts/{part_id}/swept-surface-features",
        json={"sketch_feature_id": sketch_feature_id, "path_refs": path_refs},
    )


def _create_loft_surface(part_id: str, sections: list[dict], **overrides) -> dict:
    payload = {"sections": sections}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/loft-surface-features", json=payload)


def _create_ruled_surface(part_id: str, sections: list[dict]) -> dict:
    return client.post(f"/document/parts/{part_id}/ruled-surface-features", json={"sections": sections})


def _closed_square_section(part_id: str) -> dict:
    feature = _create_square_sketch_feature(part_id, x0=-1.0, y0=-1.0, size=2.0)
    return {"sketch_feature_id": feature["id"]}


def _open_chain_section(part_id: str) -> dict:
    """A single-Sketch open chain (2 Points, 1 Line) - the open-chain
    counterpart to `_closed_square_section`, exercising `LoftSurfaceFeature`'s
    own closed-fails/falls-back-to-open probe (`_resolve_sections`) with an
    `edge_ref` section riding along in the fallback branch too."""
    feature = _create_sketch_feature(part_id, "XY")
    a = _add_point(feature["sketch_id"], -1.0, 0.0)
    b = _add_point(feature["sketch_id"], 1.0, 0.0)
    _add_line(feature["sketch_id"], a["id"], b["id"])
    return {"sketch_feature_id": feature["id"]}


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


def _assert_valid(part_id: str, body_id: str) -> None:
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    assert BRepCheck_Analyzer(bodies[body_id]).IsValid()


# --- Sweep / Swept Surface along a Body edge --------------------------------


def test_boss_sweep_along_a_body_edge_succeeds():
    box_part, box_body_id = _cube_part_and_body()
    profile = _small_square_profile_sketch_feature(box_part["id"])

    response = _create_sweep(box_part["id"], profile["id"], [_edge_ref(box_body_id, 0)])

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "body"
    mesh = _mesh(box_part["id"])
    swept_body_id = next(m["body_id"] for m in mesh if m["body_id"] != box_body_id)
    _assert_valid(box_part["id"], swept_body_id)


def test_swept_surface_along_a_body_edge_produces_a_valid_open_shell():
    box_part, box_body_id = _cube_part_and_body()
    profile = _small_square_profile_sketch_feature(box_part["id"])

    response = _create_swept_surface(box_part["id"], profile["id"], [_edge_ref(box_body_id, 0)])

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "surface"
    mesh = _mesh(box_part["id"])
    surface_body_id = next(m["body_id"] for m in mesh if m["body_id"] != box_body_id)
    _assert_valid(box_part["id"], surface_body_id)
    # Only the *swept* body must be a shell with no solid inside it (the
    # cube itself is still a solid, and is deliberately not checked here).
    part = get_part_or_404(box_part["id"])
    bodies = compute_part_bodies(part)
    explorer = TopExp_Explorer(bodies[surface_body_id], TopAbs_SOLID)
    assert not explorer.More()


# --- Loft Surface between Body edges / edge + Sketch section ----------------


def test_loft_surface_between_two_body_edges_succeeds():
    box_part, box_body_id = _cube_part_and_body()

    response = _create_loft_surface(
        box_part["id"], [_edge_ref(box_body_id, 0), _edge_ref(box_body_id, 1)]
    )

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "surface"
    mesh = _mesh(box_part["id"])
    surface_body_id = next(m["body_id"] for m in mesh if m["body_id"] != box_body_id)
    _assert_valid(box_part["id"], surface_body_id)
    assert _face_count(box_part["id"], surface_body_id) >= 1


def test_loft_surface_between_a_body_edge_and_an_open_sketch_chain_succeeds():
    box_part, box_body_id = _cube_part_and_body()

    response = _create_loft_surface(
        box_part["id"], [_edge_ref(box_body_id, 0), _open_chain_section(box_part["id"])]
    )

    assert response.status_code == 201, response.json()
    mesh = _mesh(box_part["id"])
    surface_body_id = next(m["body_id"] for m in mesh if m["body_id"] != box_body_id)
    _assert_valid(box_part["id"], surface_body_id)


def test_loft_surface_section_with_edge_ref_and_reference_point_is_rejected():
    box_part, box_body_id = _cube_part_and_body()
    edge_section = _edge_ref(box_body_id, 0)
    closed = _closed_square_section(box_part["id"])
    edge_section_with_extra = {
        **edge_section,
        "reference_point": {
            "sketch_id": "does-not-matter",
            "entity_type": "point",
            "entity_id": "does-not-matter",
        },
    }

    response = _create_loft_surface(box_part["id"], [edge_section_with_extra, closed])

    assert response.status_code == 400, response.json()


# --- Ruled Surface between Body edges ---------------------------------------


def test_ruled_surface_between_two_body_edges_succeeds():
    box_part, box_body_id = _cube_part_and_body()

    response = _create_ruled_surface(box_part["id"], [_edge_ref(box_body_id, 0), _edge_ref(box_body_id, 1)])

    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["produces"] == "surface"
    mesh = _mesh(box_part["id"])
    surface_body_id = next(m["body_id"] for m in mesh if m["body_id"] != box_body_id)
    _assert_valid(box_part["id"], surface_body_id)
