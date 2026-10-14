"""A Mate may reference geometry inside a sub-assembly by the `/`-joined
Occurrence path the client reads off assembly-mesh instances
(`outer_occurrence_id/inner_occurrence_id`).

Bug report 2026-10-14: mating Table_Top to a face of Frame_A, which lives
inside the Frame sub-assembly, failed with `422 occurrence_not_found` because
only a bare top-level Occurrence id used to resolve. These tests check the
*constraint* is satisfied in world space (not one arbitrary numeric answer),
with the sub-assembly placed away from the origin and rotated so a
transform-composition mistake cannot pass by accident.
"""

from fastapi.testclient import TestClient

from app.document.assembly import resolve_occurrence_target
from app.document.assembly_solver import _place_in_world, _resolve_local_geometry, compute_part_bodies

from app.document.store import get_document
from app.main import app
from tests.conftest import TEST_API_KEY
from tests.test_assembly_solver import _export_part, _find_planar_face, _make_box_part

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

_TOL = 1e-4


def _occurrence(occ_id: str, part_id: str, translation, angle=0.0, fixed=False) -> dict:
    return {
        "id": occ_id,
        "external_ref": f"parts/{part_id}.didsa",
        "resolved_part_id": part_id,
        "name_override": None,
        "transform": {"translation": list(translation), "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": angle},
        "suppressed": False,
        "hidden": False,
        "fixed": fixed,
    }


def _build_scene() -> dict:
    """top -> outer (sub, rotated 90deg about Z, moved to (0, 50, 0)) -> inner (leaf box at (100, 0, 0));
    top -> mover (a second box, parked far away)."""
    leaf = _make_box_part("Leaf")
    sub = _make_box_part("Sub")
    mover = _make_box_part("Mover")
    top = _make_box_part("Top")
    exports = {name: _export_part(p["id"]) for name, p in {"leaf": leaf, "sub": sub, "mover": mover, "top": top}.items()}
    parts = {name: e["document"]["parts"][0] for name, e in exports.items()}
    # The sub-assembly is a pure assembly here: drop its own box so only `inner` is in it.
    parts["sub"]["features"] = []
    parts["sub"]["occurrences"] = [_occurrence("inner", leaf["id"], (100.0, 0.0, 0.0))]
    parts["top"]["features"] = []
    parts["top"]["occurrences"] = [
        _occurrence("outer", sub["id"], (0.0, 50.0, 0.0), angle=90.0),
        _occurrence("mover", mover["id"], (500.0, 500.0, 500.0)),
    ]
    parts["top"]["mates"] = []
    payload = {
        "schema_version": exports["top"]["schema_version"],
        "document": {"id": "nested-doc", "root_part_id": top["id"], "parts": list(parts.values())},
        "sketches": [s for e in exports.values() for s in e["sketches"]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200
    return {"top": top, "leaf": leaf, "mover": mover, "sub": sub}


def _mate_payload(scene: dict, first_occurrence: str, second_occurrence: str) -> dict:
    leaf_face = _find_planar_face(scene["leaf"]["id"], scene["leaf"]["body_id"], (0.0, 0.0, 1.0))
    mover_face = _find_planar_face(scene["mover"]["id"], scene["mover"]["body_id"], (0.0, 0.0, -1.0))
    refs = {
        "mover": {"occurrence_id": "mover", "subshape_ref": {"body_id": scene["mover"]["body_id"], "shape_type": "face", "index": mover_face}},
        "outer/inner": {"occurrence_id": "outer/inner", "subshape_ref": {"body_id": scene["leaf"]["body_id"], "shape_type": "face", "index": leaf_face}},
        "outer": {"occurrence_id": "outer", "subshape_ref": {"body_id": scene["leaf"]["body_id"], "shape_type": "face", "index": leaf_face}},
    }
    return {"type": "coincident", "references": [refs[first_occurrence], refs[second_occurrence]]}


def _world_plane(scene: dict, part_id: str, ref: dict):
    document = get_document()
    part = document.parts[part_id]
    from app.document.models import MateEntityRef
    from app.document.router import _mate_entity_ref_to_domain
    from app.document.schemas import MateEntityRefResponse

    domain: MateEntityRef = _mate_entity_ref_to_domain(MateEntityRefResponse(**ref))
    target, transform = resolve_occurrence_target(document, part, domain.occurrence_id)
    local = _resolve_local_geometry(target, compute_part_bodies(target), domain)
    return _place_in_world(local, transform) if transform is not None else local


def _assert_coincident_opposed(a, b):
    na, nb = a.plane.normal, b.plane.normal
    assert abs(sum(x * y for x, y in zip(na, nb)) + 1.0) < _TOL, (na, nb)
    delta = [p - q for p, q in zip(a.point, b.point)]
    assert abs(sum(d * n for d, n in zip(delta, nb))) < _TOL, delta


def test_resolve_occurrence_target_composes_a_nested_path():
    scene = _build_scene()
    document = get_document()
    top = document.parts[scene["top"]["id"]]
    leaf_part, transform = resolve_occurrence_target(document, top, "outer/inner")
    assert leaf_part.id == scene["leaf"]["id"]
    # inner (100, 0, 0) rotated 90deg about Z -> (0, 100, 0), then outer's (0, 50, 0).
    assert all(abs(a - b) < _TOL for a, b in zip(transform.translation, (0.0, 150.0, 0.0)))
    assert transform.rotation_angle_degrees == 90.0 or abs(transform.rotation_angle_degrees - 90.0) < _TOL


def test_mate_to_geometry_inside_a_sub_assembly_is_accepted_and_satisfied_after_solve():
    scene = _build_scene()
    top_id = scene["top"]["id"]
    payload = _mate_payload(scene, "mover", "outer/inner")
    response = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert response.status_code == 201, response.text

    solve = client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={})
    assert solve.status_code == 200, solve.text

    driven = _world_plane(scene, top_id, payload["references"][0])
    fixed = _world_plane(scene, top_id, payload["references"][1])
    _assert_coincident_opposed(driven, fixed)


def test_driving_the_sub_assembly_against_a_fixed_part_moves_the_nested_face():
    scene = _build_scene()
    top_id = scene["top"]["id"]
    # mover is the fixed peer (flag it fixed), outer/inner's face is the driven side.
    assert client.patch(f"/document/parts/{top_id}/occurrences/mover", json={"fixed": True}).status_code == 200
    payload = _mate_payload(scene, "outer/inner", "mover")
    response = client.post(f"/document/parts/{top_id}/mates", json=payload)
    assert response.status_code == 201, response.text

    solve = client.post(f"/document/parts/{top_id}/occurrences/outer/solve", json={})
    assert solve.status_code == 200, solve.text

    driven = _world_plane(scene, top_id, payload["references"][0])
    fixed = _world_plane(scene, top_id, payload["references"][1])
    _assert_coincident_opposed(driven, fixed)


def test_unknown_nested_segment_is_rejected():
    scene = _build_scene()
    payload = _mate_payload(scene, "mover", "outer/inner")
    payload["references"][1]["occurrence_id"] = "outer/does-not-exist"
    response = client.post(f"/document/parts/{scene['top']['id']}/mates", json=payload)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "occurrence_not_found"


def test_two_references_inside_the_same_top_level_occurrence_are_rejected():
    scene = _build_scene()
    payload = _mate_payload(scene, "outer", "outer/inner")
    response = client.post(f"/document/parts/{scene['top']['id']}/mates", json=payload)
    assert response.status_code == 422


def test_deleting_the_top_level_occurrence_removes_mates_into_it():
    scene = _build_scene()
    top_id = scene["top"]["id"]
    assert client.post(f"/document/parts/{top_id}/mates", json=_mate_payload(scene, "mover", "outer/inner")).status_code == 201
    assert client.delete(f"/document/parts/{top_id}/occurrences/outer").status_code == 204
    assert client.get(f"/document/parts/{top_id}/mates").json() == []
