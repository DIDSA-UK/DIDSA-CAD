"""M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`, "M4 results"): the study of the pick-point tie-break rules that did NOT ship.
Not collected by pytest. Run from `backend/` in the backend conda env:

    CAD_API_KEY=test-api-key python -m tests.m4_pick_rule_study dump OUT.json [--trials 60]   # replays every accuracy trial (a few minutes)
    python -m tests.m4_pick_rule_study evaluate OUT.json                                    # every candidate rule, per scene and start class

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


ROWS: list = []

if __name__ == "__main__":
    if sys.argv[1] == "dump":
        dump(sys.argv[2], int(sys.argv[sys.argv.index("--trials") + 1]) if "--trials" in sys.argv else 60)
    else:
        report(sys.argv[2])
