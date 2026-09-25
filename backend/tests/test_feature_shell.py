"""Real-OCCT tests for `ShellFeature` (v1, uniform thickness): hollows a
solid Body, opening every face in `faces_to_remove` and giving every
remaining face a uniform wall thickness via `app.document.shell`
(`_thin_wall_solid_for_direction` -> `MakeThickSolidByJoin` with real
`ClosingFaces`). Covers the resolver directly (against a bare OCCT box, no
router involved), the router's create/update/validation surface, native
round-trip, and cascade delete. Helpers copy-pasted from
test_feature_delete_face.py, same as every other test_feature_*.py file.
"""

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCC.Core.TopExp import topexp
from OCC.Core.TopTools import TopTools_IndexedMapOfShape
from fastapi import HTTPException

from app.document.models import ShellFeature, SubShapeRef, SubShapeType, ThicknessDirection
from app.document.shell import resolve_shell_from_bodies
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Direct resolver helpers --------------------------------------------------


def _volume(shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def _bbox(shape) -> tuple[float, float, float, float, float, float]:
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    return box.Get()


def _face_index_with_max_z(shape) -> int:
    """0-based `SubShapeRef.index` (same `topexp.MapShapes` enumeration
    `resolve_subshape_from_bodies` uses) of the face whose own bounding box
    sits highest - the top face of an axis-aligned box."""
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_FACE, face_map)
    best_index, best_z = -1, float("-inf")
    for i in range(1, face_map.Size() + 1):
        zmin = _bbox(face_map.FindKey(i))[2]
        if zmin > best_z:
            best_index, best_z = i - 1, zmin
    return best_index


def _box_bodies() -> tuple[dict, int]:
    box = BRepPrimAPI_MakeBox(20.0, 20.0, 10.0).Shape()
    return {"body": box}, _face_index_with_max_z(box)


def _shell(top_index: int, thickness: float, direction: ThicknessDirection, body_id: str = "body"):
    return ShellFeature(
        id="shell-1",
        body_id=body_id,
        faces_to_remove=[SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=top_index)],
        thickness=thickness,
        thickness_direction=direction,
    )


# --- resolve_shell_from_bodies (direct, no router) -------------------------------


def test_inward_shell_of_a_box_with_its_top_removed_is_a_hollow_solid_with_the_right_wall():
    bodies, top_index = _box_bodies()
    body_id, result = resolve_shell_from_bodies(bodies, _shell(top_index, 2.0, ThicknessDirection.INWARD))

    assert body_id == "body"
    assert result.ShapeType() == TopAbs_SOLID
    assert BRepCheck_Analyzer(result).IsValid()
    # Outer dimensions preserved; interior cavity is (20-4) x (20-4) x (10-2).
    xmin, ymin, zmin, xmax, ymax, zmax = _bbox(result)
    assert xmin == pytest.approx(0.0, abs=1e-3) and xmax == pytest.approx(20.0, abs=1e-3)
    assert ymin == pytest.approx(0.0, abs=1e-3) and ymax == pytest.approx(20.0, abs=1e-3)
    assert zmin == pytest.approx(0.0, abs=1e-3) and zmax == pytest.approx(10.0, abs=1e-3)
    expected = 20 * 20 * 10 - 16 * 16 * 8
    assert _volume(result) == pytest.approx(expected, rel=1e-3)


def test_outward_shell_of_a_box_with_its_top_removed_grows_the_wall_outside():
    bodies, top_index = _box_bodies()
    _, result = resolve_shell_from_bodies(bodies, _shell(top_index, 2.0, ThicknessDirection.OUTWARD))

    assert result.ShapeType() == TopAbs_SOLID
    assert BRepCheck_Analyzer(result).IsValid()
    # Cavity is the original box; walls/floor grow 2 outward, rim stays at z=10.
    xmin, _, zmin, xmax, _, zmax = _bbox(result)
    assert xmin == pytest.approx(-2.0, abs=1e-3) and xmax == pytest.approx(22.0, abs=1e-3)
    assert zmin == pytest.approx(-2.0, abs=1e-3) and zmax == pytest.approx(10.0, abs=1e-3)
    expected = 24 * 24 * 12 - 20 * 20 * 10
    assert _volume(result) == pytest.approx(expected, rel=1e-3)


def test_symmetric_shell_straddles_the_original_boundary():
    bodies, top_index = _box_bodies()
    _, result = resolve_shell_from_bodies(bodies, _shell(top_index, 2.0, ThicknessDirection.SYMMETRIC))

    assert BRepCheck_Analyzer(result).IsValid()
    expected = 22 * 22 * 11 - 18 * 18 * 9
    assert _volume(result) == pytest.approx(expected, rel=1e-3)


def test_shell_with_a_face_from_another_body_is_a_mixed_body_selection():
    bodies, top_index = _box_bodies()
    bodies["other"] = BRepPrimAPI_MakeBox(5.0, 5.0, 5.0).Shape()
    feature = _shell(top_index, 2.0, ThicknessDirection.INWARD)
    feature.body_id = "other"

    with pytest.raises(HTTPException) as exc_info:
        resolve_shell_from_bodies(bodies, feature)
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "mixed_body_selection"


def test_shell_thicker_than_the_box_fails_closed():
    bodies, top_index = _box_bodies()
    with pytest.raises(HTTPException) as exc_info:
        resolve_shell_from_bodies(bodies, _shell(top_index, 50.0, ThicknessDirection.INWARD))
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "shell_failed"


# --- Router helpers --------------------------------------------------------------


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


def _make_box(part_id: str, size: float = 20.0, height: float = 10.0) -> str:
    sketch_feature = _create_sketch_feature(part_id)
    sketch_id = sketch_feature["sketch_id"]
    corners = [
        _add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": height,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()["id"]


def _top_face_index(part_id: str, body_id: str) -> int:
    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    bodies = compute_part_bodies(get_part_or_404(part_id))
    return _face_index_with_max_z(bodies[body_id])


def _face_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "face", "index": index}


def _create_shell(part_id: str, body_id: str, face_refs: list[dict], thickness: float = 2.0, **extra):
    return client.post(
        f"/document/parts/{part_id}/shell-features",
        json={"body_id": body_id, "faces_to_remove": face_refs, "thickness": thickness, **extra},
    )


def _body_volume(part_id: str, body_id: str) -> float:
    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    return _volume(compute_part_bodies(get_part_or_404(part_id))[body_id])


# --- Router ----------------------------------------------------------------------


def test_create_shell_feature_hollows_the_body_in_place():
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)

    response = _create_shell(part["id"], body_id, [_face_ref(body_id, top)], thickness_direction="inward")

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "shell"
    assert body["body_id"] == body_id
    assert body["thickness"] == 2.0
    assert body["thickness_direction"] == "inward"
    assert body["produces"] == "body"
    assert body["locked"] is False
    assert _body_volume(part["id"], body_id) == pytest.approx(20 * 20 * 10 - 16 * 16 * 8, rel=1e-3)


def test_create_shell_defaults_to_outward():
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)

    response = _create_shell(part["id"], body_id, [_face_ref(body_id, top)])

    assert response.status_code == 201
    assert response.json()["thickness_direction"] == "outward"


def test_create_shell_with_no_faces_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"])
    assert _create_shell(part["id"], body_id, []).status_code == 422


def test_create_shell_with_a_non_face_ref_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"])
    response = _create_shell(part["id"], body_id, [{"body_id": body_id, "shape_type": "edge", "index": 0}])
    assert response.status_code == 422


@pytest.mark.parametrize("thickness", [0.0, -1.0])
def test_create_shell_with_a_non_positive_thickness_is_rejected(thickness):
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)
    response = _create_shell(part["id"], body_id, [_face_ref(body_id, top)], thickness=thickness)
    assert response.status_code == 400


def test_create_shell_with_an_unknown_body_is_rejected():
    part = _create_part()
    _make_box(part["id"])
    response = _create_shell(part["id"], "nope", [_face_ref("nope", 0)])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"


def test_update_shell_changes_thickness_and_direction():
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)
    shell = _create_shell(part["id"], body_id, [_face_ref(body_id, top)], thickness_direction="inward").json()

    response = client.patch(
        f"/document/parts/{part['id']}/shell-features/{shell['id']}",
        json={"thickness": 1.0, "thickness_direction": "outward"},
    )

    assert response.status_code == 200
    assert response.json()["thickness"] == 1.0
    assert response.json()["thickness_direction"] == "outward"
    assert _body_volume(part["id"], body_id) == pytest.approx(22 * 22 * 11 - 20 * 20 * 10, rel=1e-3)


def test_update_shell_with_invalid_thickness_leaves_the_feature_unchanged():
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)
    shell = _create_shell(part["id"], body_id, [_face_ref(body_id, top)]).json()

    response = client.patch(
        f"/document/parts/{part['id']}/shell-features/{shell['id']}", json={"thickness": 0.0}
    )

    assert response.status_code == 400
    features = client.get(f"/document/parts/{part['id']}/features").json()
    assert next(f for f in features if f["id"] == shell["id"])["thickness"] == 2.0


def test_update_unknown_shell_feature_is_404():
    part = _create_part()
    response = client.patch(f"/document/parts/{part['id']}/shell-features/nope", json={"thickness": 1.0})
    assert response.status_code == 404


def test_shell_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"])
        top = _top_face_index(part["id"], body_id)
        shell = _create_shell(
            part["id"], body_id, [_face_ref(body_id, top)], thickness_direction="symmetric"
        ).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200
        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "shell")
        assert round_tripped["body_id"] == shell["body_id"]
        assert round_tripped["faces_to_remove"] == shell["faces_to_remove"]
        assert round_tripped["thickness"] == shell["thickness"]
        assert round_tripped["thickness_direction"] == "symmetric"
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_deleting_the_bodys_owning_extrude_cascade_deletes_the_shell():
    part = _create_part()
    body_id = _make_box(part["id"])
    top = _top_face_index(part["id"], body_id)
    shell = _create_shell(part["id"], body_id, [_face_ref(body_id, top)]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert shell["id"] in response.json()["deleted_feature_ids"]
