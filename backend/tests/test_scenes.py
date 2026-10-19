"""Scenes, backend (`docs/scenes-scope.md` S1): the composition reference against its golden vectors, CRUD on
`/parts/{id}/scenes`, validation (paths incl. `#pattern:` copies, bodies and faces, transforms, appearances, the viewpoint), the
unresolved-path report, the delete cascade and the native round trip.

Needs a real pythonocc-core environment (the fixtures are real extrudes), like `test_appearance.py`."""

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.document.scene_compose import compose_scene
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_appearance import _body_ids, _box_part, _frame_assembly

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

VECTORS = json.loads((Path(__file__).resolve().parent / "data" / "scene_vectors.json").read_text())


# --- the composition and its vectors ------------------------------------------------------------------------------


def _close(a, b, tol: float) -> bool:
    if isinstance(a, dict):
        return isinstance(b, dict) and a.keys() == b.keys() and all(_close(a[k], b[k], tol) for k in a)
    if isinstance(a, list):
        return isinstance(b, list) and len(a) == len(b) and all(_close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return abs(float(a) - float(b)) <= tol
    return a == b


def test_reference_reproduces_the_golden_vectors():
    """`tests/data/scene_vectors.json` is the backend's copy of `docs/scenes/vectors.json` (tools/scene_vectors/generate.py
    --check keeps them in step)."""
    assert len(VECTORS["cases"]) >= 6
    for case in VECTORS["cases"]:
        got = compose_scene(VECTORS["nodes"], VECTORS["model"], VECTORS["root"], case["scene"])
        assert _close(got, case["expected"], 1e-9), case["name"]


def _case(name: str) -> dict:
    return next(c for c in VECTORS["cases"] if c["name"] == name)["expected"]


def test_vectors_say_what_the_scope_decided():
    """Hand-written spot checks of D2-D4 (not read back from the generator)."""
    # D4: moves compose down the tree - the frame (turned 90 deg) lifted 120 mm carries barA's own -60 mm move (in its frame).
    assert _close(_case("exploded")["frame/barA"]["world"]["origin"], [300.0, -60.0, 120.0], 1e-9)
    assert _close(_case("exploded")["frame/barB"]["world"]["origin"], [-500.0, 0.0, 120.0], 1e-9)
    # A pattern copy moves on its own; its siblings stay.
    assert _case("exploded")["bolt#pattern:p1:1"]["world"]["origin"] == [40.0, 0.0, 50.0]
    # Hiding a sub-assembly hides its contents; the nearest scene `hidden` wins; a scene shows a part the model hides.
    hidden = _case("hidden")
    assert hidden["frame/barA"]["hidden"] and not hidden["frame/barB"]["hidden"] and not hidden["leg"]["hidden"]
    assert _case("default")["leg"]["hidden"]
    # A scene's appearance beats the model's, field by field (the bars keep the part's own roughness).
    assert _case("looks")["frame/barA"]["appearance"] == {"colour": "#D63A2F", "opacity": 0.3, "roughness": 0.6}
    assert _case("looks")["frame/barB"]["bodies"]["a2"]["metallic"] == 1.0
    # The default is the model.
    assert _case("empty") == _case("default")


# --- CRUD and validation ------------------------------------------------------------------------------------------


def _transform(z: float = 120.0) -> dict:
    return {"translation": [0.0, 0.0, z], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _scenes(part_id: str) -> list[dict]:
    r = client.get(f"/document/parts/{part_id}/scenes")
    assert r.status_code == 200
    return r.json()


def test_create_list_update_delete():
    a = _frame_assembly()
    assert _scenes(a["root"]) == []
    body = a["bar_bodies"][0]
    r = client.post(
        f"/document/parts/{a['root']}/scenes",
        json={
            "name": "  Exploded ",
            "overrides": [
                {"path": "frame", "transform": _transform()},
                {"path": "frame/barA", "hidden": True},
                {"path": "frame/barB", "body_id": body, "appearance": {"colour": "#E8834A", "opacity": 0.3}},
                {"path": "frame/barB", "face": {"body_id": body, "shape_type": "face", "index": 2}, "appearance": {"emission": "#FFFFFF"}},
                {"path": "", "appearance": {"colour": "#D0D0D0"}},
            ],
            "section_planes": [{"origin": [0, 0, 0], "normal": [1, 0, 0], "flipped": False}],
            "viewpoint": {"eye": [2400, 1500, 2400], "target": [0, 400, -780]},
        },
    )
    assert r.status_code == 201, r.text
    scene = r.json()
    assert scene["name"] == "Exploded" and scene["id"] and scene["unresolved"] == []
    assert scene["overrides"][3]["body_id"] == body  # a face override carries its body
    assert scene["viewpoint"]["up"] == [0.0, 1.0, 0.0]
    assert [s["id"] for s in _scenes(a["root"])] == [scene["id"]]
    assert client.get(f"/document/parts/{a['root']}/scenes/{scene['id']}").json()["name"] == "Exploded"
    # Update scene: a given field replaces it whole, the rest stay; viewpoint null removes it.
    r = client.patch(f"/document/parts/{a['root']}/scenes/{scene['id']}", json={"overrides": [{"path": "bolt", "hidden": True}], "viewpoint": None})
    assert r.status_code == 200, r.text
    updated = r.json()
    assert [o["path"] for o in updated["overrides"]] == ["bolt"] and updated["viewpoint"] is None
    assert updated["name"] == "Exploded" and updated["section_planes"] == scene["section_planes"]
    assert client.patch(f"/document/parts/{a['root']}/scenes/{scene['id']}", json={"name": "Lifted"}).json()["overrides"] == updated["overrides"]
    # Save as new: a second scene with its own id.
    second = client.post(f"/document/parts/{a['root']}/scenes", json={"name": "Empty"}).json()
    assert second["id"] != scene["id"] and len(_scenes(a["root"])) == 2
    assert client.delete(f"/document/parts/{a['root']}/scenes/{scene['id']}").status_code == 204
    assert [s["name"] for s in _scenes(a["root"])] == ["Empty"]
    assert client.delete(f"/document/parts/{a['root']}/scenes/{scene['id']}").status_code == 404
    # A scene lives in its own assembly (D6): the frame's file has none of the root's scenes.
    assert _scenes(a["frame"]) == []
    # A scene never changes the model.
    rows = client.get(f"/document/parts/{a['root']}/occurrences").json()
    assert all(o["hidden"] is False for o in rows) and next(o for o in rows if o["id"] == "frame")["transform"]["translation"][2] == 0.0


def test_validation():
    a = _frame_assembly()
    body = a["bar_bodies"][0]
    pattern = client.post(
        f"/document/parts/{a['root']}/component-patterns",
        json={"source_occurrence_ids": ["bolt"], "pattern_type": "linear", "direction": [0.0, 1.0, 0.0], "count": 3, "spacing": 5.0},
    ).json()
    ok = client.post(
        f"/document/parts/{a['root']}/scenes",
        json={"name": "Copies", "overrides": [{"path": f"bolt#pattern:{pattern['id']}:2", "transform": _transform(40.0)}]},
    )
    assert ok.status_code == 201, ok.text  # a pattern copy can be moved on its own (D3)
    bad = [
        ({"name": " ", "overrides": []}, None),
        ({"name": "x", "overrides": [{"path": "nope", "hidden": True}]}, "occurrence_not_found"),
        ({"name": "x", "overrides": [{"path": "frame/nope", "hidden": True}]}, "occurrence_not_found"),
        ({"name": "x", "overrides": [{"path": f"bolt#pattern:{pattern['id']}:9", "hidden": True}]}, "pattern_copy_not_found"),
        ({"name": "x", "overrides": [{"path": "frame/barA", "body_id": "no-body", "appearance": {"colour": "#000000"}}]}, "body_not_found"),
        ({"name": "x", "overrides": [{"path": "frame"}]}, None),
        ({"name": "x", "overrides": [{"path": "frame/barA", "body_id": body, "hidden": True}]}, None),
        ({"name": "x", "overrides": [{"path": "frame/barA", "body_id": body, "transform": _transform()}]}, None),
        ({"name": "x", "overrides": [{"path": "", "transform": _transform()}]}, None),
        ({"name": "x", "overrides": [{"path": "frame", "hidden": True}, {"path": "frame", "transform": _transform()}]}, None),
        ({"name": "x", "overrides": [{"path": "frame", "appearance": {"opacity": 4}}]}, "invalid_appearance"),
        ({"name": "x", "overrides": [{"path": "frame", "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 0], "rotation_angle_degrees": 30}}]}, None),
        ({"name": "x", "overrides": [{"path": "frame/barA", "face": {"body_id": body, "shape_type": "face", "index": 99}, "appearance": {"colour": "#000000"}}]}, "missing_reference"),
        ({"name": "x", "viewpoint": {"eye": [1, 2, 3], "target": [1, 2, 3]}}, None),
    ]
    for payload, reason in bad:
        r = client.post(f"/document/parts/{a['root']}/scenes", json=payload)
        assert r.status_code == 422, (payload, r.text)
        if reason is not None:
            assert r.json()["detail"]["type"] == reason, (payload, r.text)
    assert [s["name"] for s in _scenes(a["root"])] == ["Copies"]


def test_unresolved_report_and_cascade():
    a = _frame_assembly()
    pattern = client.post(
        f"/document/parts/{a['root']}/component-patterns",
        json={"source_occurrence_ids": ["bolt"], "pattern_type": "linear", "direction": [0.0, 1.0, 0.0], "count": 3, "spacing": 5.0},
    ).json()
    copy_path = f"bolt#pattern:{pattern['id']}:2"
    scene = client.post(
        f"/document/parts/{a['root']}/scenes",
        json={"name": "S", "overrides": [
            {"path": copy_path, "hidden": True},
            {"path": "frame/barA", "transform": _transform()},
            {"path": "frame/barB", "hidden": True},
            {"path": "frame", "appearance": {"colour": "#2F6FD6"}},
        ]},
    ).json()
    # A pattern now shorter: the copy's override is kept, listed, ignored (D8).
    client.patch(f"/document/parts/{a['root']}/component-patterns/{pattern['id']}", json={"count": 2})
    listed = _scenes(a["root"])[0]
    assert listed["unresolved"] == [{"path": copy_path, "body_id": None, "reason": "pattern_copy_not_found"}]
    assert len(listed["overrides"]) == 4
    # Deleting barA in the frame's own file drops the root scene's override through it (any Part's scenes).
    assert client.delete(f"/document/parts/{a['frame']}/occurrences/barA").status_code == 204
    assert [o["path"] for o in _scenes(a["root"])[0]["overrides"]] == [copy_path, "frame/barB", "frame"]
    # Deleting the pattern drops its copies' overrides.
    assert client.delete(f"/document/parts/{a['root']}/component-patterns/{pattern['id']}").status_code == 204
    assert [o["path"] for o in _scenes(a["root"])[0]["overrides"]] == ["frame/barB", "frame"]
    # Deleting the frame drops the rest; the scene itself is kept until deleted.
    assert client.delete(f"/document/parts/{a['root']}/occurrences/frame").status_code == 204
    left = _scenes(a["root"])
    assert len(left) == 1 and left[0]["id"] == scene["id"] and left[0]["overrides"] == []


def test_own_part_scene_and_bodies():
    """A Part with no occurrences can have a scene too (its own bodies take an appearance; there is nothing to move)."""
    part = _box_part("Solo", two_bodies=True)
    body_a, _body_b = _body_ids(part["id"])
    r = client.post(f"/document/parts/{part['id']}/scenes", json={"name": "Look", "overrides": [{"path": "", "body_id": body_a, "appearance": {"metallic": 1.0}}],
                                                                  "viewpoint": {"eye": [0, 0, 100], "target": [0, 0, 0]}})
    assert r.status_code == 201, r.text
    assert r.json()["overrides"][0]["body_id"] == body_a


# --- native format ------------------------------------------------------------------------------------------------


def test_native_round_trip():
    a = _frame_assembly()
    body = a["bar_bodies"][0]
    client.post(
        f"/document/parts/{a['root']}/scenes",
        json={"name": "Exploded", "overrides": [
            {"path": "frame", "transform": _transform()},
            {"path": "frame/barB", "face": {"body_id": body, "shape_type": "face", "index": 1}, "appearance": {"colour": "#FFFFFF"}},
        ], "section_planes": [{"origin": [1, 2, 3], "normal": [0, 0, 1], "flipped": True}], "viewpoint": {"eye": [10, 0, 0], "target": [0, 0, 0], "up": [0, 0, 1]}},
    )
    exported = client.get("/document/export/native").json()
    root = next(p for p in exported["document"]["parts"] if p["id"] == a["root"])
    (scene,) = root["scenes"]
    assert scene["overrides"][0] == {"path": "frame", "transform": _transform()}
    assert scene["overrides"][1]["face"]["signature"]  # measured when it was set, so it can be re-found
    assert scene["viewpoint"] == {"eye": [10.0, 0.0, 0.0], "target": [0.0, 0.0, 0.0], "up": [0.0, 0.0, 1.0]}
    assert all("scenes" not in p for p in exported["document"]["parts"] if p["id"] != a["root"])
    raw = client.get("/document/export/native").content
    assert client.post("/document/import/native", json=json.loads(raw)).status_code == 200
    assert client.get("/document/export/native").content == raw


def test_native_output_is_unchanged_without_scenes():
    _frame_assembly()
    exported = client.get("/document/export/native").json()
    assert all("scenes" not in p for p in exported["document"]["parts"])
