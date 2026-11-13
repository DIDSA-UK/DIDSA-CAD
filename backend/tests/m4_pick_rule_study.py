"""M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`, "M4 results"): the study of the pick-point tie-break rules that did NOT ship.
Not collected by pytest. Run from `backend/` in the backend conda env:

    CAD_API_KEY=test-api-key python -m tests.m4_pick_rule_study dump OUT.json [--trials 60]   # replays every accuracy trial (a few minutes)
    python -m tests.m4_pick_rule_study evaluate OUT.json                                    # every candidate rule, per scene and start class
    python -m tests.m4_pick_rule_study evaluate-view OUT.json                               # the view-direction rules (two camera models)
    python -m tests.m4_pick_rule_study selectors OUT.json                                   # "a rule per kind of request": its upper bound

`dump` replays the accuracy benchmark's trials (`tests/bench_mates_m0.py`, same seeds, same starts and pick points) and stores, per trial, the
start geometry, whether the shown answer was right, and EVERY alternative the preview returned (each branch combination solved from the same
start) with its geometry: the picked directions, the plane / axis origin and both pick points in world space. `evaluate` then lets each
candidate rule choose among those alternatives (a rule that returns nothing keeps the shown answer) and counts right-first-time per row. This is
the same as running the rule in the server for these scenes (one new mate on a free part against a fixed base, where the shown answer is one of
the alternatives), without a server build per idea. `mutual-over` reads the base's face extents from the scenes' fixed 120 x 80 x 20 base.
"""
import json
import math
import sys
from collections import defaultdict

import numpy as np

def dump(out_path: str, trials: int = 60) -> None:
    import tests.conftest  # noqa: F401
    from app.document.assembly import apply_transform_to_point
    from app.document.assembly_group import mate_world_geometries
    from app.document.models import Mate, MateType
    from app.document.router import _mate_entity_ref_to_domain
    from app.document.schemas import MateEntityRefResponse
    from app.document.store import get_document
    from tests import mate_first_guess_scenes as guess
    from tests.bench_mates_m0 import _seed

    def geom(scene, mate, transform, picks):
        guess.set_pose(scene, transform)
        document = get_document()
        d, f = mate_world_geometries(document, document.parts[scene.root], mate)
        rt = guess._rt(transform)

        def vec(g):
            n = g.plane.normal if g.plane is not None else g.direction
            return None if n is None else [float(x) for x in n]

        return {
            "nd": vec(d), "nf": vec(f),
            "kind_d": "plane" if d.plane is not None else ("axis" if d.axis_origin is not None else "point"),
            "kind_f": "plane" if f.plane is not None else ("axis" if f.axis_origin is not None else "point"),
            "pd": [float(x) for x in apply_transform_to_point(rt, tuple(picks[guess.DRIVEN]))],
            "pf": [float(x) for x in picks[guess.FIXED]],  # the fixed part sits at the origin, unturned
        }

    rows = []
    for name, factory in guess.SCENES.items():
        scene = factory()
        if scene.payload["type"] not in ("coincident", "concentric", "parallel", "distance", "angle"):
            continue  # (the peg in a hole is the type rule's scene)
        refs = [_mate_entity_ref_to_domain(MateEntityRefResponse(**r)) for r in scene.payload["references"]]
        mate = Mate(id="probe", type=MateType(scene.payload["type"]), references=refs, value=scene.payload.get("value"))
        for kind in scene.start_classes():
            rng = np.random.default_rng(_seed(name, kind))
            for t in range(trials):
                start = guess.start_pose(scene, kind, rng)
                picks = guess.trial_picks(scene, rng)
                guess.set_pose(scene, start)
                ghost = guess.preview(scene)
                shown = guess.shown_transform(ghost) if ghost["converged"] else None
                alts = []
                for a in ghost.get("alternatives") or []:
                    tr = guess.shown_transform(a)
                    alts.append({"alignment": a.get("alignment"), "flip": a.get("secondary_flip"), "cost": a.get("movement_cost"),
                                 "correct": bool(tr is not None and scene.correct(tr)), "g": geom(scene, mate, tr, picks)})
                rows.append({"scene": name, "kind": scene.kind, "seated": scene.seated, "start": kind, "trial": t,
                             "first": bool(shown is not None and scene.correct(shown)), "resolved": ghost.get("resolved"),
                             "start_g": geom(scene, mate, start, picks), "value": scene.payload.get("value"), "type": scene.payload["type"], "alts": alts})
            guess.set_pose(scene, scene.true_pose)
        print("dumped", name, file=sys.stderr, flush=True)
    with open(out_path, "w") as handle:
        json.dump(rows, handle)




def v(x):
    return np.array(x, float)


def failure_kind(r):
    if r["first"]:
        return "ok"
    truth = [a for a in r["alts"] if a["correct"]]
    if not truth:
        return "unreachable"
    t = truth[0]
    res = r["resolved"] or {}
    wrong = []
    if t["alignment"] is not None and res.get("alignment") != t["alignment"]:
        wrong.append("alignment")
    if t["flip"] is not None and res.get("secondary_flip") != t["flip"]:
        wrong.append("side")
    return "+".join(wrong) or "other"


def start_cos(r):
    g = r["start_g"]
    if g["nd"] is None or g["nf"] is None:
        return None
    return float(v(g["nd"]) @ v(g["nf"]))


# ---------- candidate rules: each returns the chosen alternative or None (= keep the default) ----------

def default(r):
    return None


def towards(a):  # driven picked face points towards the fixed pick
    g = a["g"]
    return float(v(g["nd"]) @ (v(g["pf"]) - v(g["pd"]))) > 1e-6


def mutual(a):
    g = a["g"]
    return towards(a) and float(v(g["nf"]) @ (v(g["pd"]) - v(g["pf"]))) > 1e-6


def pickdist(a):
    g = a["g"]
    return float(np.linalg.norm(v(g["pd"]) - v(g["pf"])))


def plane_plane(r):
    return r["start_g"]["kind_d"] == "plane" and r["start_g"]["kind_f"] == "plane"


def make_align_tie(pred, tie_deg=45.0, types=("distance",), planes_only=True):
    """When the start's two directions are within `tie_deg` of perpendicular (the alignment is not decided by the start), prefer
    among the alternatives those satisfying `pred`; among them, the nearest (they are sorted nearest first)."""
    def rule(r):
        if r["type"] not in types or (planes_only and not plane_plane(r)):
            return None
        c = start_cos(r)
        if c is None or abs(c) >= math.cos(math.radians(90 - tie_deg)):
            return None
        good = [a for a in r["alts"] if pred(a)]
        return good[0] if good and len(good) < len(r["alts"]) else None
    return rule


def make_align_override(pred, types=("distance",)):
    """Always prefer alternatives satisfying pred (plane-plane only)."""
    def rule(r):
        if r["type"] not in types or not plane_plane(r):
            return None
        good = [a for a in r["alts"] if pred(a)]
        return good[0] if good and len(good) < len(r["alts"]) else None
    return rule


def side_tie_pickdist(rel=0.10):
    """Same-facing distance: among the two sides of the resolved alignment, when their movement costs are within rel, choose the
    one whose pick points are nearer."""
    def rule(r):
        if r["type"] != "distance" or not plane_plane(r):
            return None
        res = r["resolved"] or {}
        same = [a for a in r["alts"] if a["alignment"] == res.get("alignment")]
        if len(same) != 2 or res.get("alignment") != "aligned":
            return None
        c0, c1 = same[0]["cost"], same[1]["cost"]
        if abs(c0 - c1) > rel * max(c0, c1):
            return None
        d0, d1 = pickdist(same[0]), pickdist(same[1])
        if abs(d0 - d1) < 1e-6:
            return None
        return same[0] if d0 < d1 else same[1]
    return rule


def side_start_pick(r):
    """Same-facing distance: the side the driven PICK POINT is on at the start (instead of the face origin)."""
    if r["type"] != "distance" or not plane_plane(r):
        return None
    res = r["resolved"] or {}
    if res.get("alignment") != "aligned":
        return None
    g = r["start_g"]
    off = float((v(g["pd"]) - v(g["pf"])) @ v(g["nf"]))
    want = off < 0  # secondary_flip True = negative side
    for a in r["alts"]:
        if a["alignment"] == "aligned" and a["flip"] == want:
            return a
    return None


RULES = {
    "default": default,
    "align-tie45-towards": make_align_tie(towards),
    "align-tie45-mutual": make_align_tie(mutual),
    "align-tie30-towards": make_align_tie(towards, 30.0),
    "align-tie45-towards-all-plane-types": make_align_tie(towards, types=("distance", "parallel", "coincident")),
    "align-override-towards": make_align_override(towards),
    "align-override-mutual": make_align_override(mutual),
    "side-tie10-pickdist": side_tie_pickdist(0.10),
    "side-start-pick": side_start_pick,
}


# base (fixed) faces' extents, world (the base is at the origin, 120 x 80 x 20)
def over_fixed_face(a):
    g = a["g"]; n = v(g["nf"]); p = v(g["pd"])
    lo, hi = np.zeros(3), np.array([120.0, 80.0, 20.0])
    k = int(np.argmax(abs(n)))
    return all(lo[i] - 1e-6 <= p[i] <= hi[i] + 1e-6 for i in range(3) if i != k)

def mutual_over(a):
    return mutual(a) and over_fixed_face(a)


RULES["align-tie45-mutual-over"] = make_align_tie(mutual_over)
RULES["align-override-mutual-over"] = make_align_override(mutual_over)

def evaluate(rule):
    cells = defaultdict(lambda: [0, 0])
    for r in ROWS:
        chosen = rule(r)
        ok = r["first"] if chosen is None else chosen["correct"]
        cells[(r["scene"], r["start"])][0] += ok
        cells[(r["scene"], r["start"])][1] += 1
    return cells


def report(path: str) -> None:
    global ROWS
    ROWS = json.load(open(path))
    rows = ROWS
    base = evaluate(default)
    print("failure kinds (baseline):")
    fk = defaultdict(lambda: defaultdict(int))
    for r in rows:
        fk[(r["scene"], r["start"])][failure_kind(r)] += 1
    for k in sorted(fk):
        print(" ", k, dict(fk[k]))
    for name, rule in RULES.items():
        cells = evaluate(rule)
        helped = sum(max(0, cells[k][0] - base[k][0]) for k in cells)
        gains = {k: cells[k][0] - base[k][0] for k in cells if cells[k][0] != base[k][0]}
        worse = {k: d for k, d in gains.items() if d < 0}
        tot = sum(c[0] for c in cells.values()); n = sum(c[1] for c in cells.values())
        three = [k for k in cells if k[1] != "upside_down"]
        p4 = ["stack", "parallel", "pin-in-post", "axis-distance-25", "inset-10", "overhang-3", "gap-6-above", "gap-6-under", "vertex-6-above"]
        p4s = sum(cells[k][0] for k in three if k[0] in p4) / sum(cells[k][1] for k in three if k[0] in p4)
        print(f"\n{name}: all {100*tot/n:.1f}%  phase4 3-class {100*p4s:.1f}%  rows worse: {len(worse)}  changes: {gains}")


# ---- the view direction (follow-up spike, 2026-11-13) ----------------------------------------------------------------------------
#
# The benchmark has no camera, so each trial gets one, seeded per trial. Two models of where the user was looking (v = the direction the
# camera looks along, world, unit):
#   visible   - uniform over the directions from which every picked FLAT face is front-facing at the START pose (v . n < -0.1): you can only
#               click a face you can see. Nothing else, so it knows nothing about the truth. Occlusion is ignored.
#   look_down - `visible`, and the camera looks down at the table (v.z < -0.3): an ASSUMPTION about how people sit at a desk.
# A trial where no such view exists (the two picked faces point away from each other at the start: a user would have turned the view
# between the picks) keeps the shown answer.


def _view_seed(r) -> int:
    return sum(ord(c) * (i + 1) for i, c in enumerate(f"view/{r['scene']}/{r['start']}/{r['trial']}")) % (2**31)


def view_dir(r, model: str):
    rng = np.random.default_rng(_view_seed(r))
    g = r["start_g"]
    normals = [v(g[k]) for k, kind in (("nd", g["kind_d"]), ("nf", g["kind_f"])) if kind == "plane"]
    for _ in range(10000):
        d = rng.normal(size=3)
        d /= np.linalg.norm(d)
        if all(d @ n < -0.1 for n in normals) and (model != "look_down" or d[2] < -0.3):
            return d
    return None


def _align_tie45(r) -> bool:
    c = start_cos(r)
    return c is not None and abs(c) < math.cos(math.radians(45))


def _choose(alts, pred):
    good = [a for a in alts if pred(a)]
    return good[0] if good and len(good) < len(alts) else None


def _faces_camera(a, d) -> bool:
    return float(v(a["g"]["nd"]) @ d) < 0


def _camera_side(a, d) -> bool:
    g = a["g"]
    offset = float((v(g["pd"]) - v(g["pf"])) @ v(g["nf"]))
    return offset * float(-d @ v(g["nf"])) > 0


def _resolved_aligned(r) -> bool:
    return (r["resolved"] or {}).get("alignment") == "aligned"


def _aligned_alts(r):
    return [a for a in r["alts"] if a["alignment"] == "aligned"]


VIEW_RULES = {
    "V1 alignment tie (45 deg): the clicked face faces the camera": lambda r, d: _choose(r["alts"], lambda a: _faces_camera(a, d)) if _align_tie45(r) else None,
    "V2 alignment tie (45 deg): the clicked face faces away": lambda r, d: _choose(r["alts"], lambda a: not _faces_camera(a, d)) if _align_tie45(r) else None,
    "V3 same-facing distance: the camera's side of the fixed face": lambda r, d: _choose(_aligned_alts(r), lambda a: _camera_side(a, d)) if _resolved_aligned(r) else None,
    "V4 same-facing distance: the far side": lambda r, d: _choose(_aligned_alts(r), lambda a: not _camera_side(a, d)) if _resolved_aligned(r) else None,
}
VIEW_RULES["V5 V1, then V3"] = lambda r, d: VIEW_RULES["V1 alignment tie (45 deg): the clicked face faces the camera"](r, d) or VIEW_RULES["V3 same-facing distance: the camera's side of the fixed face"](r, d)

_PHASE4 = {"stack", "parallel", "pin-in-post", "axis-distance-25", "inset-10", "overhang-3", "gap-6-above", "gap-6-under", "vertex-6-above"}
_SAME_FACING_FREE = {"inset-10", "overhang-3", "inset-2", "overhang-25"}


def _cells(choose) -> dict:
    """`choose(row)` -> the alternative a rule picks, or None (the shown answer stays). Right first time per (scene, start)."""
    cells = defaultdict(lambda: [0, 0])
    for r in ROWS:
        chosen = choose(r)
        cells[(r["scene"], r["start"])][0] += r["first"] if chosen is None else chosen["correct"]
        cells[(r["scene"], r["start"])][1] += 1
    return cells


def _summary(cells, base) -> str:
    def share(keys):
        return 100.0 * sum(cells[k][0] for k in keys) / max(1, sum(cells[k][1] for k in keys))

    three = [k for k in cells if k[1] != "upside_down"]
    diff = {k: cells[k][0] - base[k][0] for k in cells if cells[k][0] != base[k][0]}
    worse = {k: d for k, d in diff.items() if d < 0}
    return (f"all {share(list(cells)):.1f}% | phase4 {share([k for k in three if k[0] in _PHASE4]):.1f}% | same-facing free "
            f"{share([k for k in three if k[0] in _SAME_FACING_FREE]):.1f}% | helped {sum(d for d in diff.values() if d > 0)} harmed "
            f"{-sum(worse.values())} in {len(worse)} rows | {diff}")


def plane_distance(r) -> bool:
    return r["type"] == "distance" and plane_plane(r)


def report_view(path: str) -> None:
    global ROWS
    ROWS = json.load(open(path))
    base = _cells(lambda r: None)
    for model in ("visible", "look_down"):
        dirs = {id(r): view_dir(r, model) for r in ROWS}
        print(f"\n## view model: {model} (trials with no possible view, kept as shown: {sum(d is None for d in dirs.values())})")
        for name, rule in VIEW_RULES.items():
            cells = _cells(lambda r: rule(r, dirs[id(r)]) if dirs[id(r)] is not None and plane_distance(r) else None)
            print(f"{name}: {_summary(cells, base)}")


# ---- "a rule per kind of request": what it could reach at best -------------------------------------------------------------------
#
# A selector picks one of the candidate rules (the pick-point rules above, the view rules with the `visible` model, or none) by what it
# can see in the request. `oracle_by_scene` lets it see the SCENE (which no request carries): the upper bound of the idea. The honest
# selectors see only the request: its type and picked geometry kinds (`by_request`), and also its value (`by_request_and_value`, which
# on these synthetic scenes separates insets from overhangs only because of the sizes chosen for them: overfitting, shown to say so).


def report_selectors(path: str) -> None:
    global ROWS
    ROWS = json.load(open(path))
    base = _cells(lambda r: None)
    dirs = {id(r): view_dir(r, "visible") for r in ROWS}
    candidates = {"none": lambda r: None}
    candidates.update({name: rule for name, rule in RULES.items() if name != "default"})
    for name, rule in VIEW_RULES.items():
        candidates[name] = (lambda rule: lambda r: rule(r, dirs[id(r)]) if dirs[id(r)] is not None and plane_distance(r) else None)(rule)
    outcome = {name: {} for name in candidates}
    for name, choose in candidates.items():
        for r in ROWS:
            chosen = choose(r)
            outcome[name][id(r)] = r["first"] if chosen is None else chosen["correct"]

    def selector(key):
        groups = defaultdict(list)
        for r in ROWS:
            groups[key(r)].append(r)
        picked = {}
        for group, rows in groups.items():
            picked[group] = max(candidates, key=lambda n: (sum(outcome[n][id(r)] for r in rows), n == "none"))
        cells = defaultdict(lambda: [0, 0])
        for r in ROWS:
            cells[(r["scene"], r["start"])][0] += outcome[picked[key(r)]][id(r)]
            cells[(r["scene"], r["start"])][1] += 1
        return cells, picked

    for label, key in (
        ("oracle_by_scene (sees the scene: the idea's upper bound)", lambda r: r["scene"]),
        ("by_request (type + picked kinds)", lambda r: (r["type"], r["start_g"]["kind_d"], r["start_g"]["kind_f"])),
        ("by_request_and_value (+ the value: overfits these scenes)", lambda r: (r["type"], r["start_g"]["kind_d"], r["start_g"]["kind_f"], r["value"])),
    ):
        cells, picked = selector(key)
        print(f"\n{label}: {_summary(cells, base)}")
        for group, name in sorted(picked.items(), key=str):
            if name != "none":
                print(f"   {group}: {name}")


ROWS: list = []

if __name__ == "__main__":
    if sys.argv[1] == "dump":
        dump(sys.argv[2], int(sys.argv[sys.argv.index("--trials") + 1]) if "--trials" in sys.argv else 60)
    elif sys.argv[1] == "evaluate-view":
        report_view(sys.argv[2])
    elif sys.argv[1] == "selectors":
        report_selectors(sys.argv[2])
    else:
        report(sys.argv[2])
