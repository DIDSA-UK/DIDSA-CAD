"""N1a: the source of `tests/data/coaxial_signature_vectors.json` (read by tests/test_coaxial_signature_rules.py). Every expectation is set by hand here, never
recorded from the code. Not a test module (the name does not match `test_*.py`). Regenerate from backend/:
    python tests/coaxial_signature_vectors_source.py tests/data/coaxial_signature_vectors.json"""
import json, sys

D = 30.0  # body diagonal (mm) for every case


def cyl(r, z=5.0, x=0.0, y=0.0, axis=(0, 0, 1), sized=True):
    f = {"kind": "face", "position": [x, y, z], "surface_kind": "cylinder", "direction": list(axis), "area": 100.0, "body_diagonal": D}
    if sized:
        f["radius"] = r
    return f


def cone(a, z=5.0, sized=True):
    f = {"kind": "face", "position": [0, 0, z], "surface_kind": "cone", "direction": [0, 0, 1], "area": 100.0, "body_diagonal": D}
    if sized:
        f["half_angle"] = a
    return f


def torus(minor, major, z=10.0):
    return {"kind": "face", "position": [0, 0, z], "surface_kind": "torus", "direction": [0, 0, 1], "area": 50.0, "body_diagonal": D,
            "radius": minor, "major_radius": major}


def plane(nz, z):
    return {"kind": "face", "position": [0, 0, z], "surface_kind": "plane", "direction": [0, 0, nz], "area": 300.0, "body_diagonal": D}


tube = lambda bore=4.0, outer=10.0, sized=True: [cyl(outer, sized=sized), cyl(bore, sized=sized), plane(1, 10.0), plane(-1, 0.0)]
shaft = [cyl(3.0, z=25.0), cyl(5.0, z=15.0), cyl(8.0, z=5.0)]

cases = [
    ("tube: the bore's index now names the outer cylinder", cyl(4.0), 0, tube(), ("followed", 1, "nearest_radius")),
    ("tube: the outer cylinder's index now names the bore", cyl(10.0), 1, tube(), ("followed", 0, "nearest_radius")),
    ("tube: the bore's index still names the bore", cyl(4.0), 1, tube(), ("ok", 1, "")),
    ("tube: the bore's index now names a plane", cyl(4.0), 2, tube(), ("followed", 1, "nearest_radius")),
    ("stepped shaft: R5's index names R8", cyl(5.0, z=15.0), 2, shaft, ("followed", 1, "nearest_radius")),
    ("stepped shaft: R5's index names R3", cyl(5.0, z=15.0), 0, shaft, ("followed", 1, "nearest_radius")),
    ("stepped shaft: R3's index names R5", cyl(3.0, z=25.0), 1, shaft, ("followed", 0, "nearest_radius")),
    ("stepped shaft: R8's index names R3", cyl(8.0, z=5.0), 0, shaft, ("followed", 2, "nearest_radius")),
    ("stepped shaft: R5's index still right", cyl(5.0, z=15.0), 1, shaft, ("ok", 1, "")),
    ("radius edit: bore 4 -> 5 (outer 10), index still on the bore", cyl(4.0), 1, tube(bore=5.0), ("ok", 1, "")),
    ("radius edit: bore 4 -> 5 (outer 10), index renumbered onto the outer", cyl(4.0), 0, tube(bore=5.0), ("followed", 1, "nearest_radius")),
    ("radius edit: outer 10 -> 12 (bore 4), index renumbered onto the bore", cyl(10.0), 1, tube(outer=12.0), ("followed", 0, "nearest_radius")),
    # A limit, kept on purpose (N-4 (a) refuses the index only when a twin is CLEARLY nearer in size): the bore at 7 is nearer 4 than the outer 10 is, but
    # only 2x (errors 3 and 6, ratio 3 needed), so the index is kept as before N1a.
    ("radius edit too far: bore 4 -> 7 beside the outer 10, index on the outer: twin not clearly nearer, kept as before", cyl(4.0), 0, tube(bore=7.0), ("ok", 0, "")),
    ("radius edit too far: bore 4 -> 7 beside the outer 10, index on a plane: ambiguous", cyl(4.0), 2, tube(bore=7.0), ("lost", None, "ambiguous")),
    ("radius edit too far: bore 4 -> 7, index still on the bore: kept (no twin clearly nearer)", cyl(4.0), 1, tube(bore=7.0), ("ok", 1, "")),
    ("equal radii on one axis (a bore split by a groove), index on the outer: ambiguous",
     cyl(4.0, z=2.0), 0, [cyl(10.0), cyl(4.0, z=2.0), cyl(4.0, z=8.0)], ("lost", None, "ambiguous")),
    ("equal radii on one axis, index on the other R4: kept, as before (size cannot tell them apart)",
     cyl(4.0, z=2.0), 2, [cyl(10.0), cyl(4.0, z=2.0), cyl(4.0, z=8.0)], ("ok", 2, "")),
    ("radii within 1 % on one axis, index on the other: kept (not clearly a different size)", cyl(4.0), 0, [cyl(4.03), cyl(4.0)], ("ok", 0, "")),
    ("radii within 1 %, index on a plane: ambiguous", cyl(4.0), 2, [cyl(4.03), cyl(4.0), plane(1, 10.0)], ("lost", None, "ambiguous")),
    ("cone pair: 20 degrees' index names the 24 degree cone", cone(20.0), 1, [cone(20.0), cone(24.0, z=6.0)], ("followed", 0, "nearest_half_angle")),
    ("cone pair: 24 degrees' index names the 20 degree cone", cone(24.0, z=6.0), 0, [cone(20.0), cone(24.0, z=6.0)], ("followed", 1, "nearest_half_angle")),
    ("cone pair: index still right", cone(20.0), 0, [cone(20.0), cone(24.0, z=6.0)], ("ok", 0, "")),
    ("cone pair 0.3 degrees apart: ambiguous", cone(20.0), 2, [cone(20.0), cone(20.3, z=6.0), plane(1, 10.0)], ("lost", None, "ambiguous")),
    ("torus pair (inner and outer fillet of a ring, both R1): the major radius decides",
     torus(1.0, 4.0), 1, [torus(1.0, 4.0), torus(1.0, 9.0, z=10.2)], ("followed", 0, "nearest_radius")),
    # A signature saved before N1a (no radius) against a Body measured now (radii present): exactly today's rules.
    ("old signature: the bore's index on the outer: ok on the outer, as before", cyl(4.0, sized=False), 0, tube(), ("ok", 0, "")),
    ("old signature: the bore's index on a plane: ambiguous, as before", cyl(4.0, sized=False), 2, tube(), ("lost", None, "ambiguous")),
    ("old signature against old candidates: unchanged", cyl(4.0, sized=False), 2, tube(sized=False), ("lost", None, "ambiguous")),
    ("old signature, stepped shaft, index on R8: ok on R8, as before", cyl(5.0, z=15.0, sized=False), 2, shaft, ("ok", 2, "")),
    # Off-axis twins (two holes 20 mm apart) with different radii: the position rule still decides, size does not override it.
    ("two holes 20 mm apart, R3 and R2: the R3's index on a plane is chosen by position, as before",
     cyl(3.0, x=10.0), 2, [cyl(3.0, x=10.0), cyl(2.0, x=30.0), plane(1, 10.0)], ("potentially_moved", 0, "nearest_of_identical_vertices")),
]

out = {"_about": "N1a golden vectors for app.sketch.reference_signature.decide_reference (coaxial tie-break by radius / cone half-angle). Signatures in the "
                 "native format's tagged face shape. Expectations set by hand (tests/test_coaxial_signature_rules.py); body_diagonal 30 mm throughout.",
       "cases": [{"name": n, "stored": s, "index": i, "candidates": c,
                  "expect": {"status": e[0], "index": e[1], "reason": e[2]}} for n, s, i, c, e in cases]}
json.dump(out, open(sys.argv[1], "w"), indent=1)
print(len(cases))
