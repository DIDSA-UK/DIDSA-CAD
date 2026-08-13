"""Regression coverage for the on-device repro of the "save keeps
reproducing the first file" bug, found *after* the session-scoping fix
(`test_bugfix_document_session_isolation.py`) - this one reproduces within
a single session, no second tab/device/session involved at all:

  1. Start a new part, model it, Save.
  2. Start ANOTHER new part (same running app, same session), model it,
     Save As to a different file.
  3. Open both saved files - both show the FIRST part's model.

Root cause: `POST /document/parts` (`create_part`) has always been purely
additive - it adds a Part onto whatever Document the current session
already has (`app.document.store.get_document`), with no reset. Nothing
ever cleared the session's Document between "New Part" presses, so a
second "New Part" silently piled its Part onto the Document alongside the
first. Native Save (`GET /document/export/native`) exports the *entire*
Document - every Part ever created that session - and native Open always
displays only the first Part in the imported list (client-side
`partIds.first`, since the app has never had a "pick a Part" UI). So the
second Part's data technically survives inside the second file, but is
never reachable - both files "show" the first Part.

The fix: `POST /document/new` (`start_new_document`) does a full
Document/Sketch-store replace with an empty Document, the same "whatever
was open before is discarded entirely" semantics as native import - and
the client now calls it immediately before the first `create_part` of
every "New Part"/cold-launch flow. These tests drive that fix directly
over HTTP, confirming a `POST /document/new` between two "New Part"
sequences keeps their Saves completely independent."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _headers(session_id: str) -> dict:
    return {"X-Document-Session": session_id}


def test_new_document_clears_every_existing_part_in_the_session():
    session = "reset-parts"
    client.post("/document/parts", json={"name": "Rectangle Part"}, headers=_headers(session))
    client.post("/document/parts", json={"name": "Second Part"}, headers=_headers(session))

    response = client.post("/document/new", headers=_headers(session))
    assert response.status_code == 201
    assert response.json()["part_ids"] == []

    export = client.get("/document/export/native", headers=_headers(session)).json()
    assert export["document"]["parts"] == []


def test_new_document_clears_existing_sketches_in_the_session():
    session = "reset-sketches"
    sketch = client.post("/sketch/sketches", json={"plane": "XY"}, headers=_headers(session)).json()

    client.post("/document/new", headers=_headers(session))

    assert client.get(f"/sketch/sketches/{sketch['id']}", headers=_headers(session)).status_code == 404


def test_new_document_leaves_other_sessions_completely_untouched():
    session_a = "reset-a"
    session_b = "reset-b"
    client.post("/document/parts", json={"name": "Session A Part"}, headers=_headers(session_a))
    part_b = client.post("/document/parts", json={"name": "Session B Part"}, headers=_headers(session_b)).json()

    client.post("/document/new", headers=_headers(session_a))

    export_a = client.get("/document/export/native", headers=_headers(session_a)).json()
    assert export_a["document"]["parts"] == []

    assert client.get(f"/document/parts/{part_b['id']}", headers=_headers(session_b)).status_code == 200


def test_two_new_part_cycles_in_one_session_produce_two_independent_saves():
    """The exact on-device repro, reproduced entirely within one session:
    New Part -> model -> Save, New Part -> model -> Save As - without the
    `/document/new` reset between them, both Saves would each contain
    *both* Parts, and Open would always show only the first."""
    session = "one-session-two-new-parts"

    # "New Part" #1 (mirrors the client's own startNewDocument + createPart
    # sequence in PartScreen._loadPart) -> model a rectangle -> Save.
    client.post("/document/new", headers=_headers(session))
    part_1 = client.post(
        "/document/parts", json={"name": "Extruded Rectangle"}, headers=_headers(session)
    ).json()
    save_1 = client.get("/document/export/native", headers=_headers(session)).json()

    # "New Part" #2, same session -> model a circle -> Save As (a second,
    # different file).
    client.post("/document/new", headers=_headers(session))
    part_2 = client.post(
        "/document/parts", json={"name": "Extruded Circle"}, headers=_headers(session)
    ).json()
    save_2 = client.get("/document/export/native", headers=_headers(session)).json()

    assert part_1["id"] != part_2["id"]

    # Each save is its own, single-Part Document - neither contains the
    # other's Part, so opening either file shows the Part that was actually
    # current at Save time, not always the first one ever created.
    assert [p["name"] for p in save_1["document"]["parts"]] == ["Extruded Rectangle"]
    assert [p["name"] for p in save_2["document"]["parts"]] == ["Extruded Circle"]
