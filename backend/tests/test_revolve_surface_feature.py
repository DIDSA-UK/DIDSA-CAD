"""Integration tests for `RevolveSurfaceFeature` over the real HTTP API -
mirrors `test_stage_f_revolve.py`'s own axis/profile helper conventions and
`test_surface.py`'s own closed-vs-open-chain tolerance tests. Needs a real
pythonocc-core environment (not available in this repo's own dev sandbox -
see `app.document.revolve_surface`'s own module docstring)."""

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


def _create_offset_square_sketch_feature(part_id: str, *, x0=10.0, y0=0.0, size=10.0, plane="XY") -> dict:
    """Offset away from the origin along X, mirroring `test_stage_f_
    revolve.py`'s own "ring/tube" setup - its own left edge (x=x0) is a
    valid, non-self-intersecting axis."""
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _axis_ref(sketch_id: str, line_id: str) -> dict:
    return {"sketch_id": sketch_id, "entity_type": "line", "entity_id": line_id}


def _create_standalone_axis_line(part_id: str, *, x: float, y0: float, y1: float, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    p0 = _add_point(feature["sketch_id"], x, y0)
    p1 = _add_point(feature["sketch_id"], x, y1)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return {"sketch_id": feature["sketch_id"], "line_id": line["id"]}


def _create_revolve_surface(
    part_id: str, sketch_feature_id: str, axis_ref: dict, *, angle: float = 180.0, profile_refs=None
):
    payload = {"sketch_feature_id": sketch_feature_id, "axis_ref": axis_ref, "angle": angle}
    if profile_refs is not None:
        payload["profile_refs"] = profile_refs
    return client.post(f"/document/parts/{part_id}/revolve-surface-features", json=payload)


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _body(bodies: list[dict], body_id: str) -> dict:
    return next(b for b in bodies if b["body_id"] == body_id)


# --- Creation validation -------------------------------------------------------


def test_create_revolve_surface_feature_on_a_closed_profile_succeeds():
    part = _create_part()
    profile = _create_offset_square_sketch_feature(part["id"])
    axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0, plane="XY")

    response = _create_revolve_surface(part["id"], profile["id"], _axis_ref(axis["sketch_id"], axis["line_id"]))

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "revolve_surface"
    assert body["produces"] == "surface"
    assert body["angle"] == 180.0


def test_create_revolve_surface_feature_on_an_open_chain_succeeds():
    """Mirrors SurfaceFeature's own closed-or-open tolerance - unlike Swept/
    Planar Surface, an open chain is a valid Revolve Surface source too."""
    part = _create_part()
    feature = _create_sketch_feature(part["id"])
    _add_open_chain(feature["sketch_id"], 10.0, 0.0, 10.0)
    axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)

    response = _create_revolve_surface(part["id"], feature["id"], _axis_ref(axis["sketch_id"], axis["line_id"]))

    assert response.status_code == 201


def test_create_revolve_surface_feature_with_invalid_axis_ref_is_rejected():
    part = _create_part()
    profile = _create_offset_square_sketch_feature(part["id"])
    # A Point cannot be used as a Revolve axis.
    point = _add_point(profile["sketch_id"], 0.0, 0.0)

    response = _create_revolve_surface(
        part["id"], profile["id"], {"sketch_id": profile["sketch_id"], "entity_type": "point", "entity_id": point["id"]}
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_axis_ref"


def test_create_revolve_surface_feature_with_zero_angle_is_rejected():
    part = _create_part()
    profile = _create_offset_square_sketch_feature(part["id"])
    axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)

    response = _create_revolve_surface(
        part["id"], profile["id"], _axis_ref(axis["sketch_id"], axis["line_id"]), angle=0.0
    )

    assert response.status_code == 400


def test_create_revolve_surface_feature_with_sketch_feature_id_not_in_part_is_rejected():
    part = _create_part()
    axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)

    response = _create_revolve_surface(
        part["id"], "not-a-real-feature-id", _axis_ref(axis["sketch_id"], axis["line_id"])
    )

    assert response.status_code == 400


# --- Geometry --------------------------------------------------------------


def test_revolve_surface_full_360_produces_a_body_in_the_mesh_response():
    part = _create_part()
    profile = _create_offset_square_sketch_feature(part["id"], x0=10.0, size=10.0)
    axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)

    surface = _create_revolve_surface(
        part["id"], profile["id"], _axis_ref(axis["sketch_id"], axis["line_id"]), angle=360.0
    ).json()

    bodies = _get_bodies(part["id"])
    surface_body = _body(bodies, surface["id"])
    assert surface_body["source"] == "computed"
    assert surface_body["is_surface"] is True
    assert len(surface_body["mesh"]["vertices"]) > 0


# --- native_format round-trip -------------------------------------------------


def test_revolve_surface_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        profile = _create_offset_square_sketch_feature(part["id"])
        axis = _create_standalone_axis_line(part["id"], x=10.0, y0=-5.0, y1=15.0)
        surface = _create_revolve_surface(
            part["id"], profile["id"], _axis_ref(axis["sketch_id"], axis["line_id"]), angle=270.0
        ).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200
        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "revolve_surface")
        assert round_tripped["sketch_feature_id"] == surface["sketch_feature_id"]
        assert round_tripped["angle"] == 270.0
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
