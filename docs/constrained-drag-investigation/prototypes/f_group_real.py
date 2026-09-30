"""Follow-up to the review comment: the REAL group model.  Runs IN-PROCESS (TestClient) on the motion branch's backend package so it can
import the product's own private helpers read-only (_resolve_local_geometry, _place_in_world, _mate_residual_vector - the same residual the
shipped _free_motion differentiates).  Variables = the 6-DOF pose perturbation of EVERY non-fixed occurrence in the mate graph (frozen only:
`fixed` occurrences and the root part's own geometry).  Nothing in the product is modified; this is scratch code."""
import os, sys, math
os.environ.setdefault("CAD_API_KEY", "test-api-key")
BACKEND = os.environ.get("BACKEND", "/tmp/claude-0/-home-user/1f01ce49-d6c7-571e-bdf2-d4a301ca71e0/scratchpad/cad-motion/backend")
sys.path.insert(0, BACKEND)
import numpy as np
from tests import test_assembly_solver as T                      # reuse the repo's own scene-building helpers
from app.document.store import get_document
from app.document import assembly_solver as S
from app.document.models import RigidTransform
from app.document.extrude import compute_part_bodies

def build():
    base = T._make_box_part("Base", size=60.0, depth=10.0)
    parts = {k: T._make_box_part(k, size=8.0, depth=4.0) for k in "BCD"}
    root = base["id"]; rexp = T._export_part(root); rp = rexp["document"]["parts"][0]
    occs = []
    for k, tr in (("B", (20, 20, 10)), ("C", (28, 20, 10)), ("D", (20, 12, 10))):
        occs.append({"id": f"occ-{k}", "external_ref": f"parts/{parts[k]['id']}.didsa", "resolved_part_id": parts[k]["id"], "name_override": None,
                     "transform": {"translation": list(tr), "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}, "suppressed": False, "hidden": False})
    rp["occurrences"] = occs; rp["mates"] = []
    exports = [T._export_part(parts[k]["id"]) for k in "BCD"]
    payload = {"schema_version": rexp["schema_version"], "document": {"id": "d", "root_part_id": root, "parts": [rp] + [e["document"]["parts"][0] for e in exports]},
               "sketches": rexp["sketches"] + [s for e in exports for s in e["sketches"]]}
    assert T.client.post("/document/import/native", json=payload).status_code == 200
    def face(p, n): return {"subshape_ref": {"body_id": p["body_id"], "shape_type": "face", "index": T._find_planar_face(p["id"], p["body_id"], n)}}
    def mate(a_occ, a_ref, b_occ, b_ref):
        r = T.client.post(f"/document/parts/{root}/mates", json={"type": "coincident", "references": [{"occurrence_id": a_occ, **a_ref}, {"occurrence_id": b_occ, **b_ref}], "flipped": False}); assert r.status_code == 201, r.text
    bt = face(base, (0, 0, 1))
    for k in "BCD": mate(f"occ-{k}", face(parts[k], (0, 0, -1)), "", bt)
    mate("occ-B", face(parts["B"], (1, 0, 0)), "occ-C", face(parts["C"], (-1, 0, 0)))
    mate("occ-B", face(parts["B"], (0, -1, 0)), "occ-D", face(parts["D"], (0, 1, 0)))
    return root

def group_model(root, variable_ids):
    doc = get_document(); part = doc.parts[root]
    occ = {o.id: o for o in part.occurrences}
    mates = [m for m in part.mates if not m.suppressed and len(m.references) == 2]
    local = []
    for m in mates:
        pair = []
        for ref in m.references:
            tp, tr = S._target_part_and_transform(doc, part, ref.occurrence_id)
            pair.append((ref.occurrence_id, S._resolve_local_geometry(tp, compute_part_bodies(tp), ref), tr))
        local.append((m, pair))
    def pose(oid, delta):
        base = occ[oid].transform
        if delta is None: return base
        rx, ry, rz = delta[3:]; ang = math.sqrt(rx*rx + ry*ry + rz*rz)
        dq = (1.0, 0, 0, 0) if ang < 1e-12 else S._quaternion_from_axis_angle((rx/ang, ry/ang, rz/ang), math.degrees(ang))
        q = S._quaternion_multiply(dq, S._quaternion_from_axis_angle(base.rotation_axis, base.rotation_angle_degrees))
        ax, dg = S._axis_angle_from_quaternion(q)
        return RigidTransform(translation=tuple(base.translation[i] + delta[i] for i in range(3)), rotation_axis=ax, rotation_angle_degrees=dg)
    def resid(x):
        d = {oid: x[6*i:6*i+6] for i, oid in enumerate(variable_ids)}
        out = []
        for m, ((oa, ga, ta), (ob, gb, tb)) in local:
            def world(o, g, t):
                if o in d: return S._place_in_world(g, pose(o, d[o]))
                return g if t is None else S._place_in_world(g, t)
            out += list(S._mate_residual_vector(m, world(oa, ga, ta), world(ob, gb, tb)))
        return np.array(out)
    n = 6 * len(variable_ids); r0 = resid(np.zeros(n)); J = np.zeros((len(r0), n)); h = 1e-6
    for i in range(n):
        e = np.zeros(n); e[i] = h; J[:, i] = (resid(e) - resid(-e)) / (2 * h)
    U, Sv, Vt = np.linalg.svd(J); rank = int(np.sum(Sv > 1e-6))
    return r0, J, rank, Vt[rank:]

if __name__ == "__main__":
    root = build()
    print("== each occurrence solved alone against FROZEN peers (what the shipped mate-motion computes) ==")
    for oid in ("occ-B", "occ-C", "occ-D"):
        r0, J, rank, N = group_model(root, [oid]); print("   %s: dof = %d   (residual at rest %.1e)" % (oid, 6 - rank, np.abs(r0).max()))
    ids = ["occ-B", "occ-C", "occ-D"]
    r0, J, rank, N = group_model(root, ids)
    print("== all three free, only the plate frozen (group model) ==")
    print("   variables 18, residual rows %d, rank %d  ->  GROUP dof = %d   (residual at rest %.1e)" % (J.shape[0], rank, 18 - rank, np.abs(r0).max()))
    # per-body mobility = rank of that body's 6-row block of the basis
    for i, oid in enumerate(ids):
        blk = N[:, 6*i:6*i+6]; sv = np.linalg.svd(blk, compute_uv=False); print("   %s: mobility (rank of its block of the group basis) = %d, largest translation-part singular value %.2f" % (oid, int(np.sum(sv > 1e-6)), sv[0]))
    # is 'all three translate together in x / y' inside the group nullspace?
    for name, axis in (("x", 0), ("y", 1)):
        v = np.zeros(18); [v.__setitem__(6*i + axis, 1.0) for i in range(3)]
        print("   all three translate together in %s: residual of that motion in the null space = %.1e" % (name, np.linalg.norm(v - N.T @ (N @ v))))
    # drag B +6 in y: grabbed weight 1, followers ~0 (translation weight 1, rotation weight L)
    L = 20.0; W = np.array(([1, 1, 1, L, L, L] * 3), float) ** 2; W[6:] *= 1e-6
    want = np.zeros(18); want[1] = 6.0
    A = N @ np.diag(W) @ N.T; c = np.linalg.solve(A + 1e-12 * np.eye(len(A)), N @ np.diag(W) @ want); dvec = N.T @ c
    print("== drag B by +6 in y (B weight 1, followers ~0) ==")
    for i, oid in enumerate(ids): print("   %s moves by (%.2f, %.2f, %.2f), rotates (%.3f, %.3f, %.3f) rad" % ((oid,) + tuple(dvec[6*i:6*i+6])))
    print("   (B alone against frozen C, D would be blocked: DOF 0.)")
