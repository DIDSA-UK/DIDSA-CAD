"""Constrained drag S2: `assembly_group.solve_group` (weighted Gauss-Newton retraction over
the stacked mate residuals) on real OCCT geometry.

Parity suite: single-occurrence scenes mirroring `test_assembly_solver.py` (all five mate
types, flipped, wrong-facing start, singular ANGLE / DISTANCE starts) are solved by BOTH the
py-slvs path (`solve_occurrence_from_guess`) and the group solver from the same wish. The group
answer must satisfy the mates to residual_inf < 1e-7 and be no farther from the wish than
py-slvs' (metric diag(1,1,1,L,L,L)). Then the group-only behaviour: B/C/D followers, chain,
non-convergence, weighted-retraction "no pops" on the offset-axis concentric mate.
"""

import math

import numpy as np
import pytest

from app.document.assembly_group import GroupError, apply_delta, pose_delta, solve_group
from app.document.assembly_solver import _mate_residual_satisfied, solve_occurrence_from_guess
from app.document.models import RigidTransform
from app.document.store import get_document
from tests.test_assembly_group import _cyl, _face, _compose, _mate, _plate_bcd
from tests.test_assembly_solver import _create_mate, _find_cylindrical_face, _find_planar_face, _make_box_part, _make_cylinder_part, _place_occurrence, client

_L = 10.0
_TOL = 1e-7


def _rt(t=(0.0, 0.0, 0.0), axis=(0.0, 0.0, 1.0), deg=0.0) -> RigidTransform:
    return RigidTransform(translation=tuple(t), rotation_axis=tuple(axis), rotation_angle_degrees=deg)


def _dist(a: RigidTransform, b: RigidTransform) -> float:
    d = pose_delta(a, b)
    return float(np.linalg.norm(d * np.array([1, 1, 1, _L, _L, _L])))


def _fref(part, body_id, normal):
    return {"subshape_ref": {"body_id": body_id, "shape_type": "face", "index": _find_planar_face(part["id"], body_id, normal)}}


def _plate_scene(mate_type, *, start=((5.0, 5.0, 60.0), (0, 0, 1), 0.0), driven_normal=(0, 0, -1), fixed_normal=(0, 0, 1), **kw):
    base = _make_box_part("Base", size=20.0, depth=10.0)
    bracket = _make_box_part("Bracket", size=8.0, depth=4.0)
    _place_occurrence(base["id"], bracket["id"], translation=start[0], rotation_axis=start[1], rotation_angle_degrees=start[2])
    _create_mate(
        base["id"], mate_type=mate_type,
        driven_ref=_fref(bracket, bracket["body_id"], driven_normal), fixed_ref=_fref(base, base["body_id"], fixed_normal), **kw,
    )
    return base["id"]


def _vertex_plane_scene():
    base = _make_box_part("Base", size=20.0, depth=10.0)
    pin = _make_box_part("Pin", size=2.0, depth=2.0)
    _place_occurrence(base["id"], pin["id"], translation=(1.0, 1.0, -30.0))
    _create_mate(
        base["id"], mate_type="coincident",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "vertex", "index": 0}},
        fixed_ref=_fref(base, base["body_id"], (0, 0, 1)),
    )
    return base["id"]


def _concentric_scene(*, allow_rotation=None, pin_at=(77.0, -12.0, 5.0), start_deg=30.0):
    base = _make_cylinder_part("BasePost", radius=10.0, depth=5.0)
    pin = _make_cylinder_part("Pin", radius=3.0, depth=20.0)
    _place_occurrence(base["id"], pin["id"], translation=pin_at, rotation_axis=(1, 0, 0), rotation_angle_degrees=start_deg)
    extra = {} if allow_rotation is None else {"allow_rotation": allow_rotation}
    _create_mate(
        base["id"], mate_type="concentric",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": _find_cylindrical_face(pin["id"], pin["body_id"])}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": _find_cylindrical_face(base["id"], base["body_id"])}},
        **extra,
    )
    return base["id"]


SCENES = {
    "face": lambda: _plate_scene("coincident"),
    "face_flipped": lambda: _plate_scene("coincident", flipped=True),
    "face_wrong_way": lambda: _plate_scene("coincident", start=((5, 5, 30), (1, 0, 0), 180.0)),
    "face_tilted_spun": lambda: _plate_scene("coincident", start=((5, 5, 30), (0.3, 0.5, 0.8), 70.0)),
    "vertex_on_plane": _vertex_plane_scene,
    "concentric": lambda: _concentric_scene(),
    "concentric_no_spin": lambda: _concentric_scene(allow_rotation=False),
    "parallel": lambda: _plate_scene("parallel", start=((5, 5, 30), (1, 0, 0), 25.0)),
    "angle_60_from_45": lambda: _plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0),
    "angle_60_from_aligned": lambda: _plate_scene("angle", value=60.0),  # exactly antiparallel start: the singular one
    "angle_60_flipped": lambda: _plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0, flipped=True),
    "distance_from_apart": lambda: _plate_scene("distance", start=((5, 5, 40), (0, 0, 1), 0.0), value=5.0),
    "distance_from_touching": lambda: _plate_scene("distance", start=((5, 5, 10), (0, 0, 1), 0.0), value=5.0),
}
WISH_SHIFT = {"face": (3.0, -2.0, 4.0), "concentric": (3.0, 2.0, -4.0)}


def _wish(stored: RigidTransform, name: str) -> RigidTransform:
    shift = WISH_SHIFT.get(name, (1.5, -1.0, 2.0))
    return apply_delta(stored, (*shift, 0.05, -0.03, 0.4))


def _parity(name: str, wish_of=None):
    root = SCENES[name]()
    document = get_document()
    part = document.parts[root]
    occ = part.occurrences[0]
    wish = (wish_of or _wish)(occ.transform, name)
    result = solve_group(document, part, occ.id, wish, lever_arm=_L)
    assert result.converged, (name, result.quality)
    assert result.quality.residual_inf < _TOL
    solved = result.poses[occ.id]
    # Independent check: every mate's own satisfied-predicate (accepts both ANGLE branches).
    from app.document.assembly_group import build_group_model
    model = build_group_model(document, part, occ.id)
    for mate, a, b in model.sides:
        placed = {occ.id: solved}
        assert _mate_residual_satisfied(mate, model._world(a, placed), model._world(b, placed)), (name, mate.type)
    old = solve_occurrence_from_guess(document, part, occ.id, wish)
    return result, old, wish, solved


@pytest.mark.parametrize("name", list(SCENES))
def test_group_solve_satisfies_mates_and_is_no_farther_from_the_wish_than_py_slvs(name):
    result, old, wish, solved = _parity(name)
    if old.converged:
        assert _dist(solved, wish) <= _dist(old.transform, wish) + 1e-3, (name, _dist(solved, wish), _dist(old.transform, wish))
    assert result.analysis is not None and result.analysis.dof >= 0


def test_face_mate_results_match_the_known_dof_and_direction():
    result, _old, _wish_pose, solved = _parity("face")
    assert result.analysis.dof == 3 and result.analysis.grounded
    # Sits flush on the plate top (z = 10) facing the right way.
    assert abs(solved.translation[2] - 10.0) < 1e-6
    # In-plane wish components survive (nearest solution): x, y follow the wish.
    assert abs(solved.translation[0] - (5.0 + 3.0)) < 0.5 and abs(solved.translation[1] - (5.0 - 2.0)) < 0.5


def test_flipped_and_wrong_way_coincident_pick_the_right_branch():
    # Not flipped: bracket bottom faces down onto the plate top (normal (0,0,-1)); flipped: it faces up.
    _r, _o, _w, s_plain = _parity("face")
    _r, _o, _w, s_wrong = _parity("face_wrong_way")
    _r, _o, _w, s_flip = _parity("face_flipped")
    from app.document.assembly import apply_transform_to_direction as d
    assert d(s_plain, (0, 0, -1))[2] < -0.999999 and d(s_wrong, (0, 0, -1))[2] < -0.999999 and d(s_flip, (0, 0, -1))[2] > 0.999999


def test_angle_from_an_aligned_start_now_converges():
    result, old, _w, solved = _parity("angle_60_from_aligned")
    from app.document.assembly import apply_transform_to_direction
    n = apply_transform_to_direction(solved, (0.0, 0.0, -1.0))
    angle = math.degrees(math.acos(max(-1.0, min(1.0, n[2]))))
    assert abs(angle - 60.0) < 1e-4
    assert result.converged and result.analysis.dof == 5


def test_distance_from_touching_reaches_the_value():
    result, _o, _w, solved = _parity("distance_from_touching", wish_of=lambda t, n: t)
    assert abs(solved.translation[2] - (10.0 + 5.0)) < 1e-6


# ---- group behaviour -----------------------------------------------------------


def test_bcd_drag_b_plus_6_y_moves_b_and_d_only():
    root, _plate, _parts = _plate_bcd()
    document = get_document()
    part = document.parts[root]
    stored = {o.id: o.transform for o in part.occurrences}
    wish = apply_delta(stored["occ-B"], (0.0, 6.0, 0.0, 0.0, 0.0, 0.0))
    result = solve_group(document, part, "occ-B", wish, lever_arm=10.0)
    assert result.converged and result.analysis.dof == 5
    moved = {oid: pose_delta(result.poses[oid], stored[oid]) for oid in stored}
    assert np.allclose(moved["occ-B"][:3], (0, 6, 0), atol=1e-6)
    assert np.allclose(moved["occ-D"][:3], (0, 6, 0), atol=1e-6)  # D is glued to B's -y face
    assert np.allclose(moved["occ-C"], 0, atol=1e-6)  # C stays: B's +x face slides along it
    assert result.quality.jump < 1e-6  # flat mates: the first-order prediction is exact
    # x is blocked: B cannot leave C's face without C following, and followers do follow.
    wish_x = apply_delta(stored["occ-B"], (4.0, 0.0, 0.0, 0.0, 0.0, 0.0))
    rx = solve_group(document, part, "occ-B", wish_x, lever_arm=10.0)
    assert rx.converged and np.allclose(pose_delta(rx.poses["occ-C"], stored["occ-C"])[:3], (4, 0, 0), atol=1e-6)


def test_chain_b_slides_up_the_peg_and_c_rides_along():
    peg = _make_cylinder_part("Peg", radius=5.0, depth=40.0)
    b = _make_cylinder_part("B", radius=4.0, depth=10.0)
    c = _make_box_part("C", size=6.0, depth=4.0)
    root = _compose(peg, [("occ-B", b, (0, 0, 5)), ("occ-C", c, (-3, -3, 15))])
    _mate(root, "concentric", "occ-B", _cyl(b), "", _cyl(peg))
    _mate(root, "coincident", "occ-C", _face(c, (0, 0, -1)), "occ-B", _face(b, (0, 0, 1)))
    document = get_document()
    part = document.parts[root]
    stored = {o.id: o.transform for o in part.occurrences}
    result = solve_group(document, part, "occ-B", apply_delta(stored["occ-B"], (0, 0, 12.0, 0, 0, 0)), lever_arm=6.0)
    assert result.converged
    assert abs(pose_delta(result.poses["occ-B"], stored["occ-B"])[2] - 12.0) < 1e-6
    assert abs(pose_delta(result.poses["occ-C"], stored["occ-C"])[2] - 12.0) < 1e-6
    # The single-occurrence solver against a frozen C cannot do this move.
    frozen = solve_group(document, part, "occ-B", apply_delta(stored["occ-B"], (0, 0, 12.0, 0, 0, 0)), lever_arm=6.0, also_frozen=frozenset({"occ-C"}))
    assert not frozen.converged or abs(pose_delta(frozen.poses["occ-B"], stored["occ-B"])[2] - 12.0) > 1.0


def test_non_convergence_reports_no_basis():
    root = _plate_scene("coincident", start=((5, 5, 10), (0, 0, 1), 0.0))
    _create_mate(  # contradicts the coincident mate
        root, mate_type="distance", value=5.0,
        driven_ref=_fref_from_root(root, "driven"), fixed_ref=_fref_from_root(root, "fixed"),
    )
    document = get_document()
    part = document.parts[root]
    result = solve_group(document, part, "occ-driven", None, lever_arm=_L)
    assert result.converged is False
    assert result.analysis is None and result.dof is None
    assert result.quality.residual_inf > 1.0


def _fref_from_root(root, side):
    document = get_document()
    part = document.parts[root]
    mate = part.mates[0]
    ref = mate.references[0 if side == "driven" else 1]
    sub = ref.subshape_ref
    return {"subshape_ref": {"body_id": sub.body_id, "shape_type": "face", "index": sub.index}}


def test_stored_pose_that_already_satisfies_is_a_fixed_point_and_fixed_grabbed_raises():
    root, _plate, _parts = _plate_bcd()
    document = get_document()
    part = document.parts[root]
    result = solve_group(document, part, "occ-B", None, lever_arm=10.0)
    assert result.converged and result.quality.iterations == 0 and result.quality.jump < 1e-9
    next(o for o in part.occurrences if o.id == "occ-B").fixed = True
    with pytest.raises(GroupError):
        solve_group(document, part, "occ-B", None, lever_arm=10.0)


def _offset_pin_scene(cx=15.0):
    """Peg on the origin; pin whose own axis is `cx` mm off the pin's origin (the curved-mate case)."""
    from tests.test_assembly_solver import _add_point, _create_part
    base = _make_cylinder_part("Peg", radius=5.0, depth=20.0)
    part = _create_part("OffsetPin")
    sf = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    center = _add_point(sf["sketch_id"], cx, 0.0)
    assert client.post(f"/sketch/sketches/{sf['sketch_id']}/circles", json={"center_point_id": center["id"], "radius": 4.0, "angle": 0.0}).status_code == 201
    assert client.post(f"/document/parts/{part['id']}/extrude-features", json={"sketch_feature_id": sf["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []}).status_code == 201
    pin = {"id": part["id"], "body_id": client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]}
    _place_occurrence(base["id"], pin["id"], translation=(0.0, 0.0, 30.0))
    _create_mate(
        base["id"], mate_type="concentric",
        driven_ref={"subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": _find_cylindrical_face(pin["id"], pin["body_id"])}},
        fixed_ref={"subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": _find_cylindrical_face(base["id"], base["body_id"])}},
    )
    return base["id"]


def test_offset_axis_concentric_90_degree_wish_anchor_steps_are_smaller_than_py_slvs(capsys):
    """Solver half of `e_weighted_retraction.py`: the hand swings an off-axis pin (curved mate) by
    90 degrees; the anchor is re-solved every 9 frames from the persisted previous anchor. Because
    the retraction is nearest in the client's metric, consecutive anchors move no further than
    py-slvs' do (measured alongside from the same wishes), and stay within 1.5x the hand's own
    step (the manifold curves, so the nearest point can outrun a hand that swings about the
    wrong centre - it did NOT stay below the hand step here, unlike the toy in the prototype).
    The display-side pop needs the S4/S6 screw projector and is not testable here."""
    root = _offset_pin_scene()
    document = get_document()
    part = document.parts[root]
    occ = part.occurrences[0]
    settled = solve_group(document, part, occ.id, None, lever_arm=_L)
    assert settled.converged
    base = occ.transform = settled.poses[occ.id]
    frames, interval = 63, 9
    hand_at = lambda f: apply_delta(base, (0, 0, 15.0 * f / frames, 0, 0, math.radians(90) * f / frames))
    group_steps, slvs_steps, hand_steps = [], [], []
    slvs_prev = base
    for f in range(interval, frames + 1, interval):
        prev = occ.transform
        r = solve_group(document, part, occ.id, hand_at(f), lever_arm=_L)
        assert r.converged and r.quality.residual_inf < _TOL
        occ.transform = r.poses[occ.id]
        group_steps.append(_dist(occ.transform, prev))
        hand_steps.append(_dist(hand_at(f), hand_at(f - interval)))
        old = solve_occurrence_from_guess(document, part, occ.id, hand_at(f))  # py-slvs from the same wish
        if old.converged:
            slvs_steps.append(_dist(old.transform, slvs_prev))
            slvs_prev = old.transform
    with capsys.disabled():
        print("\nANCHOR STEPS per 9-frame interval (weighted mm): hand max %.3f | group max %.3f | py-slvs max %.3f"
              % (max(hand_steps), max(group_steps), max(slvs_steps) if slvs_steps else float("nan")))
    assert slvs_steps and max(group_steps) <= max(slvs_steps) + 1e-6, (group_steps, slvs_steps)
    assert max(group_steps) <= 1.5 * max(hand_steps), (group_steps, hand_steps)


# ---- quality.max_step (projector spec section 6) --------------------------------


def _max_steps(root, wishes):
    document = get_document()
    part = document.parts[root]
    occ = part.occurrences[0]
    settled = solve_group(document, part, occ.id, None, lever_arm=_L)
    occ.transform = settled.poses[occ.id]
    out = []
    for delta in wishes:
        r = solve_group(document, part, occ.id, apply_delta(occ.transform, delta), lever_arm=_L)
        assert r.converged
        out.append(r.quality.max_step)
    return out


def test_max_step_is_null_where_the_screw_projection_is_exact():
    """Flat mates and concentric about ANY axis (also the off-axis pin) are screw orbits: no curvature to guard."""
    root, _plate, _parts = _plate_bcd()
    stored = get_document().parts[root].occurrences[0].transform
    flat = solve_group(get_document(), get_document().parts[root], "occ-B", apply_delta(stored, (0.0, 6.0, 0.0, 0, 0, 0)), lever_arm=10.0)
    assert flat.converged and flat.quality.max_step is None
    swing = _max_steps(_offset_pin_scene(), [(0, 0, 0, 0, 0, 0), (0, 0, 15.0, 0, 0, math.radians(90))])
    # wish == stored (no step) -> None; the 90 degree swing: the screw is exact, only finite-difference noise
    # remains, so the trusted distance is null or far beyond the ~11 weighted mm the wish travels
    assert swing[0] is None and (swing[1] is None or swing[1] > 50.0), swing


def test_max_step_is_finite_on_the_angle_cone_and_independent_of_the_wish_length(capsys):
    root = _plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0)
    small, large, about_axis = _max_steps(root, [(0, 0, 0, 0.0, 0.05, 0.0), (0, 0, 0, 0.0, 0.5, 0.0), (0, 0, 0, 0.0, 0.0, 0.5)])
    with capsys.disabled():
        print("\nmax_step angle cone (weighted mm): small wish %s | large wish %s" % (small, large))
    assert small is not None and large is not None and 0.0 < large
    assert about_axis is None  # rotation about the cone's world axis is an exact orbit
    assert abs(small - large) < 0.1 * large  # a curvature property: error ~ d^2, so the trusted distance does not depend on the wish length


def test_max_step_reaches_the_http_response():
    root = _plate_scene("angle", start=((5, 5, 60), (1, 0, 0), 45.0), value=60.0)
    document = get_document()
    occ = document.parts[root].occurrences[0]
    settled = solve_group(document, document.parts[root], occ.id, None, lever_arm=_L)
    occ.transform = settled.poses[occ.id]
    wish = apply_delta(occ.transform, (0.0, 0.0, 0.0, 0.0, 0.5, 0.0))
    body = {"transform": {"translation": list(wish.translation), "rotation_axis": list(wish.rotation_axis),
                          "rotation_angle_degrees": wish.rotation_angle_degrees}, "lever_arm": _L}
    response = client.post(f"/document/parts/{root}/occurrences/{occ.id}/mate-motion", json=body)
    assert response.status_code == 200, response.text
    assert response.json()["quality"]["max_step"] is not None and response.json()["quality"]["max_step"] > 0
    flat = client.post(f"/document/parts/{root}/occurrences/{occ.id}/mate-motion", json={"transform": None, "lever_arm": _L})
    assert flat.json()["quality"]["max_step"] is None


# ---- floating bolt + plate (nothing fixed): large rigid-group wishes ---------------------------------


def _floating_bolt_scene():
    """A plate with a through hole and a bolt standing in it, BOTH floating occurrences of an empty root
    (nothing fixed): concentric (bolt shank / hole) + coincident (bolt end face on the plate top). Group dof 7:
    the rigid-body motions plus the bolt's spin."""
    from tests.test_assembly_solver import _add_point, _create_part
    plate = _make_box_part("HolePlate", size=60.0, depth=10.0)
    sf = client.post(f"/document/parts/{plate['id']}/features/sketch", json={"plane": "XY"}).json()
    center = _add_point(sf["sketch_id"], 30.0, 30.0)
    assert client.post(f"/sketch/sketches/{sf['sketch_id']}/circles", json={"center_point_id": center["id"], "radius": 5.0, "angle": 0.0}).status_code == 201
    cut = client.post(f"/document/parts/{plate['id']}/extrude-features", json={
        "sketch_feature_id": sf["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": [plate["body_id"]]})
    assert cut.status_code == 201, cut.text
    bolt = _make_cylinder_part("Bolt", radius=4.0, depth=20.0)
    root = _compose(_create_part("BoltAssembly"), [("occ-plate", plate, (0, 0, 0)), ("occ-bolt", bolt, (30, 30, 10))])
    _mate(root, "concentric", "occ-bolt", _cyl(bolt), "occ-plate", _cyl(plate))
    _mate(root, "coincident", "occ-bolt", _face(bolt, (0, 0, -1)), "occ-plate", _face(plate, (0, 0, 1)))
    return root


def test_floating_bolt_turned_by_large_angles_about_x_and_y_follows_the_wish():
    """Regression (owner report): with nothing fixed, turning a bolt mated to a plate worked for a while and then
    'cannot follow that move'. Plain Gauss-Newton from 'followers where they are' failed at a quarter turn about x/y and
    returned a pose with the bolt pulled back towards where it was for 120 deg and more; the solve now seeds the
    followers at the screw prediction, so the bolt lands (within a fraction of a degree) at the wish."""
    root = _floating_bolt_scene()
    document = get_document()
    part = document.parts[root]
    analysis0 = solve_group(document, part, "occ-bolt", None, lever_arm=20.0)
    assert analysis0.converged and analysis0.analysis.dof == 7 and analysis0.analysis.grounded is False
    stored = next(o for o in part.occurrences if o.id == "occ-bolt").transform
    for axis in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
        for degrees in (10, 30, 60, 90, 120, 150, 180):
            wish = apply_delta(stored, (0, 0, 0, *(np.array(axis, float) * math.radians(degrees))))
            result = solve_group(document, part, "occ-bolt", wish, lever_arm=20.0)
            assert result.converged and result.quality.residual_inf < _TOL, (axis, degrees, result.quality)
            off = math.degrees(float(np.linalg.norm(pose_delta(result.poses["occ-bolt"], wish)[3:])))
            assert off < 0.05, (axis, degrees, off)  # the bolt sits at the wish, not dragged back
            assert float(np.linalg.norm(pose_delta(result.poses["occ-bolt"], wish)[:3])) < 1e-6
            moved = float(np.linalg.norm(pose_delta(result.poses["occ-plate"], next(o for o in part.occurrences if o.id == "occ-plate").transform)))
            if axis != (0, 0, 1):
                assert moved > 1.0, (axis, degrees)  # the plate rode along


def test_reference_poses_warm_start_the_solve():
    """`reference` = the poses a client last accepted. The solve measures 'nearest' from them, not from the stored poses:
    with a reference that already satisfies the mates and a wish equal to its grabbed pose nothing moves at all (a fixed
    point), although the stored poses are elsewhere; and an empty/None reference is the old behaviour."""
    root = _floating_bolt_scene()
    document = get_document()
    part = document.parts[root]
    stored = {o.id: o.transform for o in part.occurrences}
    wish = apply_delta(stored["occ-bolt"], (0, 0, 0, *(np.array((1.0, 0, 0)) * math.radians(60))))
    away = solve_group(document, part, "occ-bolt", wish, lever_arm=20.0)
    assert away.converged
    plain = solve_group(document, part, "occ-bolt", wish, lever_arm=20.0, reference=None)
    assert all(float(np.linalg.norm(pose_delta(plain.poses[k], away.poses[k]))) < 1e-9 for k in stored)
    # the satisfying configuration reached above, used as the reference, with its own grabbed pose as the wish: a fixed point
    again = solve_group(document, part, "occ-bolt", away.poses["occ-bolt"], lever_arm=20.0, reference=dict(away.poses))
    assert again.converged and again.quality.iterations == 0
    for oid in stored:
        assert float(np.linalg.norm(pose_delta(again.poses[oid], away.poses[oid]))) < 1e-9
    # a second step from that reference moves the follower by about the rigid motion of the step, not by a re-pick of its free freedoms
    step = apply_delta(away.poses["occ-bolt"], (0, 0, 0, *(np.array((1.0, 0, 0)) * math.radians(2))))
    nxt = solve_group(document, part, "occ-bolt", step, lever_arm=20.0, reference=dict(away.poses))
    assert nxt.converged
    plate_move = float(np.linalg.norm(pose_delta(nxt.poses["occ-plate"], away.poses["occ-plate"])[:3]))
    assert plate_move < 3.0, plate_move  # a 2 degree turn about an axis ~40 mm from the plate origin is ~1.5 mm


def test_mate_motion_endpoint_accepts_reference_poses():
    root = _floating_bolt_scene()
    from app.document.store import get_document as _gd
    stored = {o.id: o.transform for o in _gd().parts[root].occurrences}
    body = {"transform": None, "lever_arm": 20.0,
            "reference": [{"occurrence_id": k, "transform": {"translation": list(v.translation), "rotation_axis": list(v.rotation_axis), "rotation_angle_degrees": v.rotation_angle_degrees}} for k, v in stored.items()]}
    r = client.post(f"/document/parts/{root}/occurrences/occ-bolt/mate-motion", json=body)
    assert r.status_code == 200 and r.json()["converged"], r.text
    bad = dict(body, reference=[{"occurrence_id": "occ-bolt"}])
    assert client.post(f"/document/parts/{root}/occurrences/occ-bolt/mate-motion", json=bad).status_code == 422



# ---- quality.jump in the screw chart (projector spec sections 6, 13, F2) ------------


def _jumps(root, wishes):
    document = get_document()
    part = document.parts[root]
    occ = part.occurrences[0]
    settled = solve_group(document, part, occ.id, None, lever_arm=_L)
    occ.transform = settled.poses[occ.id]
    return [solve_group(document, part, occ.id, apply_delta(occ.transform, d), lever_arm=_L).quality.jump for d in wishes]


def test_screw_exp_and_log_are_exact_inverses():
    from app.document.constraint_model import exp_rot, screw_exp, screw_log

    rng = np.random.default_rng(7)
    for _ in range(20):
        d = np.concatenate([rng.normal(size=3) * 40.0, rng.normal(size=3) * 0.8])
        base = (exp_rot(rng.normal(size=3)), rng.normal(size=3) * 50.0)
        r, t = screw_exp(base, d)
        assert np.allclose(screw_log(base, (r, t)), d, atol=1e-9)
    # a pure spin about the occurrence origin (v = 0) leaves the origin in place; a pure slide is the displacement
    base = (np.eye(3), np.array([10.0, 0.0, 0.0]))
    assert np.allclose(screw_exp(base, [0, 0, 0, 0, 0, 0.5])[1], base[1])
    assert np.allclose(screw_exp(base, [0, 0, 0, 0, 0, 0.5])[0], exp_rot([0, 0, 0.5]))
    assert np.allclose(screw_exp(base, [3.0, 4.0, 5.0, 0, 0, 0])[1], [13.0, 4.0, 5.0])


def test_jump_is_measured_against_the_screw_prediction():
    """A turn about the offset pin is a screw orbit: the screw prediction lands on it, so the jump is small (the additive
    chart reported 0.35 weighted mm for the 40 degree spin and 1.83 for slide + 90 degrees, F2); flat mates stay ~0."""
    swing = _jumps(_offset_pin_scene(), [(0, 0, 0, 0, 0, math.radians(40)), (0, 0, 15.0, 0, 0, math.radians(90))])
    assert swing[0] < 0.05 and swing[1] < 0.5, swing
    root, _plate, _parts = _plate_bcd()
    stored = get_document().parts[root].occurrences[0].transform
    flat = solve_group(get_document(), get_document().parts[root], "occ-B", apply_delta(stored, (0.0, 6.0, 0.0, 0, 0, 0)), lever_arm=10.0)
    assert flat.quality.jump < 1e-6
