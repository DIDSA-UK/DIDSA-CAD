from b_probe import *
s, drag = sk_slot()
for eps in (1e-1, 1e-2, 1e-3):
    P, ids, st = projector(s, eps=eps)
    print("eps", eps, "column norms |P e_i| (a projector has <= ~1):", np.round(np.linalg.norm(P, axis=0), 2), " singular values:", np.round(np.linalg.svd(P)[1], 2))
# what does the solver report for the perturbed slot?  (is 'converged' trustworthy?)
t = copy.deepcopy(s); solve_sketch(t); ids = free_ids(t); x0 = coords(t, ids)
x = x0.copy(); x[2] += 1e-2; set_coords(t, ids, x); r = solve_sketch(t)
print("perturbed solve: converged", r.converged, "code", r.result_code, "dof", r.dof, "| max |dx| after solve", np.max(np.abs(coords(t, ids) - x0)))
