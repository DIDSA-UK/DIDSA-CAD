"""A Mirror can mirror SEVERAL upstream Cut / Boss-into-target Features together (`tool_feature_ids`, bug report 2026-11-17 item M.1),
as Pattern can since PR #368. The single `tool_feature_id` keeps working and reports the first. Real OCCT. Helpers are the
single-feature tests' own."""

import json

import pytest

from app.document.native_format import export_native, import_native
from tests.test_stage_p_feature_pattern_mirror import (
    _body_ids,
    _create_part,
    _fixed_plane_ref,
    _hole_cut,
    _plate,
    _volume,
    client,
)

HOLE = 2.0 * 2.0 * 10.0


def _mirror(part_id: str, **extra):
    payload = {"source_body_ids": [], "mirror_plane": _fixed_plane_ref("YZ"), "merge": "fuse_into_one", **extra}
    return client.post(f"/document/parts/{part_id}/mirror-features", json=payload)


def _two_holes():
    part = _create_part()
    plate = _plate(part["id"], size=40.0)
    a = _hole_cut(part["id"], plate, x0=1.0, y0=1.0)
    b = _hole_cut(part["id"], plate, x0=5.0, y0=-10.0)
    return part["id"], plate, a["id"], b["id"]


def test_two_cuts_mirrored_together_add_both_holes_on_the_other_side():
    part_id, plate, a, b = _two_holes()
    before = _volume(part_id, plate)
    response = _mirror(part_id, tool_feature_ids=[a, b])
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["tool_feature_ids"] == [a, b] and body["tool_feature_id"] == a
    assert _body_ids(part_id) == [plate]
    assert _volume(part_id, plate) == pytest.approx(before - 2 * HOLE)  # one mirrored hole for each cut


def test_one_tool_feature_still_works_through_either_field():
    part_id, plate, a, _b = _two_holes()
    before = _volume(part_id, plate)
    body = _mirror(part_id, tool_feature_id=a).json()
    assert body["tool_feature_ids"] == [a] and body["tool_feature_id"] == a
    assert _volume(part_id, plate) == pytest.approx(before - HOLE)


def test_the_two_fields_must_agree():
    part_id, _plate_id, a, b = _two_holes()
    assert _mirror(part_id, tool_feature_id=b, tool_feature_ids=[a, b]).status_code == 422
    assert _mirror(part_id, tool_feature_id=a, tool_feature_ids=[a, b]).status_code == 201


def test_tool_features_on_different_bodies_are_refused():
    part_id, plate, a, _b = _two_holes()
    other = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={"sketch_feature_id": _square_sketch(part_id, 100.0, 100.0, 10.0), "extrude_type": "boss", "start_distance": 0.0,
              "end_distance": 10.0, "target_body_ids": []},
    ).json()["id"]
    far = _hole_cut(part_id, other, x0=102.0, y0=102.0)
    assert plate != other
    response = _mirror(part_id, tool_feature_ids=[a, far["id"]])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "tool_features_different_targets"


def _square_sketch(part_id: str, x0: float, y0: float, size: float) -> str:
    from tests.test_stage_p_feature_pattern_mirror import _create_square_sketch_feature

    return _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)["id"]


def test_a_tool_feature_that_does_not_qualify_is_refused():
    part_id, _plate_id, a, _b = _two_holes()
    assert _mirror(part_id, tool_feature_ids=[a, "no-such-feature"]).status_code == 422


def test_patch_replaces_the_list_and_omitting_it_keeps_it():
    part_id, _plate_id, a, b = _two_holes()
    feature = _mirror(part_id, tool_feature_ids=[a]).json()
    url = f"/document/parts/{part_id}/mirror-features/{feature['id']}"
    patched = client.patch(url, json={"mirror_plane": _fixed_plane_ref("XZ")}).json()
    assert patched["tool_feature_ids"] == [a]
    patched = client.patch(url, json={"tool_feature_ids": [a, b]}).json()
    assert patched["tool_feature_ids"] == [a, b]


def test_deleting_the_second_tool_feature_takes_the_mirror_with_it():
    part_id, _plate_id, a, b = _two_holes()
    feature = _mirror(part_id, tool_feature_ids=[a, b]).json()
    response = client.delete(f"/document/parts/{part_id}/features/{b}/cascade")
    assert response.status_code == 200
    assert feature["id"] in response.json()["deleted_feature_ids"]


def test_the_list_survives_save_and_open_and_an_old_file_without_it_loads():
    from app.document.models import Document, MirrorFeature, Part, PlaneRef
    from app.sketch.models import Plane

    feature = MirrorFeature(
        id="mir", source_body_ids=[], mirror_plane=PlaneRef(fixed_plane=Plane.YZ), tool_feature_id="a", extra_tool_feature_ids=["b"]
    )
    part = Part(id="p", name="P")
    part.add_feature(feature)
    document = Document(id="d")
    document.parts[part.id] = part
    data = json.loads(json.dumps(export_native(document, {})))
    loaded = import_native(data)[0].parts["p"].get_feature("mir")
    assert loaded.all_tool_feature_ids == ["a", "b"]
    for part_data in data["document"]["parts"]:
        for feature_data in part_data["features"]:
            feature_data.pop("extra_tool_feature_ids", None)
    old = import_native(data)[0].parts["p"].get_feature("mir")
    assert old.all_tool_feature_ids == ["a"]  # a file from before the list loads with just the first
