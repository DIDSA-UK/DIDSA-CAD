"""The completeness check's backend half (`docs/ai-modelling/16-assembly-mates-gaps-plan.md`, Phase 2): what an
under-constrained occurrence can still do, described in its own part frame (`assembly_group.free_motions_for_member`,
the `free_motions` field of `GET /parts/{id}/constraint-status`)."""

import math

import numpy as np

from app.document.assembly_group import constraint_report
from tests.test_assembly_group import _compose, _cyl, _doc, _face, _mate, client
from tests.test_assembly_solver import _add_point, _create_part, _make_box_part, _make_cylinder_part


def _motions(root: str, occurrence_id: str) -> list[dict]:
    document, part = _doc(root)
    status, _dof, motions = constraint_report(document, part)[occurrence_id]
    assert status == "under_constrained"
    return motions


def _by_kind(motions: list[dict], kind: str) -> list[dict]:
    return [m for m in motions if m["kind"] == kind]


def _same_line(a, b) -> bool:
    return abs(abs(float(np.dot(a, b))) - 1.0) < 1e-6


def test_one_seat_mate_leaves_two_slides_and_a_spin():
    """The dovetail plates' situation: one coincident mate to a flat face holds three of six freedoms."""
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (20.0, 20.0, 10.0))])
    _mate(root, "coincident", "occ-A", _face(box, (0, 0, -1)), "", _face(plate, (0, 0, 1)))
    motions = _motions(root, "occ-A")

    slides, spins = _by_kind(motions, "slide"), _by_kind(motions, "spin")
    assert len(motions) == 3 and len(slides) == 2 and len(spins) == 1
    # The coordinate axes inside the sliding plane are reported, not an arbitrary mix of them.
    assert sorted(tuple(abs(c) for c in s["direction"]) for s in slides) == [(0.0, 1.0, 0.0), (1.0, 0.0, 0.0)]
    assert _same_line(spins[0]["axis"], [0, 0, 1])
    assert spins[0]["through"] == [0.0, 0.0, 0.0]


def test_the_flank_mates_remove_every_free_motion():
    plate = _make_box_part("Plate", size=100.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (100.0, 100.0, 10.0))])
    _mate(root, "coincident", "occ-A", _face(box, (0, 0, -1)), "", _face(plate, (0, 0, 1)))
    _mate(root, "coincident", "occ-A", _face(box, (-1, 0, 0)), "", _face(plate, (1, 0, 0)))
    _mate(root, "coincident", "occ-A", _face(box, (0, -1, 0)), "", _face(plate, (0, 1, 0)))
    document, part = _doc(root)
    assert constraint_report(document, part)["occ-A"] == ("fully_constrained", 0, [])
    body = client.get(f"/document/parts/{root}/constraint-status").json()["occ-A"]
    assert body == {"status": "fully_constrained", "dof": 0, "free_motions": [], "rigid_set": None}


def test_an_unmated_occurrence_is_free_in_all_six():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (5.0, 5.0, 20.0))])
    motions = _motions(root, "occ-A")
    assert len(_by_kind(motions, "slide")) == 3 and len(_by_kind(motions, "spin")) == 3
    # Three coordinate axes each, nothing arbitrary.
    assert sorted(tuple(abs(c) for c in m["direction"]) for m in _by_kind(motions, "slide")) == [
        (0.0, 0.0, 1.0),
        (0.0, 1.0, 0.0),
        (1.0, 0.0, 0.0),
    ]
    assert all(m["through"] == [0.0, 0.0, 0.0] for m in _by_kind(motions, "spin"))


def test_motions_are_in_the_part_frame_not_the_world_frame():
    """A box turned 90 degrees about x so its -y face lies on the plate's top: the sliding directions are the box's own
    x and z (world x and -y), the spin its own y."""
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (20.0, 20.0, 10.0))])
    client.patch(
        f"/document/parts/{root}/occurrences/occ-A",
        json={"transform": {"translation": [20.0, 28.0, 10.0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 90.0}},
    ).raise_for_status()
    _mate(root, "coincident", "occ-A", _face(box, (0, -1, 0)), "", _face(plate, (0, 0, 1)))
    motions = _motions(root, "occ-A")
    slides, spins = _by_kind(motions, "slide"), _by_kind(motions, "spin")
    assert sorted(tuple(abs(c) for c in s["direction"]) for s in slides) == [(0.0, 0.0, 1.0), (1.0, 0.0, 0.0)]
    assert len(spins) == 1 and _same_line(spins[0]["axis"], [0, 1, 0])


def _make_offset_cylinder_part(name: str, cx: float, cy: float, *, radius: float = 5.0, depth: float = 10.0) -> dict:
    part = _create_part(name)
    sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    sketch_id = sketch.json()["sketch_id"]
    centre = _add_point(sketch_id, cx, cy)
    circle = client.post(
        f"/sketch/sketches/{sketch_id}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}
    )
    assert circle.status_code == 201
    extrude = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={"sketch_feature_id": sketch.json()["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
    )
    assert extrude.status_code == 201
    mesh = client.get(f"/document/parts/{part['id']}/mesh").json()
    return {"id": part["id"], "body_id": mesh[0]["body_id"]}


def test_a_pin_in_a_bore_slides_and_spins_about_its_own_axis_even_when_that_axis_is_off_the_origin():
    """Concentric only: slide along the bore, spin about it. The axis is at (7, 3) in the pin's own frame, so the
    reported `through` point also checks the weighting is not applied twice (a wrong scale would move it)."""
    peg = _make_cylinder_part("Peg", radius=5.0, depth=30.0)
    pin = _make_offset_cylinder_part("Pin", 7.0, 3.0)
    root = _compose(peg, [("occ-B", pin, (-7.0, -3.0, 5.0))])
    _mate(root, "concentric", "occ-B", _cyl(pin), "", _cyl(peg))
    motions = _motions(root, "occ-B")
    slides, spins = _by_kind(motions, "slide"), _by_kind(motions, "spin")
    assert len(motions) == 2 and len(slides) == 1 and len(spins) == 1
    assert _same_line(slides[0]["direction"], [0, 0, 1])
    assert _same_line(spins[0]["axis"], [0, 0, 1])
    assert np.allclose(spins[0]["through"][:2], [7.0, 3.0], atol=1e-4)
    assert abs(spins[0]["through"][2]) < 1e-4  # the point nearest the origin


def test_the_endpoint_returns_the_free_motions_and_the_schema_accepts_every_kind():
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    box = _make_box_part("Box", size=8.0, depth=4.0)
    root = _compose(plate, [("occ-A", box, (20.0, 20.0, 10.0))])
    _mate(root, "coincident", "occ-A", _face(box, (0, 0, -1)), "", _face(plate, (0, 0, 1)))
    entry = client.get(f"/document/parts/{root}/constraint-status").json()["occ-A"]
    assert entry["status"] == "under_constrained" and entry["dof"] == 3
    assert [m["kind"] for m in entry["free_motions"]] == ["slide", "slide", "spin"]
    assert math.isclose(sum(c * c for c in entry["free_motions"][0]["direction"]), 1.0)
