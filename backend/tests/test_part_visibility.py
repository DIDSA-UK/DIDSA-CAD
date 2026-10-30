"""Hide / Show as saved Part state (`docs/touch-viewport-ux-plan.md` section 6.1, phase T0):
`PATCH /document/parts/{id}/visibility`, the mesh routes honouring the stored set, the native round trip and the
legacy top-level `hidden_feature_ids` key."""

import copy

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part() -> dict:
    response = client.post("/document/parts", json={"name": "Visibility"})
    assert response.status_code == 201
    return response.json()


def _sketch(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _square(sketch_id: str) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}
        )
        assert response.status_code == 201


def _extrude(part_id: str, sketch_feature_id: str) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 10.0,
            "target_body_ids": [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _midplane(part_id: str, body_id: str) -> dict:
    for i in range(6):
        for j in range(6):
            if i == j:
                continue
            response = client.post(
                f"/document/parts/{part_id}/create-plane-features",
                json={
                    "plane_type": "midplane",
                    "face_refs": [
                        {"face_ref": {"body_id": body_id, "shape_type": "face", "index": i}},
                        {"face_ref": {"body_id": body_id, "shape_type": "face", "index": j}},
                    ],
                },
            )
            if response.status_code == 201:
                return response.json()
    raise AssertionError("a box has parallel faces")


def _scene() -> dict:
    """One Part: sketch 1 -> extrude (a body) -> a midplane -> sketch 2 (on nothing else)."""
    part = _create_part()
    sketch_1 = _sketch(part["id"])
    _square(sketch_1["sketch_id"])
    extrude = _extrude(part["id"], sketch_1["id"])
    body_id = client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]
    plane = _midplane(part["id"], body_id)
    sketch_2 = _sketch(part["id"], "YZ")
    return {
        "part_id": part["id"],
        "sketch_1": sketch_1["id"],
        "sketch_2": sketch_2["id"],
        "extrude": extrude["id"],
        "plane": plane["id"],
    }


def _patch(part_id: str, **body):
    return client.patch(f"/document/parts/{part_id}/visibility", json=body)


def test_new_part_has_nothing_hidden():
    part = _create_part()
    response = client.get(f"/document/parts/{part['id']}").json()
    assert response["hidden_feature_ids"] == []
    assert response["reference_planes_hidden"] is False


def test_hide_and_show_explicit_feature_ids():
    s = _scene()
    response = _patch(s["part_id"], hidden=True, feature_ids=[s["sketch_1"], s["extrude"]])
    assert response.status_code == 200
    assert response.json() == {
        "hidden_feature_ids": sorted([s["sketch_1"], s["extrude"]]),
        "reference_planes_hidden": False,
    }
    # PartResponse carries the same state.
    assert client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"] == sorted(
        [s["sketch_1"], s["extrude"]]
    )
    shown = _patch(s["part_id"], hidden=False, feature_ids=[s["sketch_1"]]).json()
    assert shown["hidden_feature_ids"] == [s["extrude"]]


def test_categories_resolve_from_produces_at_call_time():
    s = _scene()
    assert _patch(s["part_id"], hidden=True, categories=["sketch"]).json()["hidden_feature_ids"] == sorted(
        [s["sketch_1"], s["sketch_2"]]
    )
    assert _patch(s["part_id"], hidden=True, categories=["plane"]).json()["hidden_feature_ids"] == sorted(
        [s["sketch_1"], s["sketch_2"], s["plane"]]
    )
    assert _patch(s["part_id"], hidden=True, categories=["body"]).json()["hidden_feature_ids"] == sorted(
        [s["sketch_1"], s["sketch_2"], s["plane"], s["extrude"]]
    )
    shown = _patch(s["part_id"], hidden=False, categories=["sketch", "plane", "body"]).json()
    assert shown["hidden_feature_ids"] == []
    # A feature made after a batch hide is visible (the batch only covers what existed).
    _patch(s["part_id"], hidden=True, categories=["sketch"])
    sketch_3 = _sketch(s["part_id"], "XZ")
    assert sketch_3["id"] not in client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"]


def test_reference_planes_flag():
    s = _scene()
    response = _patch(s["part_id"], hidden=True, reference_planes=True)
    assert response.json() == {"hidden_feature_ids": [], "reference_planes_hidden": True}
    assert client.get(f"/document/parts/{s['part_id']}").json()["reference_planes_hidden"] is True
    assert _patch(s["part_id"], hidden=False, reference_planes=True).json()["reference_planes_hidden"] is False


def test_invalid_requests_are_422_and_change_nothing():
    s = _scene()
    assert _patch(s["part_id"], hidden=True).status_code == 422
    unknown = _patch(s["part_id"], hidden=True, feature_ids=[s["sketch_1"], "no-such-feature"])
    assert unknown.status_code == 422
    assert _patch(s["part_id"], hidden=True, categories=["nonsense"]).status_code == 422
    assert client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"] == []
    assert client.patch("/document/parts/no-such-part/visibility", json={"hidden": True, "reference_planes": True}).status_code == 404


def test_deleting_a_feature_drops_it_from_the_hidden_set():
    s = _scene()
    _patch(s["part_id"], hidden=True, feature_ids=[s["sketch_2"], s["sketch_1"]])
    assert client.delete(f"/document/parts/{s['part_id']}/features/{s['sketch_2']}").status_code == 204
    assert client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"] == [s["sketch_1"]]
    cascade = client.delete(f"/document/parts/{s['part_id']}/features/{s['sketch_1']}/cascade")
    assert cascade.status_code in (200, 204)
    assert client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"] == []


def test_mesh_flags_bodies_hidden_by_the_stored_set_and_unions_the_query_parameter():
    s = _scene()
    before = client.get(f"/document/parts/{s['part_id']}/mesh").json()
    assert [b["hidden"] for b in before] == [False]
    _patch(s["part_id"], hidden=True, categories=["body"])
    stored = client.get(f"/document/parts/{s['part_id']}/mesh").json()
    assert [b["hidden"] for b in stored] == [True]  # still returned, flagged
    _patch(s["part_id"], hidden=False, categories=["body"])
    query = client.get(f"/document/parts/{s['part_id']}/mesh", params={"hidden_feature_ids": [s["extrude"]]}).json()
    assert [b["hidden"] for b in query] == [True]


def test_assembly_mesh_reports_the_stored_set():
    s = _scene()
    _patch(s["part_id"], hidden=True, categories=["body"])
    response = client.get(f"/document/parts/{s['part_id']}/assembly-mesh")
    assert response.status_code == 200
    geometry = next(g for g in response.json()["geometry"] if g["part_id"] == s["part_id"])
    assert [b["hidden"] for b in geometry["bodies"]] == [True]


def test_native_round_trip_keeps_both_fields_and_writes_the_legacy_top_level_key():
    s = _scene()
    _patch(s["part_id"], hidden=True, feature_ids=[s["sketch_1"]], reference_planes=True)
    exported = client.get("/document/export/native", params={"part_id": s["part_id"]}).json()
    part_data = exported["document"]["parts"][0]
    assert part_data["hidden_feature_ids"] == [s["sketch_1"]]
    assert part_data["reference_planes_hidden"] is True
    assert exported["hidden_feature_ids"] == [s["sketch_1"]]  # legacy key: the root Part's set

    assert client.post("/document/import/native", json=exported).status_code == 200
    part = client.get(f"/document/parts/{s['part_id']}").json()
    assert part["hidden_feature_ids"] == [s["sketch_1"]]
    assert part["reference_planes_hidden"] is True


def test_a_part_with_nothing_hidden_exports_no_visibility_keys():
    s = _scene()
    exported = client.get("/document/export/native", params={"part_id": s["part_id"]}).json()
    assert "hidden_feature_ids" not in exported
    assert "hidden_feature_ids" not in exported["document"]["parts"][0]
    assert "reference_planes_hidden" not in exported["document"]["parts"][0]


def test_a_file_with_only_the_legacy_key_moves_it_into_the_root_part():
    s = _scene()
    exported = client.get("/document/export/native", params={"part_id": s["part_id"]}).json()
    legacy = copy.deepcopy(exported)
    legacy["hidden_feature_ids"] = [s["sketch_2"], "stale-id"]
    assert client.post("/document/import/native", json=legacy).status_code == 200
    part = client.get(f"/document/parts/{s['part_id']}").json()
    assert part["hidden_feature_ids"] == [s["sketch_2"]]  # a stale id is dropped
    assert part["reference_planes_hidden"] is False


def test_per_part_state_wins_over_the_legacy_key():
    s = _scene()
    _patch(s["part_id"], hidden=True, feature_ids=[s["sketch_1"]])
    exported = client.get("/document/export/native", params={"part_id": s["part_id"]}).json()
    exported["hidden_feature_ids"] = [s["sketch_2"]]
    assert client.post("/document/import/native", json=exported).status_code == 200
    assert client.get(f"/document/parts/{s['part_id']}").json()["hidden_feature_ids"] == [s["sketch_1"]]
