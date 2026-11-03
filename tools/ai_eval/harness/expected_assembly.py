"""Answer keys and scorer for the Assembly-mode sketches (sketches/asm_*).

Each key comes from a reference model built by sketches/source/models.py, which writes assembly_keys.json next
to this file: every distinct part's geometry, and every placed component's centroid and volume. For a drawing
whose author has not checked that model's reading, `confirmed` is False and a pass means "matches this reading".

A run scores per part and for the assembly, orientation-free:
- parts: each distinct part in the key is matched to a built part by volume (1%), sorted bounding box (1 mm)
  and the cylinder radii it must have. Extra parts count against it.
- assembly: solid count = component count, sorted bounding box, the union volume (parts that overlap make it
  smaller than the sum), and placement: each component's distance from the assembly's centroid, sorted, within
  1 mm of the key's. A nested sub-assembly is scored flattened.

Usage: expected_assembly.py <sketch> <run_dir>
"""
import glob
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEYS = json.load(open(os.path.join(HERE, "assembly_keys.json")))

SKETCHES = {
    "asm_pin_block": {
        "asm": "A", "images": ["asm_pin_block.png"], "confirmed": True,
        "reading": "drawn from the reference model: 80x50x20 block with a d20 hole, headed pin (d20 x 40 shank, "
        "d32 x 6 head) through it, head on the top face",
    },
    "asm_block_pins": {
        "asm": "D", "images": ["asm_block_pins.jpg"], "confirmed": False,
        "reading": "160x80x30 block, 4x d10 thru on 120x40 centres 20 in from each edge; 4 pins d30 x 10 head, "
        "d10 x 30 shank (40 overall), shank down in each hole, head on the top face",
    },
    "asm_wheel_bracket": {
        "asm": "B", "images": ["asm_wheel_bracket_1.png", "asm_wheel_bracket_2.png"], "confirmed": True,
        "reading": "drawn from the reference model: base plate, two uprights 40 apart, axle, wheel",
    },
    "asm_caster": {
        "asm": "C", "images": ["asm_caster_1.png", "asm_caster_2.png", "asm_caster_3.png"], "confirmed": True,
        "reading": "drawn from the reference model: 8 parts, wheel + bushing a sub-assembly (scored flattened)",
    },
}

VOL_TOL, LEN_TOL = 0.01, 1.0


def key(sketch):
    s = SKETCHES[sketch]
    asm = KEYS["assemblies"][s["asm"]]
    ids = [c[0] for c in asm["components"]]
    distinct = sorted(set(ids), key=ids.index)
    return s, asm, {pid: dict(KEYS["parts"][pid], qty=ids.count(pid)) for pid in distinct}


def part_matches(want, got):
    if got.get("solids") != 1:
        return False
    if abs(got["volume_mm3"] - want["volume"]) > VOL_TOL * want["volume"]:
        return False
    if any(abs(a - b) > LEN_TOL for a, b in zip(sorted(got["bbox_size"]), sorted(want["bbox"]))):
        return False
    have = [float(r) for r in got.get("cylinder_radii", {})]
    return all(any(abs(r - h) < 0.05 for h in have) for r in want["radii"])


def radial_profile(points, vols):
    tot = sum(vols)
    c = [sum(p[i] * v for p, v in zip(points, vols)) / tot for i in range(3)]
    return sorted(math.dist(p, c) for p in points)


def score(sketch, run):
    s, asm, parts = key(sketch)
    out = {"confirmed": s["confirmed"]}
    res_path = os.path.join(run, "assembly_result.json")
    res = json.load(open(res_path)) if os.path.exists(res_path) else {}
    man_path = os.path.join(run, "manifest.json")
    man = json.load(open(man_path)) if os.path.exists(man_path) else {}
    out["manifest_parts"] = len(man.get("parts", []))
    out["expected_parts"] = len(parts)
    out["retries"] = sum(1 for p in res.get("parts", []) if p.get("retried")) + int(
        bool(res.get("assembly", {}).get("retried")))
    if res.get("stopped"):
        out["stopped"] = res["stopped"]

    built = []
    for f in sorted(glob.glob(os.path.join(run, "part_*_geometry.json"))):
        g = json.load(open(f))
        if "volume_mm3" in g:
            built.append((os.path.basename(f)[:7], g))
    unused = list(built)
    matched, missing = [], []
    for pid, want in parts.items():
        hit = next((b for b in unused if part_matches(want, b[1])), None)
        if hit:
            unused.remove(hit)
            matched.append(want["name"])
        else:
            missing.append(want["name"])
    out["parts_ok"] = f"{len(matched)}/{len(parts)}"
    if missing:
        out["parts_wrong"] = missing
    if unused:
        out["parts_extra_or_wrong"] = [b[0] for b in unused]

    a = res.get("assembly", {})
    out["assembly_outcome"] = a.get("outcome")
    gpath = os.path.join(run, "assembly_geometry.json")
    if os.path.exists(gpath):
        g = json.load(open(gpath))
        comps = asm["components"]
        out["solids"] = f"{g.get('solids')}/{len(comps)}"
        bb = sorted(g["bbox_size"])
        out["bbox"] = [round(v, 1) for v in bb]
        out["bbox_ok"] = all(abs(x - y) <= LEN_TOL for x, y in zip(bb, sorted(asm["bbox"])))
        u = g.get("union_volume_mm3")
        out["union_err_pct"] = None if u is None else round(100 * (u - asm["union_volume"]) / asm["union_volume"], 2)
        summed = sum(p["volume_mm3"] for p in g.get("per_solid", []))
        out["overlap_pct"] = None if not u or not summed else round(100 * (summed - u) / summed, 2)
        place_ok = False
        if g.get("solids") == len(comps):
            want = radial_profile([c[1] for c in comps], [c[2] for c in comps])
            have = radial_profile([p["centroid"] for p in g["per_solid"]], [p["volume_mm3"] for p in g["per_solid"]])
            out["placement_max_err"] = round(max(abs(x - y) for x, y in zip(want, have)), 2)
            place_ok = out["placement_max_err"] <= LEN_TOL
        out["assembly_ok"] = bool(
            g.get("solids") == len(comps) and out["bbox_ok"] and out["union_err_pct"] is not None
            and abs(out["union_err_pct"]) <= 100 * VOL_TOL and place_ok)
    else:
        out["assembly_ok"] = False
    out["pass"] = not missing and not unused and out["assembly_ok"]
    return out


if __name__ == "__main__":
    print(json.dumps(score(sys.argv[1], sys.argv[2])))
