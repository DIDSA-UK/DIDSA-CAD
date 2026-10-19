"""The Appearance tool, backend (`docs/appearance-tool-scope.md` V1): the resolution rule against its golden vectors, the
record's checks, `PUT`/`GET /parts/{id}/appearance-overrides`, a Part's own appearance (`PATCH /parts/{id}`), the
`Occurrence.color` alias, the delete cascade, the native round trip, and the materials of `assembly-mesh.glb`.

Needs a real pythonocc-core environment (boxes are real extrudes), like `test_assembly_mesh_glb.py`."""

import copy
import json
import struct
from pathlib import Path

from fastapi.testclient import TestClient

from app.document.appearance import appearance_errors, resolve_appearance, resolve_faces
from app.document.mesh_export import material_for_appearance
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

VECTORS = json.loads((Path(__file__).resolve().parent / "data" / "appearance_vectors.json").read_text())


# --- the rule and its vectors -------------------------------------------------------------------------------------


def test_reference_reproduces_the_golden_vectors():
    """`tests/data/appearance_vectors.json` is the backend's copy of `docs/appearance/vectors.json`
    (tools/appearance_vectors/generate.py --check keeps them in step): the resolver must still answer every case."""
    assert len(VECTORS["cases"]) >= 50
    for case in VECTORS["cases"]:
        model = VECTORS["models"][case["model"]]
        got = resolve_appearance(model, case["root"], case["path"], case["body_id"], case["face_index"], case["scene_overrides"])
        assert got == case["expected"], case["name"]


def test_resolve_faces_agrees_with_resolve_appearance_face_by_face():
    """The glb paints from `resolve_faces` (one pass per instance); it must give `resolve_appearance`'s answers."""
    faces = [(body, index) for body in ("a1", "a2", "b1", "fb", "rb", "rb2", "l1", "p1", "g1") for index in range(9)]
    for case in VECTORS["cases"]:
        model = VECTORS["models"][case["model"]]
        by_face = resolve_faces(model, case["root"], case["path"], faces, case["scene_overrides"])
        for body_id, face_index in faces:
            expected = resolve_appearance(model, case["root"], case["path"], body_id, face_index, case["scene_overrides"])
            assert by_face[(body_id, face_index)] == expected, (case["name"], body_id, face_index)


def _vector(name: str) -> dict:
    return next(c for c in VECTORS["cases"] if c["name"] == name)["expected"]


def test_vectors_say_what_the_owner_decided():
    """Spot checks written by hand (not read back from the generator): the decisions in the scope's D1 / D3."""
    # Higher levels beat lower: the root's Whole assembly beats a Part's own face colour.
    assert _vector("whole_beats_part_files")["colour"] == "#D0D0D0"
    # Within one level the most specific wins: "every Frame A blue" then "this Frame A red".
    assert _vector("every_placement_this_one")["colour"] == "#D63A2F"
    assert _vector("every_placement_the_rest")["colour"] == "#2F6FD6"
    # A bolt with its own colour keeps it inside a painted sub-assembly.
    assert _vector("part_in_painted_subassembly")["colour"] == "#D63A2F"
    # Face > body > part, field by field.
    assert _vector("face_override") == {"colour": "#FFFFFF", "emission": "#FFFFFF", "emission_strength": 2.0, "metallic": 1.0, "roughness": 0.2}
    # One pattern copy beats the pattern; Pattern (all N) reaches copies.
    assert _vector("pattern_copy_named") == {"colour": "#202020", "opacity": 0.3}
    # A shown scene beats everything.
    assert _vector("scene_beats_all")["colour"] == "#D63A2F" and _vector("scene_beats_all")["opacity"] == 0.3


def test_appearance_errors():
    assert appearance_errors({"colour": "#A1B2C3", "opacity": 0.5, "metallic": 1, "roughness": 0.0, "emission": "#000000", "emission_strength": 10}) == []
    assert appearance_errors({}) == ["an appearance must set at least one field"]
    assert appearance_errors({"colour": "red"}) == ["colour must be '#RRGGBB'"]
    assert appearance_errors({"opacity": 1.5}) == ["opacity must be a number from 0 to 1"]
    assert appearance_errors({"emission_strength": 11}) == ["emission_strength must be a number from 0 to 10"]
    assert appearance_errors({"metallic": True}) == ["metallic must be a number from 0 to 1"]
    assert appearance_errors({"shine": 0.2, "colour": "#000000"}) == ["unknown appearance field 'shine'"]
    assert appearance_errors("blue") == ["appearance must be an object"]


def test_material_for_appearance():
    plain = material_for_appearance({"colour": "#FF0000"})
    assert plain["pbrMetallicRoughness"] == {"baseColorFactor": [1.0, 0.0, 0.0, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.8}
    assert "alphaMode" not in plain and "emissiveFactor" not in plain
    assert plain["extras"] == {"appearance": {"colour": "#FF0000"}}
    glass = material_for_appearance({"opacity": 0.25, "metallic": 1.0, "roughness": 0.1})
    assert glass["alphaMode"] == "BLEND"
    assert glass["pbrMetallicRoughness"]["baseColorFactor"][3] == 0.25
    glow = material_for_appearance({"colour": "#00FF00", "emission_strength": 4.0})
    assert glow["emissiveFactor"] == [0.0, 1.0, 0.0]  # no emission colour: glows in its base colour
    assert glow["extensions"] == {"KHR_materials_emissive_strength": {"emissiveStrength": 4.0}}
    assert "emissiveFactor" not in material_for_appearance({"emission": "#FFFFFF", "emission_strength": 0.0})
    assert "extensions" not in material_for_appearance({"emission": "#FFFFFF"})


# --- fixtures -----------------------------------------------------------------------------------------------------


def _create_part(name: str) -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _square(part_id: str, x0: float, size: float) -> str:
    sketch_response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    points = []
    for x, y in [(x0, 0), (x0 + size, 0), (x0 + size, size), (x0, size)]:
        r = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
        assert r.status_code == 201
        points.append(r.json()["id"])
    for a, b in zip(points, points[1:] + points[:1]):
        assert client.post(f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a, "end_point_id": b}).status_code == 201
    return sketch_response.json()["id"]


def _boss(part_id: str, sketch_feature_id: str) -> None:
    r = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={"sketch_feature_id": sketch_feature_id, "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
    )
    assert r.status_code == 201, r.text


def _box_part(name: str, *, size: float = 10.0, two_bodies: bool = False) -> dict:
    part = _create_part(name)
    _boss(part["id"], _square(part["id"], 0.0, size))
    if two_bodies:
        _boss(part["id"], _square(part["id"], 3 * size, size))
    return part


def _body_ids(part_id: str) -> list[str]:
    r = client.get(f"/document/parts/{part_id}/mesh")
    assert r.status_code == 200
    return [b["body_id"] for b in r.json()]


def _export_part_dict(part_id: str) -> tuple[dict, list]:
    data = client.get("/document/export/native", params={"part_id": part_id}).json()
    return data["document"]["parts"][0], data["sketches"]


def _occ(occurrence_id: str, child_id: str, x: float = 0.0, color: str | None = None) -> dict:
    return {
        "id": occurrence_id,
        "external_ref": f"parts/{child_id}.didsa",
        "resolved_part_id": child_id,
        "name_override": None,
        "transform": {"translation": [x, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
        "suppressed": False,
        "hidden": False,
        "color": color,
    }


def _compose(root_id: str, placements: dict[str, list[dict]], part_ids: list[str]) -> None:
    """One composed session: every Part in `part_ids` (root first), each Part's occurrences from `placements`."""
    parts, sketches = [], []
    for part_id in part_ids:
        part_dict, part_sketches = _export_part_dict(part_id)
        if part_id in placements:
            part_dict["occurrences"] = placements[part_id]
            part_dict["mates"] = []
        parts.append(part_dict)
        sketches += part_sketches
    payload = {"schema_version": 1, "document": {"id": "composed", "root_part_id": root_id, "parts": parts}, "sketches": sketches}
    payload["schema_version"] = client.get("/document/export/native", params={"part_id": root_id}).json()["schema_version"]
    r = client.post("/document/import/native", json=payload)
    assert r.status_code == 200, r.text


def _frame_assembly() -> dict:
    """Root (own box) places frame (a sub-assembly with its own box) twice-placing bar (two bodies), plus a bolt."""
    bar = _box_part("Bar", size=4.0, two_bodies=True)
    frame = _box_part("Frame", size=6.0)
    bolt = _box_part("Bolt", size=2.0)
    root = _box_part("Root", size=20.0)
    _compose(
        root["id"],
        {
            root["id"]: [_occ("frame", frame["id"], 30.0), _occ("bolt", bolt["id"], -10.0)],
            frame["id"]: [_occ("barA", bar["id"], 0.0), _occ("barB", bar["id"], 50.0)],
        },
        [root["id"], frame["id"], bar["id"], bolt["id"]],
    )
    return {"root": root["id"], "frame": frame["id"], "bar": bar["id"], "bolt": bolt["id"], "bar_bodies": _body_ids(bar["id"])}


def _put(root_id: str, body: dict):
    return client.put(f"/document/parts/{root_id}/appearance-overrides", json=body)


def _overrides(root_id: str) -> list[dict]:
    r = client.get(f"/document/parts/{root_id}/appearance-overrides")
    assert r.status_code == 200
    return r.json()["overrides"]


def _glb(part_id: str) -> dict:
    data = client.get(f"/document/parts/{part_id}/assembly-mesh.glb").content
    json_len = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20 : 20 + json_len])


def _node(gltf: dict, instance_path: str) -> dict:
    return next(n for n in gltf["nodes"] if n["extras"]["instance_path"] == instance_path)


def _materials_of(gltf: dict, node: dict) -> list[dict | None]:
    return [gltf["materials"][p["material"]] if "material" in p else None for p in gltf["meshes"][node["mesh"]]["primitives"]]


# --- overrides ----------------------------------------------------------------------------------------------------


def test_put_and_get_overrides_and_their_targets():
    a = _frame_assembly()
    assert _overrides(a["root"]) == []
    r = _put(a["root"], {"path": "frame", "appearance": {"colour": "#2F6FD6"}})
    assert r.status_code == 200, r.text
    _put(a["root"], {"path": "frame/barA", "body_id": a["bar_bodies"][1], "appearance": {"metallic": 1.0}})
    _put(a["root"], {"path": "frame/barA", "body_id": a["bar_bodies"][0], "face": {"body_id": a["bar_bodies"][0], "shape_type": "face", "index": 2}, "appearance": {"emission": "#FFFFFF"}})
    _put(a["root"], {"path": "", "scope": "same_part", "part_id": a["bar"], "appearance": {"roughness": 0.3}})
    _put(a["root"], {"path": "", "appearance": {"colour": "#D0D0D0"}})
    listed = _overrides(a["root"])
    assert [(o["path"], o["scope"], o["body_id"], o["face"] is not None) for o in listed] == [
        ("frame", None, None, False),
        ("frame/barA", None, a["bar_bodies"][1], False),
        ("frame/barA", None, a["bar_bodies"][0], True),
        ("", "same_part", None, False),
        ("", None, None, False),
    ]
    assert all(o["unresolved"] is None for o in listed)
    assert listed[2]["face_current_index"] == 2
    # Same target again replaces it (one record per target); null clears it.
    _put(a["root"], {"path": "frame", "appearance": {"colour": "#D63A2F"}})
    assert _overrides(a["root"])[0]["appearance"] == {"colour": "#D63A2F"}
    _put(a["root"], {"path": "frame", "appearance": None})
    assert [o["path"] for o in _overrides(a["root"])] == ["frame/barA", "frame/barA", "", ""]


def test_put_validation():
    a = _frame_assembly()
    cases = [
        ({"path": "nope", "appearance": {"colour": "#000000"}}, "occurrence_not_found"),
        ({"path": "frame/nope", "appearance": {"colour": "#000000"}}, "occurrence_not_found"),
        ({"path": "bolt#pattern:p:1", "appearance": {"colour": "#000000"}}, "pattern_copy_not_found"),
        ({"path": "frame", "body_id": "no-such-body", "appearance": {"colour": "#000000"}}, "body_not_found"),
        ({"path": "", "scope": "same_part", "part_id": "nope", "appearance": {"colour": "#000000"}}, "part_not_resolved"),
        ({"path": "", "scope": "same_part", "part_id": a["root"], "appearance": {"colour": "#000000"}}, "part_not_placed"),
        ({"path": "bolt", "scope": "pattern", "pattern_id": "nope", "appearance": {"colour": "#000000"}}, "pattern_not_found"),
    ]
    for body, reason in cases:
        r = _put(a["root"], body)
        assert r.status_code == 422 and r.json()["detail"]["type"] == reason, (body, r.text)
    for body in [
        {"path": "frame", "appearance": {"colour": "blue"}},
        {"path": "frame", "appearance": {"opacity": 2}},
        {"path": "frame", "appearance": {}},
        {"path": "frame", "scope": "sideways", "appearance": {"colour": "#000000"}},
        {"path": "frame", "scope": "same_part", "part_id": a["bar"], "appearance": {"colour": "#000000"}},
        {"path": "bolt", "scope": "pattern", "appearance": {"colour": "#000000"}},
        {"path": "frame", "part_id": a["bar"], "appearance": {"colour": "#000000"}},
        {"path": "frame/barA", "body_id": a["bar_bodies"][0], "face": {"body_id": a["bar_bodies"][0], "shape_type": "edge", "index": 0}, "appearance": {"colour": "#000000"}},
        {"path": "frame/barA", "body_id": a["bar_bodies"][0], "face": {"body_id": a["bar_bodies"][1], "shape_type": "face", "index": 0}, "appearance": {"colour": "#000000"}},
        {"path": "frame/barA", "face": {"body_id": a["bar_bodies"][0], "shape_type": "face", "index": 99}, "appearance": {"colour": "#000000"}},
    ]:
        assert _put(a["root"], body).status_code == 422, body
    assert _overrides(a["root"]) == []


def test_pattern_copies_and_pattern_scope():
    a = _frame_assembly()
    pattern = client.post(
        f"/document/parts/{a['root']}/component-patterns",
        json={"source_occurrence_ids": ["bolt"], "pattern_type": "linear", "direction": [0.0, 1.0, 0.0], "count": 3, "spacing": 5.0},
    ).json()
    copy_path = f"bolt#pattern:{pattern['id']}:2"
    assert _put(a["root"], {"path": copy_path, "appearance": {"opacity": 0.3}}).status_code == 200
    assert _put(a["root"], {"path": f"bolt#pattern:{pattern['id']}:9", "appearance": {"opacity": 0.3}}).status_code == 422
    assert _put(a["root"], {"path": "bolt", "scope": "pattern", "pattern_id": pattern["id"], "appearance": {"colour": "#202020"}}).status_code == 200
    gltf = _glb(a["root"])
    (copy2,) = _materials_of(gltf, _node(gltf, copy_path))
    (copy1,) = _materials_of(gltf, _node(gltf, f"bolt#pattern:{pattern['id']}:1"))
    (source,) = _materials_of(gltf, _node(gltf, "bolt"))
    assert copy2["extras"]["appearance"] == {"colour": "#202020", "opacity": 0.3}
    assert copy2["alphaMode"] == "BLEND"
    assert copy1["extras"]["appearance"] == source["extras"]["appearance"] == {"colour": "#202020"}
    # A pattern copy has no Occurrence of its own; its instance_path tells it apart.
    assert _node(gltf, copy_path)["extras"]["occurrence_id"] == ""
    # The count dropping leaves a copy override unresolved (kept, reported, ignored).
    client.patch(f"/document/parts/{a['root']}/component-patterns/{pattern['id']}", json={"count": 2})
    copy_override = next(o for o in _overrides(a["root"]) if o["path"] == copy_path)
    assert copy_override["unresolved"] == "pattern_copy_not_found"
    # Deleting the pattern takes its copies' overrides and its pattern-scope override with it.
    assert client.delete(f"/document/parts/{a['root']}/component-patterns/{pattern['id']}").status_code == 204
    assert _overrides(a["root"]) == []


def test_delete_occurrence_cascades_through_every_path():
    a = _frame_assembly()
    _put(a["root"], {"path": "frame/barA", "appearance": {"colour": "#D63A2F"}})
    _put(a["root"], {"path": "frame/barB", "appearance": {"colour": "#2F6FD6"}})
    _put(a["root"], {"path": "", "scope": "same_part", "part_id": a["bar"], "appearance": {"metallic": 1.0}})
    _put(a["frame"], {"path": "barA", "appearance": {"colour": "#2FD65A"}})
    # barA lives in the frame's file: deleting it there drops the frame's override AND the root's path through it.
    assert client.delete(f"/document/parts/{a['frame']}/occurrences/barA").status_code == 204
    assert [(o["path"], o["scope"]) for o in _overrides(a["root"])] == [("frame/barB", None), ("", "same_part")]
    assert _overrides(a["frame"]) == []
    assert client.delete(f"/document/parts/{a['root']}/occurrences/frame").status_code == 204
    assert [(o["path"], o["scope"]) for o in _overrides(a["root"])] == [("", "same_part")]
    assert _overrides(a["root"])[0]["unresolved"] == "part_not_placed"


def test_occurrence_color_is_the_legacy_alias():
    a = _frame_assembly()
    # An old client's colour reads as an override.
    client.patch(f"/document/parts/{a['root']}/occurrences/bolt", json={"color": "#ff0000"})
    assert _overrides(a["root"]) == [
        {"path": "bolt", "scope": None, "pattern_id": None, "part_id": None, "body_id": None, "face": None,
         "appearance": {"colour": "#ff0000"}, "legacy": True, "unresolved": None, "face_current_index": None}
    ]
    # A new override on that occurrence keeps the legacy colour under it until it sets its own...
    _put(a["root"], {"path": "bolt", "appearance": {"opacity": 0.5}})
    occurrence = client.get(f"/document/parts/{a['root']}/occurrences").json()
    assert next(o for o in occurrence if o["id"] == "bolt")["color"] == "#ff0000"
    gltf = _glb(a["root"])
    assert _materials_of(gltf, _node(gltf, "bolt"))[0]["extras"]["appearance"] == {"colour": "#ff0000", "opacity": 0.5}
    # ... and mirrors its own base colour into `color` for older clients.
    _put(a["root"], {"path": "bolt", "appearance": {"colour": "#00FF00", "opacity": 0.5}})
    assert next(o for o in client.get(f"/document/parts/{a['root']}/occurrences").json() if o["id"] == "bolt")["color"] == "#00FF00"
    # An old client changing `color` keeps the override's colour in step; clearing it clears that field only.
    client.patch(f"/document/parts/{a['root']}/occurrences/bolt", json={"color": "#0000ff"})
    assert _overrides(a["root"])[0]["appearance"] == {"colour": "#0000ff", "opacity": 0.5}
    client.patch(f"/document/parts/{a['root']}/occurrences/bolt", json={"color": ""})
    assert _overrides(a["root"])[0]["appearance"] == {"opacity": 0.5}
    # Clearing the override (Clear swatch) clears the legacy colour too.
    client.patch(f"/document/parts/{a['root']}/occurrences/bolt", json={"color": "#123456"})
    _put(a["root"], {"path": "bolt", "appearance": None})
    assert _overrides(a["root"]) == []
    assert next(o for o in client.get(f"/document/parts/{a['root']}/occurrences").json() if o["id"] == "bolt")["color"] is None


# --- a Part's own appearance --------------------------------------------------------------------------------------


def test_part_own_appearance():
    part = _box_part("Two bodies", two_bodies=True)
    body_a, body_b = _body_ids(part["id"])
    r = client.patch(
        f"/document/parts/{part['id']}",
        json={
            "appearance": {"roughness": 0.6},
            "body_appearances": {body_b: {"colour": "#8B5A2B"}},
            "face_appearances": [{"face": {"body_id": body_a, "shape_type": "face", "index": 1}, "appearance": {"colour": "#202020"}}],
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["appearance"] == {"roughness": 0.6}
    assert body["body_appearances"] == {body_b: {"colour": "#8B5A2B"}}
    assert body["face_appearances"][0]["current_index"] == 1 and body["face_appearances"][0]["unresolved"] is None
    # Omitted fields are unchanged; an explicit null clears the part appearance.
    r = client.patch(f"/document/parts/{part['id']}", json={"description": "x"})
    assert r.json()["appearance"] == {"roughness": 0.6}
    r = client.patch(f"/document/parts/{part['id']}", json={"appearance": None})
    assert r.json()["appearance"] is None and r.json()["body_appearances"] == {body_b: {"colour": "#8B5A2B"}}
    for bad in [
        {"appearance": {"opacity": -1}},
        {"body_appearances": {"no-such-body": {"colour": "#000000"}}},
        {"face_appearances": [{"face": {"body_id": body_a, "shape_type": "face", "index": 999}, "appearance": {"colour": "#000000"}}]},
    ]:
        assert client.patch(f"/document/parts/{part['id']}", json=bad).status_code == 422, bad

    # The glb splits the part's mesh by appearance: one primitive per look, each with its own triangles' face ids.
    gltf = _glb(part["id"])
    (node,) = gltf["nodes"]
    primitives = gltf["meshes"][node["mesh"]]["primitives"]
    assert len(primitives) == 3
    assert all("indices" in p for p in primitives)
    looks = {tuple(sorted(gltf["materials"][p["material"]]["extras"]["appearance"].items())) if "material" in p else () for p in primitives}
    assert looks == {(), (("colour", "#8B5A2B"),), (("colour", "#202020"),)}
    face_primitive = next(p for p in primitives if "material" in p and gltf["materials"][p["material"]]["extras"]["appearance"] == {"colour": "#202020"})
    assert set(zip(face_primitive["extras"]["body_ids"], face_primitive["extras"]["face_ids"])) == {(body_a, 1)}
    # Every triangle once across the primitives; the topology rides on the first.
    assert sum(len(p["extras"]["face_ids"]) for p in primitives) == sum(gltf["accessors"][p["indices"]]["count"] for p in primitives) // 3
    assert sum(gltf["accessors"][p["indices"]]["count"] for p in primitives) == gltf["accessors"][primitives[0]["attributes"]["POSITION"]]["count"]
    assert "topology" in primitives[0]["extras"] and all("topology" not in p["extras"] for p in primitives[1:])


def test_glb_resolves_levels_and_whole_assembly():
    a = _frame_assembly()
    _put(a["root"], {"path": "", "appearance": {"colour": "#D0D0D0"}})
    _put(a["root"], {"path": "frame", "appearance": {"colour": "#2F6FD6"}})
    _put(a["root"], {"path": "frame/barA", "body_id": a["bar_bodies"][0], "appearance": {"colour": "#D63A2F", "emission_strength": 2.0}})
    gltf = _glb(a["root"])
    (root_own,) = _materials_of(gltf, _node(gltf, ""))
    assert root_own["extras"]["appearance"] == {"colour": "#D0D0D0"}
    assert _materials_of(gltf, _node(gltf, "frame"))[0]["extras"]["appearance"] == {"colour": "#2F6FD6"}
    (bar_b,) = _materials_of(gltf, _node(gltf, "frame/barB"))
    assert bar_b["extras"]["appearance"] == {"colour": "#2F6FD6"}
    bar_a = _materials_of(gltf, _node(gltf, "frame/barA"))
    assert sorted(m["extras"]["appearance"].get("colour") for m in bar_a) == ["#2F6FD6", "#D63A2F"]
    glowing = next(m for m in bar_a if m["extras"]["appearance"]["colour"] == "#D63A2F")
    assert glowing["extensions"] == {"KHR_materials_emissive_strength": {"emissiveStrength": 2.0}}
    assert gltf["extensionsUsed"] == ["KHR_materials_emissive_strength"]


def test_glb_without_any_appearance_has_no_materials():
    a = _frame_assembly()
    gltf = _glb(a["root"])
    assert "materials" not in gltf
    assert all(len(m["primitives"]) == 1 and "indices" not in m["primitives"][0] for m in gltf["meshes"])
    assert {n["extras"]["instance_path"] for n in gltf["nodes"]} == {"", "frame", "frame/barA", "frame/barB", "bolt"}


# --- native format ------------------------------------------------------------------------------------------------


def test_native_round_trip():
    a = _frame_assembly()
    body = a["bar_bodies"][0]
    _put(a["root"], {"path": "frame/barA", "body_id": body, "face": {"body_id": body, "shape_type": "face", "index": 3}, "appearance": {"colour": "#FFFFFF"}})
    _put(a["root"], {"path": "", "scope": "same_part", "part_id": a["bar"], "appearance": {"metallic": 1.0}})
    client.patch(f"/document/parts/{a['bar']}", json={"appearance": {"roughness": 0.4}, "body_appearances": {body: {"opacity": 0.5}}})
    exported = client.get("/document/export/native").json()
    root_dict = next(p for p in exported["document"]["parts"] if p["id"] == a["root"])
    assert root_dict["appearance_overrides"][0]["face"]["signature"]  # measured when it was set, so it can be re-found
    assert root_dict["appearance_overrides"][1] == {"path": "", "scope": "same_part", "part_id": a["bar"], "appearance": {"metallic": 1.0}}
    assert client.post("/document/import/native", json=copy.deepcopy(exported)).status_code == 200
    assert client.get("/document/export/native").json() == exported


def test_native_output_is_unchanged_without_appearance():
    """A file with none of the new fields exports exactly as before (no new keys)."""
    a = _frame_assembly()
    exported = client.get("/document/export/native").json()
    for part in exported["document"]["parts"]:
        assert not {"appearance", "body_appearances", "face_appearances", "appearance_overrides"} & set(part)
    raw = client.get("/document/export/native").content
    assert client.post("/document/import/native", json=json.loads(raw)).status_code == 200
    assert client.get("/document/export/native").content == raw
    assert len(exported["document"]["parts"]) == 4 and a["root"]


def test_native_import_rejects_a_bad_appearance():
    a = _frame_assembly()
    exported = client.get("/document/export/native").json()
    exported["document"]["parts"][0]["appearance_overrides"] = [{"path": "frame", "appearance": {"opacity": 7}}]
    r = client.post("/document/import/native", json=exported)
    assert r.status_code == 422 and "opacity" in r.json()["detail"]
    exported["document"]["parts"][0]["appearance_overrides"] = [{"path": "frame", "scope": "nope", "appearance": {"opacity": 0.5}}]
    assert client.post("/document/import/native", json=exported).status_code == 422
    assert client.get("/document/export/native").json()["document"]["root_part_id"] == a["root"]  # the session was not replaced
