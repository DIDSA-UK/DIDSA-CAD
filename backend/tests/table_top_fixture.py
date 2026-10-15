"""The tester's table-top-on-frame assembly (`tests/data/table_top_frame/`), composed for `POST /document/import/native`.

`docs/mate-solution-choice-plan.md` ("Reproduction notes"): `Top_and_frame.didsa` is the assembly, `Frame.didsa` a sub-assembly
of four bars (`Frame_A` / `Frame_B`), `Table_Top.didsa` the plate. Composing is what the client's composer does: walk every
`occurrences[].external_ref`, set the occurrence's `resolved_part_id` to the referenced file's `root_part_id`, then concatenate
the `parts` and `sketches` of every file.
"""

import copy
import json
from pathlib import Path

DATA_DIR = Path(__file__).parent / "data" / "table_top_frame"

PLATE = "8caca0b2-7da1-4082-931a-be065ce55456"
FRAME = "32947d4e-4a96-446b-bad9-063ddde537a9"
# Occurrences inside the frame sub-assembly (`FRAME/<id>`): the two bars the plate's edges are measured from.
FRAME_BAR_Y0 = f"{FRAME}/cf9fb8c9-0bf3-4964-b2be-9262545dc401"
FRAME_BAR_X0 = f"{FRAME}/3f6d733a-f609-4a1e-99dc-3cd89a3b5697"
FRAME_TOP_BAR = f"{FRAME}/87e7b9c5-194a-4649-80b3-fe8d6ff097cd"

PLATE_BODY = "b2949a80-f591-4f8c-9e11-b738d3dac8dc"
FRAME_BODY = "e8d7bb68-342f-4421-9ae2-2a6af71d3a28"
# The plate's face indices, and the frame bars' reference faces, used by the tester's three mates.
PLATE_BOTTOM_FACE, PLATE_EDGE_X_FACE, PLATE_EDGE_Y_FACE = 4, 3, 2

# The correct plate box (plan, "Reproduction notes"): x 30..35, y 10..790, z -1560..20.
CORRECT_PLATE_TRANSLATION = (29.999999999999915, 789.9999999904013, -1559.9999995938992)
CORRECT_PLATE_ROTATION = ((1.0, 0.0, 0.0), 180.0)


def _load(name: str) -> dict:
    return json.loads((DATA_DIR / name).read_text())


def _collect(name: str, parts: dict, sketches: dict) -> dict:
    """Loads `name`, resolves its occurrences recursively and adds its parts and sketches (deduplicated by id)."""
    data = _load(name)
    document = data["document"]
    for sketch in data["sketches"]:
        sketches.setdefault(sketch["id"], sketch)
    for part in document["parts"]:
        for occurrence in part["occurrences"]:
            referenced = _collect(occurrence["external_ref"], parts, sketches)
            occurrence["resolved_part_id"] = referenced["document"]["root_part_id"]
        parts.setdefault(part["id"], part)
    return data


def compose_table_top(name: str = "Top_and_frame.didsa", keep_mates: bool = True) -> dict:
    """The import payload for `name`. `keep_mates=False` empties the top assembly's own mates (the sub-assembly keeps its)."""
    parts: dict[str, dict] = {}
    sketches: dict[str, dict] = {}
    top = _collect(name, parts, sketches)
    payload = copy.deepcopy(top)
    root = parts[top["document"]["root_part_id"]]
    if not keep_mates:
        root["mates"] = []
    payload["document"]["parts"] = [root, *(p for pid, p in parts.items() if pid != root["id"])]
    payload["sketches"] = list(sketches.values())
    return payload


def import_table_top(client, name: str = "Top_and_frame.didsa", keep_mates: bool = True) -> str:
    """Imports the composed assembly into the (test) document and returns the root part id."""
    payload = compose_table_top(name, keep_mates)
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200, response.text
    return payload["document"]["root_part_id"]


def face_ref(occurrence_id: str, body_id: str, index: int) -> dict:
    return {"occurrence_id": occurrence_id, "subshape_ref": {"body_id": body_id, "shape_type": "face", "index": index}}


def table_top_mate_payloads(coincident_flipped: bool = False) -> list[dict]:
    """The tester's three mates, as `POST .../mates` payloads (plate is the first reference of each)."""
    return [
        {
            "type": "distance",
            "references": [face_ref(PLATE, PLATE_BODY, PLATE_EDGE_Y_FACE), face_ref(FRAME_BAR_Y0, FRAME_BODY, 0)],
            "value": 10.0,
            "flipped": False,
        },
        {
            "type": "distance",
            "references": [face_ref(PLATE, PLATE_BODY, PLATE_EDGE_X_FACE), face_ref(FRAME_BAR_X0, FRAME_BODY, 0)],
            "value": 10.0,
            "flipped": False,
        },
        {
            "type": "coincident",
            "references": [face_ref(PLATE, PLATE_BODY, PLATE_BOTTOM_FACE), face_ref(FRAME_TOP_BAR, FRAME_BODY, 9)],
            "flipped": coincident_flipped,
        },
    ]
