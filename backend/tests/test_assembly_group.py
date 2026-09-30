"""Constrained drag S1 (`docs/constrained-drag-implementation-plan.md`): the group
model core (`app.document.assembly_group`) on real OCCT geometry and the real
mate residuals. Scenes are built through the HTTP API exactly like
`test_assembly_solver.py` (whose helpers are reused); the analysis itself is
called in-process on the stored document.

Reference numbers come from the investigation's `f_group_real.py`: plate + B, C,
D -> each occurrence alone against frozen peers has DOF 0/1/1, the GROUP has DOF 5
with mobility 3 for every body.
"""

import time

import numpy as np

from app.document.assembly_group import (
    GroupError,
    analyze_group,
    bounding_radius,
    build_group_model,
    discover_component,
)
from app.document.store import get_document
from tests.test_assembly_solver import (
    _export_part,
    _find_cylindrical_face,
    _find_planar_face,
    _make_box_part,
    _make_cylinder_part,
    client,
)

_LEVER = 20.0


def _face(part: dict, normal) -> dict:
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": _find_planar_face(part["id"], part["body_id"], normal)}}


def _cyl(part: dict) -> dict:
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": _find_cylindrical_face(part["id"], part["body_id"])}}


def _compose(root: dict, occurrences: list[tuple[str, dict, tuple[float, float, float]]]) -> str:
    """Root part + occurrences `(id, part, translation)` (parts may repeat)."""
    root_export = _export_part(root["id"])
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = [
        {
            "id": oid,
            "external_ref": f"parts/{p['id']}.didsa",
            "resolved_part_id": p["id"],
            "name_override": None,
            "transform": {"translation": list(t), "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0},
            "suppressed": False,
            "hidden": False,
        }
        for oid, p, t in occurrences
    ]
    root_dict["mates"] = []
    distinct = {p["id"]: p for _o, p, _t in occurrences}
    exports = [_export_part(pid) for pid in distinct]
    payload = {
        "schema_version": root_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": root["id"],
            "parts": [root_dict, *[e["document"]["parts"][0] for e in exports]],
        },
        "sketches": [*root_export["sketches"], *[s for e in exports for s in e["sketches"]]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    return root["id"]


def _mate(root_id: str, mate_type: str, a_occ: str, a_ref: dict, b_occ: str, b_ref: dict, **extra) -> dict:
    body = {
        "type": mate_type,
        "references": [{"occurrence_id": a_occ, **a_ref}, {"occurrence_id": b_occ, **b_ref}],
        "flipped": False,
        **extra,
    }
    response = client.post(f"/document/parts/{root_id}/mates", json=body)
    assert response.status_code == 201, response.text
    return response.json()


def _row_scene(k: int):
    """Plate with `k` boxes in a row, each on the plate and face-mated to its neighbour."""
    plate = _make_box_part("Plate", size=100.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    ids = [f"occ-{i}" for i in range(k)]
    root = _compose(plate, [(oid, box, (5.0 + 8.0 * i, 20.0, 10.0)) for i, oid in enumerate(ids)])
    top = _face(plate, (0, 0, 1))
    for oid in ids:
        _mate(root, "coincident", oid, _face(box, (0, 0, -1)), "", top)
    for a, b in zip(ids, ids[1:]):
        _mate(root, "coincident", a, _face(box, (1, 0, 0)), b, _face(box, (-1, 0, 0)))
    return root, ids


def _plate_bcd():
    """The investigation's B/C/D scene: B on the plate, C beside B (+x), D behind B (-y)."""
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    parts = {k: _make_box_part(k, size=8.0, depth=4.0) for k in "BCD"}
    root = _compose(
        plate,
        [("occ-B", parts["B"], (20, 20, 10)), ("occ-C", parts["C"], (28, 20, 10)), ("occ-D", parts["D"], (20, 12, 10))],
    )
    top = _face(plate, (0, 0, 1))
    for k in "BCD":
        _mate(root, "coincident", f"occ-{k}", _face(parts[k], (0, 0, -1)), "", top)
    _mate(root, "coincident", "occ-B", _face(parts["B"], (1, 0, 0)), "occ-C", _face(parts["C"], (-1, 0, 0)))
    _mate(root, "coincident", "occ-B", _face(parts["B"], (0, -1, 0)), "occ-D", _face(parts["D"], (0, 1, 0)))
    return root, plate, parts


def _doc(root: str):
    document = get_document()
    return document, document.parts[root]


def _in_nullspace(analysis, vector: np.ndarray, tol: float = 1e-6) -> bool:
    """`vector` (unweighted, 6k) lies in the group's free motion: rebuild it from the basis."""
    w = np.array([1, 1, 1, analysis.lever_arm, analysis.lever_arm, analysis.lever_arm] * len(analysis.member_ids))
    y = vector * w
    n = analysis.basis * w  # orthonormal rows in y-space
    return float(np.linalg.norm(y - n.T @ (n @ y))) < tol * max(1.0, float(np.linalg.norm(y)))


def _translation(analysis, deltas: dict[str, tuple[float, float, float]]) -> np.ndarray:
    v = np.zeros(6 * len(analysis.member_ids))
    for i, oid in enumerate(analysis.member_ids):
        if oid in deltas:
            v[6 * i : 6 * i + 3] = deltas[oid]
    return v


# ---- plate + B, C, D -------------------------------------------------------


def test_plate_bcd_group_dof_5_mobility_3_and_alone_dof_0_1_1():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)

    # Existing behaviour: each alone against frozen peers -> 0 / 1 / 1 (the v0 aliases of the
    # HTTP endpoint report it as the number of free twists; the module with peers frozen agrees).
    for oid, expected in (("occ-B", 0), ("occ-C", 1), ("occ-D", 1)):
        response = client.post(f"/document/parts/{root}/occurrences/{oid}/mate-motion", json={"transform": None})
        assert response.status_code == 200 and len(response.json()["free_twists"]) == expected, (oid, response.text)
        assert response.json()["dof"] == 5  # ... while the endpoint's own dof is now the GROUP dof
        peers = frozenset({"occ-B", "occ-C", "occ-D"} - {oid})
        assert analyze_group(document, part, oid, _LEVER, also_frozen=peers).dof == expected

    analysis = analyze_group(document, part, "occ-B", _LEVER)
    assert analysis.member_ids == ("occ-B", "occ-C", "occ-D")
    assert analysis.frozen_ids == ("",)
    assert analysis.grounded is True
    assert analysis.rank == 13 and analysis.dof == 5
    assert analysis.basis.shape == (5, 18)
    assert analysis.mobility == {"occ-B": 3, "occ-C": 3, "occ-D": 3}
    assert analysis.quality.residual_inf < 1e-6

    # All three translate together in x and in y (the plate plane), not in z.
    together = lambda axis: _translation(analysis, {o: tuple(1.0 if a == axis else 0.0 for a in range(3)) for o in analysis.member_ids})
    assert _in_nullspace(analysis, together(0)) and _in_nullspace(analysis, together(1))
    assert not _in_nullspace(analysis, together(2))
    # B alone cannot move (that is why the per-occurrence DOF is 0).
    assert not _in_nullspace(analysis, _translation(analysis, {"occ-B": (0.0, 1.0, 0.0)}))

    # Orthonormal in the lever-arm metric; healthy conditioning.
    w = np.array([1, 1, 1, _LEVER, _LEVER, _LEVER] * 3)
    gram = (analysis.basis * w) @ (analysis.basis * w).T
    assert np.allclose(gram, np.eye(5), atol=1e-9)
    assert analysis.quality.sigma_min > 1e-3 and analysis.quality.sigma_gap > 1e3


def test_group_component_is_the_same_from_any_member_and_default_lever_arm_is_positive():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)
    from_c = analyze_group(document, part, "occ-C")
    assert from_c.member_ids == ("occ-C", "occ-B", "occ-D")  # grabbed first, then occurrence order
    assert from_c.dof == 5 and from_c.lever_arm == bounding_radius(document, part, "occ-C") > 0


# ---- peg <- B <- C chain ---------------------------------------------------


def test_peg_b_c_chain_group_dof_5_and_b_lift_drags_c():
    peg = _make_cylinder_part("Peg", radius=5.0, depth=40.0)
    b = _make_cylinder_part("B", radius=4.0, depth=10.0)
    c = _make_box_part("C", size=6.0, depth=4.0)
    root = _compose(peg, [("occ-B", b, (0, 0, 5)), ("occ-C", c, (-3, -3, 15))])
    _mate(root, "concentric", "occ-B", _cyl(b), "", _cyl(peg))
    _mate(root, "coincident", "occ-C", _face(c, (0, 0, -1)), "occ-B", _face(b, (0, 0, 1)))
    document, part = _doc(root)

    analysis = analyze_group(document, part, "occ-B", 10.0)
    assert analysis.member_ids == ("occ-B", "occ-C")
    assert analysis.dof == 5 and analysis.quality.residual_inf < 1e-6
    # Alone against a frozen C, B is blocked; in the group B slides only if C rides along.
    assert _in_nullspace(analysis, _translation(analysis, {"occ-B": (0, 0, 12.0), "occ-C": (0, 0, 12.0)}))
    assert not _in_nullspace(analysis, _translation(analysis, {"occ-B": (0, 0, 12.0)}))
    assert analyze_group(document, part, "occ-B", 10.0, also_frozen=frozenset({"occ-C"})).dof == 1


# ---- frozen / suppressed / trivial cases -----------------------------------


def test_fixed_peer_is_never_a_variable():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)
    next(o for o in part.occurrences if o.id == "occ-C").fixed = True
    component = discover_component(part, "occ-B")
    assert component.member_ids == ("occ-B", "occ-D")  # C frozen: not a variable ...
    assert "occ-C" in component.frozen_ids  # ... but still a reference frame
    analysis = analyze_group(document, part, "occ-B", _LEVER)
    assert analysis.basis.shape[1] == 12 and "occ-C" not in analysis.mobility
    # B is pinned to the frozen C in x, so the pair can no longer translate in x together.
    assert not _in_nullspace(analysis, _translation(analysis, {"occ-B": (1, 0, 0), "occ-D": (1, 0, 0)}))
    assert _in_nullspace(analysis, _translation(analysis, {"occ-B": (0, 1, 0), "occ-D": (0, 1, 0)}))
    assert analysis.dof == 2  # B+D slide together in y, D alone slides in x
    # A fixed occurrence cannot be the grabbed one.
    try:
        discover_component(part, "occ-C")
        raise AssertionError("expected GroupError")
    except GroupError:
        pass


def test_suppressed_mate_is_ignored():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)
    for mate in part.mates:
        refs = {r.occurrence_id for r in mate.references}
        if refs == {"occ-B", "occ-D"}:
            mate.suppressed = True
    analysis = analyze_group(document, part, "occ-B", _LEVER)
    assert analysis.member_ids == ("occ-B", "occ-C")  # D dropped out of the component
    assert analysis.dof == 4  # two on-plate bodies (3 each) glued by one face mate (-2: x offset, z spin)
    assert analyze_group(document, part, "occ-D", _LEVER).member_ids == ("occ-D",)


def test_no_mates_gives_six_free():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (5, 5, 20))])
    document, part = _doc(root)
    analysis = analyze_group(document, part, "occ-A", 5.0)
    assert analysis.dof == 6 and analysis.rank == 0 and analysis.mobility == {"occ-A": 6}
    assert analysis.grounded is False
    assert analysis.quality.sigma_min is None and analysis.quality.residual_inf == 0.0
    assert np.allclose(analysis.basis * np.array([1, 1, 1, 5, 5, 5]), np.eye(6))


def test_ungrounded_component_is_a_free_rigid_group():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    b = _make_box_part("B", size=8.0, depth=4.0)
    c = _make_box_part("C", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-B", b, (20, 20, 30)), ("occ-C", c, (28, 20, 30))])
    _mate(root, "coincident", "occ-B", _face(b, (1, 0, 0)), "occ-C", _face(c, (-1, 0, 0)))
    document, part = _doc(root)
    analysis = analyze_group(document, part, "occ-B", _LEVER)
    assert analysis.grounded is False and analysis.frozen_ids == ()
    assert analysis.dof == 9  # 12 variables - 3 (one plane-plane coincidence)
    # The whole rigid group moves freely: 3 translations + 3 rotations about the world origin.
    for axis in range(3):
        t = [0.0, 0.0, 0.0]
        t[axis] = 1.0
        assert _in_nullspace(analysis, _translation(analysis, {"occ-B": tuple(t), "occ-C": tuple(t)}))
        omega = np.zeros(3)
        omega[axis] = 1e-3
        v = np.zeros(12)
        for i, oid in enumerate(analysis.member_ids):
            origin = np.array(next(o for o in part.occurrences if o.id == oid).transform.translation)
            v[6 * i : 6 * i + 3] = np.cross(omega, origin)
            v[6 * i + 3 : 6 * i + 6] = omega
        assert _in_nullspace(analysis, v, tol=1e-4)


# ---- rank robustness --------------------------------------------------------


def test_redundant_mate_does_not_change_rank_and_conflicting_mate_shows_in_residual():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (20, 20, 10))])
    top, bottom = _face(plate, (0, 0, 1)), _face(box, (0, 0, -1))
    _mate(root, "coincident", "occ-A", bottom, "", top)
    document, part = _doc(root)
    single = analyze_group(document, part, "occ-A", _LEVER)
    assert single.dof == 3 and single.rank == 3

    _mate(root, "coincident", "occ-A", bottom, "", top)  # exact duplicate
    document, part = _doc(root)
    redundant = analyze_group(document, part, "occ-A", _LEVER)
    assert redundant.rank == 3 and redundant.dof == 3
    assert redundant.quality.residual_inf < 1e-6
    assert redundant.quality.sigma_gap > 1e3  # the dependent rows do not blur the gap

    _mate(root, "distance", "occ-A", bottom, "", top, value=5.0)  # contradicts coincident
    document, part = _doc(root)
    conflicting = analyze_group(document, part, "occ-A", _LEVER)
    assert conflicting.rank == 3 and conflicting.dof == 3  # rank sees rows, not consistency ...
    assert conflicting.quality.residual_inf > 1.0  # ... the inconsistency shows up in the residual


def test_relative_tolerance_is_scale_free():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)
    for rtol in (1e-9, 1e-6, 1e-3):
        assert analyze_group(document, part, "occ-B", _LEVER, rank_rtol=rtol).dof == 5
    # The lever arm changes the metric, never the rank.
    for lever in (0.5, 20.0, 500.0):
        assert analyze_group(document, part, "occ-B", lever).dof == 5


def test_jacobian_matches_a_finite_difference_of_the_residual():
    root, _plate, _parts = _plate_bcd()
    document, part = _doc(root)
    model = build_group_model(document, part, "occ-B")
    jac = model.jacobian()
    step = np.zeros(model.n_vars)
    step[1] = 1e-4  # B dy: first order agreement with the stacked residual
    assert np.allclose(model.residual(step) - model.residual(), jac @ step, atol=1e-6)


# ---- timing (recorded in the tracker handoff) -------------------------------


def test_timing_k_1_3_8(capsys):
    rows = []
    for k in (1, 3, 8):
        root, ids = _row_scene(k)
        document, part = _doc(root)
        analyze_group(document, part, ids[0], _LEVER)  # warm the OCCT/body caches
        model_ms, full_ms = [], []
        for _ in range(5):
            t0 = time.perf_counter()
            model = build_group_model(document, part, ids[0])
            t1 = time.perf_counter()
            analysis = analyze_group(document, part, ids[0], _LEVER)
            t2 = time.perf_counter()
            model_ms.append((t1 - t0) * 1e3)
            full_ms.append((t2 - t1) * 1e3)
        assert len(analysis.member_ids) == k and analysis.dof == k + 2 and analysis.mobility[ids[0]] >= 1
        rows.append((k, model.n_vars, min(model_ms), min(full_ms)))
    with capsys.disabled():
        print("\nGROUP TIMING (best of 5, ms): k  vars  build_model  analyze_group(build+J+SVD)")
        for k, n, a, b in rows:
            print(f"  k={k}: {n:2d} vars  build {a:7.2f}  analyze {b:7.2f}")
    assert all(b < 5000 for *_r, b in rows)
