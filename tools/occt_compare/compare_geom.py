"""Diff two geomdiff recordings (dirs of JSONL) body by body."""
import glob, json, math, sys
from collections import Counter, defaultdict

def load(d):
    recs = {}
    for f in glob.glob(f"{d}/*.jsonl"):
        for line in open(f):
            r = json.loads(line)
            recs[(r["test"], r["step"], r["body"])] = r
    return recs

a, b = load(sys.argv[1]), load(sys.argv[2])
common = sorted(set(a) & set(b))
only_a, only_b = set(a) - set(b), set(b) - set(a)
rel = lambda x, y: abs(x - y) / max(abs(x), abs(y), 1e-9)
cats = Counter(); worst = defaultdict(list); by_feature = defaultdict(Counter)
for k in common:
    x, y = a[k], b[k]
    feat = x["feature"]
    if "probe_error" in x or "probe_error" in y or x.get("null") or y.get("null"):
        cats["probe error / null"] += 1; continue
    if x["valid"] != y["valid"]:
        cats[f"validity {x['valid']}->{y['valid']}"] += 1; worst["validity"].append((k, feat))
    topo = any(x[t] != y[t] for t in ("solids", "faces", "edges", "vertices"))
    if topo:
        cats["topology counts differ"] += 1; by_feature[feat]["topology"] += 1
        worst["topology"].append((k, feat, {t: (x[t], y[t]) for t in ("solids", "faces", "edges", "vertices") if x[t] != y[t]}))
    dv = rel(x["volume"], y["volume"]); da = rel(x["area"], y["area"])
    dc = math.dist(x["centroid"], y["centroid"])
    worst["volume"].append((dv, k, feat, x["volume"], y["volume"]))
    worst["area"].append((da, k, feat))
    worst["centroid"].append((dc, k, feat))
    for lim in (1e-9, 1e-6, 1e-4, 1e-2):
        if dv > lim: cats[f"volume rel diff > {lim:g}"] += 1
        if da > lim: cats[f"area rel diff > {lim:g}"] += 1
    if dc > 1e-3: cats["centroid moved > 0.001 mm"] += 1
print(f"bodies compared: {len(common)}  only in A: {len(only_a)}  only in B: {len(only_b)}")
print(f"tests covered: {len({k[0] for k in common})}")
va = Counter(r['valid'] for r in a.values() if 'valid' in r); vb = Counter(r['valid'] for r in b.values() if 'valid' in r)
print("valid in A:", dict(va), " valid in B:", dict(vb))
for c, n in sorted(cats.items()): print(f"  {c}: {n}")
print("topology diffs by feature:", {f: dict(c) for f, c in by_feature.items()})
for kind in ("volume", "area", "centroid"):
    print(f"worst {kind}:")
    for row in sorted(worst[kind], key=lambda r: -r[0])[:6]: print("   ", row)
print("topology examples:")
for row in worst["topology"][:12]: print("   ", row)
print("validity changes:", worst["validity"][:20])
tests_a = {k[0] for k in a}; tests_b = {k[0] for k in b}
print("tests with differing step counts:", sorted(t for t in tests_a & tests_b if max((k[1] for k in a if k[0]==t), default=-1) != max((k[1] for k in b if k[0]==t), default=-1))[:15])
