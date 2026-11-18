"""Live sessions P1, backend half (docs/live-sessions-scope.md section 5): read-only view tokens, the document revision header,
the observers' glb cache and display names in the glb.

The presenter is a client with the API key and its own `X-Document-Session`; the observer is a client with only `X-View-Token`.
Needs the real pythonocc-core environment, like test_assembly_mesh_glb.py (whose box and glb helpers this mirrors)."""

import asyncio
import json
import struct
import uuid

import httpx
import pytest
from fastapi.testclient import TestClient

from app import view_tokens
from app.document import router as document_router
from app.document import view_glb_cache
from app.main import app
from tests.conftest import TEST_API_KEY


@pytest.fixture(autouse=True)
def _clean_tokens():
    view_tokens.reset()
    view_glb_cache.reset()
    yield
    view_tokens.reset()
    view_glb_cache.reset()


def _presenter() -> TestClient:
    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY, "X-Document-Session": f"presenter-{uuid.uuid4()}"})
    return client


def _observer(token: str, **extra_headers) -> TestClient:
    client = TestClient(app)
    client.headers.update({"X-View-Token": token, **extra_headers})
    return client


def _box(client: TestClient, name: str, size: float = 10.0) -> dict:
    part = client.post("/document/parts", json={"name": name}).json()
    sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    points = [
        client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}).json()
        for x, y in [(0, 0), (size, 0), (size, size), (0, size)]
    ]
    for a, b in zip(points, points[1:] + points[:1]):
        assert client.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}).status_code == 201
    response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
    )
    assert response.status_code == 201
    return part


def _assembly(client: TestClient) -> tuple[dict, dict]:
    """A root box with one placed child box named "Left bolt" (occurrence `occ-bolt`)."""
    root = _box(client, "Mount", 20.0)
    child = _box(client, "Bolt", 2.0)
    root_export = client.get("/document/export/native", params={"part_id": root["id"]}).json()
    child_export = client.get("/document/export/native", params={"part_id": child["id"]}).json()
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = [
        {
            "id": "occ-bolt",
            "external_ref": f"parts/{child['id']}.didsa",
            "resolved_part_id": child["id"],
            "name_override": "Left bolt",
            "transform": {"translation": [15.0, 0.0, 10.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
            "suppressed": False,
            "hidden": False,
            "color": None,
        }
    ]
    root_dict["mates"] = []
    payload = {
        "schema_version": root_export["schema_version"],
        "document": {"id": "composed", "root_part_id": root["id"], "parts": [root_dict, child_export["document"]["parts"][0]]},
        "sketches": [*root_export["sketches"], *child_export["sketches"]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    return root, child


def _gltf_json(data: bytes) -> dict:
    magic, _version, _length = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF"
    json_len, _ = struct.unpack_from("<II", data, 12)
    return json.loads(data[20 : 20 + json_len])


def _mint(client: TestClient, root_id: str, **body) -> dict:
    response = client.post("/document/view-tokens", json={"root_part_id": root_id, **body})
    assert response.status_code == 201, response.text
    return response.json()


def test_an_observer_reads_the_presenters_glb_with_only_a_token():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    minted = _mint(presenter, root["id"])
    assert len(minted["token"]) >= 40

    observer = _observer(minted["token"])
    response = observer.get(f"/document/parts/{root['id']}/assembly-mesh.glb")
    assert response.status_code == 200
    assert response.headers["content-type"] == "model/gltf-binary"
    assert "content-disposition" not in response.headers  # no file name for an observer
    assert response.headers["etag"].startswith('"')
    assert response.content == presenter.get(f"/document/parts/{root['id']}/assembly-mesh.glb").content


def test_the_glb_names_each_instance():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    gltf = _gltf_json(presenter.get(f"/document/parts/{root['id']}/assembly-mesh.glb").content)
    names = {node["extras"]["instance_path"]: node["extras"].get("name") for node in gltf["nodes"]}
    assert names == {"": "Mount", "occ-bolt": "Left bolt"}


def test_a_token_reads_nothing_but_the_glb_and_view_state():
    presenter = _presenter()
    root, child = _assembly(presenter)
    observer = _observer(_mint(presenter, root["id"])["token"])
    forbidden = [
        ("GET", f"/document/parts/{root['id']}"),
        ("GET", f"/document/parts/{root['id']}/occurrences"),
        ("GET", f"/document/parts/{root['id']}/features"),
        ("GET", f"/document/parts/{root['id']}/mates"),
        ("GET", f"/document/parts/{root['id']}/assembly-mesh"),
        ("GET", "/document/export/native"),
        ("GET", f"/document/parts/{root['id']}/export/step"),
        ("GET", f"/document/parts/{root['id']}/export/assembly-glb"),
        ("GET", "/health"),
        ("POST", "/document/parts"),
        ("PATCH", f"/document/parts/{root['id']}/occurrences/occ-bolt"),
        ("DELETE", f"/document/parts/{root['id']}/occurrences/occ-bolt"),
        ("POST", "/document/view-tokens"),
    ]
    for method, path in forbidden:
        response = observer.request(method, path, json={} if method != "GET" else None)
        assert response.status_code == 401, (method, path, response.status_code)
        assert response.json()["detail"] == "view_token_not_allowed", (method, path)
    assert observer.get(f"/document/parts/{root['id']}/assembly-mesh.glb").status_code == 200
    assert observer.get("/document/view-state").status_code == 200


def test_the_token_binds_the_presenters_session_whatever_header_the_observer_sends():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    token = _mint(presenter, root["id"])["token"]

    other = _presenter()  # another session with a part of its own
    elsewhere = _box(other, "Elsewhere")

    observer = _observer(token, **{"X-Document-Session": other.headers["X-Document-Session"]})
    assert observer.get(f"/document/parts/{root['id']}/assembly-mesh.glb").status_code == 200
    assert observer.get(f"/document/parts/{elsewhere['id']}/assembly-mesh.glb").status_code == 404
    assert _observer(token).get(f"/document/parts/{elsewhere['id']}/assembly-mesh.glb").status_code == 404


def test_unknown_expired_and_revoked_tokens_are_refused():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    glb = f"/document/parts/{root['id']}/assembly-mesh.glb"

    unknown = _observer("not-a-token").get(glb)
    assert unknown.status_code == 401 and unknown.json()["detail"] == "view_token_invalid"
    nothing = TestClient(app).get(glb)
    assert nothing.status_code == 401 and nothing.json()["detail"] == "Missing or invalid API key."

    now = [1_900_000_000.0]
    view_tokens.set_clock(lambda: now[0])
    short = _mint(presenter, root["id"], ttl_s=60)["token"]
    assert _observer(short).get(glb).status_code == 200
    now[0] += 61
    expired = _observer(short).get(glb)
    assert expired.status_code == 401 and expired.json()["detail"] == "view_token_invalid"

    revoked = _mint(presenter, root["id"])["token"]
    assert presenter.delete(f"/document/view-tokens/{revoked}").status_code == 204
    assert _observer(revoked).get(glb).status_code == 401
    assert presenter.delete(f"/document/view-tokens/{revoked}").status_code == 404


def test_a_presenter_cannot_revoke_another_sessions_token_and_a_fifth_token_revokes_the_oldest():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    tokens = [_mint(presenter, root["id"])["token"] for _ in range(5)]
    glb = f"/document/parts/{root['id']}/assembly-mesh.glb"
    assert _observer(tokens[0]).get(glb).status_code == 401
    assert all(_observer(t).get(glb).status_code == 200 for t in tokens[1:])
    assert _presenter().delete(f"/document/view-tokens/{tokens[1]}").status_code == 404


def test_minting_needs_the_key_and_a_root_in_the_callers_session():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    assert TestClient(app).post("/document/view-tokens", json={"root_part_id": root["id"]}).status_code == 401
    assert _presenter().post("/document/view-tokens", json={"root_part_id": root["id"]}).status_code == 404
    assert presenter.post("/document/view-tokens", json={"root_part_id": root["id"], "ttl_s": 13 * 3600}).status_code == 422


def test_the_revision_goes_up_on_a_change_and_not_on_a_read_or_a_preview():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    rev = int(presenter.get(f"/document/parts/{root['id']}").headers["x-document-revision"])
    assert int(presenter.get(f"/document/parts/{root['id']}/occurrences").headers["x-document-revision"]) == rev

    moved = presenter.patch(
        f"/document/parts/{root['id']}/occurrences/occ-bolt",
        json={"transform": {"translation": [5.0, 0.0, 10.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}},
    )
    assert moved.status_code == 200
    assert int(moved.headers["x-document-revision"]) == rev + 1

    preview = presenter.post(
        f"/document/parts/{root['id']}/section-preview",
        json={"planes": [{"origin": [0, 0, 5], "normal": [0, 0, 1], "flipped": False}], "targets": []},
    )
    assert int(preview.headers["x-document-revision"]) == rev + 1
    refused = presenter.patch(f"/document/parts/{root['id']}/occurrences/no-such", json={"hidden": True})
    assert refused.status_code >= 400
    assert int(refused.headers["x-document-revision"]) == rev + 1

    minted = _mint(presenter, root["id"])
    assert minted["rev"] == rev + 1  # minting a token does not change the document
    state = _observer(minted["token"]).get("/document/view-state").json()
    assert state["rev"] == minted["rev"] and state["root_part_id"] == root["id"]


def test_an_observer_refetch_is_304_until_the_document_changes():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    observer = _observer(_mint(presenter, root["id"])["token"])
    glb = f"/document/parts/{root['id']}/assembly-mesh.glb"

    first = observer.get(glb)
    etag = first.headers["etag"]
    assert observer.get(glb, headers={"If-None-Match": etag}).status_code == 304
    # Another query is another entity.
    assert observer.get(glb, params={"tier": "coarse"}, headers={"If-None-Match": etag}).status_code == 200

    presenter.patch(f"/document/parts/{root['id']}/occurrences/occ-bolt", json={"hidden": True})
    after = observer.get(glb, headers={"If-None-Match": etag})
    assert after.status_code == 200
    assert after.headers["etag"] != etag
    assert len(_gltf_json(after.content)["nodes"]) == 1  # the hidden bolt is gone


def test_observers_share_one_encode_per_revision(monkeypatch):
    presenter = _presenter()
    root, _ = _assembly(presenter)
    token = _mint(presenter, root["id"])["token"]
    calls = []
    real = document_router.encode_assembly_glb
    monkeypatch.setattr(document_router, "encode_assembly_glb", lambda *a, **k: calls.append(1) or real(*a, **k))

    glb = f"/document/parts/{root['id']}/assembly-mesh.glb"
    bodies = {_observer(token).get(glb).content for _ in range(6)}
    assert len(bodies) == 1
    assert len(calls) == 1
    presenter.get(glb)  # the presenter's own request is never served from the cache
    assert len(calls) == 2


def test_observer_reads_racing_presenter_edits_never_fail():
    presenter = _presenter()
    root, _ = _assembly(presenter)
    token = _mint(presenter, root["id"])["token"]
    session = presenter.headers["X-Document-Session"]

    async def race():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            presenter_headers = {"X-API-Key": TEST_API_KEY, "X-Document-Session": session}
            observer_headers = {"X-View-Token": token}
            glb = f"/document/parts/{root['id']}/assembly-mesh.glb"
            tasks = []
            for i in range(8):
                tasks.append(
                    client.patch(
                        f"/document/parts/{root['id']}/occurrences/occ-bolt",
                        headers=presenter_headers,
                        json={"transform": {"translation": [float(i), 0.0, 10.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}},
                    )
                )
                tasks.append(client.get(glb, headers=observer_headers))
            return await asyncio.gather(*tasks)

    responses = asyncio.run(race())
    assert [r.status_code for r in responses] == [200] * len(responses)
    for response in responses[1::2]:
        assert len(_gltf_json(response.content)["nodes"]) == 2
    revs = sorted(int(r.headers["x-document-revision"]) for r in responses[0::2])
    assert revs == list(range(revs[0], revs[0] + 8))  # every edit counted once, none lost


def test_health_advertises_the_hub_only_when_told(monkeypatch):
    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    body = client.get("/health").json()
    assert "session_hub" not in body
    assert {"view_tokens", "document_revision", "glb.node_names"} <= set(body["api_features"])
    monkeypatch.setenv("SESSION_HUB_URL", "wss://hub.example.test")
    body = client.get("/health").json()
    assert body["session_hub"] == "wss://hub.example.test"
    assert "session_hub" in body["api_features"]
