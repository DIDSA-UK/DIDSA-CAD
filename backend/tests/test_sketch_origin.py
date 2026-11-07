"""Sketch origin (docs/view-override-edit-alone-sketch-origin-plan.md Item 3a): where a Sketch's local (0, 0) sits.

`SketchFeature.origin` (a Body vertex, a Sketch Point of an earlier Sketch, or a circular edge's centre) moves the origin of the Sketch's frame, projected onto its plane.
`"auto"` is opt-in: a create with no `origin` keeps today's behaviour. Needs a real pythonocc-core environment, like every other OCCT-touching test here.
"""

import json
import math

import pytest

from app.document.create_plane import _resolve_planar_face
from app.document.extrude import compute_part_bodies
from app.document.models import SubShapeRef, SubShapeType
from app.document.native_format import export_native, import_native
from app.document.router import get_part_or_404
from app.document.store import get_document
from app.sketch.store import all_sketches
from tests.test_reference_identity import _box, _feature, _fillet, _json, _pristine_box_edge_endpoints, client
from tests.test_reference_follows_upstream_topology_change import _vertex_positions

CORNER = (10.0, 10.0, 10.0)


def _top_face_index(part_id: str, body_id: str, z: float = 10.0) -> int:
    """The planar face of the Body whose outward normal is +Z (the top)."""
    bodies = compute_part_bodies(get_part_or_404(part_id))
    for i in range(40):
        try:
            plane = _resolve_planar_face(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=i))
        except Exception:
            continue
        if plane.normal[2] > 0.99 and abs(plane.origin[2] - z) < 1e-6:
            return i
    raise AssertionError("no top face")


def _plane_on_face(part_id: str, body_id: str, face_index: int) -> dict:
    return _json(
        client.post(
            f"/document/parts/{part_id}/create-plane-features",
            json={"plane_type": "offset_face", "face_refs": [{"face_ref": {"body_id": body_id, "shape_type": "face", "index": face_index}}], "offset": 0.0},
        )
    )


def _face_sketch(part_id: str, plane_id: str, **extra) -> dict:
    return _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_id, **extra}))


def _orient(sketch: dict, flip: bool, turns: int) -> None:
    _json(client.patch(f"/sketch/sketches/{sketch['sketch_id']}/orientation", json={"flip": flip, "rotation_quarter_turns": turns}))


def _set_origin(part_id: str, feature_id: str, origin, expect: int = 200):
    response = client.patch(f"/document/parts/{part_id}/features/{feature_id}/sketch-origin", json={"origin": origin})
    assert response.status_code == expect, (response.status_code, response.text[:300])
    return response.json()


def _vertex_origin(part_id: str, body_id: str, position) -> dict:
    index = next(i for i, p in _vertex_positions(part_id, body_id).items() if p == position)
    return {"point_ref": {"vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": index}}}


def _close(a, b, tol=1e-6) -> bool:
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def _oriented_axes(part_id: str, plane: dict, flip: bool, turns: int):
    """The face plane's axes with the Sketch's orientation applied, worked out here independently of the backend (flip negates x; a quarter turn maps (x, y) to (y, -x))."""
    x, y = tuple(plane["x_axis"]), tuple(plane["y_axis"])
    if flip:
        x = tuple(-c for c in x)
    for _ in range(turns):
        x, y = y, tuple(-c for c in x)
    return x, y


def _expected_bottom_left(x_axis, y_axis):
    """The top face's corners (z = 10) ranked by (smallest y, then smallest x) in the oriented frame."""
    corners = [(0.0, 0.0, 10.0), (10.0, 0.0, 10.0), (10.0, 10.0, 10.0), (0.0, 10.0, 10.0)]

    def local(p):
        return (sum(a * b for a, b in zip(p, x_axis)), sum(a * b for a, b in zip(p, y_axis)))

    return min(corners, key=lambda p: (round(local(p)[1], 6), round(local(p)[0], 6)))


# --- nothing changes unless asked ------------------------------------------------------------------------------------------------------


def test_a_fixed_plane_sketch_has_no_origin_even_when_auto_is_asked():
    part_id, *_ = _box()
    plain = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    auto = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY", "origin": "auto"}))
    for feature in (plain, auto):
        assert feature["origin"] is None and feature["resolved_origin"] is None
        assert not feature["has_lost_reference"]


def test_a_create_with_no_origin_stores_none_even_on_a_face():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    feature = _face_sketch(part_id, plane["id"])
    assert feature["origin"] is None and feature["resolved_origin"] is None
    assert get_part_or_404(part_id).get_feature(feature["id"]).origin is None


# --- auto: the bottom-left corner of the face, as the Sketch is oriented -------------------------------------------------------------


def test_auto_on_a_face_is_the_bottom_left_corner_for_the_default_orientation():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    feature = _face_sketch(part_id, plane["id"], origin="auto")
    x, y = _oriented_axes(part_id, plane, False, 0)
    assert _close(feature["resolved_origin"], _expected_bottom_left(x, y))
    assert feature["origin"]["point_ref"]["vertex_ref"]["shape_type"] == "vertex"
    assert feature["origin"]["circle_centre_ref"] is None
    assert not feature["has_lost_reference"] and feature["lost_references"] == []


@pytest.mark.parametrize("flip", [False, True])
@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_auto_follows_flip_and_rotate_when_asked_again(flip: bool, turns: int):
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    sketch = _face_sketch(part_id, plane["id"], origin="auto")
    _orient(sketch, flip, turns)
    again = _set_origin(part_id, sketch["id"], "auto")
    x, y = _oriented_axes(part_id, plane, flip, turns)
    assert _close(again["resolved_origin"], _expected_bottom_left(x, y)), (flip, turns)


def test_the_stored_origin_does_not_change_by_itself_when_the_sketch_is_turned():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    sketch = _face_sketch(part_id, plane["id"], origin="auto")
    before = _feature(part_id, sketch["id"])["resolved_origin"]
    _orient(sketch, True, 1)
    assert _feature(part_id, sketch["id"])["resolved_origin"] == before, "only asking for auto again moves it"


def test_auto_on_a_disc_face_is_the_centre_of_its_rim():
    part_id = _json(client.post("/document/parts", json={"name": "P"}))["id"]
    base = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{base['sketch_id']}/points", json={"x": 3.0, "y": 4.0}))
    _json(client.post(f"/sketch/sketches/{base['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": 5.0, "angle": 0.0}))
    extrude = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": base["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    feature = _face_sketch(part_id, plane["id"], origin="auto")
    assert _close(feature["resolved_origin"], (3.0, 4.0, 10.0), 1e-5)
    assert feature["origin"]["circle_centre_ref"]["shape_type"] == "edge"
    assert feature["origin"]["point_ref"] is None


def test_auto_on_a_plane_that_is_not_on_a_face_is_none():
    part_id, *_ = _box()
    plane = _json(client.post(f"/document/parts/{part_id}/create-plane-features", json={"plane_type": "offset_face", "face_refs": [{"fixed_plane": "XY"}], "offset": 5.0}))
    feature = _face_sketch(part_id, plane["id"], origin="auto")
    assert feature["origin"] is None and feature["resolved_origin"] is None


# --- explicit origins ------------------------------------------------------------------------------------------------------------------


def test_a_vertex_off_the_plane_is_projected_onto_it():
    part_id, _, extrude, _ = _box()
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    moved = _set_origin(part_id, sketch["id"], _vertex_origin(part_id, extrude["id"], CORNER))
    assert _close(moved["resolved_origin"], (10.0, 10.0, 0.0))
    cleared = _set_origin(part_id, sketch["id"], None)
    assert cleared["origin"] is None and cleared["resolved_origin"] is None


def test_an_extrude_of_a_rectangle_at_local_zero_lands_at_the_chosen_corner():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    sketch = _face_sketch(part_id, plane["id"], origin="auto")
    corner = tuple(sketch["resolved_origin"])
    x_axis, y_axis = _oriented_axes(part_id, plane, False, 0)
    ids = [_json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}))["id"] for x, y in [(0, 0), (2, 0), (2, 2), (0, 2)]]
    for a, b in zip(ids, ids[1:] + ids[:1]):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a, "end_point_id": b}))
    boss = _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 3.0, "target_body_ids": [extrude["id"]]},
        )
    )
    positions = set(_vertex_positions(part_id, boss.get("body_id") or extrude["id"]).values()) or set()
    if not positions:
        positions = set(_vertex_positions(part_id, extrude["id"]).values())
    far = tuple(round(corner[i] + 2 * x_axis[i] + 2 * y_axis[i] + (3.0 if i == 2 else 0.0), 3) for i in range(3))
    assert far in positions, (far, sorted(positions))


def test_a_sketch_point_of_an_earlier_sketch_can_be_the_origin_and_later_or_own_points_are_refused():
    part_id, *_ = _box()
    first = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    second = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    p1 = _json(client.post(f"/sketch/sketches/{first['sketch_id']}/points", json={"x": 4.0, "y": 6.0}))
    p2 = _json(client.post(f"/sketch/sketches/{second['sketch_id']}/points", json={"x": 1.0, "y": 1.0}))

    def ref(sketch, point):
        return {"point_ref": {"sketch_point_ref": {"sketch_id": sketch["sketch_id"], "entity_type": "point", "entity_id": point["id"]}}}

    ok = _set_origin(part_id, second["id"], ref(first, p1))
    assert _close(ok["resolved_origin"], (4.0, 6.0, 0.0))
    # A later Sketch's point, and the Sketch's own point, would be cycles.
    refused_later = _set_origin(part_id, first["id"], ref(second, p2), expect=422)
    assert refused_later["detail"]["type"] == "origin_reference_not_upstream"
    refused_own = _set_origin(part_id, second["id"], ref(second, p2), expect=422)
    assert refused_own["detail"]["type"] == "origin_reference_not_upstream"
    assert get_part_or_404(part_id).get_feature(second["id"]).origin is not None and get_part_or_404(part_id).get_feature(first["id"]).origin is None


def test_a_malformed_origin_is_refused():
    part_id, _, extrude, _ = _box()
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    _set_origin(part_id, sketch["id"], {}, expect=422)
    both = {**_vertex_origin(part_id, extrude["id"], CORNER), "circle_centre_ref": {"body_id": extrude["id"], "shape_type": "edge", "index": 0}}
    _set_origin(part_id, sketch["id"], both, expect=422)
    wrong_kind = {"point_ref": {"vertex_ref": {"body_id": extrude["id"], "shape_type": "edge", "index": 0}}}
    _set_origin(part_id, sketch["id"], wrong_kind, expect=422)
    straight_edge = {"circle_centre_ref": {"body_id": extrude["id"], "shape_type": "edge", "index": 0}}
    assert _set_origin(part_id, sketch["id"], straight_edge, expect=422)["detail"]["type"] == "not_a_circular_edge"


# --- lost and followed references ------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("new_edge", range(12))
def test_an_origin_vertex_is_followed_when_the_model_renumbers_and_lost_when_consumed(new_edge: int):
    endpoints = _pristine_box_edge_endpoints()[new_edge]
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    _set_origin(part_id, sketch["id"], _vertex_origin(part_id, extrude["id"], CORNER))
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": new_edge}]},
        )
    )
    feature = _feature(part_id, sketch["id"])
    if CORNER in endpoints:  # the fillet now eats the corner: the Sketch falls back to its plane's origin and says so, it does not fail
        assert feature["has_lost_reference"]
        assert "origin.point_ref.vertex_ref" in feature["lost_references"]
        assert feature["resolved_origin"] is None
        assert feature["reference_reasons"]["origin.point_ref.vertex_ref"] == f"consumed_by_{fillet['id']}"
    else:  # the vertex may have a new index, but it is the same corner
        assert not feature["has_lost_reference"], feature
        assert _close(feature["resolved_origin"], (10.0, 10.0, 0.0))


def test_a_lost_origin_leaves_the_sketch_at_its_planes_origin():
    part_id, _, extrude, _ = _box()
    fillet = _fillet(part_id, extrude["id"], 0)
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    _set_origin(part_id, sketch["id"], _vertex_origin(part_id, extrude["id"], CORNER))
    edge_at_corner = next(i for i, ends in _pristine_box_edge_endpoints().items() if CORNER in ends)
    _json(
        client.patch(
            f"/document/parts/{part_id}/fillet-features/{fillet['id']}",
            json={"edge_refs": [{"body_id": extrude["id"], "shape_type": "edge", "index": edge_at_corner}]},
        )
    )
    part = get_part_or_404(part_id)
    from app.document.create_plane import basis_for_sketch

    basis = basis_for_sketch(part, all_sketches()[sketch["sketch_id"]], compute_part_bodies(part), frozenset())
    assert basis.origin == (0.0, 0.0, 0.0)


def test_deleting_a_sketch_point_origin_is_reported_lost():
    part_id, *_ = _box()
    first = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    second = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    point = _json(client.post(f"/sketch/sketches/{first['sketch_id']}/points", json={"x": 4.0, "y": 6.0}))
    ref = {"point_ref": {"sketch_point_ref": {"sketch_id": first["sketch_id"], "entity_type": "point", "entity_id": point["id"]}}}
    _set_origin(part_id, second["id"], ref)
    deleted = client.delete(f"/sketch/sketches/{first['sketch_id']}/points/{point['id']}")
    assert deleted.status_code < 300, deleted.text
    feature = _feature(part_id, second["id"])
    assert feature["has_lost_reference"] and "origin.point_ref.sketch_point_ref" in feature["lost_references"]
    assert feature["resolved_origin"] is None


# --- the .didsa file --------------------------------------------------------------------------------------------------------------------


def test_native_round_trip_keeps_the_origin_and_an_old_file_loads_with_none():
    part_id, _, extrude, _ = _box()
    plane = _plane_on_face(part_id, extrude["id"], _top_face_index(part_id, extrude["id"]))
    sketch = _face_sketch(part_id, plane["id"], origin="auto")
    plain = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    before = get_part_or_404(part_id).get_feature(sketch["id"]).origin
    assert before is not None

    exported = json.loads(json.dumps(export_native(get_document(), all_sketches(), part_id)))
    by_id = {f["id"]: f for f in exported["document"]["parts"][0]["features"]}
    assert "origin" in by_id[sketch["id"]]
    assert "origin" not in by_id[plain["id"]], "written only when set: an old file is unchanged"

    document, _ = import_native(exported)
    after = document.parts[part_id].get_feature(sketch["id"]).origin
    assert after is not None and after.point_ref.vertex_ref.index == before.point_ref.vertex_ref.index
    assert document.parts[part_id].get_feature(plain["id"]).origin is None

    # An old file: the same JSON without any "origin" key.
    for feature in exported["document"]["parts"][0]["features"]:
        feature.pop("origin", None)
    old, _ = import_native(exported)
    assert old.parts[part_id].get_feature(sketch["id"]).origin is None


def test_deleting_the_feature_that_made_the_origin_body_takes_the_sketch_with_it():
    """The origin is a dependency like any other reference: the graph cascade does not leave it dangling."""
    from app.document.graph import build_feature_graph, transitive_dependents

    part_id, base, extrude, _ = _box()
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    _set_origin(part_id, sketch["id"], _vertex_origin(part_id, extrude["id"], CORNER))
    part = get_part_or_404(part_id)
    assert sketch["id"] in transitive_dependents(build_feature_graph(part), extrude["id"])
