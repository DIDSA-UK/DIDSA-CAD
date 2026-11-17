"""N1a (docs/mates-storage-sessions-plan-2026-11-12.md, "N1 plan", decision N-4 (a)), on real OCCT geometry: a tube (outer R 10, bore R 4, both on the z
axis). Before N1a a signed reference to the bore whose index had come to name the outer cylinder read `ok` there (the fast path saw the same kind, the same
axis and distance 0): the silent wrong face. Now the radius in the signature re-finds the bore. The renumbering is simulated by a wrong stored index, which is
exactly what a renumbered Body looks like to the rules. The pure rules' golden vectors are in test_coaxial_signature_rules.py."""

import dataclasses

import pytest

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import SubShapeRef, SubShapeType
from app.document.reference_signature import BodyFaceMeasurer
from app.document.router import get_part_or_404
from app.document.subshape_identity import decide_subshape, measure_signature
from app.sketch.reference_signature import ReferenceStatus
from tests.test_reference_identity import _json, client


def _tube(outer: float = 10.0, bore: float = 4.0) -> tuple[str, dict]:
    part_id = _json(client.post("/document/parts", json={"name": "Tube"}))["id"]
    sketch = _json(client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}))
    centre = _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": 0, "y": 0}))
    for radius in (outer, bore):
        _json(client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}))
    _json(
        client.post(
            f"/document/parts/{part_id}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []},
        )
    )
    return part_id, compute_part_bodies(get_part_or_404(part_id))


def _cylinder_index(body, radius: float) -> int:
    return next(i for i, s in enumerate(BodyFaceMeasurer(body).all()) if s.surface_kind == "cylinder" and abs(s.radius - radius) < 1e-6)


@pytest.fixture(scope="module")
def tube():
    _, bodies = _tube()
    ((body_id, body),) = bodies.items()
    return body_id, body, _cylinder_index(body, 4.0), _cylinder_index(body, 10.0)


def _signed(body_id, body, signed_at: int, index: int) -> SubShapeRef:
    ref = SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=signed_at)
    return dataclasses.replace(ref, signature=measure_signature(body, ref, signed_at), index=index)


def test_the_measurer_records_the_radius_of_each_cylinder(tube):
    body_id, body, bore, outer = tube
    signatures = BodyFaceMeasurer(body).all()
    assert signatures[bore].radius == pytest.approx(4.0) and signatures[outer].radius == pytest.approx(10.0)
    assert all(s.radius is None and s.half_angle is None for s in signatures if s.surface_kind == "plane")


def test_the_bore_index_renumbered_onto_the_outer_cylinder_re_finds_the_bore(tube):
    body_id, body, bore, outer = tube
    ref = _signed(body_id, body, signed_at=bore, index=outer)
    decision = decide_subshape(ref, body)
    assert decision.status == ReferenceStatus.FOLLOWED and decision.index == bore, decision
    assert decision.reason == "nearest_radius"
    # Every consumer resolves through this: it must hand back the bore, never the outer cylinder.
    assert resolve_subshape_from_bodies({body_id: body}, ref).IsSame(BodyFaceMeasurer(body).shape_at(bore))


def test_the_outer_index_renumbered_onto_the_bore_re_finds_the_outer(tube):
    body_id, body, bore, outer = tube
    decision = decide_subshape(_signed(body_id, body, signed_at=outer, index=bore), body)
    assert (decision.status, decision.index) == (ReferenceStatus.FOLLOWED, outer), decision


def test_a_right_index_stays_ok_on_the_fast_path(tube):
    body_id, body, bore, outer = tube
    for face in (bore, outer):
        decision = decide_subshape(_signed(body_id, body, signed_at=face, index=face), body)
        assert (decision.status, decision.index, decision.method) == (ReferenceStatus.OK, face, "index")


def test_a_signature_saved_before_n1a_still_behaves_as_before(tube):
    """No radius in the stored signature (every file saved so far): the outer cylinder is accepted, as it always was. This is the gap N1a closes for
    signatures stamped from now on; an old one gains its radius the next time a refresh re-stamps it."""
    body_id, body, bore, outer = tube
    ref = _signed(body_id, body, signed_at=bore, index=outer)
    old = dataclasses.replace(ref, signature=dataclasses.replace(ref.signature, radius=None))
    decision = decide_subshape(old, body)
    assert (decision.status, decision.index) == (ReferenceStatus.OK, outer)


def test_a_real_radius_edit_keeps_the_bore_and_a_renumbering_after_it_still_finds_it():
    """The bore's signature stamped on a tube with a 4 mm bore, then read against a tube whose bore is 5 mm (the outer still 10): the bore's own index is kept,
    and an index that names the outer cylinder still re-finds the bore."""
    body_id, body, bore, outer = _tube_ids(4.0)
    stamped = measure_signature(body, SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=bore), bore)
    edited_id, edited, edited_bore, edited_outer = _tube_ids(5.0)
    kept = decide_subshape(SubShapeRef(body_id=edited_id, shape_type=SubShapeType.FACE, index=edited_bore, signature=stamped), edited)
    assert (kept.status, kept.index) == (ReferenceStatus.OK, edited_bore), kept
    found = decide_subshape(SubShapeRef(body_id=edited_id, shape_type=SubShapeType.FACE, index=edited_outer, signature=stamped), edited)
    assert (found.status, found.index) == (ReferenceStatus.FOLLOWED, edited_bore), found


def _tube_ids(bore_radius: float):
    _, bodies = _tube(bore=bore_radius)
    ((body_id, body),) = bodies.items()
    return body_id, body, _cylinder_index(body, bore_radius), _cylinder_index(body, 10.0)
