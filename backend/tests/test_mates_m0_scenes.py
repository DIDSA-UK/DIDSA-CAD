"""M0 (`docs/mates-storage-sessions-plan-2026-11-12.md`): the benchmark scenes build, are satisfied as built, and solve with the
expected degrees of freedom. The long measurement is `tests/bench_mates_m0.py` (a script, not collected). No timing is asserted."""

import numpy as np
import pytest

from app.document.assembly_group import build_group_model, solve_group
from app.document.store import get_document
from tests import mate_first_guess_scenes as guess
from tests import motion_scaling_scenes as scaling
from tests.bench_mates_m0 import client_caps, client_verdict, one_preview

SMALL = [
    lambda: scaling.chain_scene(3),
    lambda: scaling.chain_scene(3, bolts=True),
    lambda: scaling.frame_scene(4),
    lambda: scaling.linkage_scene(4),
]


@pytest.mark.parametrize("variant", ["floating", "fixed"])
@pytest.mark.parametrize("factory", SMALL)
def test_scaling_scene_builds_and_solves(factory, variant):
    scene = factory()
    if variant == "fixed":
        scaling.fix(scene.root, scene.base)
    document = get_document()
    part = document.parts[scene.root]
    model = build_group_model(document, part, scene.mover)
    assert float(np.max(np.abs(model.residual()))) < 1e-6  # satisfied as built
    result = solve_group(document, part, scene.mover, None)
    assert result.converged
    assert result.dof == (scene.expected_dof_fixed if variant == "fixed" else scene.expected_dof_floating)
    verdict = client_verdict(result.constraint_model, client_caps())
    assert verdict["members"] == len(model.member_ids) and verdict["rows"] > 0


def test_a_big_chain_is_refused_by_the_client_caps():
    scene = scaling.chain_scene(10)
    result = solve_group(get_document(), get_document().parts[scene.root], scene.mover, None)
    assert client_verdict(result.constraint_model, client_caps())["refused"]


@pytest.mark.parametrize("name", ["stack", "inset-10", "gap-6-above", "pin-in-post"])
def test_first_guess_scene_truth_is_recognised_and_near_start_previews(name):
    scene = guess.SCENES[name]()
    assert scene.correct(scene.true_pose)
    start = guess.start_pose(scene, "near", np.random.default_rng(1))
    assert not scene.correct(start) or name == "stack"
    outcome = one_preview(scene, start)
    assert outcome["converged"]
    assert set(guess.trial_picks(scene, np.random.default_rng(2))) == {guess.DRIVEN, guess.FIXED}
