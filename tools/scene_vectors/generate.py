#!/usr/bin/env python3
"""Golden vectors for scene composition (docs/scenes-scope.md section 5: "scene + real tree -> per-instance pose, colour, opacity,
visibility").

    python tools/scene_vectors/generate.py            # (re)writes docs/scenes/vectors.json
    python tools/scene_vectors/generate.py --check    # exits 1 if a committed copy differs

The reference is `backend/app/document/scene_compose.py` (pure Python; it imports only `appearance.py`, so this runs on a plain
python3). DIDSA-VR (GDScript) and the flat app (Dart) copy the composition and are tested against `docs/scenes/vectors.json`;
the backend's own copy (`backend/tests/data/scene_vectors.json`, the CI image holds backend/ only) pins the reference.

Each case: `nodes` (every placed instance with its real local transform and hidden flag), `model` (the appearance resolution
model), `root`, `scene` (null = the default) and `expected` (per node path: world {basis row-major 3x3, origin mm}, hidden,
appearance, bodies). Floats are rounded to 10 decimals (and -0.0 written as 0.0); `tolerance` is what a float32 client may be off.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "scenes" / "vectors.json"
BACKEND_OUT = REPO / "backend" / "tests" / "data" / "scene_vectors.json"
sys.path.insert(0, str(REPO / "backend"))

from app.document.scene_compose import compose_scene  # noqa: E402

VERSION = 1
TOLERANCE = 1e-4  # mm and basis entries: a float32 client (Godot's Transform3D) carries ~7 significant digits


def T(tx=0.0, ty=0.0, tz=0.0, axis=(0.0, 0.0, 1.0), angle=0.0) -> dict:
    return {"translation": [tx, ty, tz], "rotation_axis": list(axis), "rotation_angle_degrees": angle}


# ---- the real tree ---------------------------------------------------------------------------------------------
# R (own body rb) places frame -> F at (300, 0, 0) turned 90 deg about z; F places barA (0, 0, 0) and barB (0, 800, 0) -> A
# (bodies a1, a2); R places bolt -> B at (0, 0, 50) with pattern p1 copies 1 and 2 every 40 mm along x; and leg -> L, really hidden.
NODES = [
    {"path": "", "local": T(), "hidden": False, "bodies": ["rb"]},
    {"path": "frame", "local": T(300.0, 0.0, 0.0, angle=90.0), "hidden": False, "bodies": []},
    {"path": "frame/barA", "local": T(), "hidden": False, "bodies": ["a1", "a2"]},
    {"path": "frame/barB", "local": T(0.0, 800.0, 0.0), "hidden": False, "bodies": ["a1", "a2"]},
    {"path": "bolt", "local": T(0.0, 0.0, 50.0), "hidden": False, "bodies": ["b1"]},
    {"path": "bolt#pattern:p1:1", "local": T(40.0, 0.0, 50.0), "hidden": False, "bodies": ["b1"]},
    {"path": "bolt#pattern:p1:2", "local": T(80.0, 0.0, 50.0), "hidden": False, "bodies": ["b1"]},
    {"path": "leg", "local": T(-200.0, 0.0, 0.0), "hidden": True, "bodies": ["l1"]},
]
MODEL = {
    "parts": {
        "R": {"occurrences": {"frame": {"part_id": "F"}, "bolt": {"part_id": "B"}, "leg": {"part_id": "L"}},
              "appearance_overrides": [{"path": "frame", "appearance": {"colour": "#2F6FD6"}}]},
        "F": {"occurrences": {"barA": {"part_id": "A"}, "barB": {"part_id": "A"}}},
        "A": {"appearance": {"roughness": 0.6}, "body_appearances": {"a2": {"colour": "#8B5A2B"}}},
        "B": {},
        "L": {},
    }
}


def ov(path: str, **fields) -> dict:
    return {"path": path, **fields}


SCENES = {
    "exploded": {"overrides": [
        ov("frame", transform=T(300.0, 0.0, 120.0, angle=90.0)),          # the frame lifted 120 mm, still turned
        ov("frame/barA", transform=T(-60.0, 0.0, 0.0)),                    # and one bar pulled out inside it (its own frame)
        ov("bolt#pattern:p1:2", transform=T(80.0, 0.0, 150.0, axis=(1.0, 0.0, 0.0), angle=45.0)),  # one pattern copy moved
    ]},
    "hidden": {"overrides": [
        ov("frame", hidden=True),          # hides what is inside it...
        ov("frame/barB", hidden=False),    # ...except what the scene shows again (the nearest wins)
        ov("leg", hidden=False),           # and shows a part the model hides
        ov("bolt#pattern:p1:1", hidden=True),
    ]},
    "looks": {"overrides": [
        ov("frame", appearance={"colour": "#D63A2F", "opacity": 0.3}),     # beats the model's own frame colour
        ov("frame/barB", body_id="a2", appearance={"metallic": 1.0}),       # one body, field by field
        ov("bolt#pattern:p1:2", appearance={"emission": "#FFFFFF", "emission_strength": 2.0}),
        ov("", body_id="rb", appearance={"colour": "#202020"}),            # the Part's own body
    ]},
    "everything": {"overrides": [
        ov("frame", transform=T(0.0, 0.0, 0.0, axis=(0.0, 1.0, 0.0), angle=180.0), appearance={"opacity": 0.5}),
        ov("frame/barB", hidden=True),
        ov("bolt", transform=T(0.0, 0.0, 0.0)),
    ], "section_planes": [{"origin": [0, 0, 0], "normal": [1, 0, 0], "flipped": False}], "viewpoint": {"eye": [2400, 1500, 2400], "target": [0, 400, -780], "up": [0, 1, 0]}},
    "empty": {"overrides": []},
}

CASES = [
    ("default", "No scene: the real tree (the frame turned 90 deg places barB at (300 - 800, 0, 0)), the model's own looks.", None),
    ("exploded", "Moves compose down the tree: the lifted frame carries both bars; barA's own move is in the frame's frame; one pattern copy moves alone.", "exploded"),
    ("hidden", "Hiding a sub-assembly hides its contents; the nearest scene `hidden` wins; a scene can show a hidden part.", "hidden"),
    ("looks", "A scene's appearance beats the model's, field by field, down to one body; the Part's own body too.", "looks"),
    ("everything", "Pose, visibility and appearance together; section planes and the viewpoint don't change composition.", "everything"),
    ("empty", "A scene with no overrides shows the default.", "empty"),
]


def _clean(value):
    if isinstance(value, float):
        r = round(value, 10)
        return 0.0 if r == 0.0 else r
    if isinstance(value, list):
        return [_clean(v) for v in value]
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items()}
    return value


def build() -> dict:
    cases = []
    for name, why, scene_name in CASES:
        scene = copy.deepcopy(SCENES[scene_name]) if scene_name else None
        expected = compose_scene(NODES, MODEL, "R", scene)
        cases.append({"name": name, "why": why, "scene": scene, "expected": _clean(expected)})
    return {"version": VERSION, "tolerance": TOLERANCE, "source": "tools/scene_vectors/generate.py (reference: backend/app/document/scene_compose.py)",
            "root": "R", "nodes": NODES, "model": MODEL, "cases": cases}


def dumps(doc: dict) -> str:
    return json.dumps(doc, indent=1, sort_keys=True) + "\n"


def main() -> int:
    text = dumps(build())
    if "--check" in sys.argv:
        stale = [str(p.relative_to(REPO)) for p in (OUT, BACKEND_OUT) if not p.exists() or p.read_text() != text]
        if stale:
            print("stale: " + ", ".join(stale) + " (run tools/scene_vectors/generate.py)")
            return 1
        print(f"ok: {len(CASES)} cases")
        return 0
    for path in (OUT, BACKEND_OUT):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    print(f"wrote {len(CASES)} cases to {OUT.relative_to(REPO)} and {BACKEND_OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
