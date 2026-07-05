"""Bug fix: on-device report - "extrude rectangle, create midplane, hide
first extrude, sketch new profile on new plane, extrude new body" produced a
`missing_reference` 422 that blanked the *entire* `/mesh` response, including
the first (perfectly fine) Body, and deleting the Plane "fixed" it.

Root cause: `hidden_feature_ids` (the client's plain Hide/Show state) and
B4 true-rollback's own exclusion set were the exact same mechanism -
`app.document.extrude.compute_part_bodies` skipped a named ExtrudeFeature
entirely, "as if it weren't in the Part's history at all" (correct for
rollback), but that also broke any *other*, still-visible Feature that
legitimately referenced the hidden Feature's Body (a Midplane's `face_refs`,
and everything built on a Sketch anchored to that Plane) - not a DAG
ordering bug (`build_feature_graph`'s topological order already sequences
this correctly), just two different concepts sharing one exclusion list.

Fix: `app.document.router.get_part_mesh` now takes two separate params -
`rollback_excluded_feature_ids` (still fed into `compute_part_bodies`,
still "pretend it doesn't exist", used only by B4) and `hidden_feature_ids`
(now purely cosmetic - every Body is always fully computed against the
Part's real, unmodified history and always present in the response;
`BodyMeshResponse.hidden` is set instead, by tracing the Body's `body_id`
back to its producing Feature via `base_feature_id`). On-device follow-up:
`hidden_feature_ids` originally *dropped* a hidden Body's entry outright,
but the Build Tree needs to keep listing a hidden Body (so Show can be
reached again from the tree) - `hidden` replaced the drop. See
`get_part_mesh`'s own docstring for the full writeup, and
`test_stage9_extrude.py`'s `hidden_feature_ids` section for the one
pre-existing test whose semantics genuinely changed (hiding a Cut, which
owns no Body of its own, still never gets tagged).

Needs a real pythonocc-core environment (not available in this sandbox -
see the recurring caveat in docs/status.md) - `ast.parse`-verified/manually
reviewed only here, same as every other OCCT-touching backend prompt in
this project until real CI runs it.
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


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
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _get_bodies(part_id: str, **params) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh", params=params or None)
    assert response.status_code == 200
    return response.json()


def _first_successful_midplane(part_id: str, body_id: str) -> dict:
    """Same brute-force-the-index-mapping style test_stage_c2_create_plane.py's
    own Midplane helper uses - face-index-to-side correspondence isn't part
    of this API's contract."""
    for i in range(6):
        for j in range(6):
            if i == j:
                continue
            response = client.post(
                f"/document/parts/{part_id}/create-plane-features",
                json={
                    "plane_type": "midplane",
                    "face_refs": [
                        {"body_id": body_id, "shape_type": "face", "index": i},
                        {"body_id": body_id, "shape_type": "face", "index": j},
                    ],
                },
            )
            if response.status_code == 201:
                return response.json()
    raise AssertionError("expected at least one parallel face pair among a box's 6 faces")


def _build_the_reported_scenario() -> dict:
    """Reproduces the on-device report's exact sequence: extrude a
    rectangle (Body A, Extrude 1), create a Midplane on two of its faces
    (Plane 1), sketch a new profile on that Plane (Sketch 2), extrude it
    (Extrude 2, Body B) - all four Features exist by the time every test
    below issues its own `/mesh` GET(s), matching the order the report's
    own failure actually surfaced in (the failing step was the *mesh
    refresh* after Extrude 2's creation, not the creation call itself -
    `create_extrude_feature` never validates resolvability up front, only
    `/mesh` (via `compute_part_bodies`) does)."""
    part = _create_part()
    base_sketch = _create_sketch_feature(part["id"])
    _add_square(base_sketch["sketch_id"], 0.0, 0.0, 10.0)
    extrude_1 = _create_extrude_feature(part["id"], base_sketch["id"])
    body_a_id = _get_bodies(part["id"])[0]["body_id"]

    plane = _first_successful_midplane(part["id"], body_a_id)

    plane_sketch = client.post(
        f"/document/parts/{part['id']}/features/sketch",
        json={"plane_feature_id": plane["id"]},
    ).json()
    _add_square(plane_sketch["sketch_id"], 0.0, 0.0, 2.0)
    extrude_2 = _create_extrude_feature(part["id"], plane_sketch["id"])

    return {
        "part": part,
        "extrude_1": extrude_1,
        "body_a_id": body_a_id,
        "plane": plane,
        "plane_sketch": plane_sketch,
        "extrude_2": extrude_2,
    }


def test_hiding_the_extrude_a_midplane_depends_on_no_longer_breaks_downstream_geometry():
    """The actual reported bug: with Extrude 1 hidden, `/mesh` used to 422
    with `missing_reference` (Midplane's own `face_refs` pointing at a Body
    `compute_part_bodies` had skipped entirely while resolving Sketch 2's
    basis for Extrude 2) - taking the *entire* response down, including
    Body A itself. It must now succeed, with both Bodies present - Body A
    tagged `hidden` (on-device follow-up: a hidden Body's entry stays in
    the array so the Build Tree can still list it, see
    app.document.router.get_part_mesh's own docstring) and Body B
    (Extrude 2's own, genuinely new Body) not."""
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]

    bodies = _get_bodies(part_id, hidden_feature_ids=[scenario["extrude_1"]["id"]])

    assert len(bodies) == 2
    body_a = next(b for b in bodies if b["body_id"] == scenario["body_a_id"])
    body_b = next(b for b in bodies if b["body_id"] != scenario["body_a_id"])
    assert body_a["hidden"] is True
    assert body_b["hidden"] is False


def test_hiding_body_a_never_actually_removes_it_only_the_display_of_it():
    """Directly answers the on-device report's own suspicion ("suspect 2nd
    extrude tries to consume 1st") - Body A is never deleted or fused away
    by hiding it, and its own geometry is untouched by the `hidden` tag.
    Un-hiding (an empty `hidden_feature_ids`) brings it right back exactly
    as it was, alongside Body B."""
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]

    visible_bodies = _get_bodies(part_id)
    assert len(visible_bodies) == 2
    assert all(not b["hidden"] for b in visible_bodies)
    original_a = next(b for b in visible_bodies if b["body_id"] == scenario["body_a_id"])

    hidden_bodies = _get_bodies(part_id, hidden_feature_ids=[scenario["extrude_1"]["id"]])
    assert len(hidden_bodies) == 2
    hidden_a = next(b for b in hidden_bodies if b["body_id"] == scenario["body_a_id"])
    assert hidden_a["hidden"] is True
    assert hidden_a["mesh"]["vertices"] == original_a["mesh"]["vertices"]

    restored_bodies = _get_bodies(part_id)
    assert len(restored_bodies) == 2
    assert all(not b["hidden"] for b in restored_bodies)
    restored_a = next(b for b in restored_bodies if b["body_id"] == scenario["body_a_id"])
    assert restored_a["mesh"]["vertices"] == original_a["mesh"]["vertices"]


def test_rollback_excluded_feature_ids_still_breaks_a_downstream_plane_as_intended():
    """The B4 true-rollback case is *supposed* to behave the old way -
    `rollback_excluded_feature_ids` genuinely means "pretend this Feature
    doesn't exist yet", so a Plane depending on it correctly fails to
    resolve, taking the mesh request down with it. This is what B4's
    editor UI is built to expect while an earlier Feature is being rolled
    back to - the fix above only had to stop plain Hide/Show from doing
    the same thing to something the user only meant to visually hide."""
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]

    response = client.get(
        f"/document/parts/{part_id}/mesh",
        params={"rollback_excluded_feature_ids": [scenario["extrude_1"]["id"]]},
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"
