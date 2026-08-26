"""Boolean family, Subtract/Common: real-OCCT tests for `BooleanFeature` -
folds every Body named by `tool_body_ids` into/against every Body named by
`target_body_ids` via `BRepAlgoAPI_Cut` (SUBTRACT) or `BRepAlgoAPI_Common`
(COMMON), reusing `app.document.extrude._register_solids` (see
`app.document.boolean.apply_boolean_to_bodies`'s own docstring). Unlike
`MergeFeature`, has a real target/tool distinction and a `consume_tool_
bodies` option. Mirrors test_stage_q_merge.py's own structure and helpers
(copy-pasted, not shared via conftest, same as every other test_stage*.py
file). Needs a real pythonocc-core environment (not available in this
repo's own dev sandbox - see docs/status.md's dated entries for whether a
real on-device/CI pass has actually run by the time this is read).
"""

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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def _create_boolean(
    part_id: str,
    operation: str,
    target_body_ids: list[str],
    tool_body_ids: list[str],
    *,
    consume_tool_bodies: bool | None = None,
):
    payload = {
        "operation": operation,
        "target_body_ids": target_body_ids,
        "tool_body_ids": tool_body_ids,
    }
    if consume_tool_bodies is not None:
        payload["consume_tool_bodies"] = consume_tool_bodies
    return client.post(f"/document/parts/{part_id}/boolean-features", json=payload)


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_boolean_requires_at_least_one_target_body_id():
    part = _create_part()
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(part["id"], "subtract", [], [tool_id])

    assert response.status_code == 422


def test_boolean_requires_at_least_one_tool_body_id():
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(part["id"], "subtract", [target_id], [])

    assert response.status_code == 422


def test_boolean_rejects_a_body_appearing_in_both_target_and_tool():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    other_id = _make_box(part["id"], x0=20.0)

    response = _create_boolean(part["id"], "subtract", [body_id, other_id], [body_id])

    assert response.status_code == 422


def test_boolean_with_an_unknown_body_id_is_rejected():
    part = _create_part()
    target_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(part["id"], "subtract", [target_id], ["not-a-real-feature-id"])

    assert response.status_code == 400


# --- Subtract geometry -------------------------------------------------------


def test_subtract_with_consume_true_removes_the_tool_body():
    """A 10x10x10 target box at x=[5,15] (overlapping [0,10] tool box by
    half) subtracted, consuming the tool - the tool Body must be gone from
    the mesh afterward."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(
        part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=True
    )

    assert response.status_code == 201
    assert response.json()["type"] == "boolean"
    assert response.json()["consume_tool_bodies"] is True

    body_ids = _body_ids(part["id"])
    assert tool_id not in body_ids
    assert target_id in body_ids
    x_range, _y, _z = _bbox_ranges(part["id"], target_id)
    assert x_range == (10.0, 15.0)


def test_subtract_with_consume_false_keeps_the_tool_body_untouched():
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(
        part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=False
    )

    assert response.status_code == 201
    assert response.json()["consume_tool_bodies"] is False

    body_ids = _body_ids(part["id"])
    assert tool_id in body_ids
    assert target_id in body_ids
    tool_x_range, _y, _z = _bbox_ranges(part["id"], tool_id)
    assert tool_x_range == (0.0, 10.0)  # tool body's own shape is untouched
    target_x_range, _y, _z = _bbox_ranges(part["id"], target_id)
    assert target_x_range == (10.0, 15.0)


def test_subtract_default_consumes_the_tool_body():
    """`consume_tool_bodies` defaults to True when omitted from the payload."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(part["id"], "subtract", [target_id], [tool_id])

    assert response.status_code == 201
    assert response.json()["consume_tool_bodies"] is True
    assert tool_id not in _body_ids(part["id"])


def test_subtract_multiple_targets_and_multiple_tools():
    """Two disjoint target boxes at x=[0,10]/x=[20,30], each notched by two
    tool boxes stacked at y=[0,5]/y=[5,10]/z-overlap - both targets end up
    with an equal, smaller footprint after both tools are folded in."""
    part = _create_part()
    target_a = _make_box(part["id"], x0=0.0, size=10.0)
    target_b = _make_box(part["id"], x0=20.0, size=10.0)
    tool_a = _make_box(part["id"], x0=0.0, y0=5.0, size=10.0)
    tool_b = _make_box(part["id"], x0=20.0, y0=5.0, size=10.0)

    response = _create_boolean(
        part["id"], "subtract", [target_a, target_b], [tool_a, tool_b], consume_tool_bodies=True
    )

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert tool_a not in body_ids
    assert tool_b not in body_ids
    assert target_a in body_ids
    assert target_b in body_ids
    _x, y_range_a, _z = _bbox_ranges(part["id"], target_a)
    _x, y_range_b, _z = _bbox_ranges(part["id"], target_b)
    assert y_range_a == (0.0, 5.0)
    assert y_range_b == (0.0, 5.0)


# --- Common geometry ---------------------------------------------------------


def test_common_keeps_only_the_shared_volume():
    """A 10x10x10 target box at x=[5,15] intersected with a tool box at
    x=[0,10] - COMMON keeps only the shared [5,10] slice."""
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(part["id"], "common", [target_id], [tool_id], consume_tool_bodies=True)

    assert response.status_code == 201
    assert response.json()["type"] == "boolean"
    assert response.json()["operation"] == "common"

    body_ids = _body_ids(part["id"])
    assert tool_id not in body_ids
    assert target_id in body_ids
    x_range, _y, _z = _bbox_ranges(part["id"], target_id)
    assert x_range == (5.0, 10.0)


def test_common_with_consume_false_keeps_the_tool_body_untouched():
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)

    response = _create_boolean(
        part["id"], "common", [target_id], [tool_id], consume_tool_bodies=False
    )

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert tool_id in body_ids
    assert target_id in body_ids
    tool_x_range, _y, _z = _bbox_ranges(part["id"], tool_id)
    assert tool_x_range == (0.0, 10.0)


# --- native_format round-trip -------------------------------------------------


def test_boolean_feature_round_trips_through_native_export_import():
    """Mirrors test_stage_q_merge.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        target_id = _make_box(part["id"], x0=5.0)
        tool_id = _make_box(part["id"], x0=0.0)
        boolean = _create_boolean(
            part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=False
        ).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "boolean")
        assert round_tripped["operation"] == boolean["operation"] == "subtract"
        assert round_tripped["target_body_ids"] == boolean["target_body_ids"] == [target_id]
        assert round_tripped["tool_body_ids"] == boolean["tool_body_ids"] == [tool_id]
        assert round_tripped["consume_tool_bodies"] == boolean["consume_tool_bodies"] is False
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_boolean_common_feature_round_trips_through_native_export_import():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        target_id = _make_box(part["id"], x0=5.0)
        tool_id = _make_box(part["id"], x0=0.0)
        boolean = _create_boolean(part["id"], "common", [target_id], [tool_id]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "boolean")
        assert round_tripped["operation"] == boolean["operation"] == "common"
        assert round_tripped["consume_tool_bodies"] == boolean["consume_tool_bodies"] is True
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_the_target_bodys_owning_extrude_cascade_deletes_the_boolean_feature():
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)
    boolean = _create_boolean(
        part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=False
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{target_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {target_id, boolean["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert boolean["id"] not in remaining
    assert target_id not in remaining
    assert tool_id in remaining


def test_deleting_the_tool_bodys_owning_extrude_cascade_deletes_the_boolean_feature():
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)
    boolean = _create_boolean(
        part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=False
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{tool_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {tool_id, boolean["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert boolean["id"] not in remaining
    assert tool_id not in remaining
    assert target_id in remaining


# --- Update endpoint -----------------------------------------------------------


def test_update_boolean_feature_operation_and_consume_flag():
    part = _create_part()
    target_id = _make_box(part["id"], x0=5.0)
    tool_id = _make_box(part["id"], x0=0.0)
    boolean = _create_boolean(
        part["id"], "subtract", [target_id], [tool_id], consume_tool_bodies=False
    ).json()

    response = client.patch(
        f"/document/parts/{part['id']}/boolean-features/{boolean['id']}",
        json={"operation": "common", "consume_tool_bodies": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["operation"] == "common"
    assert body["consume_tool_bodies"] is True
    assert body["target_body_ids"] == [target_id]
    assert body["tool_body_ids"] == [tool_id]
    assert tool_id not in _body_ids(part["id"])
