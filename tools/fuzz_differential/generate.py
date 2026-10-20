"""Seeded random cases for a differential test: the Python reference answers, the clients must agree.

    cd backend && PYTHONPATH=. python ../tools/fuzz_differential/generate.py OUT.json [seed] [count]

Covers the appearance resolution rule (`app/document/appearance.py`, including `resolve_faces` against `resolve_appearance`) and the
moved-file lookup rule (`app/document/file_lookup.py`). The golden vectors in `docs/` are hand-written edge cases; these are many
random ones, so a disagreement a hand-written case missed shows up. Not committed as data: regenerate with a new seed any time.
Dart reads it in `client/test/stress/differential_test.dart` (set DIDSA_FUZZ_CASES=OUT.json); DIDSA-VR's GDScript copies can be
checked the same way.
"""
import json
import random
import sys

from app.document.appearance import resolve_appearance, resolve_faces
from app.document.file_lookup import find_file

HEX = ["#E63946", "#3498DB", "#FFFFFF", "#000000", "#2F6FD6", "#D63A2F", "#8B5A2B"]


def rand_appearance(rng):
    out = {}
    if rng.random() < 0.6:
        out["colour"] = rng.choice(HEX)
    if rng.random() < 0.3:
        out["opacity"] = round(rng.random(), 2)
    if rng.random() < 0.25:
        out["metallic"] = round(rng.random(), 2)
    if rng.random() < 0.25:
        out["roughness"] = round(rng.random(), 2)
    if rng.random() < 0.15:
        out["emission"] = rng.choice(HEX)
        out["emission_strength"] = round(rng.random() * 10, 1)
    return out or {"colour": rng.choice(HEX)}


def rand_model(rng):
    ids = [f"P{i}" for i in range(rng.randint(2, 7))]
    occ_ids = ["a", "b", "c", "d"]
    parts = {}
    for index, pid in enumerate(ids):
        part = {}
        occs = {}
        for oid in rng.sample(occ_ids, rng.randint(0, 3)):
            # mostly children later in the list (acyclic), sometimes anything (a cycle or a self-reference)
            pool = ids[index + 1 :] if rng.random() < 0.85 and ids[index + 1 :] else ids + ["ghost"]
            occs[oid] = {"part_id": rng.choice(pool)}
            if rng.random() < 0.15:
                occs[oid]["color"] = rng.choice(HEX)
        if occs:
            part["occurrences"] = occs
        if rng.random() < 0.4:
            part["appearance"] = rand_appearance(rng)
        if rng.random() < 0.3:
            part["body_appearances"] = {rng.choice(["b1", "b2"]): rand_appearance(rng)}
        if rng.random() < 0.3:
            body = rng.choice(["b1", "b2"])
            part["face_appearances"] = [{"face": {"body_id": body, "index": rng.randint(0, 3)}, "appearance": rand_appearance(rng)}]
        parts[pid] = part
    model = {"parts": parts}
    for pid, part in parts.items():
        overrides = []
        for _ in range(rng.randint(0, 4)):
            record = rand_override(rng, occ_ids, ids)
            if rng.random() < 0.7:
                record["path"] = "/".join(walk_path(rng, {"parts": parts}) if pid == "P0" else [])
            overrides.append(record)
        if overrides:
            part["appearance_overrides"] = overrides
    return model


def rand_path(rng, occ_ids, depth=None):
    n = rng.randint(0, 3) if depth is None else depth
    segs = []
    for _ in range(n):
        seg = rng.choice(occ_ids)
        if rng.random() < 0.15:
            seg += f"#pattern:p{rng.randint(1, 2)}:{rng.randint(1, 3)}"
        segs.append(seg)
    return segs


def rand_override(rng, occ_ids, ids):
    record = {"path": "/".join(rand_path(rng, occ_ids)), "appearance": rand_appearance(rng)}
    roll = rng.random()
    if roll < 0.2:
        record.update(scope="same_part", part_id=rng.choice(ids))
    elif roll < 0.35:
        record.update(scope="pattern", pattern_id=f"p{rng.randint(1, 2)}")
    if rng.random() < 0.3:
        record["body_id"] = rng.choice(["b1", "b2"])
        if rng.random() < 0.5:
            record["face"] = {"body_id": record["body_id"], "index": rng.randint(0, 3)}
    return record


def walk_path(rng, model):
    """A path that exists in the model (so the rule has something to resolve), sometimes one segment too far."""
    part, path = "P0", []
    while rng.random() < 0.8:
        occs = (model["parts"].get(part) or {}).get("occurrences") or {}
        if not occs or len(path) > 5:
            break
        oid = rng.choice(sorted(occs))
        path.append(oid + (f"#pattern:p{rng.randint(1, 2)}:{rng.randint(1, 3)}" if rng.random() < 0.1 else ""))
        part = occs[oid]["part_id"]
    return path


def appearance_cases(rng, count):
    cases = []
    for _ in range(count):
        model = rand_model(rng)
        occ_ids = ["a", "b", "c", "d"]
        path = walk_path(rng, model) if rng.random() < 0.75 else rand_path(rng, occ_ids)
        body = rng.choice([None, "b1", "b2"])
        face = rng.randint(0, 3) if body else None
        scene = [rand_override(rng, occ_ids, list(model["parts"])) for _ in range(rng.randint(1, 3))] if rng.random() < 0.3 else None
        faces = [("b1", i) for i in range(4)] + [("b2", i) for i in range(2)]
        by_face = resolve_faces(model, "P0", path, faces, scene)
        cases.append(
            {
                "model": model, "root": "P0", "path": path, "body_id": body, "face_index": face, "scene_overrides": scene,
                "expected": resolve_appearance(model, "P0", path, body, face, scene),
                "faces": {f"{b}|{i}": by_face[(b, i)] for b, i in faces},
            }
        )
    return cases


def lookup_cases(rng, count):
    names = ["Frame", "Bolt", "Leg", "Plate"]
    folders = ["", "parts/", "parts/frames/", "old/", "x/y/"]
    exts = [".didsa", ".DIDSAprt", ".didsacad"]
    ids = [f"id{i}" for i in range(5)]
    cases = []
    for _ in range(count):
        index = []
        for _ in range(rng.randint(0, 9)):
            index.append({"path": rng.choice(folders) + rng.choice(names) + rng.choice(exts), "part_id": rng.choice(ids + [None])})
        ref = rng.choice(folders) + rng.choice(names) + rng.choice(exts)
        reference = {"external_ref": ref if rng.random() < 0.95 else "", "ref_part_id": rng.choice(ids + [None, None])}
        at_path = None
        if rng.random() < 0.5:
            at_path = {"path": ref, "part_id": rng.choice(ids + [None])}
            index.append(dict(at_path))
        cases.append({"reference": reference, "at_path": at_path, "index": index, "expected": find_file(reference, at_path, index)})
    return cases


def main():
    out = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 1500
    rng = random.Random(seed)
    json.dump({"seed": seed, "appearance": appearance_cases(rng, count), "lookup": lookup_cases(rng, count * 2)}, open(out, "w"))
    print(f"wrote {count} appearance and {count * 2} lookup cases (seed {seed}) to {out}")


if __name__ == "__main__":
    main()
