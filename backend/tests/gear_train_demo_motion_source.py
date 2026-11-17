"""Records the group solve of the gear-train demo (`tests/data/gear_train_demo_current.didsa`, copied from DIDSA-VR `demo/assemblies/gear_train/Gear_train.didsa`
at VR commit 5d8faaf, so this repo's CI needs no VR checkout) for `test_mate_reference_gear_train_demo.py`: the mate-motion answer of four grabs, and the
constraint status. `tests/data/gear_train_demo_motion.json` was recorded on the code BEFORE N1b (CAD `main` at ccc11be), to show that a mate's reference
identity changes no solve:

    cd backend && python -m tests.gear_train_demo_motion_source > tests/data/gear_train_demo_motion.json     (on the code to record)

Not a test file (no `test_` prefix); the numbers are rounded to 9 places so the golden compares across machines."""

import json
import pathlib

DATA = pathlib.Path(__file__).parent / "data"
DEMO = DATA / "gear_train_demo_current.didsa"


def _round(value, places=9):
    if isinstance(value, float):
        return round(value, places) + 0.0
    if isinstance(value, list):
        return [_round(v, places) for v in value]
    if isinstance(value, dict):
        return {k: _round(v, places) for k, v in value.items()}
    return value


def import_demo(client, path=DEMO) -> str:
    payload = json.loads(pathlib.Path(path).read_text())
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200, response.text
    return payload["document"]["root_part_id"]


def record(client, root: str) -> dict:
    stored = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}
    out: dict = {}
    for name, occurrence, dangle, dx in (("crank_turn", "crank", 40.0, 0.0), ("crank_back", "crank", -65.0, 0.0), ("pinion_turn", "pinion", 25.0, 0.0), ("rack_slide", "rack", 0.0, 5.0)):
        wish = dict(stored[occurrence])
        wish["rotation_angle_degrees"] = wish["rotation_angle_degrees"] + dangle
        wish["translation"] = [wish["translation"][0] + dx, wish["translation"][1], wish["translation"][2]]
        response = client.post(f"/document/parts/{root}/occurrences/{occurrence}/mate-motion", json={"transform": wish})
        assert response.status_code == 200, (name, response.text)
        body = response.json()
        out[name] = _round(
            {
                "converged": body["converged"],
                "dof": body.get("dof"),
                "grounded": body.get("grounded"),
                "members": sorted(({"occurrence_id": m["occurrence_id"], "transform": m["transform"]} for m in body.get("members", [])), key=lambda m: m["occurrence_id"]),
                "basis": body.get("basis"),
            }
        )
    status = client.get(f"/document/parts/{root}/constraint-status").json()
    out["constraint_status"] = _round({k: {"status": v["status"], "dof": v["dof"]} for k, v in sorted(status.items())})
    return out


if __name__ == "__main__":
    from fastapi.testclient import TestClient

    from app.main import app
    from tests.conftest import TEST_API_KEY

    test_client = TestClient(app)
    test_client.headers.update({"X-API-Key": TEST_API_KEY})
    print(json.dumps(record(test_client, import_demo(test_client)), indent=1, sort_keys=True))
