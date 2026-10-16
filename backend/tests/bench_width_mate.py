"""Width mate vs two distance mates on the tester's table top (`docs/width-mate-plan.md` section 8, measurement).

Not collected by pytest (no `test_` prefix). Run from `backend/`:

    CAD_API_KEY=test-api-key micromamba run -n didsa-backend python -m tests.bench_width_mate [trials-per-class]

Ground truth by construction: the plate's true pose is the fixture's `CORRECT_PLATE_*`; a trial moves the plate to a near
(12 mm, 25 deg) / medium (50 mm, 100 deg) / far (110 mm, any orientation) start and previews each mate with NOTHING named.
A placement is correct when the plate's two big faces are parallel to y and centred on y = 400 (extent 10..790).
Per mate: first-time-correct = the unnamed preview is already correct; extra clicks = min(branch toggles, Next-solution
presses) to reach a correct placement (the user then confirms that one). Reported per scenario:
  (a) two distance mates (10 mm inset from each y bar face, the tester's way: 2 x (2 picks + a typed value)),
  (b) one Width mate (4 picks, nothing typed).
Time is the backend preview+create time per scenario (ms), not human time; the human cost is the picks / typed values / clicks.
"""

import statistics
import sys
import time

import numpy as np

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point
from app.document.models import RigidTransform
from tests import table_top_fixture as tt
from tests.test_assembly_solver import client
from tests.test_width_mate import _frame_width, _plate_width

TRUE_CENTRE_Y = 400.0


def _rt(t: dict) -> RigidTransform:
    return RigidTransform(tuple(t["translation"]), tuple(t["rotation_axis"]), t["rotation_angle_degrees"])


def _correct(t: dict) -> bool:
    rt = _rt(t)
    ys = [apply_transform_to_point(rt, (0.0, y, 0.0))[1] for y in (0.0, 780.0)]
    normal = apply_transform_to_direction(rt, (0.0, 1.0, 0.0))
    return abs(sum(ys) / 2.0 - TRUE_CENTRE_Y) < 1e-4 and abs(abs(normal[1]) - 1.0) < 1e-6


def _start(rng: np.random.Generator, kind: str) -> dict:
    mm, deg = {"near": (12.0, 25.0), "medium": (50.0, 100.0), "far": (110.0, None)}[kind]
    direction = rng.normal(size=3)
    direction /= np.linalg.norm(direction)
    axis = rng.normal(size=3)
    axis /= np.linalg.norm(axis)
    base = _rt({"translation": tt.CORRECT_PLATE_TRANSLATION, "rotation_axis": tt.CORRECT_PLATE_ROTATION[0], "rotation_angle_degrees": tt.CORRECT_PLATE_ROTATION[1]})
    if deg is None:
        return {"translation": [float(x) for x in np.array(base.translation) + direction * mm], "rotation_axis": [float(x) for x in axis], "rotation_angle_degrees": float(rng.uniform(0, 360))}
    # a rotation of `deg` about a random axis applied on top of the true orientation
    from app.document.assembly import compose

    delta = RigidTransform((0.0, 0.0, 0.0), tuple(float(x) for x in axis), deg)
    turned = compose(delta, base)
    return {"translation": [float(x) for x in np.array(base.translation) + direction * mm], "rotation_axis": list(turned.rotation_axis), "rotation_angle_degrees": turned.rotation_angle_degrees}


def _preview(root: str, payload: dict) -> dict:
    return client.post(f"/document/parts/{root}/occurrences/{tt.PLATE}/preview-mate-solve", params={"movement": "auto"}, json=payload).json()


def _plate(ghost_or_alt: dict) -> dict | None:
    for member in ghost_or_alt["members"]:
        if member["occurrence_id"] == tt.PLATE:
            return member["transform"]
    return None


def _one_mate(root: str, payload: dict) -> tuple[bool, int, dict | None]:
    """(first-time-correct, extra clicks, the placement to confirm) for one new mate."""
    ghost = _preview(root, payload)
    if not ghost["converged"]:
        return False, 99, None
    shown = _plate(ghost) or ghost["transform"]
    if _correct(shown):
        return True, 0, {"alignment": ghost["resolved"]["alignment"], "secondary_flip": ghost["resolved"]["secondary_flip"]}
    resolved = ghost["resolved"]
    wanted = None
    for presses, alt in enumerate(ghost["alternatives"], start=0):
        plate = _plate(alt)
        if plate is not None and _correct(plate):
            wanted = (alt["alignment"], alt["secondary_flip"])
            next_solution = presses
            break
    if wanted is None:
        return False, 99, None
    toggles = int(resolved["alignment"] != wanted[0] and wanted[0] is not None) + int(resolved["secondary_flip"] != wanted[1] and wanted[1] is not None)
    return False, min(toggles, max(next_solution, 1)), {"alignment": wanted[0], "secondary_flip": wanted[1]}


def _commit(root: str, payload: dict, branch: dict) -> None:
    body = {**payload, **{k: v for k, v in branch.items() if v is not None}}
    response = client.post(f"/document/parts/{root}/mates", params={"solve": "auto", "occurrence_id": tt.PLATE}, json=body)
    assert response.status_code == 201, response.text


def _face(occ, body, index):
    return {"occurrence_id": occ, "subshape_ref": {"body_id": body, "shape_type": "face", "index": index}}


def _distance_payloads() -> list[dict]:
    return [
        {"type": "distance", "value": 10.0, "references": [_face(tt.PLATE, tt.PLATE_BODY, 2), _face(tt.FRAME_BAR_Y0, tt.FRAME_BODY, 0)]},
        {"type": "distance", "value": 10.0, "references": [_face(tt.PLATE, tt.PLATE_BODY, 0), _face(tt.FRAME_BAR_Y800, tt.FRAME_BODY, 0)]},
    ]


def _width_payloads() -> list[dict]:
    return [{"type": "coincident", "references": [_plate_width(), _frame_width()]}]


def _set_pose(root: str, transform: dict) -> None:
    assert client.patch(f"/document/parts/{root}/occurrences/{tt.PLATE}", json={"transform": transform}).status_code == 200


def run(trials: int) -> None:
    print(f"table top, centre the plate between the frame's y faces; {trials} trials per start class\n")
    print(f"{'start':7} {'scenario':16} {'picks':>5} {'typed':>5} {'first-time-correct':>19} {'extra clicks/trial':>19} {'centred after':>14} {'ms/trial':>9}")
    for kind in ("near", "medium", "far"):
        rng = np.random.default_rng({"near": 1, "medium": 2, "far": 3}[kind])
        starts = [_start(rng, kind) for _ in range(trials)]
        for name, payloads, picks, typed in (("2 distance mates", _distance_payloads(), 4, 2), ("1 Width mate", _width_payloads(), 4, 0)):
            first_ok = clicks = centred = 0
            mates = 0
            elapsed = []
            for start in starts:
                root = tt.import_table_top(client, keep_mates=False)
                _set_pose(root, start)
                began = time.perf_counter()
                trial_first = True
                for payload in payloads:
                    ok, extra, branch = _one_mate(root, payload)
                    mates += 1
                    first_ok += ok
                    clicks += extra
                    trial_first &= ok
                    if branch is None:
                        break
                    _commit(root, payload, branch)
                elapsed.append((time.perf_counter() - began) * 1000.0)
                final = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}[tt.PLATE]
                centred += _correct(final)
            print(
                f"{kind:7} {name:16} {picks:5d} {typed:5d} {100.0 * first_ok / mates:18.1f}% {clicks / trials:19.2f} {100.0 * centred / trials:13.1f}% {statistics.mean(elapsed):9.0f}"
            )


if __name__ == "__main__":
    run(int(sys.argv[1]) if len(sys.argv) > 1 else 20)
