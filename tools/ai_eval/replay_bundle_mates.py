"""Replays one assembly plan's mates from an AI Modelling zip against the backend, in process, the way the app does.

Written for docs/assembly-perf-mates-and-ui-plan.md (Part B). It composes a saved assembly `.didsa` with every file its
occurrences name (resolved ids, as the app's `add_component` merge does), imports it, rewrites the plan's `add_component`
local ids to `existing:<real id>` (including `outer/inner` paths into placed sub-assemblies), dry-runs the mates, and with
`--build` creates each mate (Closest branch) then solves its second reference's occurrence, as `PlanTranslator` does.

Run from `backend/` with the conda env (tools/setup_test_env.sh in DIDSA-VR installs it):
  CAD_API_KEY=test-api-key PYTHONPATH=. python ../tools/ai_eval/replay_bundle_mates.py DIR ASSEMBLY.didsa PLAN.json \
      [--sub SUB_PLAN.json ...] [--build] [--drop] [--skip m26,m50]
DIR holds the saved .didsa files; PLAN.json is the plan that built ASSEMBLY.didsa (its add_component steps must be in the
same order as the file's occurrences, which is what the app writes). --sub names the plans of the sub-assemblies a nested
`outer/inner` reference goes through. --drop deletes a mate whose solve fails and carries on (to find every bad mate, not
just the first); --skip leaves those mates out.
"""

from __future__ import annotations

import argparse
import collections
import copy
import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dir", type=Path)
    parser.add_argument("assembly")
    parser.add_argument("plan", type=Path)
    parser.add_argument("--sub", type=Path, nargs="*", default=[])
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--skip", default="")
    args = parser.parse_args()

    import os

    client = TestClient(app)
    client.headers.update({"X-API-Key": os.environ["CAD_API_KEY"]})

    def load(name: str) -> dict:
        return json.loads((args.dir / name).read_text())

    parts: list[dict] = []
    sketches: list[dict] = []
    root_by_file: dict[str, str] = {}

    def add_file(name: str) -> str:
        if name in root_by_file:
            return root_by_file[name]
        doc = load(name)
        root_by_file[name] = doc["document"]["root_part_id"]
        for part in doc["document"]["parts"]:
            part = copy.deepcopy(part)
            for occurrence in part.get("occurrences", []):
                occurrence["resolved_part_id"] = add_file(occurrence["external_ref"])
            parts.append(part)
        sketches.extend(doc.get("sketches", []))
        return root_by_file[name]

    top = add_file(args.assembly)
    response = client.post(
        "/document/import/native",
        json={"schema_version": 1, "document": {"id": "replay", "root_part_id": top, "parts": parts}, "sketches": sketches},
    )
    print("import", response.status_code, "" if response.status_code == 200 else response.text[:300])

    plan = json.loads(args.plan.read_text())
    adds = [s["local_id"] for s in plan["steps"] if s["kind"] == "add_component"]
    occurrences = next(p for p in parts if p["id"] == top)["occurrences"]
    real_by_local = dict(zip(adds, (o["id"] for o in occurrences)))
    sub_adds = [[s["local_id"] for s in json.loads(p.read_text())["steps"] if s["kind"] == "add_component"] for p in args.sub]

    def rewrite(local: str) -> str:
        if local in real_by_local:
            return "existing:" + real_by_local[local]
        if "/" in local:
            outer, inner = local.split("/", 1)
            outer_occurrence = next(o for o in occurrences if o["id"] == real_by_local[outer])
            sub_doc = load(outer_occurrence["external_ref"])
            sub_root = next(p for p in sub_doc["document"]["parts"] if p["id"] == sub_doc["document"]["root_part_id"])
            order = next(a for a in sub_adds if inner in a)
            return f"existing:{real_by_local[outer]}/{sub_root['occurrences'][order.index(inner)]['id']}"
        return local

    skip = set(filter(None, args.skip.split(",")))
    mates = [s for s in plan["steps"] if s["kind"] == "mate" and s["local_id"] not in skip]
    for mate in mates:
        for ref in mate["references"]:
            ref["occurrence_id"] = rewrite(ref["occurrence_id"])
    response = client.post(f"/document/parts/{top}/ai-plan/validate", json={"version": 1, "steps": mates})
    results = response.json()["results"]
    print(f"validate: {sum(r['ok'] for r in results)}/{len(results)} mates ok")
    errors = collections.Counter(json.dumps(r.get("error"), sort_keys=True)[:240] for r in results if not r["ok"])
    for error, count in errors.most_common(10):
        print(f"  {count} x {error}")
    if not args.build:
        return

    failures = 0
    near_header = 0
    for mate, result in zip(mates, results):
        if not result["ok"]:
            continue
        resolved = result.get("resolved_mate_references") or [None, None]
        refs = [
            {"occurrence_id": ref["occurrence_id"].removeprefix("existing:"), "subshape_ref": resolved[i]}
            for i, ref in enumerate(mate["references"])
        ]
        created = client.post(
            f"/document/parts/{top}/mates",
            json={
                "type": mate["type"],
                "references": refs,
                "value": mate.get("value"),
                "flipped": mate.get("flipped", False),
                "alignment": None,
                "secondary_flip": None,
            },
        )
        if created.status_code != 201:
            failures += 1
            print("create", mate["local_id"], created.status_code, created.text[:200])
            continue
        target = (refs[1]["occurrence_id"] or refs[0]["occurrence_id"]).split("/")[0]
        solved = client.post(f"/document/parts/{top}/occurrences/{target}/solve")
        if solved.status_code != 200 and "occurrence_is_fixed" in solved.text:
            solved = client.post(f"/document/parts/{top}/occurrences/{refs[0]['occurrence_id'].split('/')[0]}/solve")
        if solved.status_code == 200 and solved.headers.get("X-Mate-Tolerance") == "near":
            near_header += 1
        if solved.status_code != 200:
            failures += 1
            print("solve", mate["local_id"], mate["type"], mate.get("value"), solved.text[:200])
            if args.drop:
                client.delete(f"/document/parts/{top}/mates/{created.json()['id']}")
            elif failures > 5:
                break
    built = len(mates) - failures
    print(f"built: {len(mates)} mates tried, {failures} failures")
    # B1: how the stored mates stand now (computed status, never stored): ok / near (within tolerance) / broken.
    listed = client.get(f"/document/parts/{top}/mates").json()
    counts = collections.Counter(m["status"] for m in listed)
    near = [m for m in listed if m["status"] == "near"]
    print(
        f"mates now: {built} built = {counts['ok']} ok + {counts['near']} near + {counts['broken']} broken; "
        f"{near_header} solves answered X-Mate-Tolerance: near"
    )
    for m in near:
        print(f"  near {m['id'][:8]} {m['type']} value={m.get('value')} residual {m['status_residual_mm']:.5f} mm / {m['status_residual_deg']:.6f} deg")


if __name__ == "__main__":
    main()
