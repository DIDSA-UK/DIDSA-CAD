"""Drag cost of a group that holds a pattern-copy mate vs the same mates on the source directly
(`docs/pattern-followers-smoothness-plan.md` S1, measurement).

Not collected by pytest (no `test_` prefix). Run from `backend/`:

    CAD_API_KEY=test-api-key micromamba run -n didsa-backend python -m tests.bench_pattern_follower_drag [steps] [repeats]

Scene: a source `src` (box) and a second part `mover` (box) with THREE coincident mates between them (the three face pairs of a box:
normals +Z, +X, +Y). Case "direct": the mates are on `src`. Case "copy": the same mates are on copy 1 of a Linear pattern of `src`
(the group is then `{src, mover}` with `src` the member the copy follows). Each case POSTs `steps` mate-motion requests on `src`
(the drag: `src` moved along +X by 2 mm a step) and reports the median / max server time per step (ms, in-process `TestClient`), and
whether the answer carries a `constraint_model` (and its version): without one neither client can solve locally between server answers.
"""

import statistics
import sys
import time

from tests.test_mate_pattern_copy import _payload, _poses, _scene, client


def _case(copy: bool, steps: int) -> dict:
    scene = _scene()
    top_id = scene["top"]["id"]
    target = f"src#pattern:{scene['pid']}:1" if copy else "src"
    for normal in ((0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)):
        created = client.post(f"/document/parts/{top_id}/mates", json=_payload(scene, target, normal=normal))
        assert created.status_code == 201, created.text
    assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
    base = _poses(top_id)["src"]
    times, model_version = [], None
    for i in range(1, steps + 1):
        wanted = {**base, "translation": [base["translation"][0] + 2.0 * i, base["translation"][1], base["translation"][2]]}
        started = time.perf_counter()
        response = client.post(f"/document/parts/{top_id}/occurrences/src/mate-motion", json={"transform": wanted})
        times.append((time.perf_counter() - started) * 1000.0)
        assert response.status_code == 200, response.text
        model = response.json().get("constraint_model")
        model_version = None if model is None else model["version"]
    return {"median": statistics.median(times), "max": max(times), "first": times[0], "model_version": model_version}


def main() -> None:
    steps = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    repeats = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    results = {"direct": [], "copy": []}
    for _ in range(repeats):
        for name in results:
            results[name].append(_case(name == "copy", steps))
    print(f"{steps} mate-motion steps x {repeats} repeats (ms per step)")
    medians = {}
    for name, runs in results.items():
        medians[name] = statistics.median(r["median"] for r in runs)
        print(f"  {name:7s} median {medians[name]:6.1f}  max {max(r['max'] for r in runs):6.1f}  constraint_model sent: {runs[-1]['model_version']}")
    print(f"  copy / direct median ratio: {medians['copy'] / medians['direct']:.2f}  (target <= ~1.5, with the model sent)")


if __name__ == "__main__":
    main()
