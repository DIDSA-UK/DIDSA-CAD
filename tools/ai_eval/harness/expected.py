"""Answer keys for the sketches in ../sketches/, and the scorer for a run's geometry.json.

Each key is one reading of its drawing. `confirmed` says whether the drawing's author has checked that
reading; until they have, a "pass" means "matches this reading". Checks are orientation-free: volume, the
sorted bounding box, solid count, cylinder radii that must be present, and optional exact face counts.
Where a drawing allows two readings, both are listed and either passes.

Usage: expected.py <sketch> <geometry.json>   (geometry.json from inspect_step.py)
"""
import json
import math
import sys

pi = math.pi
Z_SECTION = 342 - 2 * 36 * (1 - pi / 4) + 2 * 9 * (1 - pi / 4)  # Z-bracket section area, mm^2
SLOT = 150 * 20 + pi * 10**2
TUBE_30 = pi * (15**2 - 12**2)
TUBE_40 = pi * (20**2 - 18**2)
FLANGE = pi * (40**2 - 12**2) * 10 - 8 * pi * 4**2 * 10

EXPECTED = {
    "zbracket": {
        "confirmed": False,
        "reading": "Z section 3 thk, bends R3 inside / R6 outside, flanges 30 and 40 to the web's far face, "
        "50 overall height, 200 long",
        "volumes": [Z_SECTION * 200],
        "bboxes": [[50, 67, 200]],
        "radii": [3, 6],
    },
    "slot_bracket": {
        "confirmed": False,
        "reading": "the Z-bracket plus 4x d5 holes 8 from each flange's free edge and 8 from each end, and an "
        "R10 slot through the web, centres 150 apart, centred along the length, 25 up from the bottom",
        "volumes": [Z_SECTION * 200 - 4 * pi * 2.5**2 * 3 - SLOT * 3],
        "bboxes": [[50, 67, 200]],
        "radii": [3, 6, 2.5, 10],
    },
    "flanged_bend": {
        "confirmed": False,
        "reading": "d30 x 3 wall tube, R100 centreline bend, both 400s to centrelines (horizontal from the flange's "
        "back face, or from its front face - both accepted), flange d80 x 10 with a d24 bore and 8x d8 on a "
        "60 PCD",
        "volumes": [FLANGE + TUBE_30 * (290 + pi / 2 * 100 + 300), FLANGE + TUBE_30 * (300 + pi / 2 * 100 + 300)],
        "bboxes": [[80, 415, 440], [80, 425, 440]],
        "radii": [12, 15, 40, 4],
    },
    "tube_3d": {
        "confirmed": False,
        "reading": "d40 x 2 wall tube, three legs along three axes: 250 to the first bend's centreline (R50), "
        "200 between the first and last legs' centrelines (R100), 300 from the middle leg's centreline to "
        "the end; bend radii to centrelines",
        "volumes": [TUBE_40 * (200 + pi / 2 * 50 + 50 + pi / 2 * 100 + 200)],
        "bboxes": [[240, 270, 320]],
        "radii": [18, 20],
    },
    "rect_round": {
        "confirmed": False,
        "reading": "solid transition, 200 long, from an 80 wide x 100 high rectangle to a d40 round end on the "
        "same axis (the d40 is the round end, not a bore: no hidden lines show one)",
        # Plain OCCT ThruSections volume; the backend's own loft comes out about 3% smaller (seen in testing).
        "volumes": [832057.8],
        "vol_tol": 0.05,
        "faces_exact": {"plane": 2, "cylinder": 0},
        "bboxes": [[80, 100, 200]],
        "radii": [],
    },
    "notch_block": {
        "confirmed": False,
        "reading": "200 x 80 x 100 block, a 40 x 40 x 50 deep notch at the top front right corner, R5 on the "
        "back right vertical edge only",
        "volumes": [200 * 100 * 80 - 40 * 50 * 40 - (1 - pi / 4) * 25 * 100],
        "bboxes": [[80, 100, 200]],
        "radii": [5],
    },
    "z_noheight": {
        "confirmed": False,
        "reading": "the Z-bracket with no height dimension anywhere: the right behaviour is to ask for it, so "
        "this sketch is scored on the first reply, not on geometry",
        "asks_for": "height",
    },
}


def score(name, g, vol_tol=0.01, bbox_tol=1.0):
    e = EXPECTED[name]
    out = {}
    if "volume_mm3" not in g:
        return {"built": False, "pass": False}
    out["solids_ok"] = g["solids"] == 1
    vols = [v for v in e["volumes"] if v]
    if vols:
        best = min(vols, key=lambda v: abs(g["volume_mm3"] - v))
        out["volume_err_pct"] = round(100 * (g["volume_mm3"] - best) / best, 2)
        out["volume_ok"] = abs(out["volume_err_pct"]) <= 100 * e.get("vol_tol", vol_tol)
    bb = sorted(g["bbox_size"])
    out["bbox"] = [round(b, 1) for b in bb]
    out["bbox_ok"] = any(all(abs(a - b) <= bbox_tol for a, b in zip(bb, ref)) for ref in e["bboxes"])
    have = {float(r) for r in g.get("cylinder_radii", {})}
    out["missing_radii"] = [r for r in e["radii"] if not any(abs(r - h) < 0.05 for h in have)]
    for kind, n in e.get("faces_exact", {}).items():
        if g["faces"].get(kind, 0) != n:
            out.setdefault("face_mismatch", []).append(f"{kind}: {g['faces'].get(kind, 0)} != {n}")
    out["pass"] = (
        not out.get("face_mismatch")
        and out["solids_ok"]
        and out.get("volume_ok", True)
        and out["bbox_ok"]
        and not out["missing_radii"]
    )
    return out


if __name__ == "__main__":
    print(json.dumps(score(sys.argv[1], json.load(open(sys.argv[2])))))
