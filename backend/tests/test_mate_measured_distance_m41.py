"""M4.1 (`docs/mates-storage-sessions-plan-2026-11-12.md`): a Distance previewed where the parts already are. `measure_value: true` and no
value: the preview measures the two picks at the stored poses (`app.document.mate_measure`), answers `measured_value` and solves the
ordinary preview with it (parallel at the current distance, on the current side)."""

import numpy as np
import pytest

from tests import mate_first_guess_scenes as guess
from tests.test_assembly_solver import client


def _measured(scene, start_kind="near", seed=4, **extra):
    guess.set_pose(scene, guess.start_pose(scene, start_kind, np.random.default_rng(seed)))
    body = {k: v for k, v in scene.payload.items() if k != "value"}
    response = client.post(
        f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}/preview-mate-solve", params={"movement": "auto"}, json={**body, "measure_value": True, **extra}
    )
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize("name", ["gap-6-above", "inset-10", "overhang-3", "vertex-6-above", "axis-distance-25"])
def test_a_distance_without_a_value_is_previewed_at_the_measured_distance(name):
    scene = guess.SCENES[name]()
    answer = _measured(scene)
    assert answer["converged"] and answer["measured_value"] > 0
    # the ghost holds exactly that distance: the scene's signature reads the driven pick's offset (planes / a vertex) or the axes' gap
    signature = scene.signature(guess.shown_transform(answer))
    assert abs(abs(signature[-1]) - answer["measured_value"]) < 1e-6
    # ...and is the same answer a client gets by sending that value itself (what it does next, from the box it filled in)
    again = guess.preview(scene, value=answer["measured_value"])
    assert {k: v for k, v in answer.items() if k != "measured_value"} == again


def test_measured_value_is_rounded_to_a_micrometre():
    answer = _measured(guess.SCENES["gap-6-above"]())
    assert answer["measured_value"] == round(answer["measured_value"], 3)


def test_the_measured_preview_keeps_the_part_on_its_current_side():
    # inset-10 from a near start: the part's face is on one side of the base's; the measured ghost stays on it (Closest), no jump across
    scene = guess.SCENES["inset-10"]()
    for seed in range(6):
        answer = _measured(scene, seed=seed)
        guess.set_pose(scene, guess.start_pose(scene, "near", np.random.default_rng(seed)))
        plain = guess.preview(scene)  # the same picks with the scene's value: the side Closest takes from this start
        assert answer["resolved"]["secondary_flip"] == plain["resolved"]["secondary_flip"]


def test_two_round_faces_measure_the_gap_between_their_axes():
    scene = guess.SCENES["pin-in-post"]()
    pin, bore = scene.payload["references"]
    guess.set_pose(scene, scene.true_pose)
    response = client.post(f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}/preview-mate-solve", json={"type": "distance", "references": [pin, bore], "measure_value": True})
    assert response.status_code == 200 and response.json()["measured_value"] == 0.0  # the pin stands in the bore: its axis is on the bore's


def test_picks_that_cannot_be_measured_answer_null():
    # two flat faces of the same kind of request, but a reference that does not resolve: nothing to measure, the old "no ghost" answer
    scene = guess.SCENES["gap-6-above"]()
    driven, fixed = scene.payload["references"]
    broken = {**driven, "subshape_ref": {**driven["subshape_ref"], "index": 999}}
    data = client.post(f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}/preview-mate-solve", json={"type": "distance", "references": [broken, fixed], "measure_value": True}).json()
    assert data["converged"] is False and "measured_value" in data and data["measured_value"] is None


def test_without_measure_value_nothing_changes():
    scene = guess.SCENES["gap-6-above"]()
    body = {k: v for k, v in scene.payload.items() if k != "value"}
    data = client.post(f"/document/parts/{scene.root}/occurrences/{guess.DRIVEN}/preview-mate-solve", json=body).json()
    assert data["converged"] is False and "measured_value" not in data
    # a value given wins: measure_value is ignored and the answer is the ordinary one (no measured_value key)
    with_value = guess.preview(scene, measure_value=True)
    assert "measured_value" not in with_value and with_value == guess.preview(scene)
    # other types ignore it
    assert "measured_value" not in guess.preview(guess.SCENES["stack"](), measure_value=True)
