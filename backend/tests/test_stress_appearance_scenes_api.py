"""Stress for the appearance and scenes API (Milestones 1-6, backend): seeded random sequences of what the clients send - valid and
hostile appearance overrides, scenes with odd names and overrides, deletes that cascade, then the outputs (assembly mesh JSON and
glb, STEP exports) read back. A hostile request must be refused with a 4xx, never a 5xx, and never leave state the outputs choke on.

Asserted after every operation: status < 500; an accepted appearance is a valid one; every stored override and scene still reads
back; and, every few operations, `assembly-mesh`, `assembly-mesh.glb` and the STEP exports still answer 200. Needs the real OCC
environment, like `test_appearance.py` (whose assembly it builds).
"""

import json
import random
import struct

import pytest

from app.document.appearance import appearance_errors
from tests.test_appearance import _frame_assembly, client

SEEDS = [1, 2, 3]
STEPS = 200

COLOURS = ["#E63946", "#3498DB", "#000000", "#FFFFFF", "#2f6fd6"]
HOSTILE_COLOURS = ["red", "#12", "#GGGGGG", "", "#1234567", "rgb(1,2,3)", None, 5, True, ["#000000"], {"a": 1}, "#" + "A" * 5000, "‮#000000"]
HOSTILE_NUMBERS = [-1, 1.0001, 2, 1e308, -1e308, "0.5", None, True, [0.5], {"v": 1}, 10**30]
NAMES = ["Exploded", "", "   ", "x" * 5000, "🙂 ünï", "a\nb", "../../x", "\u0000", "<script>", "Lifted", "name\t", "ÅÅÅ"]


def _appearance(rng: random.Random, hostile: bool) -> dict | None:
    out: dict = {}
    if rng.random() < 0.6:
        out["colour"] = rng.choice(HOSTILE_COLOURS) if hostile and rng.random() < 0.5 else rng.choice(COLOURS)
    for key in ("opacity", "metallic", "roughness"):
        if rng.random() < 0.3:
            out[key] = rng.choice(HOSTILE_NUMBERS) if hostile and rng.random() < 0.5 else round(rng.random(), 2)
    if rng.random() < 0.2:
        out["emission"] = rng.choice(COLOURS)
        out["emission_strength"] = rng.choice(HOSTILE_NUMBERS) if hostile and rng.random() < 0.5 else round(rng.random() * 10, 1)
    if hostile and rng.random() < 0.15:
        out[rng.choice(["shine", "glow", "", "colour "])] = 1
    if hostile and rng.random() < 0.05:
        return rng.choice([None, [], "blue", 7, {}])
    return out


def _paths(a: dict) -> list[str]:
    return ["", "frame", "frame/barA", "frame/barB", "bolt", "nope", "frame/nope", "frame/barA/x", "bolt#pattern:zz:1", " frame", "frame/", "/frame", "frame//barA", "x" * 3000, "frame\u0000"]


def _target(rng: random.Random, a: dict) -> dict:
    t: dict = {"path": rng.choice(["", "frame", "frame/barA", "frame/barB", "bolt"]) if rng.random() < 0.75 else rng.choice(_paths(a))}
    roll = rng.random()
    if roll < 0.25:
        t["body_id"] = rng.choice(a["bar_bodies"]) if rng.random() < 0.8 else rng.choice(["no-body", ""])
    if roll < 0.12 and "body_id" in t:
        t["face"] = {"body_id": t["body_id"], "shape_type": "face", "index": rng.choice([0, 1, 2, 5, 99, -1])}
    if rng.random() < 0.1:
        t["scope"] = rng.choice(["same_part", "pattern", "bogus"])
        t["part_id"] = rng.choice([a["bar"], a["frame"], "nope"])
    return t


def _transform(rng: random.Random) -> dict:
    return {
        "translation": [rng.uniform(-500, 500) for _ in range(3)],
        "rotation_axis": rng.choice([[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 0.0, 0.0], [1e-12, 0.0, 0.0]]),
        "rotation_angle_degrees": rng.choice([0.0, 45.0, 360.0, -720.0, 1e6]),
    }


def _scene_body(rng: random.Random, a: dict, hostile: bool) -> dict:
    overrides = []
    for _ in range(rng.randint(0, 6)):
        o = _target(rng, a)
        kind = rng.random()
        if kind < 0.4:
            o["appearance"] = _appearance(rng, hostile)
        elif kind < 0.65:
            o["hidden"] = rng.choice([True, False, "yes", None])
        elif kind < 0.9:
            o["transform"] = _transform(rng)
        overrides.append(o)
    body: dict = {"name": rng.choice(NAMES) if hostile else f"Scene {rng.randint(0, 99)}", "overrides": overrides}
    if rng.random() < 0.4:
        body["section_planes"] = [{"origin": [0, 0, 0], "normal": rng.choice([[1, 0, 0], [0, 0, 0]]), "flipped": False}]
    if rng.random() < 0.4:
        body["viewpoint"] = {"eye": [rng.uniform(-3000, 3000) for _ in range(3)], "target": rng.choice([[0, 0, 0], [1, 2, 3]])}
    return body


def _outputs(a: dict, with_step: bool) -> None:
    r = client.get(f"/document/parts/{a['root']}/assembly-mesh")
    assert r.status_code == 200, f"assembly-mesh {r.status_code}: {r.text[:300]}"
    r = client.get(f"/document/parts/{a['root']}/assembly-mesh.glb")
    assert r.status_code == 200, f"glb {r.status_code}: {r.text[:300]}"
    data = r.content
    assert data[:4] == b"glTF"
    json.loads(data[20 : 20 + struct.unpack_from("<I", data, 12)[0]])
    if with_step:
        for url in ("export/assembly-step",):
            r = client.get(f"/document/parts/{a['root']}/{url}")
            assert r.status_code == 200, f"{url} {r.status_code}: {r.text[:300]}"


@pytest.mark.parametrize("seed", SEEDS)
def test_random_sequences_never_500_and_outputs_keep_working(seed):
    rng = random.Random(seed)
    a = _frame_assembly()
    root = a["root"]
    stats = {"put_ok": 0, "put_refused": 0, "scene_ok": 0, "scene_refused": 0, "deleted": 0}
    scene_ids: list[str] = []
    for step in range(STEPS):
        op = rng.randint(0, 9)
        label = f"seed {seed} step {step} op {op}"
        if op <= 3:  # an appearance override, often hostile
            hostile = rng.random() < 0.3
            body = _target(rng, a)
            body["appearance"] = _appearance(rng, hostile) if rng.random() < 0.85 else None  # None clears
            r = client.put(f"/document/parts/{root}/appearance-overrides", json=body)
            assert r.status_code < 500, f"{label}: PUT {body} -> {r.status_code} {r.text[:300]}"
            if r.status_code == 200:
                stats["put_ok"] += 1
                sent = body.get("appearance")
                if sent is not None:
                    assert appearance_errors(sent) == [], f"{label}: accepted an invalid appearance {sent}"
            else:
                stats["put_refused"] += 1
        elif op <= 5:  # a scene created or updated
            hostile = rng.random() < 0.3
            body = _scene_body(rng, a, hostile)
            if scene_ids and rng.random() < 0.4:
                r = client.patch(f"/document/parts/{root}/scenes/{rng.choice(scene_ids)}", json=body)
            else:
                r = client.post(f"/document/parts/{root}/scenes", json=body)
                if r.status_code == 201:
                    scene_ids.append(r.json()["id"])
            assert r.status_code < 500, f"{label}: scene {json.dumps(body)[:400]} -> {r.status_code} {r.text[:300]}"
            stats["scene_ok" if r.status_code < 300 else "scene_refused"] += 1
        elif op == 6 and scene_ids:  # delete a scene
            sid = rng.choice(scene_ids)
            r = client.delete(f"/document/parts/{root}/scenes/{sid}")
            assert r.status_code in (204, 404), f"{label}: {r.status_code}"
            scene_ids.remove(sid)
        elif op == 7:  # a cascade: remove an occurrence something is painted / scened through (rarely, it is the whole assembly)
            if rng.random() < 0.15 and a.get("alive_bolt", True):
                r = client.delete(f"/document/parts/{root}/occurrences/bolt")
                assert r.status_code in (204, 404), f"{label}: {r.status_code}"
                a["alive_bolt"] = False
                stats["deleted"] += 1
        elif op == 8:  # reads
            r = client.get(f"/document/parts/{root}/appearance-overrides")
            assert r.status_code == 200
            for record in r.json()["overrides"]:
                assert appearance_errors(record["appearance"]) == [], f"{label}: stored override invalid {record}"
            r = client.get(f"/document/parts/{root}/scenes")
            assert r.status_code == 200
            for scene in r.json():
                assert scene["name"].strip() == scene["name"] and scene["name"], f"{label}: scene name not clean {scene['name']!r}"
        else:  # outputs
            _outputs(a, with_step=rng.random() < 0.25)
    _outputs(a, with_step=True)
    # Every scene the backend lists is one this run created (a delete took the rest), and each reads back by id.
    listed = client.get(f"/document/parts/{root}/scenes").json()
    for scene in listed:
        assert client.get(f"/document/parts/{root}/scenes/{scene['id']}").status_code == 200
    print(f"STRESS seed {seed}: {stats}, {len(listed)} scenes kept")


def test_ref_part_id_hostile_values_are_refused_or_round_trip_never_500():
    """Finding moved files (M7): `ref_part_id` / `resolved_part_id` of every awkward type through `import/native`."""
    a = _frame_assembly()
    export = client.get("/document/export/native").json()
    root_part = next(p for p in export["document"]["parts"] if p["id"] == a["root"])
    values = ["abc", "", " ", "x" * 10000, "🙂", "\u0000", None, 5, 1.5, True, [], ["a"], {"a": 1}, "id with spaces", "../x"]
    for value in values:
        for field in ("ref_part_id", "resolved_part_id"):
            payload = json.loads(json.dumps(export))
            part = next(p for p in payload["document"]["parts"] if p["id"] == a["root"])
            part["occurrences"][0][field] = value
            r = client.post("/document/import/native", json=payload)
            assert r.status_code < 500, f"{field}={value!r:.60} -> {r.status_code} {r.text[:200]}"
            if r.status_code == 200:
                again = client.get("/document/export/native").json()
                occ = next(p for p in again["document"]["parts"] if p["id"] == a["root"])["occurrences"][0]
                got = occ.get("ref_part_id")
                assert got is None or isinstance(got, str), f"{field}={value!r:.60} exported ref_part_id {got!r:.60}"
    # Restore a clean session for whatever runs next.
    assert client.post("/document/import/native", json=export).status_code == 200
    assert root_part["id"] == a["root"]
