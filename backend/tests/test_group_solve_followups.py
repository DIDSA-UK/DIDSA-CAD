"""M1.1 of `docs/mates-storage-sessions-plan-2026-11-12.md`: follow-ups to the rigid sets of M1.

* the built-model cache (`assembly_group.build_group_model`): a repeat call reuses the model, the cached model is the one a fresh
  build gives, and every mate / fix / suppress / pose / feature change misses it;
* a set locked to the ground keeps only enough of its mates to the fixed parts to hold it (`rigid_sets._prune_ground_rows`), with
  the same answers;
* one time budget for a whole preview (`assembly_group.PREVIEW_SECONDS`, `budget_exhausted`) and the stall stop of a conflicting
  retraction;
* rigid sets next to a coupler and next to a followed pattern copy give the answers of the unreduced solve."""

import numpy as np
import pytest

from app.document import assembly_group as ag
from app.document.assembly_group import apply_delta, bounding_radius, build_group_model, pose_delta, solve_group
from app.document.constraint_model import RIGID_MODEL_VERSION, ConstraintModel, rigid_to_pose, weights, wish_cost
from app.document.store import get_document
from tests import motion_scaling_scenes as scaling
from tests.motion_scenes import fix
from tests.test_assembly_group import _cyl, _doc, _face, _mate, client
from tests.test_rigid_sets import _locked_pair


@pytest.fixture
def switch():
    """`switch(fn, rigid=False, cache=False)` runs `fn` with rigid sets and / or the model cache off, restoring both afterwards."""

    def run(fn, rigid=True, cache=True):
        ag.rigid_sets_enabled, ag.model_cache_enabled = rigid, cache
        try:
            return fn()
        finally:
            ag.rigid_sets_enabled = ag.model_cache_enabled = True

    yield run
    ag.rigid_sets_enabled = ag.model_cache_enabled = True


def _same_answer(document, part, grabbed, wish, switch):
    """The rigid-set solve against the unreduced one: same convergence and dof, the same weighted distance to the wish."""
    plain = switch(lambda: solve_group(document, part, grabbed, wish), rigid=False)
    merged = solve_group(document, part, grabbed, wish)
    assert plain.converged and merged.converged and plain.dof == merged.dof
    stored = {o.id: o.transform for o in part.occurrences}
    lever = bounding_radius(document, part, grabbed)
    ids = list(plain.poses)
    wishes = [rigid_to_pose(wish if oid == grabbed and wish is not None else stored[oid]) for oid in ids]
    w = weights(len(ids), lever, ids.index(grabbed), 1e-2)
    costs = [wish_cost([rigid_to_pose(r.poses[o]) for o in ids], wishes, w) for r in (plain, merged)]
    assert abs(costs[0] - costs[1]) <= 1e-8 * max(1.0, costs[0])
    return plain, merged


# ---- the built-model cache -------------------------------------------------------------------------------------------------------


def _sides_text(model) -> list:
    return [(repr(m), repr(a), repr(b)) for m, a, b in model.sides]


def test_a_repeat_build_hits_the_cache_and_matches_a_fresh_build(switch):
    root, _box, _ids = _locked_pair()
    document, part = _doc(root)
    ag.clear_model_cache()
    before = dict(ag.model_cache_stats)
    first = build_group_model(document, part, "occ-B")
    second = build_group_model(document, part, "occ-B")
    assert ag.model_cache_stats["misses"] - before["misses"] == 1 and ag.model_cache_stats["hits"] - before["hits"] == 1
    fresh = switch(lambda: build_group_model(document, part, "occ-B"), cache=False)
    assert _sides_text(second) == _sides_text(fresh) and second.branches == fresh.branches
    assert second.base_transforms == fresh.base_transforms and second.member_ids == fresh.member_ids
    # each call gets its own copy: changing one does not change the next
    second.base_transforms["occ-A"] = apply_delta(second.base_transforms["occ-A"], (1.0, 0, 0, 0, 0, 0))
    second.branches.clear()
    third = build_group_model(document, part, "occ-B")
    assert third.base_transforms == first.base_transforms and third.branches == first.branches


def _misses_after(change) -> None:
    root, box, ids = _locked_pair()
    document, part = _doc(root)
    build_group_model(document, part, "occ-B")
    before = ag.model_cache_stats["misses"]
    change(root, box, ids, part)
    build_group_model(document, part, "occ-B")
    assert ag.model_cache_stats["misses"] == before + 1


def test_a_suppressed_mate_misses_the_cache():
    _misses_after(lambda root, _b, ids, _p: client.patch(f"/document/parts/{root}/mates/{ids[0]}", json={"suppressed": True}))


def test_a_branch_change_misses_the_cache():
    _misses_after(lambda root, _b, ids, _p: client.patch(f"/document/parts/{root}/mates/{ids[1]}", json={"alignment": "anti_aligned"}))


def test_fixing_an_occurrence_misses_the_cache():
    _misses_after(lambda root, _b, _ids, _p: fix(root, "occ-A"))


def test_moving_an_occurrence_misses_the_cache():
    def move(root, _b, _ids, _p):
        response = client.patch(
            f"/document/parts/{root}/occurrences/occ-B",
            json={"transform": {"translation": [9.0, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}},
        )
        assert response.status_code == 200, response.text

    _misses_after(move)


def test_a_feature_edit_in_a_placed_part_misses_the_cache_and_the_new_geometry_is_used(switch):
    root, box, _ids = _locked_pair()
    document, part = _doc(root)
    build_group_model(document, part, "occ-B")
    before = ag.model_cache_stats["misses"]
    extrude = next(f for f in document.parts[box["id"]].features if type(f).__name__ == "ExtrudeFeature")
    response = client.patch(f"/document/parts/{box['id']}/extrude-features/{extrude.id}", json={"end_distance": 7.0})
    assert response.status_code == 200, response.text
    edited = build_group_model(document, part, "occ-B")
    assert ag.model_cache_stats["misses"] == before + 1
    # what the cache now serves is what a fresh build of the edited part gives
    assert _sides_text(edited) == _sides_text(switch(lambda: build_group_model(document, part, "occ-B"), cache=False))
    assert _sides_text(build_group_model(document, part, "occ-B")) == _sides_text(edited) and ag.model_cache_stats["misses"] == before + 1


# ---- ground rows ---------------------------------------------------------------------------------------------------------------


def test_a_set_on_the_ground_keeps_only_the_rows_that_hold_it(switch):
    scene = scaling.frame_scene(4)
    scaling.fix(scene.root, scene.base)
    document, part = _doc(scene.root)
    stored = {o.id: o.transform for o in part.occurrences}
    for wish in (None, apply_delta(stored[scene.mover], (5.0, 0.0, 0.0, 0.0, 0.0, 0.08))):
        plain, merged = _same_answer(document, part, scene.mover, wish, switch)
        assert max(float(np.max(np.abs(pose_delta(plain.poses[k], merged.poses[k])))) for k in plain.poses) < 1e-9
    spec = merged.constraint_model
    assert spec["version"] == RIGID_MODEL_VERSION and spec["members"] == [scene.mover]
    identity = [(np.eye(3), np.zeros(3))]
    assert len(ConstraintModel(spec).residual(identity, with_jacobian=False)) == 12  # 44 before M1.1: the redundant mates to the base are checked once instead
    full = build_group_model(document, part, scene.mover)
    assert len(spec["mates"]) < sum(1 for m, _a, _b in full.sides)


# ---- one budget per preview, and the stall stop ------------------------------------------------------------------------------------


def _conflict_preview(scene):
    return client.post(
        f"/document/parts/{scene.root}/occurrences/{scene.inside_driven}/preview-mate-solve", params={"movement": "group"}, json=scene.conflict_mate
    ).json()


def test_a_preview_out_of_time_says_so_and_still_answers(monkeypatch):
    scene = scaling.chain_scene(3)
    monkeypatch.setattr(ag, "PREVIEW_SECONDS", 0.0)
    body = _conflict_preview(scene)
    assert body["converged"] is False and body["budget_exhausted"] is True
    monkeypatch.setattr(ag, "PREVIEW_SECONDS", 60.0)
    monkeypatch.setattr(ag, "BRANCH_SEARCH_SECONDS", 60.0)  # the search's own clock flags it as well: plenty of time on both
    body = _conflict_preview(scene)
    assert body["converged"] is False and body["budget_exhausted"] is False
    redundant = client.post(
        f"/document/parts/{scene.root}/occurrences/{scene.inside_driven}/preview-mate-solve", params={"movement": "group"}, json=scene.redundant_mate
    ).json()
    assert redundant["converged"] and redundant["budget_exhausted"] is False


def test_a_search_cut_short_by_its_own_clock_says_so(monkeypatch):
    """The branch search's own clock (`BRANCH_SEARCH_SECONDS`) ending the conflict step used to answer `conflicting: []` with
    `budget_exhausted: false`, as if nothing fought the new mate. With the clock at zero the search still gets its minimum solves, and
    the answer now says it stopped early."""
    scene = scaling.chain_scene(3)
    monkeypatch.setattr(ag, "PREVIEW_SECONDS", 60.0)
    monkeypatch.setattr(ag, "BRANCH_SEARCH_SECONDS", 0.0)
    body = _conflict_preview(scene)
    assert body["converged"] is False and body["budget_exhausted"] is True
    monkeypatch.setattr(ag, "BRANCH_SEARCH_SECONDS", 60.0)
    body = _conflict_preview(scene)
    assert body["converged"] is False and body["budget_exhausted"] is False and body["conflicting"]


def test_a_conflicting_retraction_stops_on_its_plateau():
    """The 7 mm conflict of the M0 chain: before M1.1 every retraction of it ran all 60 iterations (five times, with the re-weighted
    retries); now each stops once five steps take less than 1e-4 of the residual off."""
    scene = scaling.chain_scene(3)
    document, part = _doc(scene.root)
    model = build_group_model(document, part, scene.inside_driven)
    from app.document.router import _mate_entity_ref_to_domain
    from app.document.models import Mate, MateType
    from app.document.schemas import MateEntityRefResponse

    payload = scene.conflict_mate
    mate = Mate(
        id="conflict",
        type=MateType(payload["type"]),
        references=[_mate_entity_ref_to_domain(MateEntityRefResponse(**r)) for r in payload["references"]],
        value=payload["value"],
    )
    result = solve_group(document, part, scene.inside_driven, None, extra_mates=(mate,), with_jump=False)
    assert not result.converged and result.quality.residual_inf > 1.0
    assert result.quality.iterations < ag._MAX_ITERATIONS * (1 + len(ag._FOLLOWER_WEIGHT_FALLBACKS))
    assert len(model.member_ids) == 3


# ---- sets next to a coupler and next to a followed pattern copy -------------------------------------------------------------------


def test_a_set_next_to_a_gear_pair_answers_as_the_unreduced_solve(switch):
    from tests.test_coupler_mates import _gear_mate, gear_scene
    from tests.test_assembly_solver import _make_box_part

    root, _plate, shaft = gear_scene()
    _gear_mate(root, shaft)
    box = _make_box_part("RiderBox", size=8.0, depth=4.0)
    document, part = _doc(root)
    from app.document.models import Occurrence, RigidTransform

    for oid, x in (("box-1", 26.0), ("box-2", 34.0)):
        part.occurrences.append(Occurrence(id=oid, part_id=box["id"], transform=RigidTransform(translation=(x, 26.0, 30.0))))
    _mate(root, "coincident", "box-1", _face(box, (0, 0, -1)), "shaft-a", _face(shaft, (0, 0, 1)))
    _mate(root, "coincident", "box-2", _face(box, (-1, 0, 0)), "box-1", _face(box, (1, 0, 0)))
    _mate(root, "coincident", "box-2", _face(box, (0, 0, -1)), "box-1", _face(box, (0, 0, -1)), alignment="aligned")
    _mate(root, "coincident", "box-2", _face(box, (0, -1, 0)), "box-1", _face(box, (0, -1, 0)), alignment="aligned")
    stored = {o.id: o.transform for o in part.occurrences}
    wish = apply_delta(stored["shaft-a"], (0, 0, 0, 0, 0, np.radians(20.0)))
    plain, merged = _same_answer(document, part, "shaft-a", wish, switch)
    assert merged.rigid_sets == {"box-1": "box-1", "box-2": "box-1"}  # the boxes merge; the gears (a coupler) never do
    assert merged.solved_bodies == len(merged.poses) - 1
    assert max(float(np.max(np.abs(pose_delta(plain.poses[k], merged.poses[k])))) for k in ("shaft-a", "shaft-b")) < 1e-7
    model = merged.constraint_model
    assert model["version"] == RIGID_MODEL_VERSION and any(m["type"] == "gear" for m in model["mates"])


def test_a_set_next_to_a_followed_pattern_copy_answers_as_the_unreduced_solve(switch):
    from tests.test_mate_pattern_copy import _mate_and_settle, _scene as copy_scene

    scene = copy_scene()
    _mate_and_settle(scene)
    top_id = scene["top"]["id"]
    document, part = _doc(top_id)
    mover = next(o for o in part.occurrences if o.id == "mover")
    from app.document.models import Occurrence

    # a rider box locked to the mover (B against the mover's +x side, as `_locked_pair`): the mover and the rider are one set
    r, _t = rigid_to_pose(mover.transform)
    rider_pose = type(mover.transform)(
        translation=tuple(np.array(mover.transform.translation) + r @ np.array([10.0, 0.0, 0.0])),
        rotation_axis=mover.transform.rotation_axis,
        rotation_angle_degrees=mover.transform.rotation_angle_degrees,
    )
    part.occurrences.append(Occurrence(id="rider", part_id=scene["mover"]["id"], transform=rider_pose))
    m = scene["mover"]
    _mate(top_id, "coincident", "rider", _face(m, (-1, 0, 0)), "mover", _face(m, (1, 0, 0)))
    _mate(top_id, "coincident", "rider", _face(m, (0, 0, -1)), "mover", _face(m, (0, 0, -1)), alignment="aligned")
    _mate(top_id, "coincident", "rider", _face(m, (0, -1, 0)), "mover", _face(m, (0, -1, 0)), alignment="aligned")
    stored = {o.id: o.transform for o in part.occurrences}
    wish = apply_delta(stored["src"], (4.0, 3.0, 0.0, 0.0, 0.0, 0.0))
    plain, merged = _same_answer(document, part, "src", wish, switch)
    assert set(merged.rigid_sets) == {"mover", "rider"} and "src" not in merged.rigid_sets  # the copy's source never merges
    assert max(float(np.max(np.abs(pose_delta(plain.poses[k], merged.poses[k])))) for k in plain.poses) < 1e-7
    assert merged.constraint_model["version"] == RIGID_MODEL_VERSION
    assert any("follow" in s for mate in merged.constraint_model["mates"] for s in (mate["a"], mate["b"]))
