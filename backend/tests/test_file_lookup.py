"""Finding moved files, backend (`docs/moved-files-scope.md` F1): the lookup rule against its golden vectors, and
`Occurrence.ref_part_id` (the placed file's root Part id, kept across a single-file save and reload so a client can look a
moved file up by it): native round trip, the seed from an older file's `resolved_part_id`, the API.

Needs a real pythonocc-core environment (boxes are real extrudes), like `test_appearance.py`, whose helpers it uses."""

import copy
import json
from pathlib import Path

from app.document.file_lookup import find_file, name_key
from tests.test_appearance import _box_part, _frame_assembly, client

VECTORS = json.loads((Path(__file__).resolve().parent / "data" / "file_lookup_vectors.json").read_text())


# --- the rule and its vectors -------------------------------------------------------------------------------------


def test_reference_reproduces_the_golden_vectors():
    """`tests/data/file_lookup_vectors.json` is the backend's copy of `docs/file-lookup/vectors.json`
    (tools/file_lookup_vectors/generate.py --check keeps the two in step)."""
    assert VECTORS["cases"]
    for case in VECTORS["cases"]:
        assert find_file(case["reference"], case["at_path"], case["index"]) == case["expected"], case["name"]


def _case(name: str) -> dict:
    return next(c["expected"] for c in VECTORS["cases"] if c["name"] == name)


def test_vectors_say_what_the_scope_decided():
    # One id match is used straight away (owner, question 1); several are asked about.
    assert _case("moved_found_by_id")["result"] == "found" and _case("moved_found_by_id")["via"] == "id"
    assert _case("two_copies_ask")["result"] == "ask" and _case("two_copies_ask")["path"] is None
    # A name match is never used without the user (owner, question 2), even for an older reference with no id.
    for name in ("older_reference_name_suggest", "id_missing_name_suggest", "path_mismatch_suggest"):
        assert _case(name)["result"] == "suggest" and _case(name)["path"] is None, name
    # A different file at the path is never swapped in silently, and is always reported.
    assert _case("path_mismatch_found_by_id")["path_mismatch"] and _case("path_mismatch_found_by_id")["path"] == "archive/Frame A.didsa"
    assert _case("path_mismatch_unread_file")["result"] == "suggest"
    # An older reference still takes whatever is at its path, as before.
    assert _case("path_older_reference") == {"result": "found", "path": "parts/Frame A.didsa", "via": "path", "candidates": [], "path_mismatch": False}


def test_folder_shift_vectors():
    """Item 1b (Flutter-testing feedback 2026-11-11): a whole-path-suffix match for a reference with no stored id is `likely`
    (the client asks before using it); ties, a name-only match, a non-suffix match and a stored id are all suggestions."""
    for name in ("folder_prefix_added", "folder_prefix_removed", "folder_shift_longest_wins", "folder_shift_backslash_and_case"):
        case = _case(name)
        assert case["result"] == "likely" and case["via"] == "suffix" and case["path"] and case["candidates"] == [], name
    for name in (
        "folder_shift_two_equal_suggest",
        "folder_shift_name_only_suggest",
        "folder_shift_not_a_suffix_suggest",
        "folder_shift_stored_id_never_likely",
    ):
        assert _case(name)["result"] == "suggest" and _case(name)["path"] is None, name
    assert _case("folder_shift_two_equal_suggest")["candidates"] == ["proj1/parts/Frame A.didsa", "proj2/parts/Frame A.didsa"]
    # The id is looked up first: a file found by id is never overridden by a suffix match.
    assert _case("folder_shift_id_found_beats_suffix")["via"] == "id"


def test_candidates_are_ordered_by_shared_trailing_segments():
    answer = find_file(
        {"external_ref": "a/b/x.didsa", "ref_part_id": "id-1"},
        None,
        [{"path": "z/x.didsa", "part_id": "o"}, {"path": "q/b/x.didsa", "part_id": "o"}, {"path": "c/b/x.didsa", "part_id": "o"}],
    )
    assert answer["result"] == "suggest"
    assert answer["candidates"] == ["c/b/x.didsa", "q/b/x.didsa", "z/x.didsa"]


def test_name_key():
    assert name_key("parts/Bracket.didsa") == name_key("old/bracket.DIDSAprt") == name_key("Bracket.DIDSACAD") == "bracket"
    assert name_key("a\\b\\Frame A.didsa") == "frame a"
    assert name_key("notes.txt") == "notes.txt"


# --- Occurrence.ref_part_id ---------------------------------------------------------------------------------------


def _occurrences(part_id: str) -> dict[str, dict]:
    r = client.get(f"/document/parts/{part_id}/occurrences")
    assert r.status_code == 200, r.text
    return {o["id"]: o for o in r.json()}


def _single_file(part_id: str) -> dict:
    """What a client saves for one file: `export/native` scoped to that Part."""
    return client.get("/document/export/native", params={"part_id": part_id}).json()


def _native_occurrences(payload: dict) -> dict[str, dict]:
    (part,) = [p for p in payload["document"]["parts"] if p["id"] == payload["document"]["root_part_id"]]
    return {o["id"]: o for o in part["occurrences"]}


def test_ref_part_id_survives_a_single_file_save_and_reload():
    a = _frame_assembly()
    # A composed session: every reference resolved; the API and the saved file carry the placed Part's id.
    occurrences = _occurrences(a["root"])
    assert occurrences["frame"]["resolved_part_id"] == occurrences["frame"]["ref_part_id"] == a["frame"]
    assert occurrences["bolt"]["ref_part_id"] == a["bolt"]
    saved = _single_file(a["root"])
    assert _native_occurrences(saved)["frame"]["ref_part_id"] == a["frame"]

    # The root file opened on its own: the targets are not in the payload, so nothing resolves, but the id stays.
    assert client.post("/document/import/native", json=copy.deepcopy(saved)).status_code == 200
    occurrences = _occurrences(a["root"])
    assert occurrences["frame"]["resolved_part_id"] is None and occurrences["frame"]["ref_part_id"] == a["frame"]
    # Saved again while unresolved: the id is kept (resolved_part_id is null, as before).
    resaved = _native_occurrences(_single_file(a["root"]))["frame"]
    assert resaved["resolved_part_id"] is None and resaved["ref_part_id"] == a["frame"]


def test_an_older_file_seeds_ref_part_id_from_resolved_part_id():
    a = _frame_assembly()
    older = _single_file(a["root"])
    for occurrence in _native_occurrences(older).values():
        del occurrence["ref_part_id"]  # as written before this field existed
    assert client.post("/document/import/native", json=older).status_code == 200
    assert _occurrences(a["root"])["frame"]["ref_part_id"] == a["frame"]


def test_a_reference_never_resolved_writes_nothing_new():
    """An occurrence with no id anywhere writes no `ref_part_id` key, so such a file saves exactly as before."""
    a = _frame_assembly()
    payload = _single_file(a["root"])
    for occurrence in _native_occurrences(payload).values():
        del occurrence["ref_part_id"]
        occurrence["resolved_part_id"] = None
    assert client.post("/document/import/native", json=copy.deepcopy(payload)).status_code == 200
    assert _occurrences(a["root"])["frame"]["ref_part_id"] is None
    assert all("ref_part_id" not in o for o in _native_occurrences(_single_file(a["root"])).values())
    raw = client.get("/document/export/native", params={"part_id": a["root"]}).content
    assert client.post("/document/import/native", json=json.loads(raw)).status_code == 200
    assert client.get("/document/export/native", params={"part_id": a["root"]}).content == raw


def test_a_resolved_target_wins_over_a_stale_stored_id():
    """In a composed session the resolved target's id is what is written: the payload pairing is the newer knowledge."""
    a = _frame_assembly()
    payload = client.get("/document/export/native").json()
    root = next(p for p in payload["document"]["parts"] if p["id"] == a["root"])
    next(o for o in root["occurrences"] if o["id"] == "frame")["ref_part_id"] = "stale-id"
    assert client.post("/document/import/native", json=payload).status_code == 200
    assert _occurrences(a["root"])["frame"]["ref_part_id"] == a["frame"]


def test_native_import_rejects_a_bad_ref_part_id():
    a = _frame_assembly()
    payload = _single_file(a["root"])
    _native_occurrences(payload)["frame"]["ref_part_id"] = 7
    r = client.post("/document/import/native", json=payload)
    assert r.status_code == 422 and "ref_part_id" in r.json()["detail"]


def test_restoring_a_deleted_occurrence_keeps_its_ref_part_id():
    """Undo after a delete (`POST .../occurrences`) restores the id, even when the target is not in the session."""
    a = _frame_assembly()
    before = _occurrences(a["root"])["bolt"]
    assert client.delete(f"/document/parts/{a['root']}/occurrences/bolt").status_code == 204
    restore = {k: before[k] for k in ("id", "external_ref", "name_override", "transform", "suppressed", "hidden", "fixed", "color")}
    r = client.post(f"/document/parts/{a['root']}/occurrences", json={**restore, "resolved_part_id": "not-in-session", "ref_part_id": a["bolt"]})
    assert r.status_code in (200, 201), r.text
    assert r.json()["resolved_part_id"] is None and r.json()["ref_part_id"] == a["bolt"]


def test_add_component_records_the_placed_files_id():
    root = _box_part("Root")
    bracket = _box_part("Bracket")
    component = _single_file(bracket["id"])
    r = client.post(
        f"/document/parts/{root['id']}/add-component",
        json={"component": component, "external_ref": "parts/Bracket.didsa", "occurrence_id": "bracket"},
    )
    assert r.status_code in (200, 201), r.text
    assert _occurrences(root["id"])["bracket"]["ref_part_id"] == bracket["id"]
    assert _native_occurrences(_single_file(root["id"]))["bracket"]["ref_part_id"] == bracket["id"]
