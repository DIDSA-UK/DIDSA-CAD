"""N1b (docs/mates-storage-sessions-plan-2026-11-12.md, "N1 plan"): a mate's references are signed, re-found after an edit, and held out of solves when unsure.

Promoted from `n1_repro_mate_reference_renumbered.py`, the N1 plan's reproduction of the SILENT wrong mate: a mate stores a raw face index
(`SubShapeRef.index`, the position in `topexp.MapShapes` order); an upstream edit to the referenced Part that changes its topology (a fillet in the Part's own
design table) renumbers its faces, and the stored index then names ANOTHER VALID face of the same kind. Measured on 2026-11-17 (pythonocc-core 8.0.1.2):
  * 10 x 10 x 10 box, faces 0..5 = -Y, +X, +Y, -X, bottom (-Z, z 0), top (+Z, z 10). A fillet on edge 0 gives 7 faces in a new order: index 4 becomes the TOP
    (+Z, z 10) and the bottom moves to index 1.
  * 40 x 20 x 10 plate with holes at x 10 and x 30: face 5 is the x-30 hole. A fillet on edges 0 and 5 gives 10 faces: index 5 becomes the R 1.5 fillet's own
    cylinder at the plate's corner; the x-30 hole moves to index 9.
Before N1b both ended with the part on the wrong face and the mate reading `ok`. They now follow the face (and the listing says so).

Renumbering by a real edit is used where one is known (the two above); elsewhere it is simulated by writing a wrong index into the stored mate, which is exactly
what a renumbered Body looks like to the rules (the same device as N1a's tests).
"""

import math

import numpy as np
import pytest

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

    first_listing = _mate(base["id"], mate["id"])  # the first read after the edit is the one that re-finds the face and says so
    status_after_edit = first_listing["status"]
    _json(client.post(f"/document/parts/{base['id']}/occurrences/occ-driven/solve"))
    after = _occurrence(base["id"])["transform"]
    status_after_solve = _mate(base["id"], mate["id"])["status"]

    # What N1 must give: the box's own bottom (local -Z) still faces down and sits on the base's top at z 10.
    assert np.allclose(_dir_to_world(after, (0, 0, -1)), (0, 0, -1), atol=1e-6), (
        f"the mate followed the stored index onto another face: the box was turned over (status after the edit: {status_after_edit}, "
        f"after the solve: {status_after_solve}; transform {after})"
    )
    assert abs(_to_world(after, (5, 5, 0))[2] - 10.0) < 1e-6
    # N1b: the listing says what happened. The reference was re-found (signature search), the new index is persisted and shown, and nothing is held.
    listed = first_listing
    assert listed["followed_references"] == ["references[0].subshape_ref"], listed
    assert listed["lost_references"] == [] and listed["moved_references"] == [] and listed["held"] is False
    assert listed["status"] == "ok"
    new_bottom = next(i for i in range(7) if np.allclose(_measure_face(box["id"], box["body_id"], i).get("normal") or [0, 0, 0], [0, 0, -1]))
    assert listed["references"][0]["subshape_ref"]["index"] == new_bottom != 4
    assert _mate(base["id"], mate["id"])["followed_references"] == []  # persisted: the next listing has nothing to report


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

    first_listing = _mate(plate["id"], mate["id"])
    status_after_edit = first_listing["status"]
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
    listed = first_listing
    assert listed["lost_references"] == [] and listed["held"] is False and listed["status"] == "ok", listed
    # The x-30 hole kept its place among its twins (distance 0, the other hole 20 mm away): followed by the mate-only exact-place rule, not held.
    assert listed["followed_references"] == ["references[1].subshape_ref"] and listed["reference_reasons"]["references[1].subshape_ref"] == "exact_place_among_twins"
    assert listed["references"][1]["subshape_ref"]["index"] == 9  # where the hole is after the fillet (see the docstring)


# --- helpers for the cases below ----------------------------------------------------------------------------------------------------


def _stored_mate(root_id, mate_id):
    from app.document.router import get_part_or_404

    return next(m for m in get_part_or_404(root_id).mates if m.id == mate_id)


def _refs(root_id, mate_id):
    from app.document.subshape_identity import iter_mate_subshape_refs

    return dict(iter_mate_subshape_refs(_stored_mate(root_id, mate_id)))


def _write_index(root_id, mate_id, path, index):
    """Simulates a renumbering: the stored reference at `path` now names `index` (its signature is untouched)."""
    import dataclasses

    from app.document.subshape_identity import _rebuild

    mate = _stored_mate(root_id, mate_id)
    mate.references = [
        _rebuild(entity, f"references[{i}]", lambda p, ref: dataclasses.replace(ref, index=index) if p == path else ref) for i, entity in enumerate(mate.references)
    ]


def _delete_circle(part_id, x):
    """Removes the sketch circle centred at x (the plate's hole) from the Part's first sketch; the Part's Features replay without it."""
    from app.document.router import get_part_or_404

    sketch_id = next(f.sketch_id for f in get_part_or_404(part_id).features if hasattr(f, "sketch_id"))
    circles = _json(client.get(f"/sketch/sketches/{sketch_id}/circles"))
    points = {p["id"]: p for p in _json(client.get(f"/sketch/sketches/{sketch_id}/points"))}
    circle = next(c for c in circles if abs(points[c["center_point_id"]]["x"] - x) < 1e-9)
    _json(client.delete(f"/sketch/sketches/{sketch_id}/circles/{circle['id']}"))


def _pin_in_plate_hole(hole_index=5, solve="group"):
    pin = _make_cylinder_part("Pin", radius=3.0, depth=20.0)
    plate = _plate_with_two_holes("Plate")
    _place_occurrence(plate["id"], pin["id"], translation=(31.0, 12.0, -5.0))
    pin_face = next(i for i in range(3) if _measure_face(pin["id"], pin["body_id"], i).get("normal") is None)
    mate = _json(
        client.post(
            f"/document/parts/{plate['id']}/mates?solve={solve}&occurrence_id=occ-driven",
            json={
                "type": "concentric",
                "references": [
                    {"occurrence_id": "occ-driven", "subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": pin_face}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": plate["body_id"], "shape_type": "face", "index": hole_index}},
                ],
            },
        ),
        201,
    )
    return pin, plate, mate


def _mate_motion(root_id, occurrence_id="occ-driven", **fields):
    return _json(client.post(f"/document/parts/{root_id}/occurrences/{occurrence_id}/mate-motion", json=fields))


# --- creation signs every reference -------------------------------------------------------------------------------------------------


def test_a_new_mate_is_signed_on_create_and_the_signature_never_reaches_the_wire():
    pin, plate, mate = _pin_in_plate_hole()
    refs = _refs(plate["id"], mate["id"])
    assert set(refs) == {"references[0].subshape_ref", "references[1].subshape_ref"}
    assert all(ref.signature is not None for ref in refs.values())
    assert refs["references[1].subshape_ref"].signature.radius == pytest.approx(3.0)  # N1a's size, measured on the plate's final Body
    # clients compare ref dicts for equality and highlight by index: no signature, no extra key
    assert set(mate["references"][1]["subshape_ref"]) == {"body_id", "shape_type", "index"}
    assert mate["held"] is False and mate["lost_references"] == [] and mate["moved_references"] == [] and mate["followed_references"] == []
    assert mate["reference_reasons"] == {}


# --- a deleted hole with a twin -----------------------------------------------------------------------------------------------------


def test_a_deleted_hole_with_a_twin_is_never_solved_onto_the_twin():
    """The plan's probe: the x-30 hole is deleted (its sketch circle removed) and the x-10 twin remains. Today's rules bind `unique_fingerprint_far` to the
    OTHER hole. For a mate that binding moves a part, so it is held (N-2 (c)): shown, flagged, left out of every solve, and the pin stays where it was."""
    pin, plate, mate = _pin_in_plate_hole()
    _delete_circle(plate["id"], 30.0)
    before = _occurrence(plate["id"])["transform"]

    listed = _mate(plate["id"], mate["id"])
    # Measured: the only fingerprint-equal face left is the twin hole, far from where the x-30 hole was (`unique_fingerprint_far`): bound for display, held.
    assert listed["held"] is True and listed["moved_references"] == ["references[1].subshape_ref"], listed
    assert listed["reference_reasons"] == {"references[1].subshape_ref": "unique_fingerprint_far"} and listed["lost_references"] == []
    assert listed["status"] == "broken"  # the pin sits in the x-30 hole, and the face it is bound to now is the x-10 one
    # Any solve leaves the mate out and says so; the pin does not move onto the twin.
    motion = _mate_motion(plate["id"])
    assert motion["held_mate_ids"] == [mate["id"]]
    nudged = {**before, "translation": [before["translation"][0] + 0.5, before["translation"][1], before["translation"][2]]}
    _json(client.patch(f"/document/parts/{plate['id']}/occurrences/occ-driven", json={"transform": nudged}))
    response = client.post(f"/document/parts/{plate['id']}/occurrences/occ-driven/solve")
    assert response.status_code == 200, response.text
    assert response.headers["X-Held-Mates"] == mate["id"]
    axis = _to_world(_occurrence(plate["id"])["transform"], (0, 0, 0))[:2]
    assert not np.allclose(axis, (10.0, 10.0), atol=1e-3), "the pin was solved onto the twin hole"
    assert np.allclose(axis, (30.5, 10.0), atol=1e-6)  # where the user left it (the nudge): no mate moved it


def test_confirming_a_held_mate_takes_the_bound_face_and_clears_the_hold():
    pin, plate, mate = _pin_in_plate_hole()
    _delete_circle(plate["id"], 30.0)
    listed = _mate(plate["id"], mate["id"])
    assert listed["held"] is True
    bound = listed["references"][1]["subshape_ref"]["index"]
    confirmed = _json(client.patch(f"/document/parts/{plate['id']}/mates/{mate['id']}", json={"confirm_references": True}))
    assert confirmed["held"] is False and confirmed["moved_references"] == [] and confirmed["references"][1]["subshape_ref"]["index"] == bound
    assert _refs(plate["id"], mate["id"])["references[1].subshape_ref"].index == bound
    # included in solves now: the pin goes to the hole the user confirmed (the twin at x 10)
    motion = _mate_motion(plate["id"])
    assert "held_mate_ids" not in motion  # only present when a mate was left out
    response = client.post(f"/document/parts/{plate['id']}/occurrences/occ-driven/solve")
    assert response.status_code == 200, response.text
    assert np.allclose(_to_world(_occurrence(plate["id"])["transform"], (0, 0, 0))[:2], (10.0, 10.0), atol=1e-6)


# --- the native file: signatures round-trip; an unsigned file adopts by the N-3 rule --------------------------------------------------


def _box_on_base():
    """A base (root) with a box seated on its top by a Coincident: the mate is satisfied at the stored poses. Returns (root id, mate id)."""
    from tests.test_assembly_group import _compose, _face

    base = _make_box_part("Base", size=40.0, depth=10.0)
    box = _make_box_part("Box", size=10.0, depth=10.0)
    root = _compose(base, [("a", box, (5.0, 5.0, 30.0))])
    mate = _json(
        client.post(
            f"/document/parts/{root}/mates?solve=group&occurrence_id=a",
            json={"type": "coincident", "alignment": "anti_aligned", "references": [{"occurrence_id": "a", **_face(box, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}]},
        ),
        201,
    )
    return root, mate["id"]


def _mate_ref_dicts(exported, root_id):
    part = next(p for p in exported["document"]["parts"] if p["id"] == root_id)
    return [r["subshape_ref"] for m in part["mates"] for r in m["references"] if r.get("subshape_ref")], part


def _strip_signatures(exported, root_id):
    refs, _ = _mate_ref_dicts(exported, root_id)
    for ref in refs:
        ref.pop("signature", None)
        ref.pop("lineage", None)
    return exported


def test_the_native_file_keeps_the_mate_signatures_and_a_round_trip_loses_nothing():
    root, mate_id = _box_on_base()
    before = {path: ref.signature for path, ref in _refs(root, mate_id).items()}
    assert all(sig is not None for sig in before.values())
    exported = _json(client.get("/document/export/native"))
    refs, _ = _mate_ref_dicts(exported, root)
    assert len(refs) == 2 and all("signature" in ref and ref["signature"]["kind"] == "face" for ref in refs)
    _json(client.post("/document/import/native", json=exported))
    assert {path: ref.signature for path, ref in _refs(root, mate_id).items()} == before
    listed = _mate(root, mate_id)
    assert listed["status"] == "ok" and all(listed[f] == [] for f in ("lost_references", "moved_references", "followed_references")) and listed["held"] is False


def test_an_export_after_a_renumbering_saves_the_current_index():
    """The refresh runs before every native export: a Part edited since the mate was made, and no mates listing in between, still saves the right index."""
    root, mate_id = _box_on_base()
    from app.document.store import get_document

    box_part = next(p for p in get_document().parts.values() if p.name == "Box")
    body_id = _refs(root, mate_id)["references[0].subshape_ref"].body_id
    _fillet(box_part.id, body_id, [0], 2.0)  # renumbers the box's faces: the stored index now names the top
    stale = _refs(root, mate_id)["references[0].subshape_ref"].index
    exported = _json(client.get("/document/export/native"))
    refs, _ = _mate_ref_dicts(exported, root)
    saved = next(r for r in refs if r["body_id"] == body_id)
    assert saved["index"] != stale
    assert _refs(root, mate_id)["references[0].subshape_ref"].index == saved["index"]  # and the live document carries it too


def test_an_unsigned_file_adopts_the_faces_its_indices_name_when_the_stored_placement_confirms_them():
    root, mate_id = _box_on_base()
    exported = _strip_signatures(_json(client.get("/document/export/native")), root)
    _json(client.post("/document/import/native", json=exported))
    assert all(ref.signature is None for ref in _refs(root, mate_id).values())  # an unsigned file loads unsigned
    listed = _mate(root, mate_id)
    assert listed["held"] is False and listed["status"] == "ok"
    assert all(listed[f] == [] for f in ("lost_references", "moved_references", "followed_references")) and listed["reference_reasons"] == {}
    assert all(ref.signature is not None for ref in _refs(root, mate_id).values())  # adopted, and persisted for the next save


def test_an_unsigned_mate_the_stored_placement_does_not_confirm_is_held_as_unconfirmed():
    root, mate_id = _box_on_base()
    exported = _strip_signatures(_json(client.get("/document/export/native")), root)
    _, part = _mate_ref_dicts(exported, root)
    part["occurrences"][0]["transform"]["translation"] = [60.0, 60.0, 90.0]  # the file's placement no longer meets the mate
    _json(client.post("/document/import/native", json=exported))
    listed = _mate(root, mate_id)
    assert listed["held"] is True and sorted(listed["moved_references"]) == ["references[0].subshape_ref", "references[1].subshape_ref"]
    assert set(listed["reference_reasons"].values()) == {"unconfirmed"} and listed["status"] == "broken"
    assert all(ref.signature is None for ref in _refs(root, mate_id).values())  # not adopted
    # held out of the solve: nothing pulls the box onto the base, and the answer says why
    motion = _mate_motion(root, "a")
    assert motion["held_mate_ids"] == [mate_id]
    assert np.allclose(_occurrence(root, "a")["transform"]["translation"], (60.0, 60.0, 90.0))
    # the user's confirmation adopts the faces and the next solve includes the mate
    confirmed = _json(client.patch(f"/document/parts/{root}/mates/{mate_id}", json={"confirm_references": True}))
    assert confirmed["held"] is False and confirmed["moved_references"] == []
    assert all(ref.signature is not None for ref in _refs(root, mate_id).values())
    _json(client.post(f"/document/parts/{root}/occurrences/a/solve"))
    assert _mate(root, mate_id)["status"] == "ok"


# --- coaxial faces: a mate on a bore, a stepped shaft (N1a's size tie-break, end to end through a mate) --------------------------------


def _coaxial_part(name, radii):
    """One Body made of coaxial bosses on the z axis (`radii`: [(radius, z0, z1)], fused): a stepped shaft. Returns (part dict with body_id, {radius: face index})."""
    from app.document.extrude import compute_part_bodies
    from app.document.reference_signature import BodyFaceMeasurer
    from app.document.router import get_part_or_404

    part = _create_part(name)
    body_id = None
    for radius, z0, z1 in radii:
        sketch = _json(client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}))
        centre = _add_point(sketch["sketch_id"], 0.0, 0.0)
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}))
        _json(
            client.post(
                f"/document/parts/{part['id']}/extrude-features",
                json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": z0, "end_distance": z1, "target_body_ids": [body_id] if body_id else []},
            )
        )
        body_id = next(iter(compute_part_bodies(get_part_or_404(part["id"]))))
    (body,) = compute_part_bodies(get_part_or_404(part["id"])).values()
    faces = {round(s.radius, 6): i for i, s in enumerate(BodyFaceMeasurer(body).all()) if s.surface_kind == "cylinder"}
    return {"id": part["id"], "body_id": body_id}, faces


def _tube_part(name, outer, bore):
    part = _create_part(name)
    sketch = _json(client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}))
    centre = _add_point(sketch["sketch_id"], 0.0, 0.0)
    for radius in (outer, bore):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}))
    _json(
        client.post(
            f"/document/parts/{part['id']}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    from app.document.extrude import compute_part_bodies
    from app.document.reference_signature import BodyFaceMeasurer
    from app.document.router import get_part_or_404

    ((body_id, body),) = compute_part_bodies(get_part_or_404(part["id"])).items()
    return {"id": part["id"], "body_id": body_id}, {round(s.radius, 6): i for i, s in enumerate(BodyFaceMeasurer(body).all()) if s.surface_kind == "cylinder"}


def _concentric_on(root_part, face_index, pin_radius):
    pin = _make_cylinder_part("Pin", radius=pin_radius, depth=20.0)
    _place_occurrence(root_part["id"], pin["id"], translation=(3.0, 2.0, 1.0))
    pin_face = next(i for i in range(3) if _measure_face(pin["id"], pin["body_id"], i).get("normal") is None)
    return _json(
        client.post(
            f"/document/parts/{root_part['id']}/mates?solve=group&occurrence_id=occ-driven",
            json={
                "type": "concentric",
                "references": [
                    {"occurrence_id": "occ-driven", "subshape_ref": {"body_id": pin["body_id"], "shape_type": "face", "index": pin_face}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": root_part["body_id"], "shape_type": "face", "index": face_index}},
                ],
            },
        ),
        201,
    )


def _assert_followed_by_radius(root_id, mate, true_index, wrong_index):
    path = "references[1].subshape_ref"
    _write_index(root_id, mate["id"], path, wrong_index)  # a renumbering that hands the index to another face on the same axis
    listed = _mate(root_id, mate["id"])
    assert listed["followed_references"] == [path] and listed["reference_reasons"][path] == "nearest_radius", listed
    assert listed["lost_references"] == [] and listed["moved_references"] == [] and listed["held"] is False  # never `ok` on the wrong face, never ambiguous
    assert listed["references"][1]["subshape_ref"]["index"] == true_index
    assert _refs(root_id, mate["id"])[path].index == true_index


def test_a_mate_on_a_tubes_bore_and_on_its_outer_surface_follows_by_radius():
    tube, faces = _tube_part("Tube", outer=10.0, bore=4.0)
    bore, outer = faces[4.0], faces[10.0]
    mate = _concentric_on(tube, bore, pin_radius=3.0)
    assert _refs(tube["id"], mate["id"])["references[1].subshape_ref"].signature.radius == pytest.approx(4.0)
    _assert_followed_by_radius(tube["id"], mate, true_index=bore, wrong_index=outer)  # the bore's index now names the outer cylinder
    # and the other way: a mate on the outer cylinder whose index lands on the bore
    tube, faces = _tube_part("Tube2", outer=10.0, bore=4.0)
    mate = _concentric_on(tube, faces[10.0], pin_radius=3.0)
    _assert_followed_by_radius(tube["id"], mate, true_index=faces[10.0], wrong_index=faces[4.0])


def test_a_mate_on_each_step_of_a_stepped_shaft_follows_by_radius():
    for stepped in ((10.0, 6.0, 3.0),):
        shaft, faces = _coaxial_part("Shaft", [(stepped[0], 0, 10), (stepped[1], 10, 20), (stepped[2], 20, 30)])
        assert set(faces) == set(stepped)
        mate = _concentric_on(shaft, faces[6.0], pin_radius=2.0)
        for other in (10.0, 3.0):  # the middle step's index handed to each of the other two
            _assert_followed_by_radius(shaft["id"], mate, true_index=faces[6.0], wrong_index=faces[other])
