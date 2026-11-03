"""Regression tests built from the tester's frame assembly (`tests/data/frame_ai_test/`, the files attached to the
2026-11-03 report in `docs/pattern-component-bugfix-plan.md`).

B1: after confirming the second pattern, the copy of "Short Rail BOT_RIGHT" (rotated 180 degrees about an axis with X ~ 0)
rendered flipped - its length ran +Y out of the frame instead of -Y. The assembly-mesh walk converts the derived transform
to axis-angle twice, and the old 180-degree branch lost the axis sign on the second pass. Here every pattern copy's world
placement is checked against an independent expectation (a linear pattern only translates its source), rotation and
translation both - a bounding box alone would not catch a flip about the rail's own long axis.

B3: an edge on a pattern copy resolves through `component-pattern-direction` (it used to 422 with `missing_reference`).

Composing mirrors `tests/table_top_fixture.py`: every `external_ref` is resolved by file name inside the data directory and
its `resolved_part_id` set to that file's `root_part_id`. `CORNER_GUSSET_001.DIDSAprt` is the tester's `GUSSET_001.didsa`,
whose part id differs from the one the assembly last saw (`ref_part_id`) - the gussets are not patterned, so this only
matters for being loadable.
"""

import copy
import json
import math
from pathlib import Path

from fastapi.testclient import TestClient

from app.document.assembly import _mat3_from_axis_angle
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

DATA_DIR = Path(__file__).parent / "data" / "frame_ai_test"
ASSEMBLY = "FRAME_ASSY_AI_TEST.didsa"

RAIL_PATTERN = "1c85495d-578d-4a75-a917-712a57929422"
POST_PATTERN = "5cd87f1b-e4ba-47ee-b77e-97a787c307f2"
SHORT_RAIL_BOT_RIGHT = "fb10281a-4b75-458a-8f0e-835b6b814041"
SHORT_RAIL_BODY = "73702b17-fc39-4e87-9e1d-7afbf2ec0984"


def _compose() -> dict:
    parts: dict[str, dict] = {}
    sketches: dict[str, dict] = {}

    def collect(name: str) -> dict:
        data = json.loads((DATA_DIR / name).read_text())
        for sketch in data["sketches"]:
            sketches.setdefault(sketch["id"], sketch)
        for part in data["document"]["parts"]:
            for occurrence in part["occurrences"]:
                referenced = collect(occurrence["external_ref"].split("/")[-1])
                occurrence["resolved_part_id"] = referenced["document"]["root_part_id"]
            parts.setdefault(part["id"], part)
        return data

    top = collect(ASSEMBLY)
    payload = copy.deepcopy(top)
    root_id = top["document"]["root_part_id"]
    payload["document"]["parts"] = [parts[root_id], *(p for pid, p in parts.items() if pid != root_id)]
    payload["sketches"] = list(sketches.values())
    return payload


def _import() -> tuple[str, dict]:
    payload = _compose()
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200, response.text
    root = payload["document"]["parts"][0]
    return root["id"], root


def _rotation(transform: dict):
    return _mat3_from_axis_angle(tuple(transform["rotation_axis"]), transform["rotation_angle_degrees"])


def _assert_matrix_close(actual, expected, label: str) -> None:
    worst = max(abs(actual[r][c] - expected[r][c]) for r in range(3) for c in range(3))
    assert worst < 1e-6, f"{label}: rotation differs by {worst}"


def _expected_linear_offsets(pattern: dict) -> dict[int, tuple[float, float, float]]:
    """Index -> world offset of each derived instance of a linear pattern, the convention in
    `assembly.expand_component_pattern_instances` (`i * count_2 + j`, index 0 the seed), computed independently here."""

    def unit(v):
        length = math.sqrt(sum(c * c for c in v))
        return [c / length for c in v]

    d1, d2 = unit(pattern["direction"]), unit(pattern["direction_2"])
    s1 = -1.0 if pattern["reverse"] else 1.0
    s2 = -1.0 if pattern["reverse_2"] else 1.0
    count_2 = max(pattern["count_2"], 1)
    offsets = {}
    for i in range(pattern["count"]):
        for j in range(count_2):
            index = i * count_2 + j
            if index == 0:
                continue
            a = pattern["spacing"] * i * s1
            b = pattern["spacing_2"] * j * s2 if count_2 > 1 else 0.0
            offsets[index] = tuple(d1[k] * a + d2[k] * b for k in range(3))
    return offsets


def test_every_pattern_copy_in_the_frame_keeps_its_sources_orientation_and_lands_at_its_offset():
    root_id, root = _import()
    response = client.get(f"/document/parts/{root_id}/assembly-mesh")
    assert response.status_code == 200, response.text
    by_path = {"/".join(i["occurrence_path"]): i["world_transform"] for i in response.json()["instances"]}
    occurrences = {o["id"]: o for o in root["occurrences"]}

    checked = 0
    for pattern in root["component_patterns"]:
        for source_id in pattern["source_occurrence_ids"]:
            source = occurrences[source_id]["transform"]
            source_rotation = _rotation(source)
            for index, offset in _expected_linear_offsets(pattern).items():
                path = f"{source_id}#pattern:{pattern['id']}:{index}"
                label = f"{occurrences[source_id]['name_override'] or source_id} copy {index}"
                world = by_path[path]
                _assert_matrix_close(_rotation(world), source_rotation, label)
                expected_translation = [source["translation"][k] + offset[k] for k in range(3)]
                assert all(abs(world["translation"][k] - expected_translation[k]) < 1e-6 for k in range(3)), label
                checked += 1
    # 3 corner-post copies (2 x 2 grid) + 4 rail copies.
    assert checked == 7


def test_the_short_rail_bot_right_copy_runs_along_minus_y_like_its_source():
    """The exact symptom from the report: the rail's local +Z (its 1200 mm length) must map to world -Y, not +Y."""
    root_id, _ = _import()
    instances = client.get(f"/document/parts/{root_id}/assembly-mesh").json()["instances"]
    copy_path = [f"{SHORT_RAIL_BOT_RIGHT}#pattern:{RAIL_PATTERN}:1"]
    world = next(i["world_transform"] for i in instances if i["occurrence_path"] == copy_path)
    rotation = _rotation(world)
    local_z_in_world = (rotation[0][2], rotation[1][2], rotation[2][2])
    assert all(abs(a - b) < 1e-6 for a, b in zip(local_z_in_world, (0.0, -1.0, 0.0))), local_z_in_world
    assert abs(world["translation"][2] - 1200.0) < 1e-6


def _direction(root_id: str, occurrence_id: str, edge_index: int):
    return client.post(
        f"/document/parts/{root_id}/component-pattern-direction",
        json={
            "ref": {
                "occurrence_id": occurrence_id,
                "subshape_ref": {"body_id": SHORT_RAIL_BODY, "shape_type": "edge", "index": edge_index},
            }
        },
    )


def _first_straight_edge(root_id: str, occurrence_id: str) -> tuple[int, tuple[float, float, float]]:
    for index in range(64):
        response = _direction(root_id, occurrence_id, index)
        if response.status_code == 200:
            return index, tuple(response.json()["direction"])
    raise AssertionError("no straight edge found on the short rail")


def test_an_edge_on_a_linear_pattern_copy_gives_the_same_direction_as_the_seed_edge():
    root_id, _ = _import()
    index, seed_direction = _first_straight_edge(root_id, SHORT_RAIL_BOT_RIGHT)
    response = _direction(root_id, f"{SHORT_RAIL_BOT_RIGHT}#pattern:{RAIL_PATTERN}:1", index)
    assert response.status_code == 200, response.text
    copy_direction = response.json()["direction"]
    # A direction's sign is arbitrary for an edge; a linear copy is only translated, so the line is the same.
    assert abs(abs(sum(a * b for a, b in zip(seed_direction, copy_direction))) - 1.0) < 1e-9


def test_an_edge_on_a_circular_pattern_copy_is_rotated_by_the_pattern():
    root_id, _ = _import()
    created = client.post(
        f"/document/parts/{root_id}/component-patterns",
        json={
            "source_occurrence_ids": [SHORT_RAIL_BOT_RIGHT],
            "pattern_type": "circular",
            "axis": {"origin": [1200.0, 600.0, 0.0], "direction": [0.0, 0.0, 1.0]},
            "count_angular": 4,
            "angle_total": 360.0,
        },
    )
    assert created.status_code == 201, created.text
    pattern_id = created.json()["id"]

    # An edge along the rail's length (world -Y on the seed), so a 90 degree turn about Z is visible.
    seed_index = None
    for index in range(64):
        response = _direction(root_id, SHORT_RAIL_BOT_RIGHT, index)
        if response.status_code == 200 and abs(abs(response.json()["direction"][1]) - 1.0) < 1e-9:
            seed_index = index
            break
    assert seed_index is not None, "no edge along the short rail's length"

    response = _direction(root_id, f"{SHORT_RAIL_BOT_RIGHT}#pattern:{pattern_id}:1", seed_index)
    assert response.status_code == 200, response.text
    direction = response.json()["direction"]
    # Rz(90) maps the seed's +/-Y line onto the X axis.
    assert abs(abs(direction[0]) - 1.0) < 1e-9 and abs(direction[1]) < 1e-9 and abs(direction[2]) < 1e-9, direction


def test_an_edge_on_a_copy_index_the_pattern_does_not_derive_is_rejected():
    root_id, _ = _import()
    index, _ = _first_straight_edge(root_id, SHORT_RAIL_BOT_RIGHT)
    response = _direction(root_id, f"{SHORT_RAIL_BOT_RIGHT}#pattern:{RAIL_PATTERN}:7", index)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "missing_reference"
