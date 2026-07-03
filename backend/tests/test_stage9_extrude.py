import pytest
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
    """Draws a closed `size` x `size` square, bottom-left at (x0, y0), into
    an existing (empty) Sketch via the real /sketch API - the square shape
    every test below extrudes."""
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
    return response


def _get_bodies(part_id: str, hidden_feature_ids: list[str] | None = None) -> list[dict]:
    """A1: GET /mesh now returns a JSON array of Bodies (see
    app.document.schemas.BodyMeshResponse) instead of one combined mesh -
    every call site that used to do `client.get(...).json()` and read
    `body["source"]`/`body["mesh"]` directly now goes through this (and
    `_single_body`/`_max_z`/`_min_z` below) instead."""
    response = client.get(
        f"/document/parts/{part_id}/mesh",
        params={"hidden_feature_ids": hidden_feature_ids} if hidden_feature_ids else None,
    )
    assert response.status_code == 200
    return response.json()


def _single_body(part_id: str, hidden_feature_ids: list[str] | None = None) -> dict:
    """For the many existing tests that only ever produce one Body -
    asserts there's exactly one and returns it, so the rest of the test
    reads exactly as it did before A1's array-wrapping."""
    bodies = _get_bodies(part_id, hidden_feature_ids)
    assert len(bodies) == 1
    return bodies[0]


# --- Creation validation -------------------------------------------------------


def test_create_boss_extrude_on_closed_square_profile_succeeds():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(part["id"], sketch_feature["id"])

    assert response.status_code == 201
    body = response.json()
    assert body["type"] == "extrude"
    assert body["extrude_type"] == "boss"
    assert body["sketch_feature_id"] == sketch_feature["id"]
    assert body["locked"] is False


def test_create_extrude_on_sketch_with_no_closed_profile_is_rejected():
    part = _create_part()
    # An empty Sketch - no Lines at all, so no closed profile.
    sketch_feature = _create_sketch_feature(part["id"])

    response = _create_extrude_feature(part["id"], sketch_feature["id"])

    assert response.status_code == 400
    assert "closed profile" in response.json()["detail"].lower()


def test_create_extrude_on_sketch_with_a_hole_flush_against_its_container_is_rejected():
    """On-device bug: previously this sailed through profile detection (the
    hole's centroid is inside the outer loop, which is all the original
    check verified) and produced a malformed partial solid instead of a
    clean 400 - see test_stage2_profile.py's equivalent detection-level
    test for the root cause."""
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 20.0)
    _add_square(sketch_feature["sketch_id"], 5.0, 0.0, 5.0)

    response = _create_extrude_feature(part["id"], sketch_feature["id"])

    assert response.status_code == 400
    assert "overlapping_loops" in response.json()["detail"].lower()


def test_create_extrude_referencing_a_non_sketch_feature_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude_feature = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    response = _create_extrude_feature(part["id"], extrude_feature["id"])

    assert response.status_code == 400


def test_create_extrude_referencing_unknown_sketch_feature_is_rejected():
    part = _create_part()

    response = _create_extrude_feature(part["id"], "does-not-exist")

    assert response.status_code == 400


# --- Mesh generation -----------------------------------------------------------


def test_part_with_no_extrude_feature_returns_placeholder_mesh():
    part = _create_part()

    body = _single_body(part["id"])

    assert body["source"] == "placeholder"
    assert body["body_id"] == "placeholder"
    assert len(body["mesh"]["vertices"]) > 0


def test_boss_extrude_produces_a_non_empty_computed_mesh():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()
    assert extrude["type"] == "extrude"

    body = _single_body(part["id"])

    assert body["source"] == "computed"
    # A1: a Boss with no target_body_ids starts a brand-new Body, identified
    # by the Boss ExtrudeFeature's own id (see
    # app.document.models.ExtrudeFeature's docstring).
    assert body["body_id"] == extrude["id"]
    assert len(body["mesh"]["vertices"]) > 0
    assert len(body["mesh"]["triangle_indices"]) > 0


def test_cut_with_empty_target_body_ids_is_rejected_with_422():
    """A1: replaces the old "cut with no prior boss is skipped gracefully"
    test - that scenario is no longer expressible, since Cut now requires
    a named target Body at creation time (there is nothing to name if none
    exists yet). See test_cut_targeting_a_hidden_body_is_skipped_gracefully
    below for the new equivalent of "nothing to cut from"."""
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(part["id"], sketch_feature["id"], extrude_type="cut")

    assert response.status_code == 422
    assert "target_body_ids" in response.json()["detail"]


def test_cut_targeting_a_hidden_body_is_skipped_gracefully():
    """A1's equivalent of the old "cut with nothing to cut from" case: the
    target Body's creating Boss is hidden, so the Body doesn't exist at
    recompute time - the Cut must be skipped (not raised) and the mesh
    request must still succeed, with no Body for it in the array."""
    part = _create_part()
    boss_sketch = _create_square_sketch_feature(part["id"])
    boss = _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss").json()
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    )

    bodies = _get_bodies(part["id"], hidden_feature_ids=[boss["id"]])

    assert bodies == []


def test_boss_followed_by_cut_produces_a_different_accumulated_solid():
    part = _create_part()

    boss_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss = _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss").json()
    boss_only_body = _single_body(part["id"])
    assert len(boss_only_body["mesh"]["vertices"]) > 0

    # A smaller square, fully inside the boss footprint and overlapping its
    # full depth, so the Cut genuinely removes material from the Boss solid.
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut_response = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    )
    assert cut_response.status_code == 201

    boss_and_cut_body = _single_body(part["id"])

    assert boss_and_cut_body["source"] == "computed"
    # Cut doesn't change which Body it targets - the id stays the Boss's.
    assert boss_and_cut_body["body_id"] == boss["id"]
    assert len(boss_and_cut_body["mesh"]["vertices"]) > 0
    assert boss_and_cut_body["mesh"]["vertices"] != boss_only_body["mesh"]["vertices"]


def _max_z(mesh_body: dict) -> float:
    return max(v[2] for v in mesh_body["mesh"]["vertices"])


def _min_z(mesh_body: dict) -> float:
    return min(v[2] for v in mesh_body["mesh"]["vertices"])


def test_patch_updates_extrude_distances_and_the_mesh_changes_accordingly():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(
        part["id"], sketch_feature["id"], start_distance=0.0, end_distance=10.0
    ).json()

    mesh_before = _single_body(part["id"])
    assert _max_z(mesh_before) == pytest.approx(10.0)

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{extrude['id']}",
        json={"end_distance": 20.0},
    )
    assert response.status_code == 200
    assert response.json()["end_distance"] == pytest.approx(20.0)

    mesh_after = _single_body(part["id"])
    assert _max_z(mesh_after) == pytest.approx(20.0)


def test_patch_on_a_locked_extrude_feature_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()
    # Add a second SketchFeature after it, locking the extrude feature.
    _create_sketch_feature(part["id"])

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{extrude['id']}",
        json={"end_distance": 20.0},
    )

    assert response.status_code == 400


def test_patch_unknown_extrude_feature_is_404():
    part = _create_part()

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/does-not-exist",
        json={"end_distance": 20.0},
    )

    assert response.status_code == 404


def test_list_features_includes_extrude_feature_after_its_sketch_feature():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    response = client.get(f"/document/parts/{part['id']}/features")

    assert response.status_code == 200
    feature_ids = [f["id"] for f in response.json()]
    assert feature_ids == [sketch_feature["id"], extrude["id"]]


# --- Signed start_distance ------------------------------------------------------


def test_boss_extrude_with_a_nonzero_start_distance_spans_from_start_to_end():
    # start_distance/end_distance are both signed offsets from the sketch
    # plane (see app.document.extrude._solid_for_extrude_feature) - the
    # solid must span literally from one to the other, not from 0 to
    # (end - start).
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(
        part["id"], sketch_feature["id"], start_distance=5.0, end_distance=15.0
    ).json()
    assert extrude["start_distance"] == pytest.approx(5.0)
    assert extrude["end_distance"] == pytest.approx(15.0)

    mesh = _single_body(part["id"])

    assert _min_z(mesh) == pytest.approx(5.0)
    assert _max_z(mesh) == pytest.approx(15.0)


def test_boss_extrude_with_a_negative_start_distance_spans_across_the_sketch_plane():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"], start_distance=-5.0, end_distance=5.0)

    mesh = _single_body(part["id"])

    assert _min_z(mesh) == pytest.approx(-5.0)
    assert _max_z(mesh) == pytest.approx(5.0)


# --- end_distance > start_distance validation -----------------------------------


def test_create_extrude_with_end_distance_not_greater_than_start_distance_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(
        part["id"], sketch_feature["id"], start_distance=10.0, end_distance=10.0
    )

    assert response.status_code == 400
    assert "end_distance must be greater than start_distance" in response.json()["detail"]


def test_create_extrude_with_end_distance_less_than_start_distance_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(
        part["id"], sketch_feature["id"], start_distance=10.0, end_distance=0.0
    )

    assert response.status_code == 400


def test_patch_making_end_distance_not_greater_than_start_distance_is_rejected():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(
        part["id"], sketch_feature["id"], start_distance=0.0, end_distance=10.0
    ).json()

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{extrude['id']}",
        json={"start_distance": 10.0},
    )

    assert response.status_code == 400
    assert "end_distance must be greater than start_distance" in response.json()["detail"]

    # The rejected PATCH must not have mutated the stored feature.
    mesh = _single_body(part["id"])
    assert _max_z(mesh) == pytest.approx(10.0)


# --- hidden_feature_ids ----------------------------------------------------------


def test_hidden_feature_ids_excludes_a_boss_feature_from_the_computed_mesh():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    visible_body = _single_body(part["id"])
    assert len(visible_body["mesh"]["vertices"]) > 0

    # A1: hiding the only Boss feature means its Body was never created at
    # all this recompute, so the array is empty - there is no Body left to
    # return an empty mesh for.
    hidden_bodies = _get_bodies(part["id"], hidden_feature_ids=[extrude["id"]])

    assert hidden_bodies == []


def test_hidden_feature_ids_un_subtracts_a_hidden_cut_feature():
    part = _create_part()

    boss_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss = _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss").json()
    boss_only_body = _single_body(part["id"])

    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    ).json()

    cut_hidden_body = _single_body(part["id"], hidden_feature_ids=[cut["id"]])

    # With the Cut hidden, the mesh should match the pre-Cut (Boss-only) solid.
    assert cut_hidden_body["mesh"]["vertices"] == boss_only_body["mesh"]["vertices"]


# --- C1: nested profiles (a hole in a plate) --------------------------------


def _add_square_hole(sketch_id: str, x0: float, y0: float, size: float) -> None:
    """Draws a second, smaller closed square inside a Sketch that already
    has an outer square in it (see `_add_square`) - the closed inner loop
    `detect_profile` should classify as a hole of the outer one."""
    _add_square(sketch_id, x0, y0, size)


def test_extruding_a_square_with_a_square_hole_produces_a_hollow_prism():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 20.0)
    _add_square_hole(sketch_feature["sketch_id"], 5.0, 5.0, 5.0)

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude.status_code == 201

    body = _single_body(part["id"])

    assert body["source"] == "computed"
    # 2 end caps (each with a hole) + 4 outer walls + 4 inner walls.
    assert len(set(body["mesh"]["face_ids"])) == 10


def test_extruding_a_square_with_a_circular_hole_produces_a_hollow_prism():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    _add_square(sketch_id, 0.0, 0.0, 20.0)
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 10.0}).json()
    circle_response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": 3.0, "angle": 0.0},
    )
    assert circle_response.status_code == 201

    extrude = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert extrude.status_code == 201

    body = _single_body(part["id"])

    assert body["source"] == "computed"
    # 2 end caps (each with a round hole) + 4 outer walls + 1 inner cylindrical wall.
    assert len(set(body["mesh"]["face_ids"])) == 7


# --- C2: multiple disjoint closed profiles (MultiProfile) -------------------


def test_extrude_on_sketch_with_two_disjoint_squares_is_accepted():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)

    response = _create_extrude_feature(part["id"], sketch_feature["id"])

    assert response.status_code == 201


def test_extruding_two_disjoint_squares_produces_two_separate_single_solid_bodies():
    from OCC.Core.TopAbs import TopAbs_SOLID
    from OCC.Core.TopExp import TopExp_Explorer

    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    # Amendment to A1: a Body is always one maximally-connected solid - a
    # single Boss that produces a multi-solid compound via C2's
    # MultiProfile (two disjoint squares) now splits into two separate
    # Bodies, `#0`/`#1` split-index suffixes on the Boss Feature's own id,
    # each containing exactly one solid.
    bodies = compute_part_bodies(get_part_or_404(part["id"]))

    assert set(bodies.keys()) == {f"{extrude['id']}#0", f"{extrude['id']}#1"}
    for solid in bodies.values():
        explorer = TopExp_Explorer(solid, TopAbs_SOLID)
        solid_count = 0
        while explorer.More():
            solid_count += 1
            explorer.Next()
        assert solid_count == 1


def test_extruding_two_disjoint_squares_produces_two_separate_computed_meshes():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 2
    assert {b["body_id"] for b in bodies} == {f"{extrude['id']}#0", f"{extrude['id']}#1"}
    for body in bodies:
        assert body["source"] == "computed"
        # A single 10x10x10 box: 6 faces, 12 triangles.
        assert len(set(body["mesh"]["face_ids"])) == 6
        assert len(body["mesh"]["triangle_indices"]) == 12


def test_multi_profile_sub_profile_with_a_hole_produces_two_separate_bodies():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    _add_square(sketch_id, 0.0, 0.0, 20.0)
    _add_square_hole(sketch_id, 5.0, 5.0, 5.0)
    _add_square(sketch_id, 100.0, 0.0, 10.0)
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 2
    face_counts = sorted(len(set(b["mesh"]["face_ids"])) for b in bodies)
    # Holed square (10 faces, see above) and plain square (6 faces) are now
    # two separate Bodies rather than one compound's combined 16.
    assert face_counts == [6, 10]
    assert {b["body_id"] for b in bodies} == {f"{extrude['id']}#0", f"{extrude['id']}#1"}
