"""Which Feature made a face (`POST /document/parts/{part_id}/face-owner-features`, bug report 2026-11-17 item 2A): what a face pick adds
to a Pattern / Mirror scope on the Feature tab. Real OCCT; the part-building helpers are the Pattern / Mirror tests' own."""

from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import topexp
from OCC.Core.TopTools import TopTools_IndexedMapOfShape
from OCC.Core.TopoDS import topods

from app.document.extrude import compute_part_bodies
from app.document.store import get_document
from tests.test_stage_p_feature_pattern_mirror import (
    _create_extrude_feature,
    _create_part,
    _create_square_sketch_feature,
    _fixed_axis_direction,
    _fixed_plane_ref,
    _hole_cut,
    _plate,
    client,
)


def _faces(part_id: str, body_id: str) -> list[dict]:
    """Each face of the Body as {index, centre, normal (planar faces only, else None), area}, indexed as the selection indexes them."""
    part = get_document().parts[part_id]
    body = compute_part_bodies(part, frozenset())[body_id]
    faces = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, TopAbs_FACE, faces)
    out = []
    for i in range(faces.Size()):
        face = topods.Face(faces.FindKey(i + 1))
        props = GProp_GProps()
        brepgprop.SurfaceProperties(face, props)
        c = props.CentreOfMass()
        surface = BRepAdaptor_Surface(face)
        normal = None
        if surface.GetType() == GeomAbs_Plane:
            d = surface.Plane().Axis().Direction()
            normal = (round(abs(d.X())), round(abs(d.Y())), round(abs(d.Z())))
        out.append({"index": i, "centre": (c.X(), c.Y(), c.Z()), "normal": normal, "area": props.Mass()})
    return out


def _face(part_id: str, body_id: str, test) -> int:
    matches = [f["index"] for f in _faces(part_id, body_id) if test(f)]
    assert len(matches) == 1, matches
    return matches[0]


def _owners(part_id: str, body_id: str, indices: list[int]) -> list[str]:
    response = client.post(
        f"/document/parts/{part_id}/face-owner-features",
        json={"faces": [{"body_id": body_id, "shape_type": "face", "index": i} for i in indices]},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert [entry["face"]["subshape_ref"]["index"] for entry in body["features"]] == indices
    return [entry["feature_id"] for entry in body["features"]]


def _near(a: float, b: float) -> bool:
    return abs(a - b) < 1e-6


def test_block_and_through_hole():
    part_id = _create_part()["id"]
    plate = _plate(part_id)  # 40 x 40 x 10, centred
    cut = _hole_cut(part_id, plate, x0=1.0, y0=1.0)["id"]  # 2 x 2 square hole, x 1..3, y 1..3
    top = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 10.0))
    bottom = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 0.0))
    hole_wall = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 1.0))
    outer_wall = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], -20.0))
    # The hole's tool starts and ends on the top and bottom faces' planes: its caps are coplanar with them but cover only the hole.
    assert _owners(part_id, plate, [top, hole_wall, bottom, outer_wall]) == [plate, cut, plate, plate]


def test_boss_merged_into_the_block():
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    sketch = _create_square_sketch_feature(part_id, x0=-5.0, y0=-5.0, size=4.0)
    boss = _create_extrude_feature(part_id, sketch["id"], start_distance=10.0, end_distance=15.0, target_body_ids=[plate])
    assert boss.status_code == 201, boss.text
    boss_id = boss.json()["id"]
    side = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], -5.0))
    boss_top = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 15.0))
    block_top = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 10.0))
    assert _owners(part_id, plate, [side, boss_top, block_top]) == [boss_id, boss_id, plate]


def test_a_pocket_starting_on_the_top_face_does_not_claim_it():
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    sketch = _create_square_sketch_feature(part_id, x0=2.0, y0=2.0, size=6.0)
    pocket = _create_extrude_feature(part_id, sketch["id"], extrude_type="cut", start_distance=5.0, end_distance=10.0, target_body_ids=[plate])
    assert pocket.status_code == 201, pocket.text
    pocket_id = pocket.json()["id"]
    top = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 10.0))
    floor = _face(part_id, plate, lambda f: f["normal"] == (0, 0, 1) and _near(f["centre"][2], 5.0))
    wall = _face(part_id, plate, lambda f: f["normal"] == (0, 1, 0) and _near(f["centre"][1], 8.0))
    assert _owners(part_id, plate, [top, floor, wall]) == [plate, pocket_id, pocket_id]


def test_pattern_instance_faces_belong_to_the_pattern():
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    cut = _hole_cut(part_id, plate, x0=1.0, y0=1.0)["id"]
    pattern = client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": [],
            "pattern_type": "rectangular",
            "direction_1": _fixed_axis_direction("x"),
            "count_1": 3,
            "spacing_1": 5.0,
            "merge": "fuse_into_one",
            "tool_feature_ids": [cut],
        },
    )
    assert pattern.status_code == 201, pattern.text
    pattern_id = pattern.json()["id"]
    original = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 1.0))
    copy_1 = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 6.0))
    copy_2 = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 11.0))
    assert _owners(part_id, plate, [original, copy_1, copy_2]) == [cut, pattern_id, pattern_id]


def test_a_body_copy_pattern_body_is_the_patterns():
    # A Pattern that copies Bodies makes new ones: their faces belong to it through the Body rule.
    part_id = _create_part()["id"]
    plate = _plate(part_id, size=4.0)
    pattern = client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={"source_body_ids": [plate], "pattern_type": "rectangular", "direction_1": _fixed_axis_direction("x"), "count_1": 2,
              "spacing_1": 10.0},
    )
    assert pattern.status_code == 201, pattern.text
    pattern_id = pattern.json()["id"]
    copies = [b for b in compute_part_bodies(get_document().parts[part_id], frozenset()) if b != plate]
    assert len(copies) == 1
    assert _owners(part_id, copies[0], [0]) == [pattern_id]


def test_mirrored_hole_faces_belong_to_the_mirror():
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    cut = _hole_cut(part_id, plate, x0=1.0, y0=1.0)["id"]
    mirror = client.post(
        f"/document/parts/{part_id}/mirror-features",
        json={"source_body_ids": [], "mirror_plane": _fixed_plane_ref("YZ"), "tool_feature_id": cut, "merge": "fuse_into_one"},
    )
    assert mirror.status_code == 201, mirror.text
    mirror_id = mirror.json()["id"]
    original = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 1.0))
    mirrored = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], -1.0))
    assert _owners(part_id, plate, [original, mirrored]) == [cut, mirror_id]


def test_a_hidden_cut_is_skipped_and_a_bad_ref_is_422():
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    cut = _hole_cut(part_id, plate, x0=1.0, y0=1.0)["id"]
    hole_wall = _face(part_id, plate, lambda f: f["normal"] == (1, 0, 0) and _near(f["centre"][0], 1.0))
    get_document().parts[part_id].hidden_feature_ids.add(cut)
    assert _owners(part_id, plate, [hole_wall]) == [plate]
    response = client.post(
        f"/document/parts/{part_id}/face-owner-features",
        json={"faces": [{"body_id": plate, "shape_type": "face", "index": 999}]},
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"
    response = client.post(
        f"/document/parts/{part_id}/face-owner-features",
        json={"faces": [{"occurrence_id": "", "subshape_ref": {"body_id": plate, "shape_type": "edge", "index": 0}}]},
    )
    assert response.status_code == 422


def test_rolled_back_features_made_nothing():
    # With the cut rolled back the plate is a plain block again: every face of it is the plate's.
    part_id = _create_part()["id"]
    plate = _plate(part_id)
    cut = _hole_cut(part_id, plate, x0=1.0, y0=1.0)["id"]
    response = client.post(
        f"/document/parts/{part_id}/face-owner-features",
        json={"faces": [{"body_id": plate, "shape_type": "face", "index": i} for i in range(6)], "rollback_excluded_feature_ids": [cut]},
    )
    assert response.status_code == 200, response.text
    assert {entry["feature_id"] for entry in response.json()["features"]} == {plate}
