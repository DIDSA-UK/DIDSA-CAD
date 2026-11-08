"""B4 (docs/assembly-perf-mates-and-ui-plan.md): a Boss whose target body was split into pieces (`<id>#0`, `<id>#1`) still
fuses into those pieces instead of starting a new Body."""
from fastapi.testclient import TestClient

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_stage9_extrude import _add_square, _create_extrude_feature, _create_part, _create_sketch_feature

client = TestClient(app, headers={"X-API-Key": TEST_API_KEY})


def _add_rectangle(sketch_id: str, x0: float, y0: float, width: float, height: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + width, y0), (x0 + width, y0 + height), (x0, y0 + height)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]}
        )
        assert response.status_code == 201


def _split_boss(part_id: str) -> str:
    """A Boss over two disjoint squares: stored as two Bodies, `<id>#0` and `<id>#1`. Returns the Boss's id."""
    sketch = _create_sketch_feature(part_id)
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    _add_square(sketch["sketch_id"], 100.0, 0.0, 10.0)
    boss = _create_extrude_feature(part_id, sketch["id"]).json()
    assert set(compute_part_bodies(get_part_or_404(part_id))) == {f"{boss['id']}#0", f"{boss['id']}#1"}
    return boss["id"]


def test_a_boss_targeting_a_split_body_by_its_base_id_fuses_into_all_its_pieces():
    part = _create_part()
    boss_id = _split_boss(part["id"])
    # a bar from x=5 to x=105 overlaps both pieces
    bridge = _create_sketch_feature(part["id"])
    _add_rectangle(bridge["sketch_id"], 5.0, 0.0, 100.0, 10.0)
    response = _create_extrude_feature(part["id"], bridge["id"], target_body_ids=[boss_id])
    assert response.status_code == 201, response.text
    bodies = compute_part_bodies(get_part_or_404(part["id"]))
    assert len(bodies) == 1, list(bodies)
    # re-joined, the Body gets back the id the split pieces were made from
    assert list(bodies) == [boss_id]


def test_a_boss_that_reaches_only_one_piece_does_not_join_the_pieces():
    """The base id names both pieces, but they become one Body only if the new solid connects them: one that overlaps just
    the left piece leaves two disconnected pieces."""
    part = _create_part()
    boss_id = _split_boss(part["id"])
    short = _create_sketch_feature(part["id"])
    _add_rectangle(short["sketch_id"], 5.0, 0.0, 10.0, 10.0)  # overlaps only the left piece
    assert _create_extrude_feature(part["id"], short["id"], target_body_ids=[boss_id]).status_code == 201
    bodies = compute_part_bodies(get_part_or_404(part["id"]))
    assert len(bodies) == 2  # still two pieces: nothing connects them


def test_a_boss_away_from_its_unsplit_target_stays_a_separate_body():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    first = _create_extrude_feature(part["id"], sketch["id"]).json()
    other = _create_sketch_feature(part["id"])
    _add_square(other["sketch_id"], 50.0, 0.0, 10.0)
    _create_extrude_feature(part["id"], other["id"], target_body_ids=[first["id"]])
    # `first` is a real target but the new square does not touch it: the fuse is a compound that splits again
    bodies = compute_part_bodies(get_part_or_404(part["id"]))
    assert len(bodies) == 2


def test_an_unsplit_target_is_used_as_before():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    first = _create_extrude_feature(part["id"], sketch["id"]).json()
    overlap = _create_sketch_feature(part["id"])
    _add_square(overlap["sketch_id"], 5.0, 0.0, 10.0)
    _create_extrude_feature(part["id"], overlap["id"], target_body_ids=[first["id"]])
    assert list(compute_part_bodies(get_part_or_404(part["id"]))) == [first["id"]]


def test_the_platform_rails_from_the_owners_run_are_one_body_each():
    """tools/ai_eval/fixtures/plt-platform-6m-25t: the guardrail parts came out as 17 and 7 Bodies because the handrail
    tube is exactly tangent to the post tops, so the first fuse split the Body and every later Boss started a new one."""
    import json
    from pathlib import Path

    fixtures = Path(__file__).resolve().parents[2] / "tools" / "ai_eval" / "fixtures" / "plt-platform-6m-25t"
    for name in ("PLT_RAIL_A_001.didsa", "PLT_RAIL_B_001.didsa"):
        response = client.post("/document/import/native", json=json.loads((fixtures / name).read_text()))
        assert response.status_code == 200, response.text
        for part_id in response.json()["part_ids"]:
            assert len(compute_part_bodies(get_part_or_404(part_id))) == 1, name
