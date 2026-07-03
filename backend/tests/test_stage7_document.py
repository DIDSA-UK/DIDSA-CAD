import pytest
from fastapi.testclient import TestClient

from app.document.mesh import MeshQuality, tessellate_shape
from app.document.models import Document, Part, SketchFeature
from app.document.store import is_sketch_locked
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Pure domain model tests (no HTTP) --------------------------------------


def test_part_is_locked_for_every_feature_except_the_last():
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    second = SketchFeature(id="f2", sketch_id="s2")
    part.add_feature(first)

    assert part.is_locked(first.id) is False

    part.add_feature(second)

    assert part.is_locked(first.id) is True
    assert part.is_locked(second.id) is False


def test_part_is_locked_for_unknown_feature_id():
    part = Part(id="p", name="Part 1")
    assert part.is_locked("does-not-exist") is True


def test_delete_feature_raises_if_not_last():
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    second = SketchFeature(id="f2", sketch_id="s2")
    part.add_feature(first)
    part.add_feature(second)

    with pytest.raises(ValueError):
        part.delete_feature(first.id)
    assert first in part.features


def test_delete_feature_succeeds_when_last():
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    part.add_feature(first)

    part.delete_feature(first.id)

    assert part.features == []


def test_delete_features_removes_exactly_the_given_ids_in_original_order():
    """B2: `Part.delete_features` itself has no graph knowledge - it just
    partitions `self.features` by membership in the given id set (the real
    dependency-graph closure computation is `app.document.graph.
    transitive_dependents`, tested directly in test_stage_b2_graph.py). This
    replaces the old `delete_feature_cascade`, which took a single
    `feature_id` and deleted it plus everything positionally after it in
    the list - wrong as soon as list order and dependency order can
    diverge (A1's `target_body_ids`), which is exactly why B2 exists."""
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    second = SketchFeature(id="f2", sketch_id="s2")
    third = SketchFeature(id="f3", sketch_id="s3")
    part.add_feature(first)
    part.add_feature(second)
    part.add_feature(third)

    deleted = part.delete_features({second.id, third.id})

    assert deleted == [second, third]
    assert part.features == [first]


def test_delete_features_deletes_a_non_contiguous_subset_leaving_the_rest_untouched():
    """The key behaviour change from the old list-position cascade: an id
    set doesn't have to be a contiguous "everything after X" tail - B2's
    whole point is that the real dependent set for a deleted Feature can
    skip over untouched siblings in between."""
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    second = SketchFeature(id="f2", sketch_id="s2")
    third = SketchFeature(id="f3", sketch_id="s3")
    part.add_feature(first)
    part.add_feature(second)
    part.add_feature(third)

    deleted = part.delete_features({first.id, third.id})

    assert deleted == [first, third]
    assert part.features == [second]


def test_delete_features_with_an_unknown_id_deletes_nothing_for_that_id():
    part = Part(id="p", name="Part 1")
    first = SketchFeature(id="f1", sketch_id="s1")
    part.add_feature(first)

    deleted = part.delete_features({"does-not-exist"})

    assert deleted == []
    assert part.features == [first]


def test_document_add_part_creates_independent_parts():
    document = Document(id="d")
    part_a = document.add_part("A")
    part_b = document.add_part("B")

    assert part_a.id != part_b.id
    assert document.parts[part_a.id] is part_a
    assert document.parts[part_b.id] is part_b


def test_is_sketch_locked_false_for_sketch_with_no_feature():
    assert is_sketch_locked("no-such-sketch") is False


# --- Mesh tessellation tests (no HTTP) --------------------------------------


def test_tessellate_shape_produces_triangles_for_a_box():
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    mesh = tessellate_shape(box)

    assert len(mesh.vertices) > 0
    assert len(mesh.triangles) > 0
    assert len(mesh.normals) == len(mesh.vertices)
    for triangle in mesh.triangles:
        assert 0 <= triangle.a < len(mesh.vertices)
        assert 0 <= triangle.b < len(mesh.vertices)
        assert 0 <= triangle.c < len(mesh.vertices)


def test_tessellate_shape_quality_is_a_real_overridable_parameter():
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    coarse = tessellate_shape(box, MeshQuality(linear_deflection=2.0, angular_deflection=1.0))
    fine = tessellate_shape(box, MeshQuality(linear_deflection=0.01, angular_deflection=0.05))

    assert len(fine.triangles) >= len(coarse.triangles)


# --- API tests ---------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def test_create_part_over_the_api():
    part = _create_part("My Part")

    assert part["name"] == "My Part"
    assert part["feature_ids"] == []


def test_get_part_not_found_over_the_api():
    response = client.get("/document/parts/does-not-exist")
    assert response.status_code == 404


def test_create_sketch_feature_over_the_api():
    part = _create_part()

    feature = _create_sketch_feature(part["id"])

    assert feature["type"] == "sketch"
    assert feature["locked"] is False
    # The wrapped Sketch is real and usable via the existing sketch API.
    assert client.get(f"/sketch/sketches/{feature['sketch_id']}").status_code == 200


def test_create_sketch_feature_with_invalid_plane_is_rejected():
    part = _create_part()
    response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "QQ"})
    assert response.status_code == 422


def test_list_features_reflects_creation_order():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])

    response = client.get(f"/document/parts/{part['id']}/features")

    assert response.status_code == 200
    feature_ids = [f["id"] for f in response.json()]
    assert feature_ids == [first["id"], second["id"]]


def test_only_last_feature_is_unlocked():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])

    features = client.get(f"/document/parts/{part['id']}/features").json()
    by_id = {f["id"]: f for f in features}

    assert by_id[first["id"]]["locked"] is True
    assert by_id[second["id"]]["locked"] is False


def test_locked_feature_is_still_readable():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    _create_sketch_feature(part["id"])

    response = client.get(f"/document/parts/{part['id']}/features/{first['id']}")

    assert response.status_code == 200
    assert response.json()["locked"] is True


def test_deleting_a_locked_feature_is_rejected_over_the_api():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    _create_sketch_feature(part["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{first['id']}")

    assert response.status_code == 400
    assert client.get(f"/document/parts/{part['id']}/features/{first['id']}").status_code == 200


def test_deleting_the_last_feature_succeeds_over_the_api():
    part = _create_part()
    _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{second['id']}")

    assert response.status_code == 204
    assert client.get(f"/document/parts/{part['id']}/features/{second['id']}").status_code == 404


def test_mutating_a_sketch_behind_a_locked_feature_is_allowed_over_the_api():
    """B4: earlier-Feature editing needs this to actually work - a Sketch
    wrapped by a non-last Feature is no longer rejected at the sketch
    endpoint (the pre-B4 cross-module enforcement via app.sketch.router's
    `_ensure_sketch_editable`/`app.document.store.is_sketch_locked` was
    removed for this exact reason). `locked` (see `Part.is_locked`/the
    Feature response field) still reflects Feature *deletion*-eligibility
    (single-DELETE vs. cascade-delete) - it just no longer gates editing."""
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    _create_sketch_feature(part["id"])

    response = client.post(
        f"/sketch/sketches/{first['sketch_id']}/points", json={"x": 1.0, "y": 1.0}
    )

    assert response.status_code == 201


def test_mutating_a_sketch_behind_the_last_feature_is_allowed_over_the_api():
    part = _create_part()
    only = _create_sketch_feature(part["id"])

    response = client.post(
        f"/sketch/sketches/{only['sketch_id']}/points", json={"x": 1.0, "y": 1.0}
    )

    assert response.status_code == 201


def test_reading_a_sketch_behind_a_locked_feature_remains_unrestricted():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    _create_sketch_feature(part["id"])

    response = client.get(f"/sketch/sketches/{first['sketch_id']}")

    assert response.status_code == 200


def test_cascade_delete_from_the_last_feature_deletes_only_that_one_over_the_api():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{second['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert body["deleted_feature_ids"] == [second["id"]]
    assert body["deleted_sketch_ids"] == [second["sketch_id"]]

    remaining = client.get(f"/document/parts/{part['id']}/features").json()
    assert [f["id"] for f in remaining] == [first["id"]]

    # The deleted Feature's Sketch is genuinely gone from the sketch store...
    assert client.get(f"/sketch/sketches/{second['sketch_id']}").status_code == 404
    # ...but the surviving Feature's Sketch must be untouched.
    assert client.get(f"/sketch/sketches/{first['sketch_id']}").status_code == 200


def test_cascade_delete_of_an_independent_earlier_feature_deletes_only_itself_over_the_api():
    """B2: three separate SketchFeatures share no dependency edges at all
    (each Sketch is its own graph node with no `depends_on`, per
    `app.document.graph.build_feature_graph`) - cascade-deleting the first
    one now removes only itself, not "everything after it in the list" as
    the pre-B2 position-based cascade delete did. See test_stage_b2_
    cascade.py for the genuine multi-branch-DAG cases (a shared Sketch
    feeding two Extrudes, etc.) that actually exercise a real cascade."""
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])
    third = _create_sketch_feature(part["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{first['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert body["deleted_feature_ids"] == [first["id"]]
    assert body["deleted_sketch_ids"] == [first["sketch_id"]]

    remaining = client.get(f"/document/parts/{part['id']}/features").json()
    assert [f["id"] for f in remaining] == [second["id"], third["id"]]

    assert client.get(f"/sketch/sketches/{first['sketch_id']}").status_code == 404
    assert client.get(f"/sketch/sketches/{second['sketch_id']}").status_code == 200
    assert client.get(f"/sketch/sketches/{third['sketch_id']}").status_code == 200


def test_cascade_delete_of_a_locked_feature_is_allowed_unlike_single_delete():
    part = _create_part()
    first = _create_sketch_feature(part["id"])
    second = _create_sketch_feature(part["id"])

    # The single-delete endpoint rejects a locked Feature...
    assert client.delete(f"/document/parts/{part['id']}/features/{first['id']}").status_code == 400

    # ...but cascade-delete is exactly the way to remove one anyway. `first`
    # and `second` are independent Sketches (no dependency edge between
    # them), so only `first` is actually removed - B2's whole point, unlike
    # the pre-B2 behaviour that would have taken `second` down with it
    # purely because of list position.
    response = client.delete(f"/document/parts/{part['id']}/features/{first['id']}/cascade")
    assert response.status_code == 200
    assert response.json()["deleted_feature_ids"] == [first["id"]]
    assert [f["id"] for f in client.get(f"/document/parts/{part['id']}/features").json()] == [
        second["id"]
    ]


def test_cascade_delete_of_an_unknown_feature_is_404_over_the_api():
    part = _create_part()

    response = client.delete(f"/document/parts/{part['id']}/features/does-not-exist/cascade")

    assert response.status_code == 404


def test_get_part_mesh_returns_placeholder_geometry_over_the_api():
    """A1: GET /mesh now returns an array of Bodies - a Part with no
    ExtrudeFeature still gets exactly one (the placeholder box)."""
    part = _create_part()

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    bodies = response.json()
    assert len(bodies) == 1
    body = bodies[0]
    assert body["source"] == "placeholder"
    assert len(body["mesh"]["vertices"]) > 0
    assert len(body["mesh"]["triangle_indices"]) > 0
