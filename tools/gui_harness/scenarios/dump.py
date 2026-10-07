sid = list(all_sketches())[0]; sk = all_sketches()[sid]
names = {p.id: f"P{i}({p.x:.2f},{p.y:.2f})" for i, p in enumerate(sk.points.values())}
for c in sk.constraints.values():
    d = {k: v for k, v in vars(c).items() if k != 'id'}
    d = {k: (names.get(v, v) if isinstance(v, str) else v) for k, v in d.items()}
    print(type(c).__name__, d)
circ = list(sk.circles.values())[0] if isinstance(sk.circles, dict) else sk.circles()[0]
print({k: (names.get(v, v)) if isinstance(v,str) else v for k,v in vars(circ).items()})
