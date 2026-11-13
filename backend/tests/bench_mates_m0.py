"""Mates benchmark, phase M0 of `docs/mates-storage-sessions-plan-2026-11-12.md`: the numbers every later mates phase is judged
against. It changes nothing in the solver; it only measures it.

Not collected by pytest (no `test_` prefix). Run from `backend/`, in the conda env of `backend/environment.yml`:

    CAD_API_KEY=test-api-key python -m tests.bench_mates_m0 scaling  [--quick] [--json FILE]
    CAD_API_KEY=test-api-key python -m tests.bench_mates_m0 accuracy [--trials N] [--json FILE]
    CAD_API_KEY=test-api-key python -m tests.bench_mates_m0 all      [--quick] [--trials N] [--json FILE]

`tests/test_mates_m0_scenes.py` is the small, fast pytest check that the scenes build and solve; this script is the long run
(a few minutes for `scaling`, more with a slow machine; `--quick` keeps the small sizes only).

**scaling** (`tests/motion_scaling_scenes.py`; every scene floating and with its base fixed). Per scene:
  * the grabbed part's group: members (6 variables each), mates, residual rows, group dof;
  * `solve_group` in-process (build + Gauss-Newton + nearest-point stage + analysis, as the smoothness study timed it): at
    rest (no wish) and with a wish (the grabbed part asked 5 mm and 5 deg away);
  * the drag anchor: `POST .../mate-motion` through the in-process `TestClient`, 10 steps of one drag, each warm-started from the
    previous answer (`reference`), the constraint model asked for on the first step only;
  * `POST .../preview-mate-solve` for three new mates, in `auto` (what the Flutter mate panel sends by default: only the mated
    part moves if that is enough) and `group` movement: `probe` (a loose part onto the group), `redundant` (a distance the
    locked group already meets) and `conflict` (the same distance 7 mm off: nothing fits, so the preview runs the branch search
    and the conflict step). Each with the number of `solve_group` calls it made (alternatives and search included);
  * the exported constraint model against the Flutter client's caps (`kLocalMaxMembers`, `kLocalMaxRows`, read from
    `client/lib/motion/local_retraction.dart`): refused = the local per-frame solve is off for this group.

**accuracy** (`tests/mate_first_guess_scenes.py`): first-time accuracy of an unnamed mate's default placement, per scene and
start class, and the extra clicks (Flip side / Next solution, whichever is fewer) to reach the truth.

All times are wall-clock milliseconds on the machine that ran it (printed in the header): compare runs on one machine only.
"""

import argparse
import json
import os
import platform
import re
import statistics
import sys
import time
from pathlib import Path

import numpy as np

import tests.conftest  # noqa: F401  (sets CAD_API_KEY for the test client)
from app.document import router as router_module
from app.document.assembly_group import apply_delta, build_group_model, solve_group
from app.document.constraint_model import ConstraintModel
from app.document.store import get_document
from tests import mate_first_guess_scenes as guess
from tests import motion_scaling_scenes as scaling
from tests.test_assembly_solver import client

_LOCAL_RETRACTION = Path(__file__).resolve().parents[2] / "client" / "lib" / "motion" / "local_retraction.dart"
_LIMIT_TYPES = ("limit_distance", "limit_angle")
_DRAG_STEPS = 10
_WISH = (5.0, 0.0, 0.0, 0.0, 0.0, np.radians(5.0))  # the grabbed part asked 5 mm along x and 5 deg about z away
_DRAG_STEP = (2.0, 0.0, 0.0, 0.0, 0.0, np.radians(1.0))  # per drag step


# ---- helpers ------------------------------------------------------------------


def client_caps() -> tuple[int, int]:
    """(`kLocalMaxMembers`, `kLocalMaxRows`) as the Flutter client declares them (8 and 64 if the file is not there)."""
    members, rows = 8, 64
    try:
        text = _LOCAL_RETRACTION.read_text(encoding="utf-8")
        members = int(re.search(r"const int kLocalMaxMembers = (\d+);", text).group(1))
        rows = int(re.search(r"const int kLocalMaxRows = (\d+);", text).group(1))
    except (OSError, AttributeError):
        pass
    return members, rows


def client_model_rows(spec: dict) -> int:
    """The row count `LocalRetractor.tryParse` compares with `kLocalMaxRows`: the residual rows of the exported model at identity
    poses (the Python reference model the Dart one mirrors, pinned by `docs/motion/vectors.json`) plus one per limit mate."""
    identity = [(np.eye(3), np.zeros(3)) for _ in spec["members"]]
    rows = len(ConstraintModel(spec).residual(identity, with_jacobian=False))
    return rows + sum(1 for m in spec["mates"] if m.get("type") in _LIMIT_TYPES)


_SHIPPED_CLIENT_MAX_VERSION = 8  # the newest constraint model the Flutter / VR clients parse (v8, rigid sets: read since M2)


def client_verdict(spec: dict | None, caps: tuple[int, int]) -> dict:
    """`refused` = over the caps (members or rows). For a version-8 model (M1 rigid sets) `members` are the sets' leads and `rows`
    exclude the mates inside a set; `shipped_reads` says whether the clients parse the version at all (before M2 they returned null for v8
    and kept projecting; since M2 both read it), so `refused: false` means the local solve runs for this group."""
    if spec is None:
        return {"version": None, "members": None, "rows": None, "refused": True, "why": "no model exported", "shipped_reads": False}
    members, rows = len(spec["members"]), client_model_rows(spec)
    why = [w for w, over in ((f"members {members} > {caps[0]}", members > caps[0]), (f"rows {rows} > {caps[1]}", rows > caps[1])) if over]
    return {
        "version": spec["version"],
        "members": members,
        "rows": rows,
        "refused": bool(why),
        "why": ", ".join(why),
        "shipped_reads": spec["version"] <= _SHIPPED_CLIENT_MAX_VERSION,
        "followers": sum(len(s["followers"]) for s in spec.get("rigid_sets") or []),
    }


def timed(fn, budget_s: float = 6.0, max_repeats: int = 7) -> tuple[list[float], object]:
    """Runs `fn` until `max_repeats` or the time budget (always at least once). Returns (ms per run, the last result)."""
    times, result, started = [], None, time.perf_counter()
    while len(times) < max_repeats and (not times or time.perf_counter() - started < budget_s):
        began = time.perf_counter()
        result = fn()
        times.append((time.perf_counter() - began) * 1000.0)
    return times, result


class SolveCounter:
    """Counts (and times) the `solve_group` calls the routes make, alternatives and the branch search included."""

    def __init__(self):
        self.calls, self.ms, self.members, self.bodies = 0, 0.0, [], []
        self._real = router_module.solve_group

    def __enter__(self):
        def counted(*args, **kwargs):
            began = time.perf_counter()
            result = self._real(*args, **kwargs)
            self.ms += (time.perf_counter() - began) * 1000.0
            self.calls += 1
            self.members.append(len(result.poses))
            self.bodies.append(getattr(result, "solved_bodies", None) or len(result.poses))
            return result

        router_module.solve_group = counted
        return self

    def __exit__(self, *exc):
        router_module.solve_group = self._real
        return False


def _stat(times: list[float]) -> dict:
    return {"median": statistics.median(times), "min": min(times), "max": max(times), "n": len(times)}


def machine() -> dict:
    cpu = platform.processor() or ""
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    ram = None
    try:
        ram = round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1)
    except (ValueError, OSError):
        pass
    import OCC  # noqa: PLC0415

    return {
        "date": time.strftime("%Y-%m-%d"),
        "cpu": cpu,
        "cores": os.cpu_count(),
        "ram_gb": ram,
        "os": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "numpy": np.__version__,
        "occt": OCC.VERSION,
    }


# ---- scaling ------------------------------------------------------------------

SCALING_SCENES = [
    ("chain", 5, lambda: scaling.chain_scene(5)),
    ("chain", 10, lambda: scaling.chain_scene(10)),
    ("chain", 20, lambda: scaling.chain_scene(20)),
    ("chain", 50, lambda: scaling.chain_scene(50)),
    ("chain+bolts", 5, lambda: scaling.chain_scene(5, bolts=True)),
    ("chain+bolts", 10, lambda: scaling.chain_scene(10, bolts=True)),
    ("frame", 4, lambda: scaling.frame_scene(4)),
    ("frame", 10, lambda: scaling.frame_scene(10)),
    ("frame", 20, lambda: scaling.frame_scene(20)),
    ("frame", 30, lambda: scaling.frame_scene(30)),
    ("linkage", 24, lambda: scaling.linkage_scene(20)),
]
_QUICK = {("chain", 5), ("chain", 10), ("chain+bolts", 5), ("frame", 4), ("frame", 10), ("linkage", 24)}


def _preview_case(scene, driven: str, payload: dict, movement: str) -> dict:
    def call():
        return client.post(f"/document/parts/{scene.root}/occurrences/{driven}/preview-mate-solve", params={"movement": movement}, json=payload)

    with SolveCounter() as counter:
        response = call()  # counted once (the count does not vary between runs)
    assert response.status_code == 200, response.text
    times, response = timed(call, budget_s=4.0, max_repeats=5)
    answer = response.json()
    return {
        "ms": _stat(times),
        "solves": counter.calls,
        "solve_ms": counter.ms,
        "largest_solve_members": max(counter.members, default=0),
        "largest_solve_bodies": max(counter.bodies, default=0),  # M1: one body per rigid set
        "converged": answer["converged"],
        "alternatives": len(answer.get("alternatives") or []),
        "branch_changes": len(answer.get("branch_changes") or []),
        "conflicting": len(answer.get("conflicting") or []),
        "blocked_by": len(answer.get("blocked_by") or []),
    }


def measure_scaling(family: str, n: int, factory, variant: str, caps: tuple[int, int]) -> dict:
    scene = factory()
    if variant == "fixed":
        scaling.fix(scene.root, scene.base)
    document = get_document()
    part = document.parts[scene.root]
    grabbed = scene.mover
    model = build_group_model(document, part, grabbed)
    stored = part.occurrences
    stored_pose = {o.id: o.transform for o in stored}[grabbed]
    solve_group(document, part, grabbed, None)  # warm-up: the first solve builds every body
    rest_ms, rest = timed(lambda: solve_group(document, part, grabbed, None))
    wish_pose = apply_delta(stored_pose, np.array(_WISH))
    wish_ms, wish = timed(lambda: solve_group(document, part, grabbed, wish_pose))
    row = {
        "scene": scene.name,
        "family": family,
        "n": n,
        "variant": variant,
        "members": len(model.member_ids),
        "variables": model.n_vars,
        "mates": len(model.component.mates),
        "rows": int(len(model.residual())),
        "dof": rest.dof,
        "expected_dof": scene.expected_dof_fixed if variant == "fixed" else scene.expected_dof_floating,
        "solve_rest": {**_stat(rest_ms), "converged": rest.converged, "iterations": rest.quality.iterations},
        "solve_wish": {**_stat(wish_ms), "converged": wish.converged, "iterations": wish.quality.iterations, "seeded_by": wish.quality.seeded_by},
        "client": client_verdict(rest.constraint_model, caps),
        "bodies": getattr(rest, "solved_bodies", None) or len(model.member_ids),  # M1: one per rigid set + every other member
        "rigid_sets": len(set(getattr(rest, "rigid_sets", {}).values())),
    }

    # the drag: every step warm-started from the last accepted answer, like `ConstrainedDragSession`
    reference, wanted, wall, server, converged = None, stored_pose, [], [], 0
    for step in range(_DRAG_STEPS):
        wanted = apply_delta(wanted, np.array(_DRAG_STEP))
        body = {
            "transform": {"translation": list(wanted.translation), "rotation_axis": list(wanted.rotation_axis), "rotation_angle_degrees": wanted.rotation_angle_degrees},
            "include_constraint_model": step == 0,
        }
        if reference:
            body["reference"] = reference
        began = time.perf_counter()
        response = client.post(f"/document/parts/{scene.root}/occurrences/{grabbed}/mate-motion", json=body)
        wall.append((time.perf_counter() - began) * 1000.0)
        assert response.status_code == 200, response.text
        answer = response.json()
        server.append(answer["diagnostics"]["solve_ms"])
        if answer["converged"]:
            converged += 1
            reference = [{"occurrence_id": m["occurrence_id"], "transform": m["transform"]} for m in answer["members"]]
    row["drag"] = {"wall": _stat(wall), "first": wall[0], "solve_ms": _stat(server), "converged": converged, "steps": _DRAG_STEPS}

    row["preview"] = {}
    for case, driven, payload in (
        ("probe", scene.probe_driven, scene.probe_mate),
        ("redundant", scene.inside_driven, scene.redundant_mate),
        ("conflict", scene.inside_driven, scene.conflict_mate),
    ):
        for movement in ("auto", "group"):
            row["preview"][f"{case}/{movement}"] = _preview_case(scene, driven, payload, movement)
    return row


def run_scaling(quick: bool, only: tuple[str, ...] = ()) -> list[dict]:
    caps = client_caps()
    rows = []
    for family, n, factory in SCALING_SCENES:
        if quick and (family, n) not in _QUICK:
            continue
        if only and family not in only:
            continue
        for variant in ("floating", "fixed"):
            began = time.perf_counter()
            row = measure_scaling(family, n, factory, variant, caps)
            rows.append(row)
            print(f"  measured {row['scene']} {variant} in {time.perf_counter() - began:.0f} s", file=sys.stderr, flush=True)
    return rows


def _ms(value: float) -> str:
    return f"{value:.0f}" if value >= 100 else (f"{value:.1f}" if value >= 10 else f"{value:.2f}")


def print_scaling(rows: list[dict], caps: tuple[int, int]) -> None:
    print("\n### Scaling: the group, `solve_group`, the drag anchor and the client caps\n")
    print(f"Client caps: kLocalMaxMembers = {caps[0]}, kLocalMaxRows = {caps[1]}. Times: median ms.\n")
    print("| scene | variant | members | mates | rows | dof | solve_group at rest | solve_group with a wish (iterations) | drag anchor: wall (server solve_ms), max | client model: members / rows | refused by the caps |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        dof = f"{r['dof']}" + ("" if r["dof"] == r["expected_dof"] else f" (expected {r['expected_dof']})")
        wish = r["solve_wish"]
        wish_text = f"{_ms(wish['median'])} ({wish['iterations']})" + ("" if wish["converged"] else " NOT converged")
        drag = r["drag"]
        drag_text = f"{_ms(drag['wall']['median'])} ({_ms(drag['solve_ms']['median'])}), {_ms(drag['wall']['max'])}"
        if drag["converged"] != drag["steps"]:
            drag_text += f"; {drag['converged']}/{drag['steps']} converged"
        c = r["client"]
        refused = f"**yes** ({c['why']})" if c["refused"] else "no"
        print(f"| {r['scene']} | {r['variant']} | {r['members']} | {r['mates']} | {r['rows']} | {dof} | {_ms(r['solve_rest']['median'])} | {wish_text} | {drag_text} | {c['members']} / {c['rows']} | {refused} |")

    print("\n### Scaling: `preview-mate-solve` (alternatives and the branch search included)\n")
    print("Per cell: median ms / `solve_group` calls in that one preview (largest group solved, members). `auto` = only the mated part moves if that is enough; `group` = the whole component is solved.\n")
    cases = ["probe/auto", "probe/group", "redundant/auto", "redundant/group", "conflict/auto", "conflict/group"]
    print("| scene | variant | " + " | ".join(cases) + " |")
    print("|---|---|" + "---|" * len(cases))
    for r in rows:
        cells = []
        for case in cases:
            p = r["preview"][case]
            flag = "" if p["converged"] else (" x" if case.startswith("conflict") else " NOT converged")
            cells.append(f"{_ms(p['ms']['median'])} / {p['solves']} ({p['largest_solve_members']}){flag}")
        print(f"| {r['scene']} | {r['variant']} | " + " | ".join(cells) + " |")
    print("\n`x` = no placement (expected for `conflict`: the answer names the conflicting mates instead).")
    refused = sum(1 for r in rows if r["client"]["refused"])
    print(f"\nClient model refused by the caps: {refused} of {len(rows)} scene variants.")


# ---- first-time accuracy --------------------------------------------------------


def _seed(scene_name: str, kind: str) -> int:
    return sum(ord(c) * (i + 1) for i, c in enumerate(f"{scene_name}/{kind}")) % (2**31)


def one_preview(scene: "guess.GuessScene", start: dict, picks: dict | None = None, payload: dict | None = None) -> dict:
    """One trial: the part at `start`, the mate previewed with nothing named. `clicks`: 0 = right first time, else the fewer of
    branch toggles (Aligned / Flip side) and Next-solution presses that reach the truth; None = no alternative reaches it.
    M4: `picks` (this trial's pick points, `guess.trial_picks`) are sent as `pick_points`; `payload` replaces the scene's mate (the
    "before M4" type of the peg-in-hole scene)."""
    guess.set_pose(scene, start)
    named = {}
    if picks is not None:
        named["pick_points"] = [picks[guess.DRIVEN], picks[guess.FIXED]]
    if payload is not None:
        named = {**payload, **named}
    began = time.perf_counter()
    ghost = guess.preview(scene, **named)
    elapsed = (time.perf_counter() - began) * 1000.0
    if not ghost["converged"]:
        return {"first": False, "clicks": None, "converged": False, "ms": elapsed}
    if scene.correct(guess.shown_transform(ghost)):
        return {"first": True, "clicks": 0, "converged": True, "ms": elapsed}
    resolved = ghost.get("resolved") or {}
    for presses, alternative in enumerate(ghost.get("alternatives") or []):
        shown = guess.shown_transform(alternative)
        if shown is not None and scene.correct(shown):
            toggles = sum(
                1 for key in ("alignment", "secondary_flip") if alternative.get(key) is not None and resolved.get(key) is not None and alternative[key] != resolved[key]
            )
            return {"first": False, "clicks": min(max(toggles, 1), max(presses, 1)), "converged": True, "ms": elapsed}
    return {"first": False, "clicks": None, "converged": True, "ms": elapsed}


def run_accuracy(trials: int, only: tuple[str, ...] = (), send_picks: bool = True) -> list[dict]:
    """Every scene and start class. M4: each trial sends its pick points (`send_picks`); a scene with `notes["old_default"]` (the
    peg in a hole) is also run with the payload a client sent before M4, as the row `<scene> [before M4]`."""
    rows = []
    for name, factory in guess.SCENES.items():
        if only and name not in only:
            continue
        scene = factory()
        assert scene.correct(scene.true_pose), name
        variants = [(name, None)]
        if scene.notes.get("old_default"):
            variants.append((f"{name} [before M4]", scene.notes["old_default"]))
        for label, payload in variants:
            rows.extend(_accuracy_rows(scene, label, payload, trials, send_picks))
        print(f"  measured {name}", file=sys.stderr, flush=True)
    return rows


def _accuracy_rows(scene: "guess.GuessScene", label: str, payload: dict | None, trials: int, send_picks: bool) -> list[dict]:
    rows = []
    name = scene.name
    for kind in scene.start_classes():
        rng = np.random.default_rng(_seed(name, kind))
        first = unreachable = not_converged = clicks = 0
        times, samples = [], []
        for _ in range(trials):
            start = guess.start_pose(scene, kind, rng)
            picks = guess.trial_picks(scene, rng)
            outcome = one_preview(scene, start, picks if send_picks else None, payload)
            first += outcome["first"]
            not_converged += not outcome["converged"]
            unreachable += outcome["clicks"] is None
            clicks += outcome["clicks"] or 0
            times.append(outcome["ms"])
            samples.append({"start": start, "pick_points": picks, "first": outcome["first"], "clicks": outcome["clicks"]})
        guess.set_pose(scene, scene.true_pose)
        rows.append({
            "scene": label, "group": scene.group, "kind": scene.kind, "seated": scene.seated, "start": kind, "trials": trials, "first": first,
            "clicks": clicks, "unreachable": unreachable, "not_converged": not_converged, "preview_ms": statistics.median(times), "samples": samples,
            "pick_points_sent": send_picks,
        })
    return rows


# ---- M4: the type the picks suggest ----------------------------------------------------

_TYPE_BEFORE_M4 = "coincident"  # both clients' type control started on Coincident before M4 (Flutter `kMateTypes.first`, VR `mate_type`)


def run_types(only: tuple[str, ...] = ()) -> list[dict]:
    """Per scene: the scene's own mate type, what `type: "auto"` suggests for its two picks, and whether a client starts on the right
    type before M4 (always Coincident) and after (the suggestion, else still Coincident)."""
    rows = []
    for name, factory in guess.SCENES.items():
        if only and name not in only:
            continue
        scene = factory()
        guess.set_pose(scene, scene.true_pose)
        answer = guess.preview(scene, type="auto")
        suggested = answer.get("suggested_type")
        after = suggested or _TYPE_BEFORE_M4
        truth = scene.payload["type"]
        rows.append({"scene": name, "type": truth, "suggested": suggested, "right_before": _TYPE_BEFORE_M4 == truth, "right_after": after == truth,
                     "auto_converged": answer["converged"], "auto_correct": bool(answer["converged"] and scene.correct(guess.shown_transform(answer)))})
    return rows


def print_types(rows: list[dict]) -> None:
    print("\n### M4: the type the picks suggest (`type: \"auto\"`, part at its true pose)\n")
    print("Before M4 both clients started on Coincident; after, on the suggestion (Coincident when there is none).\n")
    print("| scene | its type | suggested | right type first, before | after | auto preview at the truth is right |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['scene']} | {r['type']} | {r['suggested'] or 'none'} | {'yes' if r['right_before'] else 'no'} | {'yes' if r['right_after'] else 'no'} | "
              f"{'yes' if r['auto_correct'] else ('no' if r['suggested'] else 'n/a')} |")
    before, after = sum(r["right_before"] for r in rows), sum(r["right_after"] for r in rows)
    harmed = [r["scene"] for r in rows if r["right_before"] and not r["right_after"]]
    print(f"\nRight type first: {before} of {len(rows)} scenes before, {after} after; harmed: {', '.join(harmed) or 'none'}.")


def _share(rows: list[dict]) -> str:
    trials = sum(r["trials"] for r in rows)
    return "n/a" if not trials else f"{100.0 * sum(r['first'] for r in rows) / trials:.1f}%"


def _clicks(rows: list[dict]) -> str:
    trials = sum(r["trials"] for r in rows)
    return "n/a" if not trials else f"{sum(r['clicks'] for r in rows) / trials:.3f}"


def print_accuracy(rows: list[dict]) -> None:
    trials = rows[0]["trials"] if rows else 0
    classes = list(guess.START_CLASSES)
    print(f"\n### First-time accuracy of an unnamed mate ({trials} trials per scene and start class)\n")
    print("Right first time, per start class; `all` = near + medium + far (the Phase 4 bench's three classes). Extra clicks per mate over the same three.\n")
    print("| scene | set | kind | " + " | ".join(classes) + " | all | extra clicks | no way to the truth | median preview ms |")
    print("|---|---|---|" + "---|" * (len(classes) + 4))
    by_scene: dict[str, list[dict]] = {}
    for r in rows:
        by_scene.setdefault(r["scene"], []).append(r)
    for name, scene_rows in by_scene.items():
        by_class = {r["start"]: r for r in scene_rows}
        three = [r for r in scene_rows if r["start"] != "upside_down"]
        cells = [_share([by_class[c]]) if c in by_class else "n/a" for c in classes]
        unreachable = sum(r["unreachable"] for r in scene_rows)
        first = scene_rows[0]
        kind = first["kind"] + (", seated" if first["seated"] else "")
        print(f"| {name} | {first['group']} | {kind} | " + " | ".join(cells) + f" | {_share(three)} | {_clicks(three)} | {unreachable} | {_ms(statistics.median(r['preview_ms'] for r in scene_rows))} |")

    def pick(group=None, kind=None, start=None, three=False, seated=None):
        return [
            r for r in rows
            if (group is None or r["group"] == group) and (kind is None or r["kind"] == kind) and (start is None or r["start"] == start)
            and (not three or r["start"] != "upside_down") and (seated is None or r["seated"] == seated)
        ]

    peg_rows = [r for r in rows if r["kind"] == "peg"]
    rows = [r for r in rows if r["kind"] != "peg"]  # M0's population: the summaries below stay comparable with M0's

    print("\n| summary | right first time | extra clicks per mate |")
    print("|---|---|---|")
    summaries = [
        ("Phase 4 set (9 mates), near + medium + far", pick(group="phase4", three=True)),
        ("Phase 4 set, near", pick(group="phase4", start="near")),
        ("Phase 4 set, medium", pick(group="phase4", start="medium")),
        ("Phase 4 set, far", pick(group="phase4", start="far")),
        ("Same-facing distances (all 6 scenes), near + medium + far", pick(kind="same_facing", three=True)),
        ("Same-facing, free part (4 scenes), near + medium + far", pick(kind="same_facing", three=True, seated=False)),
        ("Same-facing, seated (2 scenes), near + medium + far", pick(kind="same_facing", three=True, seated=True)),
        ("Same-facing insets only, near + medium + far", [r for r in pick(kind="same_facing", three=True) if r["scene"].startswith("inset")]),
        ("Same-facing overhangs only, near + medium + far", [r for r in pick(kind="same_facing", three=True) if r["scene"].startswith("overhang")]),
        ("Upside-down starts, every free scene (11)", pick(start="upside_down")),
        ("Upside-down starts, same-facing distances (4)", pick(start="upside_down", kind="same_facing")),
        ("Upside-down starts, the other mates (7)", [r for r in pick(start="upside_down") if r["kind"] != "same_facing"]),
        ("Every scene and start class", rows),
    ]
    if peg_rows:
        summaries += [
            ("M4 peg in a hole, Peg in hole (the suggestion), every start class", [r for r in peg_rows if "[before M4]" not in r["scene"]]),
            ("M4 peg in a hole, Coincident on the edges (before M4), every start class", [r for r in peg_rows if "[before M4]" in r["scene"]]),
        ]
    for label, subset in summaries:
        print(f"| {label} | {_share(subset)} | {_clicks(subset)} |")


# ---- entry ----------------------------------------------------------------------


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("what", choices=("scaling", "accuracy", "all"))
    parser.add_argument("--quick", action="store_true", help="scaling: the small sizes only")
    parser.add_argument("--trials", type=int, default=60, help="accuracy: trials per scene and start class (default 60, as Phase 4)")
    parser.add_argument("--family", action="append", default=[], help="scaling: only this family (chain, chain+bolts, frame, linkage; repeatable)")
    parser.add_argument("--scene", action="append", default=[], help="accuracy: only this scene (repeatable)")
    parser.add_argument("--no-pick-points", action="store_true", help="accuracy: do not send pick_points (M4 sends them by default)")
    parser.add_argument("--json", help="also write the raw results here")
    args = parser.parse_args(argv)
    info = machine()
    print("## M0 mates benchmark\n")
    print(f"Machine: {info['cpu']}, {info['cores']} cores, {info['ram_gb']} GB, {info['os']}; Python {info['python']}, numpy {info['numpy']}, OCCT {info['occt']}. Date: {info['date']}.")
    out = {"machine": info, "caps": dict(zip(("members", "rows"), client_caps()))}
    if args.what in ("scaling", "all"):
        out["scaling"] = run_scaling(args.quick, tuple(args.family))
        print_scaling(out["scaling"], client_caps())
    if args.what in ("accuracy", "all"):
        out["accuracy"] = run_accuracy(args.trials, tuple(args.scene), send_picks=not args.no_pick_points)
        print_accuracy(out["accuracy"])
        out["types"] = run_types(tuple(args.scene))
        print_types(out["types"])
    if args.json:
        Path(args.json).write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
