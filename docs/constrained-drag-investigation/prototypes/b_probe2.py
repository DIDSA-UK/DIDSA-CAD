from b_probe import *
def tangent_basis(P, gap=0.5):
    U, S, Vt = np.linalg.svd(P)
    k = int(np.sum(S > gap))
    return U[:, :k], S
def mobility_from_basis(Q, ids, tol=0.05):
    out = {}
    for k, pid in enumerate(ids):
        B = Q[2 * k:2 * k + 2, :]
        if B.shape[1] == 0: out[pid] = (0, None); continue
        U, S, _ = np.linalg.svd(B)
        rank = int(np.sum(S > tol)); out[pid] = (rank, tuple(U[:, 0]) if rank == 1 else None)
    return out
def idem(P): return float(np.linalg.norm(P @ P - P) / max(1e-12, np.linalg.norm(P)))

if __name__ == "__main__":
    print("epsilon sweep - is the recovered rank stable?")
    for name in ("rect_partial(w fixed, h free)", "two_link_arm", "hexagon(provisional)", "slot", "rect_floating"):
        s, drag = ALL[name]()
        row = []
        for eps in (1e-1, 1e-2, 1e-3, 1e-4):
            P, ids, st = projector(s, eps=eps); U, S, _ = np.linalg.svd(P)
            row.append("eps=%g: rank=%d (sv gap %.3f|%.3f, idem-err %.1e, fails %d)" % (eps, int(np.sum(S > 0.5)), S[S > 0.5].min() if np.any(S > 0.5) else 0, S[S <= 0.5].max() if np.any(S <= 0.5) else 0, idem(P), st["fails"]))
        print(" ", name, "backend dof", st["dof0"]); [print("     ", r) for r in row]
    
    print("\nper-point mobility from the basis (rank of the point's 2xd block):")
    for name in ("rect_partial(w fixed, h free)", "two_link_arm", "rect_floating", "hexagon(provisional)"):
        s, drag = ALL[name]()
        P, ids, st = projector(s, eps=1e-3); Q, S = tangent_basis(P); mob = mobility_from_basis(Q, ids)
        cnt = {0: 0, 1: 0, 2: 0}
        for k, (rk, d) in mob.items(): cnt[rk] += 1
        rk, d = mob[drag]
        print("  %-32s dof=%d pinned=%d line-only=%d free=%d | drag target: rank %d%s" % (name, Q.shape[1], cnt[0], cnt[1], cnt[2], rk, "" if d is None else " dir (%.3f,%.3f)" % d))
