"""Timings of `GET /parts/{id}/assembly-tree` (assembly tree overhaul A1; the numbers are in `docs/assembly-tree/spec.md`, "Cost").

Not collected by pytest (no `test_` prefix). Run from `backend/`, one scenario per process (a fresh process is a cold start):

    CAD_API_KEY=test-api-key python -m tests.bench_assembly_tree demo        # the gear-train demo (9 occurrences, 18 mates)
    CAD_API_KEY=test-api-key python -m tests.bench_assembly_tree demo-after-mesh   # ...after an assembly-mesh fetch, as a client sees it
    CAD_API_KEY=test-api-key python -m tests.bench_assembly_tree trains      # the demo placed 222 times: 2,220 occurrences
    CAD_API_KEY=test-api-key python -m tests.bench_assembly_tree distinct    # 40 sub-assemblies x 49 distinct parts: 2,000 occurrences, no mates

Each prints: structure only (no `status`), `status=true` cold (the first call: the placed Parts' bodies are built), status warm
(median of 5), structure warm (median of 5), and the response size. `demo-after-mesh` fetches `assembly-mesh` first (what a
client sees once the viewport has loaded: the bodies are already built, so "cold" is not cold)."""

import json
import statistics
import sys
import time

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY
from tests.gear_train_demo_motion_source import DEMO

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _ms(path: str) -> tuple[float, dict]:
    start = time.perf_counter()
    response = client.get(path)
    assert response.status_code == 200, response.text
    return (time.perf_counter() - start) * 1000, response.json()


def _occ(i: int, part_id: str) -> dict:
    return {
        "id": f"o{i}",
        "external_ref": f"parts/{part_id}.didsa",
        "resolved_part_id": part_id,
        "transform": {"translation": [i * 300.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
        "ref_part_id": part_id,
    }


def _part(part_id: str, name: str, occurrences=()) -> dict:
    return {"id": part_id, "name": name, "features": [], "occurrences": list(occurrences), "mates": [], "component_patterns": []}


def _payload(scenario: str) -> tuple[dict, str]:
    if scenario in ("demo", "demo-after-mesh", "trains"):
        payload = json.loads(DEMO.read_text())
        if scenario != "trains":
            return payload, payload["document"]["root_part_id"]
        train = payload["document"]["root_part_id"]
        payload["document"]["parts"].append(_part("bench_root", "Gear trains", [_occ(i, train) for i in range(222)]))
        payload["document"]["root_part_id"] = "bench_root"
        return payload, "bench_root"
    parts, subs = [], []
    for s in range(40):
        leaves = []
        for k in range(49):
            parts.append(_part(f"leaf{s}_{k}", f"Leaf {s}.{k}"))
            leaves.append(_occ(k, f"leaf{s}_{k}"))
        parts.append(_part(f"sub{s}", f"Sub {s}", leaves))
        subs.append(_occ(s, f"sub{s}"))
    parts.append(_part("bench_root", "Distinct parts", subs))
    return {"schema_version": 1, "document": {"id": "bench", "root_part_id": "bench_root", "parts": parts}, "sketches": []}, "bench_root"


def main(scenario: str) -> None:
    payload, root = _payload(scenario)
    assert client.post("/document/import/native", json=payload).status_code == 200
    tree = f"/document/parts/{root}/assembly-tree"
    structure, body = _ms(tree)
    if scenario == "demo-after-mesh":
        mesh, _ = _ms(f"/document/parts/{root}/assembly-mesh")
        print(f"assembly-mesh first: {mesh:.0f} ms, then:")
    cold, with_status = _ms(tree + "?status=true")
    warm = statistics.median(_ms(tree + "?status=true")[0] for _ in range(5))
    structure_warm = statistics.median(_ms(tree)[0] for _ in range(5))
    print(
        f"{scenario}: {body['node_count']} occurrences; structure first {structure:.0f} ms, warm {structure_warm:.0f} ms; "
        f"status cold {cold:.0f} ms, warm {warm:.0f} ms; {len(json.dumps(body)) / 1e3:.0f} kB / {len(json.dumps(with_status)) / 1e3:.0f} kB with status"
    )


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "demo")
