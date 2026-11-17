"""N1b: what a mate-reference refresh costs, on the M0 scaling scenes (`tests/motion_scaling_scenes.py`).

Not collected by pytest (no `test_` prefix). Run from `backend/` in the conda env of `backend/environment.yml`, on the same machine for every comparison:

    CAD_API_KEY=test-api-key python -m tests.bench_mate_reference_refresh [--only chain-20 frame-20 ...] [--json FILE]

It runs on the code before N1b too (the refresh columns are then empty), so one run on `main` and one on this branch give the "before" and "after" of the
columns that exist in both: the group solve at rest, and the drag anchor (`POST .../mate-motion`, warm-started, 10 steps).

Per scene (floating):
  * `refresh`: `refresh_mate_references(document, part, persist=False)`, what a solve pays once per model-cache miss to decide which mates to hold out;
  * `refresh_persist`: the same with `persist=True`, which a listing, a create / PATCH response and an export pay; nothing to write once the signatures are in;
  * `listing`: `GET .../mates` through the in-process TestClient (the refresh, every status and the rigid sets);
  * `listing_without_refresh`: `mate_status_details` + `mate_rigid_sets` only, the listing's own work before N1b;
  * `solve_rest`, `drag_wall`: as in M0.
Times are medians of up to 7 runs, in milliseconds."""

import argparse
import json
import statistics
import time

import numpy as np

import tests.conftest  # noqa: F401  (sets CAD_API_KEY for the test client)
from app.document.assembly_group import apply_delta, solve_group
from app.document.mate_status import mate_status_details
from app.document.rigid_sets import mate_rigid_sets
from app.document.store import get_document
from tests import motion_scaling_scenes as scaling
from tests.test_assembly_solver import client

try:
    from app.document.subshape_identity import refresh_mate_references
except ImportError:  # the code before N1b
    refresh_mate_references = None

SCENES = {
    "chain-5": lambda: scaling.chain_scene(5),
    "chain-20": lambda: scaling.chain_scene(20),
    "chain-50": lambda: scaling.chain_scene(50),
    "chain-5-bolts": lambda: scaling.chain_scene(5, bolts=True),
    "frame-4": lambda: scaling.frame_scene(4),
    "frame-20": lambda: scaling.frame_scene(20),
    "frame-30": lambda: scaling.frame_scene(30),
    "linkage-20": lambda: scaling.linkage_scene(20),
}


def median_ms(fn, repeats: int = 7, budget_s: float = 8.0) -> float:
    times, began = [], time.perf_counter()
    for _ in range(repeats):
        start = time.perf_counter()
        fn()
        times.append((time.perf_counter() - start) * 1000.0)
        if time.perf_counter() - began > budget_s and len(times) >= 3:
            break
    return statistics.median(times)


def measure(name: str) -> dict:
    scene = SCENES[name]()
    document = get_document()
    part = document.parts[scene.root]
    grabbed = scene.mover
    solve_group(document, part, grabbed, None)  # warm-up: builds every body and the model
    stored = {o.id: o.transform for o in part.occurrences}[grabbed]
    row = {"scene": name, "mates": len(part.mates), "solve_rest": median_ms(lambda: solve_group(document, part, grabbed, None))}
    if refresh_mate_references is not None:
        refresh_mate_references(document, part)  # signs everything once (a created mate is signed already; a scene built from files is not)
        row["refresh"] = median_ms(lambda: refresh_mate_references(document, part, persist=False))
        row["refresh_persist"] = median_ms(lambda: refresh_mate_references(document, part))
    row["listing"] = median_ms(lambda: client.get(f"/document/parts/{scene.root}/mates"))
    row["listing_without_refresh"] = median_ms(lambda: (mate_status_details(document, part), mate_rigid_sets(document, part)))
    wanted, wall, reference = stored, [], None
    for step in range(10):
        wanted = apply_delta(wanted, np.array((2.0, 0.0, 0.0, 0.0, 0.0, np.radians(1.0))))
        body = {"transform": {"translation": list(wanted.translation), "rotation_axis": list(wanted.rotation_axis), "rotation_angle_degrees": wanted.rotation_angle_degrees}}
        if reference:
            body["reference"] = reference
        began = time.perf_counter()
        response = client.post(f"/document/parts/{scene.root}/occurrences/{grabbed}/mate-motion", json=body)
        wall.append((time.perf_counter() - began) * 1000.0)
        assert response.status_code == 200, response.text
        answer = response.json()
        reference = [{"occurrence_id": m["occurrence_id"], "transform": m["transform"]} for m in answer.get("members", [])] or None
    row["drag_wall"] = statistics.median(wall)
    return row


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", nargs="*", default=list(SCENES))
    parser.add_argument("--json")
    args = parser.parse_args()
    rows = []
    for name in args.only:
        row = measure(name)
        rows.append(row)
        print(json.dumps({k: (round(v, 2) if isinstance(v, float) else v) for k, v in row.items()}), flush=True)
    if args.json:
        with open(args.json, "w") as out:
            json.dump(rows, out, indent=1)


if __name__ == "__main__":
    main()
