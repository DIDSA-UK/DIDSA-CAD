#!/usr/bin/env python3
"""Golden vectors for `assembly.pattern_copy_pose` (the pose of copy `index` of a ComponentPattern for a source at a pose).

    cd backend && python ../tools/motion_vectors/pattern_copy_pose_vectors.py           # (re)writes the fixture copies
    cd backend && python ../tools/motion_vectors/pattern_copy_pose_vectors.py --check   # exits 1 if a committed copy differs

Unlike `generate.py` this needs the BACKEND (it is the reference): run it with the backend's python (`import app`). The same file is
read by backend/tests/test_pattern_copy_pose_vectors.py (which also recomputes every number from the backend), the Flutter client's
`patternCopyPose` (client/test/pattern_copy_pose_test.dart) and VR's GDScript mirror (tests/pattern_copy_pose.gd, a copy in
tests/fixtures/). Every pose is `translation` + a 3x3 `rotation` (row-major, 9 floats: compare matrices, never axis-angle), rounded
to 10 decimals; tolerance 1e-9. Deterministic: no randomness.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "backend"))

from app.document.assembly import _live_pattern_indices, pattern_copy_pose  # noqa: E402
from app.document.constraint_model import rigid_to_pose  # noqa: E402
from app.document.models import ComponentPattern, ComponentPatternAxis, ComponentPatternType, RigidTransform  # noqa: E402

OUTS = [
    REPO / "backend" / "tests" / "data" / "pattern_copy_pose_vectors.json",
    REPO / "client" / "test" / "fixtures" / "pattern_copy_pose_vectors.json",
]


def r10(x: float) -> float:
    v = round(float(x), 10)
    return 0.0 if v == 0 else v


def rt_json(rt: RigidTransform) -> dict:
    return {"translation": [r10(c) for c in rt.translation], "rotation_axis": [r10(c) for c in rt.rotation_axis], "rotation_angle_degrees": r10(rt.rotation_angle_degrees)}


def pose_json(rt: RigidTransform) -> dict:
    r, t = rigid_to_pose(rt)
    return {"translation": [r10(c) for c in t], "rotation": [r10(c) for c in r.reshape(9)]}


def pattern_json(p: ComponentPattern) -> dict:
    return {
        "pattern_type": p.pattern_type.value, "direction": [r10(c) for c in p.direction], "count": p.count, "spacing": r10(p.spacing), "reverse": p.reverse,
        "direction_2": [r10(c) for c in p.direction_2], "count_2": p.count_2, "spacing_2": r10(p.spacing_2), "reverse_2": p.reverse_2,
        "axis": None if p.axis is None else {"origin": [r10(c) for c in p.axis.origin], "direction": [r10(c) for c in p.axis.direction]},
        "count_angular": p.count_angular, "angle_total": r10(p.angle_total), "reverse_angular": p.reverse_angular,
        "skip_indices": list(p.skip_indices), "orient_with_rotation": p.orient_with_rotation,
    }


def pattern_from_json(j: dict) -> ComponentPattern:
    axis = j["axis"]
    return ComponentPattern(
        id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType(j["pattern_type"]), direction=tuple(j["direction"]), count=j["count"],
        spacing=j["spacing"], reverse=j["reverse"], direction_2=tuple(j["direction_2"]), count_2=j["count_2"], spacing_2=j["spacing_2"], reverse_2=j["reverse_2"],
        axis=None if axis is None else ComponentPatternAxis(origin=tuple(axis["origin"]), direction=tuple(axis["direction"])),
        count_angular=j["count_angular"], angle_total=j["angle_total"], reverse_angular=j["reverse_angular"], skip_indices=list(j["skip_indices"]),
        orient_with_rotation=j["orient_with_rotation"],
    )


def pattern_vector_cases() -> list[dict]:
    identity = RigidTransform()
    moved = RigidTransform(translation=(120.0, -45.0, 30.0))
    turned = RigidTransform(translation=(200.0, 10.0, -5.0), rotation_axis=(0.0, 0.0, 1.0), rotation_angle_degrees=30.0)
    tilted = RigidTransform(translation=(-35.0, 80.0, 12.5), rotation_axis=(1.0, 2.0, 2.0), rotation_angle_degrees=65.0)
    flipped = RigidTransform(translation=(10.0, 20.0, 30.0), rotation_axis=(0.0, 1.0, 0.0), rotation_angle_degrees=180.0)
    sources = {"identity": identity, "moved": moved, "turned-z-30": turned, "tilted-65": tilted, "flipped-180": flipped}
    linear_1d = dict(pattern_type=ComponentPatternType.LINEAR, direction=(1.0, 0.0, 0.0), count=4, spacing=300.0)
    patterns = {
        "linear-1d": ComponentPattern(id="p", source_occurrence_ids=["src"], **linear_1d),
        "linear-1d-reverse-skew-direction": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.LINEAR, direction=(1.0, 1.0, 0.0), count=3, spacing=50.0, reverse=True),
        "linear-2d-grid": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.LINEAR, direction=(1.0, 0.0, 0.0), count=3, spacing=100.0, direction_2=(0.0, 1.0, 0.0), count_2=2, spacing_2=70.0),
        "linear-2d-both-reversed": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.LINEAR, direction=(0.0, 0.0, 1.0), count=2, spacing=40.0, reverse=True, direction_2=(1.0, 0.0, 0.0), count_2=3, spacing_2=25.0, reverse_2=True),
        "linear-2d-skip": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.LINEAR, direction=(1.0, 0.0, 0.0), count=3, spacing=100.0, direction_2=(0.0, 1.0, 0.0), count_2=2, spacing_2=70.0, skip_indices=[1, 4]),
        "circular-orient": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.CIRCULAR, count_angular=5, angle_total=360.0, axis=ComponentPatternAxis(origin=(10.0, -20.0, 0.0), direction=(0.0, 0.0, 1.0)), orient_with_rotation=True),
        "circular-keep-rotation": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.CIRCULAR, count_angular=5, angle_total=360.0, axis=ComponentPatternAxis(origin=(10.0, -20.0, 0.0), direction=(0.0, 0.0, 1.0)), orient_with_rotation=False),
        "circular-tilted-axis-orient": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.CIRCULAR, count_angular=4, angle_total=270.0, axis=ComponentPatternAxis(origin=(5.0, 5.0, 5.0), direction=(1.0, 1.0, 1.0)), orient_with_rotation=True),
        "circular-tilted-axis-keep-reverse": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.CIRCULAR, count_angular=4, angle_total=270.0, reverse_angular=True, axis=ComponentPatternAxis(origin=(5.0, 5.0, 5.0), direction=(1.0, 1.0, 1.0)), orient_with_rotation=False),
        "circular-skip": ComponentPattern(id="p", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.CIRCULAR, count_angular=6, angle_total=180.0, axis=ComponentPatternAxis(origin=(0.0, 0.0, 0.0), direction=(0.0, 1.0, 0.0)), skip_indices=[2, 3]),
    }
    cases = []
    for pname, pattern in patterns.items():
        for sname, source in sources.items():
            # the vector stores the rounded inputs and the expected values are computed FROM those, so a reader reproduces them from what it sees
            pj = pattern_json(pattern)
            sj = rt_json(source)
            p = pattern_from_json(pj)
            s = RigidTransform(translation=tuple(sj["translation"]), rotation_axis=tuple(sj["rotation_axis"]), rotation_angle_degrees=sj["rotation_angle_degrees"])
            live = _live_pattern_indices(p)
            cases.append({
                "id": f"{pname}/{sname}", "pattern": pj, "source": sj, "live_indices": live,
                "expected": [{"index": i, **pose_json(pattern_copy_pose(p, s, i))} for i in live],
            })
    return cases


def build() -> dict:
    return {
        "generator": "tools/motion_vectors/pattern_copy_pose_vectors.py (the backend's assembly.pattern_copy_pose is the reference)",
        "tolerance": 1e-9,
        "pose_in": "translation + rotation_axis (normalised on read) + rotation_angle_degrees",
        "pose_out": "translation + rotation (3x3 row-major, 9 floats): compare matrices, never axis-angle",
        "cases": pattern_vector_cases(),
    }


def main() -> None:
    text = json.dumps(build(), indent=1) + "\n"
    if "--check" in sys.argv:
        sys.exit(0 if all(o.exists() and o.read_text() == text for o in OUTS) else 1)
    for out in OUTS:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    print(f"wrote {len(build()['cases'])} cases to " + ", ".join(str(o.relative_to(REPO)) for o in OUTS))


if __name__ == "__main__":
    main()
