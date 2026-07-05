"""C5: real-OCCT tests for Create Plane's `PlaneRef` generalization over the
real HTTP API - a `face_refs` entry can now be a Body face (unchanged from
C2-C4), a fixed reference plane (XY/XZ/YZ), or an existing CreatePlaneFeature
(`plane_feature_id`), for OFFSET_FACE, MIDPLANE, and PARALLEL_TO_FACE_
THROUGH_VERTEX alike. Mirrors test_stage_c2_create_plane.py/test_stage_c4_
create_plane.py's exact structure/helpers.

Needs a real pythonocc-core environment (not available in this sandbox -
see the recurring caveat in docs/status.md) since `app.main` imports OCC
directly - `ast.parse`-verified/manually reviewed only here, same as every
other OCCT-touching backend prompt in this project until real CI runs it.
"""

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


def _first_body_id(part_id: str) -> str:
    mesh = client.get(f"/document/parts/{part_id}/mesh").json()
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _boxy_part_and_body() -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], sketch_feature["id"])
    return part, _first_body_id(part["id"])


def _face_ref(body_id: str, index: int) -> dict:
    return {"face_ref": {"body_id": body_id, "shape_type": "face", "index": index}}


def _fixed_plane_ref(plane: str) -> dict:
    return {"fixed_plane": plane}


def _plane_feature_ref(plane_feature_id: str) -> dict:
    return {"plane_feature_id": plane_feature_id}


def _create_offset_face_plane(part_id: str, plane_ref: dict, offset: float):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "offset_face", "face_refs": [plane_ref], "offset": offset},
    )


def _create_midplane(part_id: str, plane_ref_a: dict, plane_ref_b: dict):
    return client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={"plane_type": "midplane", "face_refs": [plane_ref_a, plane_ref_b]},
    )


# --- OFFSET_FACE on a fixed reference plane ------------------------------------


def test_offset_face_from_the_xy_plane_succeeds():
    part = _create_part()
    response = _create_offset_face_plane(part["id"], _fixed_plane_ref("XY"), 5.0)
    assert response.status_code == 201
    body = response.json()
    assert body["origin"] == pytest.approx((0.0, 0.0, 5.0))
    assert body["normal"] == pytest.approx((0.0, 0.0, 1.0))


def test_offset_face_from_an_existing_plane_feature_succeeds():
    """A plane offset from another plane, not from a fixed reference plane or
    a Body face directly - the `plane_feature_id` case, resolved recursively
    against the same `bodies` accumulator rather than a fresh
    `compute_part_bodies` call (see `app.document.create_plane._resolve_
    plane_ref`'s own docstring on why that avoids infinite recursion)."""
    part = _create_part()
    base = _create_offset_face_plane(part["id"], _fixed_plane_ref("XY"), 3.0)
    assert base.status_code == 201
    response = _create_offset_face_plane(part["id"], _plane_feature_ref(base.json()["id"]), 2.0)
    assert response.status_code == 201
    body = response.json()
    assert body["origin"] == pytest.approx((0.0, 0.0, 5.0))
    assert body["normal"] == pytest.approx((0.0, 0.0, 1.0))


# --- MIDPLANE mixing fixed planes, plane features, and Body faces -------------


def test_midplane_between_two_fixed_planes_succeeds():
    part = _create_part()
    response = _create_midplane(part["id"], _fixed_plane_ref("XZ"), _fixed_plane_ref("XZ"))
    # Both refs resolve to the same XZ plane (origin (0,0,0)) - degenerate but
    # still two parallel, coincident planes, so this should succeed with a
    # midpoint equal to that same origin.
    assert response.status_code == 201
    body = response.json()
    assert body["origin"] == pytest.approx((0.0, 0.0, 0.0))


def test_midplane_between_a_fixed_plane_and_a_body_face_succeeds():
    part, body_id = _boxy_part_and_body()
    for index in range(6):
        response = _create_midplane(part["id"], _fixed_plane_ref("XY"), _face_ref(body_id, index))
        if response.status_code == 201:
            body = response.json()
            assert body["plane_type"] == "midplane"
            assert body["origin"] is not None
            return
    raise AssertionError("expected at least one box face parallel to the XY plane")


def test_midplane_between_a_plane_feature_and_a_body_face_succeeds():
    part, body_id = _boxy_part_and_body()
    base = _create_offset_face_plane(part["id"], _fixed_plane_ref("XY"), 0.0)
    assert base.status_code == 201
    for index in range(6):
        response = _create_midplane(
            part["id"], _plane_feature_ref(base.json()["id"]), _face_ref(body_id, index)
        )
        if response.status_code == 201:
            body = response.json()
            assert body["plane_type"] == "midplane"
            assert body["origin"] is not None
            return
    raise AssertionError("expected at least one box face parallel to the XY plane")


def test_midplane_between_non_parallel_planes_is_rejected():
    part = _create_part()
    response = _create_midplane(part["id"], _fixed_plane_ref("XY"), _fixed_plane_ref("XZ"))
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "faces_not_parallel"
    detail = response.json()["detail"]
    assert detail["ref_a"] == {"kind": "fixed_plane", "plane": "XY"}
    assert detail["ref_b"] == {"kind": "fixed_plane", "plane": "XZ"}


# --- PARALLEL_TO_FACE_THROUGH_VERTEX on a fixed plane --------------------------


def test_parallel_to_face_through_vertex_from_a_fixed_plane_succeeds():
    part, body_id = _boxy_part_and_body()
    for vertex_index in range(8):
        response = client.post(
            f"/document/parts/{part['id']}/create-plane-features",
            json={
                "plane_type": "parallel_to_face_through_vertex",
                "face_refs": [_fixed_plane_ref("XY")],
                "vertex_ref": {"body_id": body_id, "shape_type": "vertex", "index": vertex_index},
            },
        )
        if response.status_code == 201:
            body = response.json()
            assert body["normal"] == pytest.approx((0.0, 0.0, 1.0))
            return
    raise AssertionError("expected at least one resolvable vertex on a box")


# --- Validation of a malformed `face_refs` entry -------------------------------


def test_face_refs_entry_with_no_fields_set_is_rejected():
    part = _create_part()
    response = _create_offset_face_plane(part["id"], {}, 1.0)
    assert response.status_code == 422


def test_face_refs_entry_with_two_fields_set_is_rejected():
    part = _create_part()
    plane_ref = {"fixed_plane": "XY", "plane_feature_id": "does-not-matter"}
    response = _create_offset_face_plane(part["id"], plane_ref, 1.0)
    assert response.status_code == 422


def test_face_refs_entry_with_an_unknown_plane_feature_id_is_rejected():
    part = _create_part()
    response = _create_offset_face_plane(part["id"], _plane_feature_ref("no-such-plane"), 1.0)
    assert response.status_code == 400


def test_face_refs_entry_naming_a_non_plane_feature_id_is_rejected():
    """A `plane_feature_id` must resolve to a CreatePlaneFeature specifically
    - naming a real Feature of a different type (an ExtrudeFeature here) is
    the same class of error `_validate_sketch_feature_payload` already
    guards against for its own `plane_feature_id`."""
    part, _body_id = _boxy_part_and_body()
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    extrude_feature_id = mesh[0]["body_id"]
    response = _create_offset_face_plane(part["id"], _plane_feature_ref(extrude_feature_id), 1.0)
    assert response.status_code == 400


def test_face_refs_entry_with_a_non_face_shape_type_is_still_rejected():
    part, body_id = _boxy_part_and_body()
    plane_ref = {"face_ref": {"body_id": body_id, "shape_type": "edge", "index": 0}}
    response = _create_offset_face_plane(part["id"], plane_ref, 1.0)
    assert response.status_code == 422


# --- Editing a plane_feature_id-anchored plane --------------------------------


def test_patch_can_repoint_an_offset_face_plane_from_a_fixed_plane_to_another_plane_feature():
    part = _create_part()
    base = _create_offset_face_plane(part["id"], _fixed_plane_ref("XZ"), 4.0)
    assert base.status_code == 201
    created = _create_offset_face_plane(part["id"], _fixed_plane_ref("XY"), 1.0)
    assert created.status_code == 201

    patch_response = client.patch(
        f"/document/parts/{part['id']}/create-plane-features/{created.json()['id']}",
        json={"face_refs": [_plane_feature_ref(base.json()["id"])]},
    )
    assert patch_response.status_code == 200
    updated = patch_response.json()
    assert updated["face_refs"] == [{"face_ref": None, "fixed_plane": None, "plane_feature_id": base.json()["id"]}]
    # base is XZ offset by 4 (origin (0, 4, 0), normal (0, 1, 0) - see
    # plane_geometry._PLANE_BASIS's hand-written XZ row); `created` keeps its
    # own offset (1.0, untouched by this face_refs-only PATCH) stacked on top
    # of that, along the same normal: (0, 4, 0) + 1 * (0, 1, 0) = (0, 5, 0).
    assert updated["origin"] == pytest.approx((0.0, 5.0, 0.0))
