"""Integration tests for `SweptSurfaceFeature` over the real HTTP API -
mirrors `test_stage_h_sweep.py`'s own profile/path helper conventions. Needs
a real pythonocc-core environment (not available in this repo's own dev
sandbox - see `app.document.swept_surface`'s own module docstring)."""

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


def _add_open_chain(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y) for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_profile_sketch_feature(part_id: str, *, size: float = 2.0) -> dict:
    """A small square Profile at the origin on the XY plane - deliberately
    small relative to the path fixture below, mirroring `test_stage_h_
    sweep.py`'s own "small profile, no self-intersection against path
    corners" reasoning."""
    feature = _create_sketch_feature(part_id, "XY")
    _add_square(feature["sketch_id"], 0.0, 0.0, size)
    return feature


def _create_hollow_profile_sketch_feature(part_id: str, *, outer: float = 4.0, inner: float = 2.0) -> dict:
    feature = _create_sketch_feature(part_id, "XY")
    center_outer = outer / 2
    center_inner = inner / 2
    _add_square(feature["sketch_id"], -center_outer, -center_outer, outer)
    _add_square(feature["sketch_id"], -center_inner, -center_inner, inner)
    return feature


def _create_straight_path_sketch_feature(part_id: str, *, length: float = 10.0) -> tuple[dict, dict]:
    feature = _create_sketch_feature(part_id, "XZ")
    p0 = _add_point(feature["sketch_id"], 0.0, 0.0)
    p1 = _add_point(feature["sketch_id"], 0.0, length)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return feature, line


def _path_ref(sketch_id: str, entity_id: str, entity_type: str = "line") -> dict:
    return {"sketch_id": sketch_id, "entity_type": entity_type, "entity_id": entity_id}


def _create_swept_surface(part_id: str, sketch_feature_id: str, path_refs: list[dict], *, profile_refs=None):
    payload = {"sketch_feature_id": sketch_feature_id, "path_refs": path_refs}
    if profile_refs is not None:
        payload["profile_refs"] = profile_refs
    return client.post(f"/document/parts/{part_id}/swept-surface-features", json=payload)


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


# --- Creation validation -------------------------------------------------------


def test_create_swept_surface_feature_along_a_single_straight_segment_succeeds():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    response = _create_swept_surface(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "swept_surface"
    assert body["produces"] == "surface"


def test_create_swept_surface_feature_on_an_open_chain_succeeds():
    """On-device feedback ("swept surface should support an open profile
    sketch"): unlike Sweep (which builds a solid, and genuinely needs a
    closed cross-section), a Swept Surface's own `BRepOffsetAPI_
    MakePipeShell` never calls `.MakeSolid()` and has no dependency on the
    profile wire being closed - see `app.document.swept_surface`'s own
    module docstring."""
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    _add_open_chain(feature["sketch_id"], 0.0, 0.0, 2.0)
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    response = _create_swept_surface(
        part["id"], feature["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "swept_surface"
    assert body["produces"] == "surface"


def test_swept_surface_feature_on_an_open_chain_produces_a_valid_open_shell():
    """Real-OCCT geometry check, not just "the request didn't fail" - the
    resulting shape must be a genuinely valid open shell (an open chain
    swept along a straight path) with no solid at all (this tool never
    calls `.MakeSolid()` - see `app.document.swept_surface._shell_for_
    wire`)."""
    from OCC.Core.BRepCheck import BRepCheck_Analyzer
    from OCC.Core.TopAbs import TopAbs_SOLID
    from OCC.Core.TopExp import TopExp_Explorer

    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    _add_open_chain(feature["sketch_id"], 0.0, 0.0, 2.0)
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    response = _create_swept_surface(
        part["id"], feature["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )
    assert response.status_code == 201

    bodies = _get_bodies(part["id"])
    assert len(bodies) == 1

    part_obj = get_part_or_404(part["id"])
    shapes = compute_part_bodies(part_obj)
    shape = shapes[bodies[0]["body_id"]]

    assert BRepCheck_Analyzer(shape).IsValid()
    solid_explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    assert not solid_explorer.More()


def test_create_swept_surface_feature_with_no_path_refs_is_rejected():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])

    response = _create_swept_surface(part["id"], profile["id"], [])

    assert response.status_code == 422


def test_create_swept_surface_feature_with_a_hollow_profile_is_rejected():
    """v1 scope: a profile with holes has no shell equivalent for the
    volumetric boolean-cut technique a hollow SweepFeature uses."""
    part = _create_part()
    profile = _create_hollow_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"])

    response = _create_swept_surface(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "swept_surface_holes_unsupported"


# --- Geometry --------------------------------------------------------------


def test_swept_surface_produces_an_open_shell_body_in_the_mesh_response():
    part = _create_part()
    profile = _create_profile_sketch_feature(part["id"])
    path_feature, path_line = _create_straight_path_sketch_feature(part["id"], length=10.0)

    surface = _create_swept_surface(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], path_line["id"])]
    ).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["source"] == "computed"
    assert surface_body["is_surface"] is True
    assert len(surface_body["mesh"]["vertices"]) > 0


# --- native_format round-trip -------------------------------------------------


def test_swept_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        profile = _create_profile_sketch_feature(part["id"])
        path_feature, path_line = _create_straight_path_sketch_feature(part["id"])
        path_refs = [_path_ref(path_feature["sketch_id"], path_line["id"])]
        surface = _create_swept_surface(part["id"], profile["id"], path_refs).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200
        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "swept_surface")
        assert round_tripped["sketch_feature_id"] == surface["sketch_feature_id"]
        # `path_refs` entries are now `SketchOrEdgeRefSchema` (see
        # app.document.models.SketchOrEdgeRef), which always echoes its own
        # `edge_ref` field (None for a Sketch-entity entry) alongside the
        # original flat sketch_id/entity_type/entity_id fields.
        assert round_tripped["path_refs"] == [{**ref, "edge_ref": None} for ref in path_refs]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
