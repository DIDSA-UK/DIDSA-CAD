"""N1 reproduction (docs/mates-storage-sessions-plan-2026-11-12.md, "Part 2b: Stable mate references", N1 plan): the SILENT wrong mate.

A mate stores a raw face index (`SubShapeRef.index`, the position in `topexp.MapShapes` order). An upstream edit to the referenced Part that changes its
topology (here: a fillet added in the Part's own design table) renumbers its faces, and the stored index then names ANOTHER VALID face of the same kind. The
mate still solves, and after the solve it reads `ok`: nothing tells the user the part now sits on the wrong face.

Measured on 2026-11-17 (pythonocc-core 8.0.1.2, and the same face order under 7.9.3):
  * 10 x 10 x 10 box, faces 0..5 = -Y, +X, +Y, -X, bottom (-Z, z 0), top (+Z, z 10). A fillet on edge 0 (a vertical edge) gives 7 faces in a new order:
    index 4 becomes the TOP (+Z, z 10) and the bottom moves to index 1.
  * 40 x 20 x 10 plate with holes at x 10 and x 30: face 5 is the x-30 hole. A fillet on edges 0 and 5 gives 10 faces: index 5 becomes the R 1.5 fillet's
    own cylinder at the plate's corner (x 0.5, y 0.5); the x-30 hole moves to index 9.

Both tests MUST FAIL on today's code (that is the point) and pass once N1 is built. NOT in the suite: the file name does not match `test_*.py`, so CI does not
collect it. Run it explicitly:  pytest tests/n1_repro_mate_reference_renumbered.py
"""

import math

import numpy as np

from tests.test_assembly_solver import (
    _add_line,
    _add_point,
    _create_part,
    _make_box_part,
    _make_cylinder_part,
    _measure_face,
    _place_occurrence,
    client,
)


def _json(response, status=None):
    assert response.status_code < 300 if status is None else response.status_code == status, (response.status_code, response.text[:400])
    return response.json()


def _rmat(axis, degrees):
    a = np.array(axis, float)
    a /= np.linalg.norm(a)
    t = math.radians(degrees)
    k = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * k + (1 - math.cos(t)) * (k @ k)


def _to_world(transform, point):
    return _rmat(transform["rotation_axis"], transform["rotation_angle_degrees"]) @ np.array(point, float) + np.array(transform["translation"], float)


def _dir_to_world(transform, direction):
    return _rmat(transform["rotation_axis"], transform["rotation_angle_degrees"]) @ np.array(direction, float)


def _occurrence(root_id, occurrence_id="occ-driven"):
    return next(o for o in _json(client.get(f"/document/parts/{root_id}/occurrences")) if o["id"] == occurrence_id)


def _mate(root_id, mate_id):
    return next(m for m in _json(client.get(f"/document/parts/{root_id}/mates")) if m["id"] == mate_id)


def _fillet(part_id, body_id, edges, radius):
    _json(
        client.post(
            f"/document/parts/{part_id}/fillet-features",
            json={"edge_refs": [{"body_id": body_id, "shape_type": "edge", "index": e} for e in edges], "radius": radius},
        )
    )


def _plate_with_two_holes(name):
    """40 x 20 x 10, through holes R 3 at (10, 10) and (30, 10). Returns {"id", "body_id"}."""
    part = _create_part(name)
    sketch = _json(client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}))
    corners = [_add_point(sketch["sketch_id"], x, y) for x, y in [(0, 0), (40, 0), (40, 20), (0, 20)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch["sketch_id"], a["id"], b["id"])
    for x in (10.0, 30.0):
        centre = _add_point(sketch["sketch_id"], x, 10.0)
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": 3.0, "angle": 0.0}))
    _json(
        client.post(
            f"/document/parts/{part['id']}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    mesh = _json(client.get(f"/document/parts/{part['id']}/mesh"))
    return {"id": part["id"], "body_id": mesh[0]["body_id"]}


def test_coincident_mate_stays_on_the_bottom_face_after_a_fillet_renumbers_the_box():
    """Coincident: the driven box's BOTTOM (index 4) on the base's top. A fillet on the driven box's edge 0 makes index 4 its TOP. Expected: the mate
    still means the bottom (the box sits upright on the base). Today: the solve turns the box over and sits it on its top, and the mate reads `ok`."""
    base = _make_box_part("Base", size=40.0, depth=10.0)
    box = _make_box_part("Box", size=10.0, depth=10.0)
    _place_occurrence(base["id"], box["id"], translation=(5.0, 5.0, 25.0))

    bottom = _measure_face(box["id"], box["body_id"], 4)
    assert bottom["normal"] == [0.0, 0.0, -1.0] or np.allclose(bottom["normal"], [0, 0, -1])  # the premise: index 4 is the bottom today
    base_top = next(i for i in range(6) if np.allclose(_measure_face(base["id"], base["body_id"], i).get("normal") or [0, 0, 0], [0, 0, 1]))
    mate = _json(
        client.post(
            f"/document/parts/{base['id']}/mates?solve=group&occurrence_id=occ-driven",
            json={
                "type": "coincident",
                "alignment": "anti_aligned",
                "references": [
                    {"occurrence_id": "occ-driven", "subshape_ref": {"body_id": box["body_id"], "shape_type": "face", "index": 4}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": base["body_id"], "shape_type": "face", "index": base_top}},
                ],
            },
        ),
        201,
    )
    before = _occurrence(base["id"])["transform"]
    assert np.allclose(_dir_to_world(before, (0, 0, -1)), (0, 0, -1), atol=1e-6)  # upright before the edit
    assert abs(_to_world(before, (5, 5, 0))[2] - 10.0) < 1e-6

    # The design-table edit: a fillet on one vertical edge of the driven box (its Part, not the assembly).
    _fillet(box["id"], box["body_id"], [0], 2.0)
    assert np.allclose(_measure_face(box["id"], box["body_id"], 4)["normal"], [0, 0, 1])  # the premise: index 4 now names the TOP

    status_after_edit = _mate(base["id"], mate["id"])["status"]
    _json(client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/solve"))
    after = _occurrence(base["id"])["transform"]
    status_after_solve = _mate(base["id"], mate["id"])["status"]

    # What N1 must give: the box's own bottom (local -Z) still faces down and sits on the base's top at z 10.
    assert np.allclose(_dir_to_world(after, (0, 0, -1)), (0, 0, -1), atol=1e-6), (
        f"the mate followed the stored index onto another face: the box was turned over (status after the edit: {status_after_edit}, "
        f"after the solve: {status_after_solve}; transform {after})"
    )
    assert abs(_to_world(after, (5, 5, 0))[2] - 10.0) < 1e-6


def test_concentric_mate_stays_on_its_hole_after_a_fillet_renumbers_the_plate():
    """Concentric: a pin in the plate's x-30 hole (face 5). A fillet on two plate edges makes index 5 the fillet's own R 1.5 cylinder at the plate corner.
    Expected: the pin stays in the x-30 hole. Today: the solve moves the pin to the plate's corner, and the mate reads `ok`."""
    pin = _make_cylinder_part("Pin", radius=3.0, depth=20.0)
    plate = _plate_with_two_holes("Plate")
    _place_occurrence(plate["id"], pin["id"], translation=(31.0, 12.0, -5.0))
    hole = _measure_face(plate["id"], plate["body_id"], 5)
    assert hole.get("radius") is None or abs(hole["radius"] - 3.0) < 1e-6  # the premise, as far as Measure reports it
    pin_face = next(i for i in range(3) if _measure_face(pin["id"], pin["body_id"], i).get("normal") is None)
    mate = _json(
        client.post(
            f"/document/parts/{plate['id']}/mates?solve=group&occurrence_id=occ-driven",
            json={
                "type": "concentric",
                "references": [
                    {"occurrence_id": "occ-driven", "subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": pin_face}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": plate["body_id"], "shape_type": "face", "index": 5}},
                ],
            },
        ),
        201,
    )
    before = _occurrence(plate["id"])["transform"]
    assert np.allclose(_to_world(before, (0, 0, 0))[:2], (30.0, 10.0), atol=1e-6)  # in the x-30 hole

    _fillet(plate["id"], plate["body_id"], [0, 5], 1.5)  # the design-table edit, on the fixed part this time

    status_after_edit = _mate(plate["id"], mate["id"])["status"]
    # Any solve that includes the mate (a drag, mate-motion, the solve button) re-reads the reference.
    nudged = {**before, "translation": [before["translation"][0] + 0.5, before["translation"][1], before["translation"][2]]}
    _json(client.patch(f"/document/parts/{plate['id']}/occurrences/occ-driven", json={"transform": nudged}))
    _json(client.post(f"/document/parts/{plate['id']}/occurrences/occ-driven/solve"))
    after = _occurrence(plate["id"])["transform"]
    status_after_solve = _mate(plate["id"], mate["id"])["status"]

    axis = _to_world(after, (0, 0, 0))[:2]
    assert np.allclose(axis, (30.0, 10.0), atol=1e-6), (
        f"the pin left its hole for the face now at the stored index: axis at {axis.round(3).tolist()} (status after the edit: {status_after_edit}, "
        f"after the solve: {status_after_solve})"
    )
