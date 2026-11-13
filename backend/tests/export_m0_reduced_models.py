"""Exports the constraint model (version 8: the rigid-set leads) of every M0 scaling scene variant, with the leads' stored poses and a wish
(the grabbed part 5 mm along x and 5 degrees about z away), for the client benchmarks (`client/test/local_retraction_m0_bench_test.dart`,
DIDSA-VR `tests/bench_local_retraction.gd`): the file is `client/test/data/m0_reduced_models.json`. Not collected by pytest. Run from `backend/`:

    CAD_API_KEY=test-api-key python -m tests.export_m0_reduced_models ../client/test/data/m0_reduced_models.json
"""

import json
import sys

import numpy as np

from app.document.assembly_group import apply_delta, solve_group
from app.document.store import get_document
from tests import motion_scaling_scenes as scaling
from tests.bench_mates_m0 import _WISH, SCALING_SCENES, client_verdict


_LEVER = 100.0  # mm: a stand-in for the grabbed part's bounding radius (the benchmark only needs one size of wish)


def _wire(pose) -> dict:
    return {
        "translation": [float(x) for x in pose.translation],
        "rotation_axis": [float(x) for x in pose.rotation_axis],
        "rotation_angle_degrees": float(pose.rotation_angle_degrees),
    }


def main(path: str) -> None:
    out = []
    for _family, _n, factory in SCALING_SCENES:
        for variant in ("floating", "fixed"):
            scene = factory()
            if variant == "fixed":
                scaling.fix(scene.root, scene.base)
            document = get_document()
            part = document.parts[scene.root]
            stored = {o.id: o.transform for o in part.occurrences}
            wish = apply_delta(stored[scene.mover], np.array(_WISH))
            spec = solve_group(document, part, scene.mover, wish).constraint_model
            poses = [_wire(stored[oid]) for oid in spec["members"]]
            out.append(
                {
                    "scene": scene.name,
                    "variant": variant,
                    "model": spec,
                    "poses": poses,
                    "wishes": [_wire(wish)] + poses[1:],
                    "lever_arm": _LEVER,
                    "verdict": client_verdict(spec, (8, 64)),
                }
            )
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(out, handle)


if __name__ == "__main__":
    main(sys.argv[1])
