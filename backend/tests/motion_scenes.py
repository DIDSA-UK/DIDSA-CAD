"""Multi-part assemblies with variable degrees of freedom, for the constrained-drag smoothness study
(`tools/motion_smoothness/`) and its tests. Built through the real HTTP surface like `test_assembly_group.py`.

Each builder returns `(root_part_id, {role: occurrence_id})` for a scene in which NOTHING is fixed; `fix(root, occ_id)`
fixes one occurrence afterwards (the "one part fixed" variant)."""

from tests.test_assembly_group import _compose, _cyl, _face, _mate
from tests.test_assembly_solver import _add_point, _create_part, _make_box_part, _make_cylinder_part, client


def _plate_with_hole(name: str, *, size: float = 60.0, depth: float = 10.0, at=(30.0, 30.0), radius: float = 5.0) -> dict:
    plate = _make_box_part(name, size=size, depth=depth)
    sf = client.post(f"/document/parts/{plate['id']}/features/sketch", json={"plane": "XY"}).json()
    center = _add_point(sf["sketch_id"], at[0], at[1])
    assert client.post(f"/sketch/sketches/{sf['sketch_id']}/circles", json={"center_point_id": center["id"], "radius": radius, "angle": 0.0}).status_code == 201
    cut = client.post(f"/document/parts/{plate['id']}/extrude-features", json={
        "sketch_feature_id": sf["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": depth, "target_body_ids": [plate["body_id"]]})
    assert cut.status_code == 201, cut.text
    return plate


def fix(root: str, occurrence_id: str) -> None:
    response = client.patch(f"/document/parts/{root}/occurrences/{occurrence_id}", json={"fixed": True})
    assert response.status_code == 200, response.text


def bolt_scene(root_part: dict | None = None):
    """Plate with a through hole + bolt standing in it: concentric + coincident. Floating group dof 7, plate fixed -> 1."""
    plate = _plate_with_hole("HolePlate")
    bolt = _make_cylinder_part("Bolt", radius=4.0, depth=20.0)
    root = _compose(root_part or _create_part("BoltAssembly"), [("occ-plate", plate, (0, 0, 0)), ("occ-bolt", bolt, (30, 30, 10))])
    _mate(root, "concentric", "occ-bolt", _cyl(bolt), "occ-plate", _cyl(plate))
    _mate(root, "coincident", "occ-bolt", _face(bolt, (0, 0, -1)), "occ-plate", _face(plate, (0, 0, 1)))
    return root, {"base": "occ-plate", "mover": "occ-bolt"}


def hinge_scene(root_part: dict | None = None):
    """Two leaves (plates with a hole) stacked and joined by a pin through both holes: pin concentric to each hole,
    leaf B's bottom face coincident with leaf A's top face. Three parts. Floating dof 7 (rigid body + hinge angle),
    leaf A fixed -> 1 (leaf B swings about the pin; the pin follows, spinning free)."""
    leaf_a = _plate_with_hole("LeafA", size=40.0, depth=5.0, at=(20.0, 20.0), radius=4.5)
    leaf_b = _plate_with_hole("LeafB", size=40.0, depth=5.0, at=(20.0, 20.0), radius=4.5)
    pin = _make_cylinder_part("Pin", radius=4.0, depth=14.0)
    root = _compose(root_part or _create_part("HingeAssembly"),
                    [("occ-a", leaf_a, (0, 0, 0)), ("occ-b", leaf_b, (0, 0, 5)), ("occ-pin", pin, (20, 20, -2))])
    _mate(root, "concentric", "occ-pin", _cyl(pin), "occ-a", _cyl(leaf_a))
    _mate(root, "concentric", "occ-pin", _cyl(pin), "occ-b", _cyl(leaf_b))
    _mate(root, "coincident", "occ-b", _face(leaf_b, (0, 0, -1)), "occ-a", _face(leaf_a, (0, 0, 1)))
    return root, {"base": "occ-a", "mover": "occ-b", "extra": "occ-pin"}
