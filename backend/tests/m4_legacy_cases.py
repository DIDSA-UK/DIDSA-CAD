"""M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`): the legacy `preview-mate-solve` requests whose answers must stay
byte-identical after M4. A request that sends neither `type: "auto"` nor `pick_points` must get exactly the bytes it got before M4.

`tests/data/m4_legacy_previews.json` holds the answers recorded on `main` BEFORE M4 (commit 22643c4) by running this module:

    CAD_API_KEY=test-api-key python -m tests.m4_legacy_cases   (from backend/, in the backend conda env)

`tests/test_mate_first_guess_m4.py::test_legacy_previews_are_byte_identical` replays every case and compares the response bytes.
Do not re-record it to make that test pass: a difference means M4 changed what an older client sees.
"""

import json
from pathlib import Path

import numpy as np

from tests import mate_first_guess_scenes as guess
from tests.test_assembly_solver import client

GOLDEN = Path(__file__).resolve().parent / "data" / "m4_legacy_previews.json"
SCENES = ("stack", "parallel", "pin-in-post", "axis-distance-25", "inset-10", "overhang-3", "gap-6-above", "vertex-6-above")
STARTS = ("near", "far")
MOVEMENTS = ("auto", "group")


def cases():
    """Yields `(key, scene, start pose, body, movement)` for every legacy case, in a fixed order with fixed seeds."""
    for name in SCENES:
        scene = guess.SCENES[name]()
        for kind in STARTS:
            rng = np.random.default_rng(sum(ord(c) for c in f"m4-legacy/{name}/{kind}"))
            start = guess.start_pose(scene, kind, rng)
            for movement in MOVEMENTS:
                yield f"{name}/{kind}/{movement}", scene, start, dict(scene.payload), movement
        if scene.payload.get("value") is not None:
            # an in-progress payload (no value yet): `converged: false`, nothing else
            body = {k: v for k, v in scene.payload.items() if k != "value"}
            yield f"{name}/no-value", scene, scene.true_pose, body, "auto"


def answer(scene, start: dict, body: dict, movement: str) -> str:
    guess.set_pose(scene, start)
    response = client.post(f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}/preview-mate-solve", params={"movement": movement}, json=body)
    assert response.status_code == 200, response.text
    return response.content.decode()


def record() -> dict[str, str]:
    return {key: answer(scene, start, body, movement) for key, scene, start, body, movement in cases()}


if __name__ == "__main__":
    import tests.conftest  # noqa: F401

    GOLDEN.write_text(json.dumps(record(), indent=1, sort_keys=False) + "\n")
    print(f"wrote {GOLDEN}")
