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
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
        },
    )
    return response


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

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "placeholder"
    assert len(body["mesh"]["vertices"]) > 0


def test_boss_extrude_produces_a_non_empty_computed_mesh():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()
    assert extrude["type"] == "extrude"

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "computed"
    assert len(body["mesh"]["vertices"]) > 0
    assert len(body["mesh"]["triangle_indices"]) > 0


def test_cut_with_no_prior_boss_is_skipped_gracefully():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"], extrude_type="cut").json()
    assert extrude["extrude_type"] == "cut"

    response = client.get(f"/document/parts/{part['id']}/mesh")

    # The mesh request itself must still succeed - just with nothing in it,
    # since the Cut had no base solid to subtract from.
    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "computed"
    assert body["mesh"]["vertices"] == []
    assert body["mesh"]["triangle_indices"] == []


def test_boss_followed_by_cut_produces_a_different_accumulated_solid():
    part = _create_part()

    boss_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss")
    boss_only_mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    assert len(boss_only_mesh["mesh"]["vertices"]) > 0

    # A smaller square, fully inside the boss footprint and overlapping its
    # full depth, so the Cut genuinely removes material from the Boss solid.
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut_response = _create_extrude_feature(part["id"], cut_sketch["id"], extrude_type="cut")
    assert cut_response.status_code == 201

    boss_and_cut_mesh = client.get(f"/document/parts/{part['id']}/mesh").json()

    assert boss_and_cut_mesh["source"] == "computed"
    assert len(boss_and_cut_mesh["mesh"]["vertices"]) > 0
    assert boss_and_cut_mesh["mesh"]["vertices"] != boss_only_mesh["mesh"]["vertices"]


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

    mesh_before = client.get(f"/document/parts/{part['id']}/mesh").json()
    assert _max_z(mesh_before) == pytest.approx(10.0)

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{extrude['id']}",
        json={"end_distance": 20.0},
    )
    assert response.status_code == 200
    assert response.json()["end_distance"] == pytest.approx(20.0)

    mesh_after = client.get(f"/document/parts/{part['id']}/mesh").json()
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

    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()

    assert _min_z(mesh) == pytest.approx(5.0)
    assert _max_z(mesh) == pytest.approx(15.0)


def test_boss_extrude_with_a_negative_start_distance_spans_across_the_sketch_plane():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"], start_distance=-5.0, end_distance=5.0)

    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()

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
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    assert _max_z(mesh) == pytest.approx(10.0)


# --- hidden_feature_ids ----------------------------------------------------------


def test_hidden_feature_ids_excludes_a_boss_feature_from_the_computed_mesh():
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    extrude = _create_extrude_feature(part["id"], sketch_feature["id"]).json()

    visible_mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    assert len(visible_mesh["mesh"]["vertices"]) > 0

    hidden_mesh = client.get(
        f"/document/parts/{part['id']}/mesh",
        params={"hidden_feature_ids": [extrude["id"]]},
    ).json()

    assert hidden_mesh["source"] == "computed"
    assert hidden_mesh["mesh"]["vertices"] == []
    assert hidden_mesh["mesh"]["triangle_indices"] == []


def test_hidden_feature_ids_un_subtracts_a_hidden_cut_feature():
    part = _create_part()

    boss_sketch = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    _create_extrude_feature(part["id"], boss_sketch["id"], extrude_type="boss")
    boss_only_mesh = client.get(f"/document/parts/{part['id']}/mesh").json()

    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut = _create_extrude_feature(part["id"], cut_sketch["id"], extrude_type="cut").json()

    cut_hidden_mesh = client.get(
        f"/document/parts/{part['id']}/mesh",
        params={"hidden_feature_ids": [cut["id"]]},
    ).json()

    # With the Cut hidden, the mesh should match the pre-Cut (Boss-only) solid.
    assert cut_hidden_mesh["mesh"]["vertices"] == boss_only_mesh["mesh"]["vertices"]


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

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
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

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
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


def test_extruding_two_disjoint_squares_produces_a_compound_of_two_solids():
    from OCC.Core.TopAbs import TopAbs_SOLID
    from OCC.Core.TopExp import TopExp_Explorer

    from app.document.extrude import compute_part_solid
    from app.document.store import get_part_or_404

    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)
    _create_extrude_feature(part["id"], sketch_feature["id"])

    solid = compute_part_solid(get_part_or_404(part["id"]))

    assert solid is not None
    explorer = TopExp_Explorer(solid, TopAbs_SOLID)
    solid_count = 0
    while explorer.More():
        solid_count += 1
        explorer.Next()
    assert solid_count == 2


def test_extruding_two_disjoint_squares_produces_a_non_empty_computed_mesh():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    _add_square(sketch_feature["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch_feature["sketch_id"], 100.0, 0.0, 10.0)
    _create_extrude_feature(part["id"], sketch_feature["id"])

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "computed"
    # Two separate 10x10x10 boxes: 12 faces total (6 each), 24 triangles.
    assert len(set(body["mesh"]["face_ids"])) == 12
    assert len(body["mesh"]["triangle_indices"]) == 24


def test_multi_profile_sub_profile_with_a_hole_produces_a_hollow_solid_for_that_sub_profile():
    part = _create_part()
    sketch_feature = _create_sketch_feature(part["id"])
    sketch_id = sketch_feature["sketch_id"]
    _add_square(sketch_id, 0.0, 0.0, 20.0)
    _add_square_hole(sketch_id, 5.0, 5.0, 5.0)
    _add_square(sketch_id, 100.0, 0.0, 10.0)
    _create_extrude_feature(part["id"], sketch_feature["id"])

    response = client.get(f"/document/parts/{part['id']}/mesh")

    assert response.status_code == 200
    body = response.json()
    assert body["source"] == "computed"
    # Holed square (10 faces, see above) + plain square (6 faces) = 16.
    assert len(set(body["mesh"]["face_ids"])) == 16
