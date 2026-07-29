"""Pattern/Mirror scoping's Phase 6 (`docs/pattern-mirror-scope.md` §2.8/§4):
real-OCCT tests for multi-feature seed selection (`source_feature_ids`, both
Mirror and Pattern) and Pattern's own multi-body widening (`source_body_ids`
from exactly-one to 1+, mirroring Mirror's Phase 1 revision). Mirrors
test_stage_i_mirror.py/test_stage_j_pattern.py's structure and helpers - all
touch `app.main`/`app.document.mirror`/`app.document.pattern`/`app.document.
extrude`, which import OCC.Core directly.
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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


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


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body() -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"]), extrude["id"]


def _two_box_part() -> tuple[dict, str, str, str, str]:
    """A Part with two independent boxes, each its own ExtrudeFeature -
    returns (part, body_id_a, extrude_id_a, body_id_b, extrude_id_b)."""
    part = _create_part()
    sketch_a = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0)
    extrude_a = _create_extrude_feature(part["id"], sketch_a["id"])
    sketch_b = _create_square_sketch_feature(part["id"], x0=100.0, y0=100.0)
    extrude_b = _create_extrude_feature(part["id"], sketch_b["id"])
    body_id_a, body_id_b = _body_ids(part["id"])
    return part, body_id_a, extrude_a["id"], body_id_b, extrude_b["id"]


def _fixed_plane_ref(plane: str) -> dict:
    return {"face_ref": None, "fixed_plane": plane, "plane_feature_id": None}


def _fixed_axis_direction(axis: str) -> dict:
    return {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": axis}


def _vertex_x_range(part_id: str, body_id: str) -> tuple[float, float]:
    mesh = next(entry for entry in _mesh(part_id) if entry["body_id"] == body_id)
    xs = [v[0] for v in mesh["mesh"]["vertices"]]
    return min(xs), max(xs)


def _create_mirror(
    part_id: str,
    source_body_ids: list[str],
    mirror_plane: dict,
    *,
    source_feature_ids: list[str] | None = None,
    merge: str = "keep_separate",
):
    return client.post(
        f"/document/parts/{part_id}/mirror-features",
        json={
            "source_body_ids": source_body_ids,
            "mirror_plane": mirror_plane,
            "source_feature_ids": source_feature_ids or [],
            "merge": merge,
        },
    )


def _create_pattern(
    part_id: str,
    source_body_ids: list[str],
    direction_1: dict,
    count_1: int,
    spacing_1: float,
    *,
    source_feature_ids: list[str] | None = None,
    skip_indices: list[int] | None = None,
    merge: str = "keep_separate",
):
    return client.post(
        f"/document/parts/{part_id}/pattern-features",
        json={
            "source_body_ids": source_body_ids,
            "source_feature_ids": source_feature_ids or [],
            "direction_1": direction_1,
            "count_1": count_1,
            "spacing_1": spacing_1,
            "skip_indices": skip_indices or [],
            "merge": merge,
        },
    )


# --- Mirror: source_feature_ids -----------------------------------------------


def test_mirror_zero_source_body_ids_and_zero_source_feature_ids_is_rejected():
    part, _body_id, _extrude_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"))
    assert response.status_code == 422


def test_mirror_source_feature_ids_alone_resolves_to_its_body():
    part, body_id, extrude_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), source_feature_ids=[extrude_id])
    assert response.status_code == 201
    feature = response.json()
    assert feature["source_body_ids"] == []
    assert feature["source_feature_ids"] == [extrude_id]

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert body_id in body_ids


def test_mirror_source_body_ids_and_source_feature_ids_combine():
    part, body_id_a, _extrude_id_a, body_id_b, extrude_id_b = _two_box_part()
    response = _create_mirror(
        part["id"], [body_id_a], _fixed_plane_ref("YZ"), source_feature_ids=[extrude_id_b]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 4  # 2 originals + 2 mirrored
    mirrored_ids = [bid for bid in body_ids if bid not in (body_id_a, body_id_b)]
    assert len(mirrored_ids) == 2


def test_mirror_naming_a_body_both_directly_and_via_its_own_feature_dedupes():
    part, body_id, extrude_id = _boxy_part_and_body()
    response = _create_mirror(
        part["id"], [body_id], _fixed_plane_ref("YZ"), source_feature_ids=[extrude_id]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    # Deduplicated: exactly one mirrored copy, not two.
    assert len(body_ids) == 2


def test_mirror_source_feature_ids_unknown_feature_is_rejected():
    part, _body_id, _extrude_id = _boxy_part_and_body()
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), source_feature_ids=["no-such-feature"])
    assert response.status_code == 400


def test_mirror_source_feature_ids_naming_a_sketch_feature_is_rejected():
    part, _body_id, _extrude_id = _boxy_part_and_body()
    sketch = _create_sketch_feature(part["id"])
    response = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), source_feature_ids=[sketch["id"]])
    assert response.status_code == 400


def test_mirror_source_feature_ids_naming_another_mirror_feature_resolves_its_bodies():
    """Phase 6 completes the nested-pattern/chained-mirror scope Phase 1's
    own docstring deferred: a MirrorFeature is now an accepted
    source_feature_ids producer too."""
    part, body_id, extrude_id = _boxy_part_and_body()
    first_mirror = _create_mirror(part["id"], [extrude_id], _fixed_plane_ref("YZ")).json()

    response = _create_mirror(
        part["id"], [], _fixed_plane_ref("XZ"), source_feature_ids=[first_mirror["id"]]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    # original + first mirror + second mirror (of the first mirror's body)
    assert len(body_ids) == 3


def test_mirror_update_can_change_source_feature_ids():
    part, body_id_a, extrude_id_a, body_id_b, extrude_id_b = _two_box_part()
    mirror = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), source_feature_ids=[extrude_id_a]).json()
    assert len(_body_ids(part["id"])) == 3

    response = client.patch(
        f"/document/parts/{part['id']}/mirror-features/{mirror['id']}",
        json={"source_feature_ids": [extrude_id_b]},
    )
    assert response.status_code == 200
    assert response.json()["source_feature_ids"] == [extrude_id_b]
    assert len(_body_ids(part["id"])) == 3


# --- Pattern: multi-body source_body_ids (Phase 6 widening) -------------------


def test_pattern_zero_source_body_ids_and_zero_source_feature_ids_is_rejected():
    part, _body_id, _extrude_id = _boxy_part_and_body()
    response = _create_pattern(part["id"], [], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 422


def test_pattern_two_source_body_ids_now_accepted_produces_bodies_for_both():
    part, body_id_a, _extrude_id_a, body_id_b, _extrude_id_b = _two_box_part()
    response = _create_pattern(part["id"], [body_id_a, body_id_b], _fixed_axis_direction("x"), 3, 20.0)
    assert response.status_code == 201
    feature = response.json()
    assert feature["source_body_ids"] == [body_id_a, body_id_b]

    body_ids = _body_ids(part["id"])
    # 2 seeds + 2 new instances per source (count_1=3 -> 2 new each) = 6
    assert len(body_ids) == 6


def test_pattern_source_feature_ids_alone_resolves_to_its_body():
    part, body_id, extrude_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"], [], _fixed_axis_direction("x"), 3, 20.0, source_feature_ids=[extrude_id]
    )
    assert response.status_code == 201
    feature = response.json()
    assert feature["source_feature_ids"] == [extrude_id]

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 3  # seed + 2 new instances
    assert body_id in body_ids


def test_pattern_source_body_ids_and_source_feature_ids_combine():
    part, body_id_a, _extrude_id_a, body_id_b, extrude_id_b = _two_box_part()
    response = _create_pattern(
        part["id"], [body_id_a], _fixed_axis_direction("x"), 2, 20.0, source_feature_ids=[extrude_id_b]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    # 2 seeds + 1 new instance per source (count_1=2 -> 1 new each) = 4
    assert len(body_ids) == 4


def test_pattern_naming_a_body_both_directly_and_via_its_own_feature_dedupes():
    part, body_id, extrude_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"], [body_id], _fixed_axis_direction("x"), 3, 20.0, source_feature_ids=[extrude_id]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 3  # seed + 2 new instances (not 5)


def test_pattern_source_feature_ids_unknown_feature_is_rejected():
    part, _body_id, _extrude_id = _boxy_part_and_body()
    response = _create_pattern(
        part["id"], [], _fixed_axis_direction("x"), 3, 20.0, source_feature_ids=["no-such-feature"]
    )
    assert response.status_code == 400


def test_pattern_multi_source_translates_each_source_independently():
    part, body_id_a, _extrude_id_a, body_id_b, _extrude_id_b = _two_box_part()
    _create_pattern(part["id"], [body_id_a, body_id_b], _fixed_axis_direction("x"), 2, 50.0)

    new_ids = [bid for bid in _body_ids(part["id"]) if bid not in (body_id_a, body_id_b)]
    assert len(new_ids) == 2
    original_a_range = _vertex_x_range(part["id"], body_id_a)
    original_b_range = _vertex_x_range(part["id"], body_id_b)
    new_ranges = {_vertex_x_range(part["id"], bid) for bid in new_ids}
    expected_a = (original_a_range[0] + 50.0, original_a_range[1] + 50.0)
    expected_b = (original_b_range[0] + 50.0, original_b_range[1] + 50.0)
    assert expected_a in new_ranges
    assert expected_b in new_ranges


def test_pattern_multi_source_skip_indices_apply_to_every_source():
    part, body_id_a, _extrude_id_a, body_id_b, _extrude_id_b = _two_box_part()
    response = _create_pattern(
        part["id"], [body_id_a, body_id_b], _fixed_axis_direction("x"), 3, 20.0, skip_indices=[1]
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    # 2 seeds + 1 new instance per source (index 2 only, index 1 skipped) = 4
    assert len(body_ids) == 4


def test_pattern_multi_source_fuse_into_one_absorbs_every_source_and_instance():
    """`MergeMode.FUSE_INTO_ONE` fuses every source plus every realized
    instance - across every source, not per-source - into a single result
    (mirrors Mirror's own identical multi-source fuse behaviour, see
    test_stage_m_merge.py's `test_mirror_fuse_into_one_with_two_sources_
    survivor_is_the_earlier_created_source`), registered entirely under
    whichever source's own Feature sorts earliest. Small spacing so each
    source's own realized instance overlaps its own seed; the two sources
    themselves stay far apart (x0=0 vs x0=100), so the fused result still
    splits into two disconnected solids - both under the same survivor
    base id, proving both sources' own seeds were genuinely absorbed into
    one merge rather than each keeping its own separate identity."""
    part, body_id_a, _extrude_id_a, body_id_b, _extrude_id_b = _two_box_part()
    response = _create_pattern(
        part["id"], [body_id_a, body_id_b], _fixed_axis_direction("x"), 2, 5.0, merge="fuse_into_one"
    )
    assert response.status_code == 201

    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    base_ids = {bid.split("#", 1)[0] for bid in body_ids}
    assert base_ids == {body_id_a}


def test_pattern_update_can_change_source_feature_ids():
    part, body_id_a, extrude_id_a, body_id_b, extrude_id_b = _two_box_part()
    pattern = _create_pattern(
        part["id"], [], _fixed_axis_direction("x"), 2, 20.0, source_feature_ids=[extrude_id_a]
    ).json()
    assert len(_body_ids(part["id"])) == 3

    response = client.patch(
        f"/document/parts/{part['id']}/pattern-features/{pattern['id']}",
        json={"source_feature_ids": [extrude_id_b]},
    )
    assert response.status_code == 200
    assert response.json()["source_feature_ids"] == [extrude_id_b]
    assert len(_body_ids(part["id"])) == 3


# --- Cascade delete -----------------------------------------------------------


def test_cascade_deleting_a_source_feature_ids_owning_extrude_takes_the_mirror_with_it():
    part, _body_id, extrude_id = _boxy_part_and_body()
    mirror = _create_mirror(part["id"], [], _fixed_plane_ref("YZ"), source_feature_ids=[extrude_id]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{extrude_id}/cascade")
    assert response.status_code == 200
    assert mirror["id"] in response.json()["deleted_feature_ids"]


def test_cascade_deleting_a_source_feature_ids_owning_extrude_takes_the_pattern_with_it():
    part, _body_id, extrude_id = _boxy_part_and_body()
    pattern = _create_pattern(
        part["id"], [], _fixed_axis_direction("x"), 3, 20.0, source_feature_ids=[extrude_id]
    ).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{extrude_id}/cascade")
    assert response.status_code == 200
    assert pattern["id"] in response.json()["deleted_feature_ids"]
