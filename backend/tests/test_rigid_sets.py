"""M1 of `docs/mates-storage-sessions-plan-2026-11-12.md`: rigid sets in the group solve (`app/document/rigid_sets.py`).

* the M0 scaling scenes give the same answers with sets as without (`assembly_group.rigid_sets_enabled`): at rest the same poses to
  1e-9, with a wish the same weighted distance to the wish (where the answer is unique - a rigid chain - the same poses too);
* a locked pair reports one set; suppressing one of its mates splits it; a set fixed to the ground reports none;
* the risk rule: a `near` (amber) mate still locks, a broken one does not; a limit never merges its parts;
* the constraint model is version 8 only when a set exists, and the routes still list every member;
* previews (redundant, conflicting) and the legacy table-top fixture answer as before;
* the 50-plate chain solves as one body (time reported with `check_timing`, never a gate)."""

import time

import numpy as np
import pytest

from app.document import assembly_group as ag
from app.document import rigid_sets
from app.document.assembly_group import apply_delta, bounding_radius, build_group_model, constraint_report, pose_delta, solve_group
from app.document.constraint_model import FOLLOW_MODEL_VERSION, RIGID_MODEL_VERSION, rigid_to_pose, weights, wish_cost
from app.document.store import get_document
from tests import motion_scaling_scenes as scaling
from tests import motion_scenes as ms
from tests.test_assembly_group import _compose, _doc, _face, _mate, client
from tests.test_assembly_solver import _create_part, _make_box_part
from tests.timing import check_timing

SMALL = {
    "chain-3": lambda: scaling.chain_scene(3),
    "chain-3-bolts": lambda: scaling.chain_scene(3, bolts=True),
    "frame-4": lambda: scaling.frame_scene(4),
    "linkage-4": lambda: scaling.linkage_scene(4),
}


@pytest.fixture
def unreduced():
    """Runs a block with rigid sets switched off, restoring the switch afterwards."""

    class Switch:
        def __call__(self, fn):
            ag.rigid_sets_enabled = False
            try:
                return fn()
            finally:
                ag.rigid_sets_enabled = True

    yield Switch()
    ag.rigid_sets_enabled = True


def _max_pose_diff(a: dict, b: dict) -> float:
    assert set(a) == set(b)
    return max(float(np.max(np.abs(pose_delta(a[k], b[k])))) for k in a)


def _scene(name: str, variant: str):
    scene = SMALL[name]()
    if variant == "fixed":
        scaling.fix(scene.root, scene.base)
    document, part = _doc(scene.root)
    return scene, document, part


# ---- the M0 scenes: same answers ---------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("variant", ["floating", "fixed"])
@pytest.mark.parametrize("name", list(SMALL))
def test_m0_scenes_at_rest_give_the_same_poses_and_analysis(name, variant, unreduced):
    scene, document, part = _scene(name, variant)
    plain = unreduced(lambda: solve_group(document, part, scene.mover, None))
    merged = solve_group(document, part, scene.mover, None)
    assert plain.converged and merged.converged
    assert _max_pose_diff(plain.poses, merged.poses) < 1e-9
    assert merged.dof == plain.dof
    assert merged.analysis.member_ids == plain.analysis.member_ids  # every member is still listed, in the same order
    assert merged.analysis.mobility == plain.analysis.mobility
    assert merged.analysis.basis.shape == plain.analysis.basis.shape
    # the same free-motion space: each basis lies in the other's span (rows orthonormal in the same metric)
    lever = merged.analysis.lever_arm
    w = np.tile([1.0, 1.0, 1.0, lever, lever, lever], len(merged.analysis.member_ids))
    a, b = plain.analysis.basis * w, merged.analysis.basis * w
    if a.size:
        assert np.allclose(b @ b.T, np.eye(len(b)), atol=1e-8)
        assert float(np.linalg.norm(a - (a @ b.T) @ b)) < 1e-6
    assert merged.solved_bodies is not None and merged.solved_bodies < len(merged.poses)  # every M0 scene has a set


@pytest.mark.parametrize("variant", ["floating", "fixed"])
@pytest.mark.parametrize("name", list(SMALL))
def test_m0_scenes_with_a_wish_land_as_near_the_wish(name, variant, unreduced):
    """With a wish the answer is the weighted-nearest point, which is not unique where followers have free motion of their own (a
    bolt's spin, the linkage): the two solves may take different paths to it. They must agree on the distance to the wish (the
    objective) and on the grabbed pose; poses only where the answer is unique."""
    scene, document, part = _scene(name, variant)
    stored = {o.id: o.transform for o in part.occurrences}
    wish = apply_delta(stored[scene.mover], (5.0, 0.0, 0.0, 0.0, 0.0, np.radians(5.0)))
    plain = unreduced(lambda: solve_group(document, part, scene.mover, wish))
    merged = solve_group(document, part, scene.mover, wish)
    assert plain.converged and merged.converged and plain.dof == merged.dof
    lever = bounding_radius(document, part, scene.mover)
    ids = list(plain.poses)
    gi = ids.index(scene.mover)
    wishes = [rigid_to_pose(wish if oid == scene.mover else stored[oid]) for oid in ids]
    for follower in (1e-2, 1e-4):
        w = weights(len(ids), lever, gi, follower)
        c_plain = wish_cost([rigid_to_pose(plain.poses[o]) for o in ids], wishes, w)
        c_merged = wish_cost([rigid_to_pose(merged.poses[o]) for o in ids], wishes, w)
        assert abs(c_merged - c_plain) <= 1e-8 * max(1.0, c_plain)
    metric = np.array([1.0, 1.0, 1.0, lever, lever, lever])
    off = lambda r: float(np.linalg.norm(pose_delta(r.poses[scene.mover], wish) * metric))
    assert abs(off(merged) - off(plain)) < 1e-5
    if name in ("chain-3", "frame-4"):  # the whole group is one rigid body: one answer, to the solver's tolerance (_SOLVE_TOL 1e-7)
        assert _max_pose_diff(plain.poses, merged.poses) < 1e-7


# ---- detection and reporting -------------------------------------------------------------------------------------------------------


def _locked_pair(fix_a: bool = False):
    """Two boxes, B against A's +x side, bottoms and -y sides flush: three plane mates lock B to A (rank 6)."""
    box = _make_box_part("LockBox", size=8.0, depth=4.0)
    root = _compose(_create_part("LockedPair"), [("occ-A", box, (0.0, 0.0, 0.0)), ("occ-B", box, (8.0, 0.0, 0.0))])
    ids = [
        _mate(root, "coincident", "occ-B", _face(box, (-1, 0, 0)), "occ-A", _face(box, (1, 0, 0)))["id"],
        _mate(root, "coincident", "occ-B", _face(box, (0, 0, -1)), "occ-A", _face(box, (0, 0, -1)), alignment="aligned")["id"],
        _mate(root, "coincident", "occ-B", _face(box, (0, -1, 0)), "occ-A", _face(box, (0, -1, 0)), alignment="aligned")["id"],
    ]
    if fix_a:
        ms.fix(root, "occ-A")
    return root, box, ids


def _status(root):
    return client.get(f"/document/parts/{root}/constraint-status").json()


def test_a_locked_pair_reports_one_set_and_its_mates_lie_inside_it():
    root, _box, mate_ids = _locked_pair()
    status = _status(root)
    assert status["occ-A"]["rigid_set"] == status["occ-B"]["rigid_set"] == "occ-A"
    assert status["occ-A"]["status"] == "under_constrained" and status["occ-A"]["dof"] == 6  # the pair floats as one body
    mates = {m["id"]: m for m in client.get(f"/document/parts/{root}/mates").json()}
    assert all(mates[mid]["rigid_set"] == "occ-A" for mid in mate_ids)
    document, part = _doc(root)
    result = solve_group(document, part, "occ-B", None)
    assert result.converged and result.solved_bodies == 1 and result.rigid_sets == {"occ-A": "occ-A", "occ-B": "occ-A"}
    spec = result.constraint_model
    assert spec["version"] == RIGID_MODEL_VERSION and spec["members"] == ["occ-B"] and spec["mates"] == []
    assert [f["id"] for s in spec["rigid_sets"] for f in s["followers"]] == ["occ-A"]
    # the drag answer still lists both members, with a basis over both
    body = client.post(f"/document/parts/{root}/occurrences/occ-B/mate-motion", json={"include_constraint_model": True}).json()
    assert body["converged"] and [m["occurrence_id"] for m in body["members"]] == ["occ-B", "occ-A"]
    assert len(body["basis"]) == 6 and all(len(row) == 12 for row in body["basis"])
    assert body["constraint_model"]["version"] == RIGID_MODEL_VERSION


def test_suppressing_one_mate_splits_the_set():
    root, _box, mate_ids = _locked_pair()
    assert _status(root)["occ-B"]["rigid_set"] == "occ-A"
    response = client.patch(f"/document/parts/{root}/mates/{mate_ids[0]}", json={"suppressed": True})
    assert response.status_code == 200, response.text
    status = _status(root)
    assert status["occ-A"]["rigid_set"] is None and status["occ-B"]["rigid_set"] is None
    document, part = _doc(root)
    result = solve_group(document, part, "occ-B", None)
    assert result.converged and result.dof == 7  # one plane mate fewer: B also slides along x on its own
    assert result.solved_bodies is None and result.constraint_model["version"] != RIGID_MODEL_VERSION


def test_a_set_fixed_to_the_ground_reports_no_id():
    root, _box, _ids = _locked_pair(fix_a=True)
    status = _status(root)
    assert status["occ-A"] == {"status": "fixed", "dof": 0, "free_motions": [], "rigid_set": None}
    assert status["occ-B"] == {"status": "fully_constrained", "dof": 0, "free_motions": [], "rigid_set": None}


def _move_b(root, dx: float) -> None:
    response = client.patch(
        f"/document/parts/{root}/occurrences/occ-B",
        json={"transform": {"translation": [8.0 + dx, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}},
    )
    assert response.status_code == 200, response.text


def test_a_near_mate_still_locks_and_a_broken_one_does_not():
    root, _box, mate_ids = _locked_pair()
    _move_b(root, 0.002)  # the x mate misses by 0.002 mm: near (amber), within the 0.01 mm limit
    mates = {m["id"]: m for m in client.get(f"/document/parts/{root}/mates").json()}
    assert mates[mate_ids[0]]["status"] == "near"
    assert _status(root)["occ-B"]["rigid_set"] == "occ-A"
    _move_b(root, 2.0)  # 2 mm: broken - it does not lock, so the pair is no set (the solve then pulls B back)
    mates = {m["id"]: m for m in client.get(f"/document/parts/{root}/mates").json()}
    assert mates[mate_ids[0]]["status"] == "broken"
    assert _status(root)["occ-B"]["rigid_set"] is None
    document, part = _doc(root)
    result = solve_group(document, part, "occ-B", None)
    assert result.converged and result.solved_bodies is None
    assert abs(result.poses["occ-B"].translation[0] - result.poses["occ-A"].translation[0] - 8.0) < 1e-7


def test_a_limit_never_merges_its_parts():
    root, box, _ids = _locked_pair()
    response = client.post(
        f"/document/parts/{root}/mates",
        json={"type": "limit_distance", "references": [{"occurrence_id": "occ-B", **_face(box, (1, 0, 0))}, {"occurrence_id": "occ-A", **_face(box, (1, 0, 0))}],
              "limit_min": 0.0, "limit_max": 20.0},
    )
    assert response.status_code == 201, response.text
    assert _status(root)["occ-B"]["rigid_set"] is None
    document, part = _doc(root)
    model = build_group_model(document, part, "occ-B")
    assert {"occ-A", "occ-B"} <= rigid_sets._never_merged(model)
    assert not rigid_sets.detect(document, part, model)


def test_the_source_of_a_followed_pattern_copy_never_joins_a_set():
    from tests.test_mate_pattern_copy import _follower_model, _mate_and_settle, _scene as copy_scene

    scene = copy_scene()
    _mate_and_settle(scene)
    model = _follower_model(scene)
    assert "src" in rigid_sets._never_merged(model)
    assert not any("src" in group for group in rigid_sets.detect(get_document(), get_document().parts[scene["top"]["id"]], model).groups)
    result = solve_group(get_document(), get_document().parts[scene["top"]["id"]], "mover", None)
    assert result.constraint_model["version"] == FOLLOW_MODEL_VERSION  # no set here: the model is the v7 one, unchanged


def test_detection_is_cached_and_a_mate_change_misses_the_cache():
    root, _box, mate_ids = _locked_pair()
    document, part = _doc(root)
    rigid_sets.clear_cache()
    before = dict(rigid_sets.cache_stats)
    solve_group(document, part, "occ-B", None)
    solve_group(document, part, "occ-A", None)  # the other member grabbed: same component state, a hit
    assert rigid_sets.cache_stats["misses"] - before["misses"] == 1
    assert rigid_sets.cache_stats["hits"] - before["hits"] >= 1
    client.patch(f"/document/parts/{root}/mates/{mate_ids[1]}", json={"suppressed": True})
    solve_group(document, part, "occ-B", None)
    assert rigid_sets.cache_stats["misses"] - before["misses"] == 2


# ---- previews and the constraint model -----------------------------------------------------------------------------------------------


def _preview_summary(body: dict) -> dict:
    members = {m["occurrence_id"]: m["transform"] for m in body.get("members") or []}
    return {
        "converged": body["converged"],
        "blocked_by": body.get("blocked_by"),
        "conflicting": body.get("conflicting"),
        "branch_changes": body.get("branch_changes"),
        "alternatives": [(a["alignment"], a["secondary_flip"]) for a in body.get("alternatives") or []],
        "driven": members,
    }


@pytest.mark.parametrize("case", ["redundant", "conflict"])
@pytest.mark.parametrize("name", ["chain-3", "frame-4"])
def test_previews_answer_as_before(name, case, unreduced):
    scene, _document, _part = _scene(name, "floating")
    payload = scene.redundant_mate if case == "redundant" else scene.conflict_mate

    def call():
        return client.post(f"/document/parts/{scene.root}/occurrences/{scene.inside_driven}/preview-mate-solve", params={"movement": "group"}, json=payload).json()

    plain, merged = _preview_summary(unreduced(call)), _preview_summary(call())
    for key in ("converged", "blocked_by", "conflicting", "branch_changes", "alternatives"):
        assert plain[key] == merged[key], key
    assert merged["converged"] == (case == "redundant")
    for oid, t in plain["driven"].items():
        assert np.allclose(t["translation"], merged["driven"][oid]["translation"], atol=1e-6)


def test_no_set_keeps_the_old_model_version():
    root, roles = ms.bolt_scene()  # a bolt that spins in a plate: no two parts locked together
    document, part = _doc(root)
    result = solve_group(document, part, roles["mover"], None)
    assert result.converged and result.solved_bodies is None and result.rigid_sets == {}
    assert result.constraint_model["version"] < RIGID_MODEL_VERSION and "rigid_sets" not in result.constraint_model


# ---- legacy fixtures ------------------------------------------------------------------------------------------------------------------


def test_the_table_top_fixture_keeps_its_poses_and_statuses(unreduced):
    from tests import table_top_fixture as tt

    root = tt.import_table_top(client)
    document, part = _doc(root)
    plain_status = unreduced(lambda: constraint_report(document, part))
    assert constraint_report(document, part) == plain_status
    for occurrence in part.occurrences:
        if occurrence.fixed or not any(occurrence.id in {r.occurrence_id.split("/")[0] for r in m.references} for m in part.mates):
            continue
        plain = unreduced(lambda: solve_group(document, part, occurrence.id, None))
        merged = solve_group(document, part, occurrence.id, None)
        assert plain.converged == merged.converged
        if plain.converged:
            assert _max_pose_diff(plain.poses, merged.poses) < 1e-9
            assert plain.near.keys() == merged.near.keys()


def test_the_platform_module_plan_builds_with_the_same_near_mates():
    """tools/ai_eval/fixtures/plt-platform-6m-25t, the module plan (93 mates) replayed the way the app builds it: before M1 it ends
    with 85 ok + 8 near mates, each 0.00385 mm (docs/status.md, B1). Near mates count as locking; a set held by mates that disagree
    gets the unreduced Gauss-Newton steps at the end (`assembly_group._expand_result`), so the same 8 come out with the same miss."""
    import contextlib
    import io
    import sys
    from pathlib import Path

    fixtures = Path(__file__).resolve().parents[2] / "tools" / "ai_eval" / "fixtures" / "plt-platform-6m-25t"
    if not fixtures.is_dir():  # the backend's CI image holds backend/ only, not tools/
        pytest.skip("tools/ai_eval fixtures are not in this checkout")
    sys.path.insert(0, str(fixtures.parents[1]))
    try:
        import replay_bundle_mates
    finally:
        sys.path.pop(0)
    argv = sys.argv
    sys.argv = ["replay", str(fixtures), "PLT_MODULE_001.didsa", str(fixtures / "plan" / "90_PLT_MODULE.json"), "--build"]
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            replay_bundle_mates.main()
    finally:
        sys.argv = argv
    text = out.getvalue()
    assert "built: 93 mates tried, 0 failures" in text, text[-2000:]
    assert "93 built = 85 ok + 8 near + 0 broken" in text, text[-2000:]
    residuals = [float(line.split("residual ")[1].split(" mm")[0]) for line in text.splitlines() if line.strip().startswith("near ")]
    assert len(residuals) == 8 and max(residuals) < 0.004


# ---- scaling --------------------------------------------------------------------------------------------------------------------------


def test_the_50_plate_chain_solves_as_one_body():
    times = {}
    for name, n in (("50 plates", 50), ("2 plates", 2)):
        scene = scaling.chain_scene(n)  # an import: it replaces the document, so one scene at a time
        document, part = _doc(scene.root)
        stored = {o.id: o.transform for o in part.occurrences}[scene.mover]
        wish = apply_delta(stored, (5.0, 0.0, 0.0, 0.0, 0.0, np.radians(5.0)))
        result = solve_group(document, part, scene.mover, wish)  # warm (bodies, detection cache)
        assert result.converged and result.solved_bodies == 1 and result.dof == 6
        assert len(result.poses) == n
        best = float("inf")
        for _ in range(3):
            began = time.perf_counter()
            solve_group(document, part, scene.mover, wish)
            best = min(best, time.perf_counter() - began)
        times[name] = best
    # The plan's target: about the time of a 1 to 2 member group. Building the 50-plate model (geometry of 147 mates) is still per
    # member, so a ratio is reported, never gated.
    check_timing(times["50 plates"] / times["2 plates"], 6.0, "solve_group with a wish, 50-plate chain / 2-plate chain", unit="x")
