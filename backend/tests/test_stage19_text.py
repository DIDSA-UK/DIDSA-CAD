import pytest
from fastapi.testclient import TestClient

from app.document.native_format import _entity_from_dict, _entity_to_dict
from app.main import app
from app.sketch.models import Plane, Sketch, TextEntity
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.text_fonts import FONT_ALLOWLIST
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def test_text_entity_round_trips_through_native_format_dict():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    text = sketch.add_text("Hi", "Open Sans", 12.0, anchor.id, rotation_degrees=30.0, construction=True)

    data = _entity_to_dict(text)
    restored = _entity_from_dict(data)

    assert isinstance(restored, TextEntity)
    assert restored.id == text.id
    assert restored.content == text.content
    assert restored.font == text.font
    assert restored.size == text.size
    assert restored.anchor_point_id == text.anchor_point_id
    assert restored.rotation_degrees == text.rotation_degrees
    assert restored.construction is True


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_add_text_creates_entity_with_expected_fields():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)

    text = sketch.add_text("Hi", "Open Sans", 10.0, anchor.id, rotation_degrees=15.0)

    assert isinstance(text, TextEntity)
    assert text.content == "Hi"
    assert text.font == "Open Sans"
    assert text.size == 10.0
    assert text.anchor_point_id == anchor.id
    assert text.rotation_degrees == 15.0
    assert text.construction is False
    assert text.endpoint_point_ids() is None
    assert sketch.texts() == [text]


def test_add_text_rejects_unknown_anchor_point():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.add_text("Hi", "Open Sans", 10.0, "missing-point")


def test_delete_text_removes_entity_and_prunes_now_orphaned_anchor_point():
    # Bug fix (pre-existing stale test - predates `_prune_orphaned_points`;
    # see test_delete_line_prunes_a_now_orphaned_endpoint's own comment in
    # test_stage6_delete.py): the anchor Point no longer unconditionally
    # survives the Text's own deletion.
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    text = sketch.add_text("Hi", "Open Sans", 10.0, anchor.id)

    sketch.delete_text(text.id)

    assert text.id not in sketch.entities
    assert anchor.id not in sketch.points


def test_delete_text_leaves_an_anchor_point_still_shared_with_something_else():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    other = sketch.add_point(20.0, 20.0)
    sketch.add_line(anchor.id, other.id)
    text = sketch.add_text("Hi", "Open Sans", 10.0, anchor.id)

    sketch.delete_text(text.id)

    assert text.id not in sketch.entities
    assert anchor.id in sketch.points


def test_delete_text_rejects_unknown_id():
    sketch = Sketch(id="s", plane=Plane.XY)
    with pytest.raises(KeyError):
        sketch.delete_text("missing")


def test_point_deletion_blocked_while_referenced_by_text():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    sketch.add_text("Hi", "Open Sans", 10.0, anchor.id)

    with pytest.raises(ValueError, match="still referenced by text"):
        sketch.delete_point(anchor.id)


# --- Profile detection (pure domain, no HTTP) -------------------------------


def test_text_profile_produces_one_loop_per_glyph_contour_with_holes():
    """"oi" -> 3 disjoint outer loops: "o"'s own ring (with its own 1-hole
    counter as an inner_loop), plus "i"'s dot and stem as 2 further
    disjoint outer loops - exercises detect_profile's MultiProfile status
    via Text alone, with no Line/Circle/Ellipse/Spline in the sketch at
    all."""
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    sketch.add_text("oi", "Open Sans", 10.0, anchor.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.MULTIPLE_LOOPS
    assert len(result.loops) == 3
    hole_counts = sorted(len(loop.inner_loops) for loop in result.loops)
    assert hole_counts == [0, 0, 1]
    for loop in result.loops:
        assert loop.point_ids == []
        assert len(loop.text_vertices) > 2
        for inner in loop.inner_loops:
            assert len(inner.text_vertices) > 2


def test_text_with_no_holed_glyphs_produces_single_closed_loop():
    sketch = Sketch(id="s", plane=Plane.XY)
    anchor = sketch.add_point(0.0, 0.0)
    sketch.add_text("I", "Open Sans", 10.0, anchor.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert result.profile.inner_loops == []


def test_text_entity_can_be_nested_as_a_hole_inside_a_larger_line_chain_rectangle():
    """A small Text entity fully inside a large rectangle should be
    classified as the rectangle's own hole, via the generic
    _classify_nesting machinery (the same centroid/area/containment
    checks every other entity type already goes through) - confirms the
    _is_text_profile branches added to _loop_centroid/_loop_area/
    _loop_contains_point/_loop_fully_contains actually work, not just
    _text_profile's own self-contained glyph nesting."""
    sketch = Sketch(id="s", plane=Plane.XY)
    corner1 = sketch.add_point(-50.0, -50.0)
    corner2 = sketch.add_point(50.0, -50.0)
    corner3 = sketch.add_point(50.0, 50.0)
    corner4 = sketch.add_point(-50.0, 50.0)
    sketch.add_line(corner1.id, corner2.id)
    sketch.add_line(corner2.id, corner3.id)
    sketch.add_line(corner3.id, corner4.id)
    sketch.add_line(corner4.id, corner1.id)
    anchor = sketch.add_point(0.0, 0.0)
    sketch.add_text("I", "Open Sans", 10.0, anchor.id)

    result = detect_profile(sketch)

    assert result.status == ProfileStatus.CLOSED_LOOP
    assert result.profile is not None
    assert len(result.profile.inner_loops) == 1
    assert result.profile.inner_loops[0].text_vertices is not None


# --- API tests ---------------------------------------------------------------


def _create_sketch(plane: str = "XY") -> dict:
    response = client.post("/sketch/sketches", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def test_create_text_over_the_api():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/texts",
        json={"content": "Hi", "anchor_point_id": anchor["id"], "size": 12.0, "rotation_degrees": 30.0},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "text"
    assert body["content"] == "Hi"
    assert body["font"] == "Open Sans"
    assert body["size"] == 12.0
    assert body["anchor_point_id"] == anchor["id"]
    assert body["rotation_degrees"] == 30.0
    assert body["construction"] is False


@pytest.mark.parametrize("font", sorted(FONT_ALLOWLIST))
def test_create_text_with_each_allowlisted_font_over_the_api(font):
    """Feedback round: expanded FONT_ALLOWLIST from Open Sans alone to 8
    fonts - every one of them must actually round-trip through the real
    OCCT font-to-BRep path (app.sketch.text_geometry.text_to_shape), not
    just be accepted by the request schema's validation, since a font
    whose embedded family name doesn't match its FONT_ALLOWLIST key would
    silently fall back to a system font rather than erroring (see
    text_fonts.py's own doc comment on the allowlist) - the preview
    endpoint below exercises that real conversion for each one."""
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)

    created = client.post(
        f"/sketch/sketches/{sketch['id']}/texts",
        json={"content": "Hi", "anchor_point_id": anchor["id"], "font": font},
    ).json()
    assert created["font"] == font

    preview = client.get(f"/sketch/sketches/{sketch['id']}/texts/{created['id']}/preview")
    assert preview.status_code == 200
    assert len(preview.json()["contours"]) > 0


def test_create_text_rejects_empty_content():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "", "anchor_point_id": anchor["id"]}
    )

    assert response.status_code == 422


def test_create_text_rejects_unknown_font():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/texts",
        json={"content": "Hi", "anchor_point_id": anchor["id"], "font": "Comic Sans"},
    )

    assert response.status_code == 422


def test_create_text_rejects_unknown_anchor_point():
    sketch = _create_sketch()

    response = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "Hi", "anchor_point_id": "missing"}
    )

    assert response.status_code == 404


def test_list_and_get_texts_over_the_api():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "Hi", "anchor_point_id": anchor["id"]}
    ).json()

    listed = client.get(f"/sketch/sketches/{sketch['id']}/texts")
    assert listed.status_code == 200
    assert [t["id"] for t in listed.json()] == [created["id"]]

    fetched = client.get(f"/sketch/sketches/{sketch['id']}/texts/{created['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["id"] == created["id"]

    missing = client.get(f"/sketch/sketches/{sketch['id']}/texts/missing")
    assert missing.status_code == 404


def test_update_text_over_the_api():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "Hi", "anchor_point_id": anchor["id"]}
    ).json()

    response = client.patch(
        f"/sketch/sketches/{sketch['id']}/texts/{created['id']}",
        json={"content": "Bye", "size": 20.0, "rotation_degrees": 90.0, "construction": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["content"] == "Bye"
    assert body["size"] == 20.0
    assert body["rotation_degrees"] == 90.0
    assert body["construction"] is True
    # font untouched, since it was omitted from the PATCH.
    assert body["font"] == "Open Sans"


def test_delete_text_over_the_api():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "Hi", "anchor_point_id": anchor["id"]}
    ).json()

    response = client.delete(f"/sketch/sketches/{sketch['id']}/texts/{created['id']}")

    # Bug fix (pre-existing stale test - predates `DeleteEntityResponse`/
    # `_prune_orphaned_points`; see test_delete_line_over_the_api's own
    # comment in test_stage6_delete.py): a 200 + `pruned_point_ids` now,
    # and the anchor Point - genuinely orphaned here - is one of them.
    assert response.status_code == 200
    assert response.json()["pruned_point_ids"] == [anchor["id"]]
    assert client.get(f"/sketch/sketches/{sketch['id']}/texts/{created['id']}").status_code == 404
    assert client.get(f"/sketch/sketches/{sketch['id']}/points/{anchor['id']}").status_code == 404


def test_text_preview_endpoint_returns_one_contour_per_glyph():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)
    created = client.post(
        f"/sketch/sketches/{sketch['id']}/texts", json={"content": "oi", "anchor_point_id": anchor["id"]}
    ).json()

    response = client.get(f"/sketch/sketches/{sketch['id']}/texts/{created['id']}/preview")

    assert response.status_code == 200
    contours = response.json()["contours"]
    assert len(contours) == 3
    hole_counts = sorted(len(c["holes"]) for c in contours)
    assert hole_counts == [0, 0, 1]
    for contour in contours:
        assert len(contour["outer"]) > 2
        assert all(len(point) == 2 for point in contour["outer"])


def test_profile_detection_over_the_api_reports_text_loops():
    sketch = _create_sketch()
    anchor = _create_point(sketch["id"], 0.0, 0.0)
    client.post(f"/sketch/sketches/{sketch['id']}/texts", json={"content": "oi", "anchor_point_id": anchor["id"]})

    response = client.get(f"/sketch/sketches/{sketch['id']}/profile")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "multiple_loops"
    assert len(body["loops"]) == 3


# --- Extrude (Text glyph wire construction) ---------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _create_extrude_feature(part_id: str, sketch_feature_id: str, *, end_distance: float = 5.0) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": end_distance,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()


def test_extruding_a_single_holed_glyph_produces_a_non_empty_computed_mesh():
    """Exercises app.document.extrude's Text branch of wire_for_profile
    (the exact, non-tessellated outer + hole wires re-derived via
    text_contour_wire) for a glyph with a real hole ("o"'s own counter) -
    the same shape of check test_stage16_arc.py/test_stage17_ellipse.py/
    test_stage18_spline.py already run for their own curved wire paths."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    anchor = _create_point(sketch_id, 0.0, 0.0)
    client.post(f"/sketch/sketches/{sketch_id}/texts", json={"content": "o", "anchor_point_id": anchor["id"]})

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_extruding_multi_glyph_text_produces_one_body_per_disjoint_outer_loop():
    """"Hi" has 3 disjoint outer loops (see the MultiProfile profile-
    detection test above) - each becomes its own separate solid body,
    the same MultiProfile behaviour any other sketch with 3 disjoint
    Line-chain/Circle loops would already produce, exercised here purely
    through Text."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    anchor = _create_point(sketch_id, 0.0, 0.0)
    client.post(f"/sketch/sketches/{sketch_id}/texts", json={"content": "Hi", "anchor_point_id": anchor["id"]})

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 3
    for body in bodies:
        assert len(body["mesh"]["vertices"]) > 0


def test_extruding_a_rotated_offset_text_entity_produces_a_non_empty_computed_mesh():
    """Exercises _text_world_transform's rotation+anchor-offset composition
    (not just the identity-at-origin case every other test above uses)."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    anchor = _create_point(sketch_id, 20.0, 30.0)
    client.post(
        f"/sketch/sketches/{sketch_id}/texts",
        json={"content": "I", "anchor_point_id": anchor["id"], "size": 10.0, "rotation_degrees": 90.0},
    )

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")
    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    assert len(bodies[0]["mesh"]["vertices"]) > 0
