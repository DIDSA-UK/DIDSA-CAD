"""Extrude Thin Solid: real-OCCT test for the rectangular-profile wall-
flatness/corner bug reported from on-device testing ("extrude thin solid
isn't working as desired with a rectangular sketch, the wall thickness is
wrong, not flat, lines look wrong"). Needs a real pythonocc-core
environment (not available in this repo's own dev sandbox - see
`app.document.shell_ops`'s own module docstring); `ast.parse`-verified/
manually reviewed only until this runs somewhere with a real OCCT kernel,
same caveat as every other OCCT-touching test in this project.

Root-caused (see `app.document.shell_ops._thicken_by_join`'s own doc
comment) to `BRepOffsetAPI_MakeThickSolid.MakeThickSolidBySimple`'s lack of
an explicit corner-join type - a naive per-face offset that can produce a
non-planar/slanted wall at a profile's sharp corners. This test builds
exactly that repro (a rectangular sketch profile, thin extrude) and checks
the actual geometry, not just that the request didn't fail - every face of
the resulting solid must come back planar, which a slanted/curved corner
artifact would fail directly."""

from fastapi.testclient import TestClient
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
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


def _add_rectangle(sketch_id: str, x0: float, y0: float, width: float, height: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + width, y0), (x0 + width, y0 + height), (x0, y0 + height)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_rectangle_sketch_feature(part_id: str, *, width: float = 20.0, height: float = 10.0) -> dict:
    feature = _create_sketch_feature(part_id, "XY")
    _add_rectangle(feature["sketch_id"], 0.0, 0.0, width, height)
    return feature


def _create_thin_extrude(
    part_id: str,
    sketch_feature_id: str,
    *,
    thickness: float,
    start_distance: float = 0.0,
    end_distance: float = 5.0,
):
    return client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": [],
            "thickness": thickness,
        },
    )


def _body_ids(part_id: str) -> list[str]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return [entry["body_id"] for entry in response.json()]


def _face_types(shape) -> list[int]:
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    types = []
    while explorer.More():
        types.append(BRepAdaptor_Surface(explorer.Current()).GetType())
        explorer.Next()
    return types


# --- Tests -------------------------------------------------------------------


def test_thin_extrude_of_a_rectangular_profile_has_only_planar_walls():
    """The reported defect: a rectangular sketch's thin-wall extrude comes
    back with a non-flat wall/bad lines near a corner. Every face of a
    thin-walled rectangular box should be a flat quad - inner walls, outer
    walls, and the two end rings alike - so any face that isn't
    `GeomAbs_Plane` is exactly the reported artifact."""
    part = _create_part()
    profile = _create_rectangle_sketch_feature(part["id"], width=20.0, height=10.0)

    response = _create_thin_extrude(part["id"], profile["id"], thickness=1.0)
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 1

    part_obj = get_part_or_404(part["id"])
    bodies = compute_part_bodies(part_obj)
    shape = bodies[body_ids[0]]

    assert BRepCheck_Analyzer(shape).IsValid()

    face_types = _face_types(shape)
    assert face_types, "expected at least one face on the thin-walled solid"
    assert all(face_type == GeomAbs_Plane for face_type in face_types)

    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    assert props.Mass() > 0
