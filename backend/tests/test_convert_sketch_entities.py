"""Bug report 2026-11-18 plan part C2: Convert Entities from another Sketch (`convert-entities/sketch`). A whole Sketch, or some of its entities, projected
square onto this Sketch's plane through the same `project_edge_onto_sketch` a Body edge uses; each copy follows its source on rebuild and is reported lost
when the source entity is deleted. Only an earlier Sketch can be the source. Pattern instances are converted, Text is skipped, loose Points come as Points.
Needs a real pythonocc-core environment."""

import math

import pytest

from app.document.native_format import sketch_to_dict
from app.sketch.store import all_sketches
from tests.test_convert_projected_body_edge import COS30, _part, _tilted_sketch
from tests.test_reference_identity import _feature, _json, client


def _sketch(part_id: str, **where):
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json=where or {"plane": "XY"}))


def _point(sketch: dict, x: float, y: float) -> dict:
    return _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}))


def _line(sketch: dict, a: dict, b: dict) -> dict:
    return _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}))


def _source(part_id: str):
    """An XY Sketch with a closed outline (three Lines and an Arc), a Circle, a Spline, a construction Line and a loose Point. Returns (sketch, ids)."""
    s = _sketch(part_id)
    sid = s["sketch_id"]
    p0, p1, p2 = _point(s, 0, 0), _point(s, 20, 0), _point(s, 20, 10)
    bottom, right = _line(s, p0, p1), _line(s, p1, p2)
    centre = _point(s, 10, 10)
    arc = _json(client.post(f"/sketch/sketches/{sid}/arcs", json={"center_point_id": centre["id"], "start_point_id": p2["id"], "end_angle": math.pi}))
    left = _json(client.post(f"/sketch/sketches/{sid}/lines", json={"start_point_id": arc["end_point_id"], "end_point_id": p0["id"]}))
    hole_centre = _point(s, 30, 5)
    circle = _json(client.post(f"/sketch/sketches/{sid}/circles", json={"center_point_id": hole_centre["id"], "radius": 3.0, "angle": 0.0}))
    t0, t1, t2 = _point(s, 40, 0), _point(s, 45, 6), _point(s, 50, 0)
    spline = _json(client.post(f"/sketch/sketches/{sid}/splines", json={"through_point_ids": [t0["id"], t1["id"], t2["id"]]}))
    c0, c1 = _point(s, -5, -5), _point(s, -5, 20)
    guide = _line(s, c0, c1)
    _json(client.patch(f"/sketch/sketches/{sid}/lines/{guide['id']}", json={"construction": True}))
    loose = _point(s, 60, 7)
    ids = {"bottom": bottom["id"], "right": right["id"], "arc": arc["id"], "left": left["id"], "circle": circle["id"], "spline": spline["id"], "guide": guide["id"],
           "loose": loose["id"], "p0": p0["id"], "p1": p1["id"], "p2": p2["id"], "centre": centre["id"], "hole_centre": hole_centre["id"]}
    return s, ids


def _convert(part_id: str, target: dict, source: dict, **extra):
    return client.post(
        f"/document/parts/{part_id}/features/sketch/{target['id']}/convert-entities/sketch",
        json={"source_sketch_feature_id": source["id"], **extra},
    )


def _kind(item: dict) -> str:
    return next(k for k in ("line", "arc", "circle", "ellipse", "ellipse_arc", "spline", "point") if item.get(k) is not None)


def _by_source(items: list[dict]) -> dict:
    return {item["source_entity_id"]: item for item in items}


def _points(sketch: dict) -> dict:
    return {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch['sketch_id']}/points"))}


def _xy(points: dict, point_id: str):
    return (points[point_id]["x"], points[point_id]["y"])


def _offset_sketch(part_id: str, offset: float = 15.0):
    plane = _json(
        client.post(
            f"/document/parts/{part_id}/create-plane-features",
            json={"plane_type": "offset_face", "face_refs": [{"fixed_plane": "XY"}], "offset": offset},
        )
    )
    return _sketch(part_id, plane_feature_id=plane["id"])


# --- a whole sketch -----------------------------------------------------------------------------------------------------------


def test_a_whole_sketch_converts_onto_a_parallel_plane_as_the_same_shapes():
    part_id = _part()
    source, ids = _source(part_id)
    target = _offset_sketch(part_id)
    response = _convert(part_id, target, source)
    assert response.status_code == 201, response.text
    data = response.json()
    items = _by_source(data["items"])
    # Every curve entity and the loose Point; not the construction Line (not asked for).
    assert set(items) == {ids[k] for k in ("bottom", "right", "arc", "left", "circle", "spline", "loose")}
    assert {_kind(items[ids[k]]) for k in ("bottom", "right", "left")} == {"line"}
    assert _kind(items[ids["arc"]]) == "arc" and _kind(items[ids["circle"]]) == "circle" and _kind(items[ids["spline"]]) == "spline"
    assert _kind(items[ids["loose"]]) == "point" and data["skipped"] == []
    points = _points(target)
    assert items[ids["circle"]]["circle"]["radius"] == pytest.approx(3.0)
    assert _xy(points, items[ids["circle"]]["circle"]["center_point_id"]) == pytest.approx((30, 5))
    arc = items[ids["arc"]]["arc"]
    assert _xy(points, arc["center_point_id"]) == pytest.approx((10, 10)) and _xy(points, arc["start_point_id"]) == pytest.approx((20, 10))
    spline = items[ids["spline"]]["spline"]
    src_spline = next(s for s in _json(client.get(f"/sketch/sketches/{source['sketch_id']}/splines")) if s["id"] == ids["spline"])
    src_points = _points(source)
    assert [_xy(points, p) for p in spline["through_point_ids"]] == [pytest.approx(_xy(src_points, p)) for p in src_spline["through_point_ids"]]
    assert [_xy(points, p) for p in spline["control_point_ids"]] == [pytest.approx(_xy(src_points, p)) for p in src_spline["control_point_ids"]]
    # The outline's copies share their corner Points, as the source's Lines and Arc do, so it is still one closed profile.
    lines = {ids[k]: items[ids[k]]["line"] for k in ("bottom", "right", "left")}
    assert lines[ids["bottom"]]["end_point_id"] == lines[ids["right"]]["start_point_id"]
    assert lines[ids["right"]]["end_point_id"] == arc["start_point_id"] and arc["end_point_id"] == lines[ids["left"]]["start_point_id"]
    profiles = _json(client.get(f"/sketch/sketches/{target['sketch_id']}/profile"))
    assert profiles["status"] == "multiple_loops" and len(profiles["loops"]) == 2, profiles  # the outline and the circle
    # Everything made is pinned, the sketch solves, and nothing is lost.
    assert all(p["is_locked"] for pid, p in points.items() if pid != all_sketches()[target["sketch_id"]].origin_point_id)
    assert _json(client.post(f"/sketch/sketches/{target['sketch_id']}/solve-and-refresh"))["solve"]["converged"] is True
    assert not _feature(part_id, target["id"])["has_lost_reference"]


def test_construction_geometry_is_converted_only_when_asked():
    part_id = _part()
    source, ids = _source(part_id)
    target = _sketch(part_id)
    items = _by_source(_json(_convert(part_id, target, source, include_construction=True))["items"])
    assert ids["guide"] in items and items[ids["guide"]]["line"]["construction"] is True
    assert items[ids["bottom"]]["line"]["construction"] is False


def test_a_whole_sketch_converts_onto_a_tilted_plane_as_its_projection():
    part_id = _part()
    source, ids = _source(part_id)
    target = _tilted_sketch(part_id)
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    # Seen square to a plane tilted 30 degrees about x: y shrinks by cos 30, x is kept. The circle is an ellipse, the arc an elliptical arc.
    ellipse = items[ids["circle"]]["ellipse"]
    assert ellipse["major_radius"] == pytest.approx(3.0) and ellipse["minor_radius"] == pytest.approx(3.0 * COS30)
    arc = items[ids["arc"]]["ellipse_arc"]
    assert arc["major_radius"] == pytest.approx(10.0) and arc["minor_radius"] == pytest.approx(10.0 * COS30)
    points = _points(target)
    assert _xy(points, items[ids["right"]]["line"]["end_point_id"]) == pytest.approx((20.0, 10.0 * COS30))
    assert _xy(points, items[ids["loose"]]["point"]["id"]) == pytest.approx((60.0, 7.0 * COS30))
    assert _kind(items[ids["spline"]]) == "spline"
    assert _json(client.post(f"/sketch/sketches/{target['sketch_id']}/solve-and-refresh"))["solve"]["converged"] is True


def test_some_entities_of_a_sketch_convert_by_id():
    part_id = _part()
    source, ids = _source(part_id)
    target = _sketch(part_id)
    data = _json(_convert(part_id, target, source, entity_ids=[ids["circle"], ids["guide"], "nope"]))
    assert {i["source_entity_id"] for i in data["items"]} == {ids["circle"], ids["guide"]}  # a construction entity named by id is converted
    assert data["skipped"] == [{"entity_id": "nope", "reason": "not_found", "message": "No such entity or point in the source sketch."}]


def test_converting_again_answers_with_the_copies_already_made():
    part_id = _part()
    source, ids = _source(part_id)
    target = _sketch(part_id)
    first = _by_source(_json(_convert(part_id, target, source))["items"])
    again = _by_source(_json(_convert(part_id, target, source))["items"])
    assert {k: _kind(v) for k, v in first.items()} == {k: _kind(v) for k, v in again.items()}
    assert all(first[k][_kind(first[k])]["id"] == again[k][_kind(again[k])]["id"] for k in first)


def test_a_reference_convert_flags_everything_it_made():
    part_id = _part()
    source, ids = _source(part_id)
    target = _sketch(part_id)
    data = _json(_convert(part_id, target, source, reference=True, construction=True))
    flagged = all_sketches()[target["sketch_id"]].reference_ids
    for item in data["items"]:
        shape = item[_kind(item)]
        assert shape["id"] in flagged and shape.get("is_reference", True) is True


# --- order --------------------------------------------------------------------------------------------------------------------


def test_a_later_sketch_is_refused():
    part_id = _part()
    target = _sketch(part_id)
    source, _ = _source(part_id)  # made after the target
    response = _convert(part_id, target, source)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "source_after_sketch"
    assert "earlier" in response.json()["detail"]["message"]
    itself = _convert(part_id, target, target)
    assert itself.status_code == 422 and itself.json()["detail"]["type"] == "source_is_this_sketch"


# --- following the source -----------------------------------------------------------------------------------------------------


def test_the_copy_follows_when_the_source_is_edited_and_the_target_rebuilt():
    part_id = _part()
    source, ids = _source(part_id)
    target = _tilted_sketch(part_id)
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    sid = source["sketch_id"]
    # Move a corner the bottom and right Lines share, and resize the circle.
    _json(client.patch(f"/sketch/sketches/{sid}/points/{ids['p1']}", json={"x": 24.0, "y": 2.0}))
    radius_point = next(c for c in _json(client.get(f"/sketch/sketches/{sid}/circles")) if c["id"] == ids["circle"])["radius_point_id"]
    _json(client.patch(f"/sketch/sketches/{sid}/points/{ids['hole_centre']}", json={"x": 32.0, "y": 5.0}))
    _json(client.patch(f"/sketch/sketches/{sid}/points/{radius_point}", json={"x": 36.0, "y": 5.0}))

    feature = _feature(part_id, target["id"])
    assert not feature["has_lost_reference"], feature
    points = _points(target)
    assert _xy(points, items[ids["bottom"]]["line"]["end_point_id"]) == pytest.approx((24.0, 2.0 * COS30))
    assert _xy(points, items[ids["right"]]["line"]["start_point_id"]) == pytest.approx((24.0, 2.0 * COS30))
    ellipse = next(e for e in _json(client.get(f"/sketch/sketches/{target['sketch_id']}/ellipses")) if e["id"] == items[ids["circle"]]["ellipse"]["id"])
    assert ellipse["major_radius"] == pytest.approx(4.0) and ellipse["minor_radius"] == pytest.approx(4.0 * COS30)
    assert _xy(points, ellipse["center_point_id"]) == pytest.approx((32.0, 5.0 * COS30))
    assert _json(client.post(f"/sketch/sketches/{target['sketch_id']}/solve-and-refresh"))["solve"]["converged"] is True


def test_a_deleted_source_entity_is_reported_lost():
    part_id = _part()
    source, ids = _source(part_id)
    target = _sketch(part_id)
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    _json(client.delete(f"/sketch/sketches/{source['sketch_id']}/circles/{ids['circle']}"))
    feature = _feature(part_id, target["id"])
    assert feature["has_lost_reference"] is True
    centre = items[ids["circle"]]["circle"]["center_point_id"]
    assert centre in feature["lost_reference_point_ids"]
    assert feature["reference_reasons"][centre] == "source_entity_deleted"
    # The copy stays where it was (it is not removed), and the others are fine.
    assert _xy(_points(target), centre) == pytest.approx((30, 5))
    assert items[ids["bottom"]]["line"]["start_point_id"] not in feature["lost_reference_point_ids"]


def test_deleting_the_source_sketch_keeps_the_copies_and_flags_them_lost():
    part_id = _part()
    source, ids = _source(part_id)
    target = _offset_sketch(part_id)
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    deleted = _json(client.delete(f"/document/parts/{part_id}/features/{source['id']}/cascade"))
    assert target["id"] not in deleted["deleted_feature_ids"], deleted  # the converting sketch is not taken with it
    feature = _feature(part_id, target["id"])
    assert feature["has_lost_reference"] is True
    centre = items[ids["circle"]]["circle"]["center_point_id"]
    assert feature["reference_reasons"][centre] == "source_sketch_missing"
    assert _xy(_points(target), centre) == pytest.approx((30, 5))  # kept where it was
    assert len(all_sketches()[target["sketch_id"]].external_curves) == len(items)


# --- pattern and text -----------------------------------------------------------------------------------------------------------


def test_pattern_instances_are_converted_and_text_is_skipped():
    part_id = _part()
    s = _sketch(part_id)
    sid = s["sketch_id"]
    centre = _point(s, 0, 0)
    circle = _json(client.post(f"/sketch/sketches/{sid}/circles", json={"center_point_id": centre["id"], "radius": 1.0, "angle": 0.0}))
    _json(
        client.post(
            f"/sketch/sketches/{sid}/pattern-instances",
            json={"source_entity_ids": [circle["id"]], "direction_1": {"fixed_axis": "x"}, "count_1": 3, "spacing_1": 5.0},
        )
    )
    anchor = _point(s, 0, 20)
    text = _json(client.post(f"/sketch/sketches/{sid}/texts", json={"content": "A", "anchor_point_id": anchor["id"]}))
    target = _offset_sketch(part_id, 4.0)
    data = _json(_convert(part_id, target, s))
    circles = [i for i in data["items"] if i.get("circle") is not None]
    points = _points(target)
    assert sorted(_xy(points, c["circle"]["center_point_id"])[0] for c in circles) == pytest.approx([0.0, 5.0, 10.0])
    assert any("#" in c["source_entity_id"] for c in circles)  # the instances, by their expanded ids
    assert [(k["entity_id"], k["reason"]) for k in data["skipped"]] == [(text["id"], "text")]
    # A pattern instance's copy follows the pattern: change the spacing.
    instance = _json(client.get(f"/sketch/sketches/{sid}/pattern-instances"))[0]
    _json(client.patch(f"/sketch/sketches/{sid}/pattern-instances/{instance['id']}", json={"spacing_1": 6.0}))
    assert not _feature(part_id, target["id"])["has_lost_reference"]
    points = _points(target)
    assert sorted(_xy(points, c["circle"]["center_point_id"])[0] for c in circles) == pytest.approx([0.0, 6.0, 12.0])


# --- save and reopen ------------------------------------------------------------------------------------------------------------


def test_sketch_references_survive_a_save_and_reopen_and_still_follow():
    from app.document.store import get_document, replace_document
    from app.sketch.store import replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part_id = _part()
        source, ids = _source(part_id)
        target = _offset_sketch(part_id)
        items = _by_source(_json(_convert(part_id, target, source))["items"])
        stored = sketch_to_dict(all_sketches()[target["sketch_id"]])["external_curves"]
        assert {c["source_entity_id"] for c in stored} == set(items) and all(c["source"] == "sketch_entity" for c in stored)
        exported = client.get("/document/export/native").json()
        assert client.post("/document/import/native", json=exported).status_code == 200

        assert len(all_sketches()[target["sketch_id"]].external_curves) == len(items)
        _json(client.patch(f"/sketch/sketches/{source['sketch_id']}/points/{ids['loose']}", json={"x": 61.0, "y": 8.0}))
        assert not _feature(part_id, target["id"])["has_lost_reference"]
        assert _xy(_points(target), items[ids["loose"]]["point"]["id"]) == pytest.approx((61.0, 8.0))
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- planes moving ----------------------------------------------------------------------------------------------------------------


def test_the_copy_follows_when_the_source_sketchs_plane_moves():
    part_id = _part()
    plane = _json(
        client.post(f"/document/parts/{part_id}/create-plane-features", json={"plane_type": "offset_face", "face_refs": [{"fixed_plane": "XY"}], "offset": 5.0})
    )
    source = _sketch(part_id, plane_feature_id=plane["id"])
    loose = _point(source, 4.0, 2.0)
    target = _tilted_sketch(part_id)  # normal (0, -sin 30, cos 30): a point's height shows as + h sin 30 in the target's y
    item = _json(_convert(part_id, target, source))["items"][0]
    assert _xy(_points(target), item["point"]["id"]) == pytest.approx((4.0, 2.0 * COS30 + 5.0 * 0.5))

    _json(client.patch(f"/document/parts/{part_id}/create-plane-features/{plane['id']}", json={"offset": 9.0}))
    assert not _feature(part_id, target["id"])["has_lost_reference"]
    assert _xy(_points(target), item["point"]["id"]) == pytest.approx((4.0, 2.0 * COS30 + 9.0 * 0.5))
    assert loose["id"] == item["source_entity_id"]


def test_the_copy_follows_when_the_target_sketchs_plane_tilts_further():
    part_id = _part()
    source, ids = _source(part_id)
    # The target's plane is through the x axis and a Point of a YZ sketch; moving that Point tilts the plane from 30 to 60 degrees.
    xy = _sketch(part_id)
    yz = _sketch(part_id, plane="YZ")
    a, b = _point(xy, 0.0, 0.0), _point(xy, 10.0, 0.0)
    c = _point(yz, 10 * COS30, 5.0)

    def ref(s, p):
        return {"sketch_point_ref": {"sketch_id": s["sketch_id"], "entity_type": "point", "entity_id": p["id"]}}

    plane = _json(client.post(f"/document/parts/{part_id}/create-plane-features", json={"plane_type": "three_points", "point_refs": [ref(xy, a), ref(xy, b), ref(yz, c)]}))
    target = _sketch(part_id, plane_feature_id=plane["id"])
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    assert items[ids["circle"]]["ellipse"]["minor_radius"] == pytest.approx(3.0 * COS30)

    _json(client.patch(f"/sketch/sketches/{yz['sketch_id']}/points/{c['id']}", json={"x": 5.0, "y": 10 * COS30}))  # now 60 degrees
    assert not _feature(part_id, target["id"])["has_lost_reference"]
    ellipse = next(e for e in _json(client.get(f"/sketch/sketches/{target['sketch_id']}/ellipses")) if e["id"] == items[ids["circle"]]["ellipse"]["id"])
    assert ellipse["major_radius"] == pytest.approx(3.0) and ellipse["minor_radius"] == pytest.approx(1.5)
    assert _xy(_points(target), items[ids["right"]]["line"]["end_point_id"]) == pytest.approx((20.0, 5.0))


def test_a_copy_that_would_change_kind_is_flagged_lost_and_kept():
    # The same plane tilted back to flat: the circle's copy would have to become a circle again, which an ellipse cannot. Lost, not reshaped.
    part_id = _part()
    source, ids = _source(part_id)
    xy = _sketch(part_id)
    yz = _sketch(part_id, plane="YZ")
    a, b = _point(xy, 0.0, 0.0), _point(xy, 10.0, 0.0)
    c = _point(yz, 10 * COS30, 5.0)

    def ref(s, p):
        return {"sketch_point_ref": {"sketch_id": s["sketch_id"], "entity_type": "point", "entity_id": p["id"]}}

    plane = _json(client.post(f"/document/parts/{part_id}/create-plane-features", json={"plane_type": "three_points", "point_refs": [ref(xy, a), ref(xy, b), ref(yz, c)]}))
    target = _sketch(part_id, plane_feature_id=plane["id"])
    items = _by_source(_json(_convert(part_id, target, source))["items"])
    ellipse = items[ids["circle"]]["ellipse"]
    before = _xy(_points(target), ellipse["center_point_id"])
    _json(client.patch(f"/sketch/sketches/{yz['sketch_id']}/points/{c['id']}", json={"x": 10.0, "y": 0.0}))  # flat again
    feature = _feature(part_id, target["id"])
    assert feature["reference_reasons"][ellipse["center_point_id"]] == "shape_changed"
    assert _xy(_points(target), ellipse["center_point_id"]) == pytest.approx(before)
    # The lines are still lines: they followed.
    assert _xy(_points(target), items[ids["right"]]["line"]["end_point_id"]) == pytest.approx((20.0, 10.0))
