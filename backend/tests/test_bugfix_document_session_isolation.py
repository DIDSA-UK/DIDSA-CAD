"""Regression coverage for the "save gets stuck on the first file" data-loss
bug: the backend's Document/Sketch stores used to be single global
singletons (`app.document.store`/`app.sketch.store`, pre-fix), shared by
every connection to the backend regardless of which client/tab/device sent
the request. Two sessions editing concurrently could silently see or
overwrite each other's Document, and Native Save (`GET
/document/export/native`) could hand back whatever the *last-touched*
session's state happened to be rather than the requesting session's own -
exactly the "different model swapped in" symptom reported.

`app.session_context.bind_session_id` now scopes both stores per
`X-Document-Session` header. These tests drive the fix from the same real
HTTP surface the client uses, with two independent session ids standing in
for two independent app instances/tabs/devices talking to the same
backend."""

import threading
import uuid

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _headers(session_id: str) -> dict:
    return {"X-Document-Session": session_id}


def _new_session_id(label: str) -> str:
    return f"{label}-{uuid.uuid4()}"


def _create_part(session_id: str, name: str) -> dict:
    response = client.post("/document/parts", json={"name": name}, headers=_headers(session_id))
    assert response.status_code == 201
    return response.json()


def test_two_sessions_get_independent_parts_not_visible_to_each_other():
    session_a = _new_session_id("session-a")
    session_b = _new_session_id("session-b")

    part_a = _create_part(session_a, "Session A Part")
    part_b = _create_part(session_b, "Session B Part")

    # Each session can read its own Part...
    assert client.get(f"/document/parts/{part_a['id']}", headers=_headers(session_a)).status_code == 200
    assert client.get(f"/document/parts/{part_b['id']}", headers=_headers(session_b)).status_code == 200

    # ...but not the other session's - a single shared global would 200 here.
    assert client.get(f"/document/parts/{part_a['id']}", headers=_headers(session_b)).status_code == 404
    assert client.get(f"/document/parts/{part_b['id']}", headers=_headers(session_a)).status_code == 404


def test_export_native_reflects_only_the_requesting_sessions_own_document():
    """The exact reported symptom: Save (`GET /document/export/native`)
    must hand back the model the requesting session was actually editing,
    never a different session's - even though both sessions hit the same
    backend process and the same in-memory stores under it."""
    session_a = _new_session_id("session-a")
    session_b = _new_session_id("session-b")

    _create_part(session_a, "Todays Model")
    _create_part(session_b, "Yesterdays Model")

    export_a = client.get("/document/export/native", headers=_headers(session_a)).json()
    export_b = client.get("/document/export/native", headers=_headers(session_b)).json()

    names_a = {p["name"] for p in export_a["document"]["parts"]}
    names_b = {p["name"] for p in export_b["document"]["parts"]}

    assert names_a == {"Todays Model"}
    assert names_b == {"Yesterdays Model"}


def test_native_import_full_replace_does_not_touch_another_sessions_document():
    session_a = _new_session_id("session-a")
    session_b = _new_session_id("session-b")

    _create_part(session_a, "Session A Original Part")
    part_b = _create_part(session_b, "Session B Part")

    imported_payload = {
        "schema_version": client.get(
            "/document/export/native", headers=_headers(session_a)
        ).json()["schema_version"],
        "document": {"id": "imported-doc", "parts": [{"id": "imp-part", "name": "Imported Part", "features": []}]},
        "sketches": [],
    }
    response = client.post("/document/import/native", json=imported_payload, headers=_headers(session_a))
    assert response.status_code == 200

    export_a = client.get("/document/export/native", headers=_headers(session_a)).json()
    assert {p["name"] for p in export_a["document"]["parts"]} == {"Imported Part"}

    # Session B's own Document must be completely unaffected by Session A's import.
    export_b = client.get("/document/export/native", headers=_headers(session_b)).json()
    assert {p["name"] for p in export_b["document"]["parts"]} == {"Session B Part"}
    assert client.get(f"/document/parts/{part_b['id']}", headers=_headers(session_b)).status_code == 200


def test_sketch_created_in_one_session_is_not_resolvable_from_another():
    session_a = _new_session_id("session-a")
    session_b = _new_session_id("session-b")

    response = client.post("/sketch/sketches", json={"plane": "XY"}, headers=_headers(session_a))
    assert response.status_code == 201
    sketch_id = response.json()["id"]

    assert client.get(f"/sketch/sketches/{sketch_id}", headers=_headers(session_a)).status_code == 200
    assert client.get(f"/sketch/sketches/{sketch_id}", headers=_headers(session_b)).status_code == 404


def test_omitting_the_session_header_is_backward_compatible_and_self_consistent():
    """No `X-Document-Session` header at all (an older client, a stray
    request) must not error - it falls back to a fixed default session,
    consistently, rather than crashing or silently aliasing onto a random
    other session."""
    response = client.post("/document/parts", json={"name": "No Header Part"})
    assert response.status_code == 201
    part = response.json()

    # Reading it back with no header again must see the same Part...
    assert client.get(f"/document/parts/{part['id']}").status_code == 200

    # ...but an explicit, distinct session must not see it.
    other_session = _new_session_id("other-session")
    assert client.get(f"/document/parts/{part['id']}", headers=_headers(other_session)).status_code == 404


def test_concurrent_requests_across_two_sessions_never_cross_contaminate():
    """Drives real thread-pool-style concurrency (FastAPI runs sync path
    operations off the event loop in a threadpool, same as production) -
    interleaved creates/reads across two sessions must never let one
    session observe the other's Part. This is the closest reproduction of
    the reported bug: two live connections hitting the backend at
    (approximately) the same time."""
    session_a = _new_session_id("concurrent-a")
    session_b = _new_session_id("concurrent-b")
    iterations = 20
    errors: list[str] = []

    def _hammer(session_id: str, label: str) -> None:
        for i in range(iterations):
            name = f"{label}-{i}"
            created = client.post(
                "/document/parts", json={"name": name}, headers=_headers(session_id)
            ).json()
            fetched = client.get(
                f"/document/parts/{created['id']}", headers=_headers(session_id)
            ).json()
            if fetched.get("name") != name:
                errors.append(f"session {session_id}: expected {name!r}, got {fetched.get('name')!r}")

    thread_a = threading.Thread(target=_hammer, args=(session_a, "A"))
    thread_b = threading.Thread(target=_hammer, args=(session_b, "B"))
    thread_a.start()
    thread_b.start()
    thread_a.join()
    thread_b.join()

    assert errors == []

    export_a = client.get("/document/export/native", headers=_headers(session_a)).json()
    export_b = client.get("/document/export/native", headers=_headers(session_b)).json()
    names_a = {p["name"] for p in export_a["document"]["parts"]}
    names_b = {p["name"] for p in export_b["document"]["parts"]}

    assert names_a == {f"A-{i}" for i in range(iterations)}
    assert names_b == {f"B-{i}" for i in range(iterations)}
    assert names_a.isdisjoint(names_b)
