"""Coupler mates with REAL gear parts (gear features): the ratio, travel and sense a new gear / rack and pinion mate fills in
for itself (`docs/gears-and-motion-plan.md` 3.3.3). File name carries `gear` so conftest puts it in the `gears` leg."""

import math

from tests.test_assembly_group import _compose
from tests.test_assembly_solver import _create_part, _find_straight_edge, _measure_face, client
from tests.test_coupler_mates import _post_mate, _ref


def _cyl(part: dict) -> dict:
    """A cylindrical face of a gear part (the bore, or a tooth land: all share the gear's axis). A gear has far more faces than the
    first dozen the box-and-cylinder helpers scan."""
    for index in range(600):
        result = _measure_face(part["id"], part["body_id"], index)
        if result.get("axis") is not None and result.get("radius") is not None:
            return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": index}}
    raise AssertionError("no cylindrical face")


def _gear_part(name: str, *, teeth: int, internal: bool = False, module: float = 2.0) -> dict:
    part = _create_part(name)
    payload = {"gear_type": "boss", "is_internal": internal, "module": module, "tooth_count": teeth, "face_width": 10.0}
    if internal:
        payload["outer_diameter"] = module * (teeth + 8)
    else:
        payload["bore_diameter"] = 8.0
    response = client.post(f"/document/parts/{part['id']}/gear-features", json=payload)
    assert response.status_code == 201, response.text
    meshes = client.get(f"/document/parts/{part['id']}/mesh").json()
    part["body_id"] = meshes[0]["body_id"]
    return part


def _axis_dot(a: dict, b: dict) -> float:
    def direction(part):
        ref = _cyl(part)["subshape_ref"]
        return _measure_face(part["id"], part["body_id"], ref["index"])["axis"]["direction"]

    return sum(x * y for x, y in zip(direction(a), direction(b)))


def _rack_part(name: str) -> dict:
    part = _create_part(name)
    response = client.post(f"/document/parts/{part['id']}/rack-features", json={"rack_type": "boss", "module": 2.0, "tooth_count": 10, "face_width": 10.0})
    assert response.status_code == 201, response.text
    part["body_id"] = client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]
    return part


def _pair(a_part, b_part):
    root = _compose(_create_part("GearPair"), [("occ-a", a_part, (0, 0, 0)), ("occ-b", b_part, (60, 0, 0))])
    return root


def _make(root, a_part, b_part, mate_type="gear", **extra):
    return _post_mate(root, mate_type, _ref("occ-a", _cyl(a_part)), _ref("occ-b", _cyl(b_part)), **extra)


def test_auto_ratio_from_the_tooth_counts_and_the_external_pair_sense():
    a, b = _gear_part("Pinion", teeth=20), _gear_part("Wheel", teeth=40)
    root = _pair(a, b)
    r = _make(root, a, b)
    assert r.status_code == 201, r.text
    assert abs(r.json()["value"] - 0.5) < 1e-12  # z_A / z_B
    assert r.json()["secondary_flip"] is False  # parallel same-way axes, both external: opposite turns, k = -1
    assert r.json()["branch_source"] == "auto"


def test_a_typed_value_wins_and_a_named_sense_is_the_users():
    a, b = _gear_part("Pinion", teeth=20), _gear_part("Wheel", teeth=40)
    root = _pair(a, b)
    r = _make(root, a, b, value=3.0, secondary_flip=True)
    assert r.status_code == 201 and r.json()["value"] == 3.0 and r.json()["secondary_flip"] is True and r.json()["branch_source"] == "user"


def test_internal_with_external_turn_the_same_way():
    ring, pinion = _gear_part("Ring", teeth=60, internal=True), _gear_part("Pinion", teeth=20)
    root = _pair(ring, pinion)
    r = _make(root, ring, pinion)
    assert r.status_code == 201, r.text
    assert abs(r.json()["value"] - 3.0) < 1e-12
    # Internal + external turn the same way about a shared direction: k = c (the sign of the dot of the two resolved axes, which
    # follows each face's own orientation - a concave ring face may report its axis the other way), not -c as for two external gears.
    c = math.copysign(1.0, _axis_dot(ring, pinion))
    assert r.json()["secondary_flip"] is (c > 0)


def test_the_sense_follows_a_flipped_axis_direction():
    a, b = _gear_part("Pinion", teeth=20), _gear_part("Wheel", teeth=40)
    root = _pair(a, b)
    flip = {"translation": [60, 0, 0], "rotation_axis": [1, 0, 0], "rotation_angle_degrees": 180.0}
    assert client.patch(f"/document/parts/{root}/occurrences/occ-b", json={"transform": flip}).status_code == 200
    r = _make(root, a, b)
    assert r.status_code == 201, r.text
    assert r.json()["secondary_flip"] is True  # the axes now point opposite ways: c = -1, k = -c = +1


def test_rack_travel_is_pi_times_the_pitch_diameter():
    pinion, rack = _gear_part("Pinion", teeth=20), _rack_part("Rack")
    root = _pair(pinion, rack)
    edge = None
    for direction in ((1, 0, 0), (0, 1, 0)):
        try:
            edge = _find_straight_edge(rack["id"], rack["body_id"], direction)
            break
        except AssertionError:
            continue
    assert edge is not None
    r = _post_mate(root, "rack_pinion", _ref("occ-a", _cyl(pinion)), _ref("occ-b", {"subshape_ref": {"body_id": rack["body_id"], "shape_type": "edge", "index": edge}}))
    assert r.status_code == 201, r.text
    assert abs(r.json()["value"] - math.pi * 40.0) < 1e-9
    assert r.json()["secondary_flip"] in (True, False)


def test_a_part_with_two_gears_needs_a_typed_ratio():
    a, b = _gear_part("Pinion", teeth=20), _gear_part("Wheel", teeth=40)
    extra = client.post(f"/document/parts/{b['id']}/gear-features", json={"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 30, "face_width": 5.0})
    assert extra.status_code == 201, extra.text
    root = _pair(a, b)
    r = _make(root, a, b)
    assert r.status_code == 422 and r.json()["detail"]["type"] == "gear_ratio_required"
