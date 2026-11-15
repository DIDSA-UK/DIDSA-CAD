"""A Pattern can repeat SEVERAL upstream Cut / Boss-into-target Features together (`tool_feature_ids`), like SOLIDWORKS "Features to Pattern". The single
`tool_feature_id` keeps working and reports the first. Real OCCT. Helpers are the ones of the single-feature tests."""

import json

import pytest

from app.document.native_format import export_native, import_native
from app.document.store import get_document
from app.sketch.store import all_sketches
from tests.test_stage_p_feature_pattern_mirror import (
    _body_ids,
    _create_part,
    _fixed_axis_direction,
    _hole_cut,
    _plate,
    _volume,
    client,
)

HOLE = 2.0 * 2.0 * 10.0


def _pattern(part_id: str, **extra):
    payload = {
        "source_body_ids": [],
        "pattern_type": "rectangular",
        "direction_1": _fixed_axis_direction("x"),
        "count_1": 3,
        "spacing_1": 5.0,
        "merge": "fuse_into_one",
        **extra,
    }
    return client.post(f"/document/parts/{part_id}/pattern-features", json=payload)


def _two_holes():
    part = _create_part()
    plate = _plate(part["id"], size=40.0)
    a = _hole_cut(part["id"], plate, x0=1.0, y0=1.0)
    b = _hole_cut(part["id"], plate, x0=1.0, y0=-10.0)
    return part["id"], plate, a["id"], b["id"]


def test_two_cuts_patterned_together_add_both_rows_of_holes():
    part_id, plate, a, b = _two_holes()
    before = _volume(part_id, plate)
    response = _pattern(part_id, tool_feature_ids=[a, b])
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["tool_feature_ids"] == [a, b] and body["tool_feature_id"] == a
    assert _body_ids(part_id) == [plate]
    assert _volume(part_id, plate) == pytest.approx(before - 4 * HOLE)  # two more holes of each of the two cuts


def test_one_tool_feature_still_works_through_either_field():
    part_id, plate, a, _b = _two_holes()
    before = _volume(part_id, plate)
    body = _pattern(part_id, tool_feature_id=a).json()
    assert body["tool_feature_ids"] == [a] and body["tool_feature_id"] == a
    assert _volume(part_id, plate) == pytest.approx(before - 2 * HOLE)


def test_the_two_fields_must_agree():
    part_id, _plate_id, a, b = _two_holes()
    assert _pattern(part_id, tool_feature_id=b, tool_feature_ids=[a, b]).status_code == 422
    assert _pattern(part_id, tool_feature_id=a, tool_feature_ids=[a, b]).status_code == 201


def test_tool_features_on_different_bodies_are_refused():
    part_id, plate, a, _b = _two_holes()
    other = _plate(part_id, size=10.0)  # a second plate (a separate body) with its own cut
    far = _hole_cut(part_id, other, x0=0.0, y0=0.0)
    assert plate != other
    response = _pattern(part_id, tool_feature_ids=[a, far["id"]])
    assert response.status_code == 422


def test_a_tool_feature_that_does_not_qualify_is_refused():
    part_id, _plate_id, a, _b = _two_holes()
    assert _pattern(part_id, tool_feature_ids=[a, "no-such-feature"]).status_code == 422


def test_patch_replaces_the_list_and_omitting_it_keeps_it():
    part_id, plate, a, b = _two_holes()
    feature = _pattern(part_id, tool_feature_ids=[a]).json()
    patched = client.patch(f"/document/parts/{part_id}/pattern-features/{feature['id']}", json={"count_1": 2}).json()
    assert patched["tool_feature_ids"] == [a]
    patched = client.patch(f"/document/parts/{part_id}/pattern-features/{feature['id']}", json={"tool_feature_ids": [a, b]}).json()
    assert patched["tool_feature_ids"] == [a, b]


def test_deleting_the_second_tool_feature_takes_the_pattern_with_it():
    part_id, _plate_id, a, b = _two_holes()
    feature = _pattern(part_id, tool_feature_ids=[a, b]).json()
    response = client.delete(f"/document/parts/{part_id}/features/{b}/cascade")
    assert response.status_code == 200
    assert feature["id"] in response.json()["deleted_feature_ids"]


def test_the_list_survives_save_and_open_and_an_old_file_without_it_loads():
    from app.document.models import Document, Part, PatternFeature

    feature = PatternFeature(id="pat", source_body_ids=[], tool_feature_id="a", extra_tool_feature_ids=["b"])
    part = Part(id="p", name="P")
    part.add_feature(feature)
    document = Document(id="d")
    document.parts[part.id] = part
    data = json.loads(json.dumps(export_native(document, {})))
    loaded = import_native(data)[0].parts["p"].get_feature("pat")
    assert loaded.all_tool_feature_ids == ["a", "b"]
    for part_data in data["document"]["parts"]:
        for feature_data in part_data["features"]:
            feature_data.pop("extra_tool_feature_ids", None)
    old = import_native(data)[0].parts["p"].get_feature("pat")
    assert old.all_tool_feature_ids == ["a"]  # a file from before the list loads with just the first


def test_the_coarse_preview_shows_every_tool_features_copies():
    part_id, _plate_id, a, b = _two_holes()
    response = client.post(
        f"/document/parts/{part_id}/pattern-features/coarse-preview",
        json={"source_body_ids": [], "pattern_type": "rectangular", "direction_1": _fixed_axis_direction("x"), "count_1": 3, "spacing_1": 5.0,
              "merge": "fuse_into_one", "tool_feature_ids": [a, b]},
    )
    assert response.status_code == 200, response.text
    assert len(response.json()) == 4  # two copies of each tool
