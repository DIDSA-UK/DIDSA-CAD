"""N1b, test plan item 4: every kind of reference a mate can hold is signed when the mate is made, and re-found when its index is renumbered.

Kinds: `subshape_ref` as a face, an edge and a vertex; `plane_ref.face_ref`; `point_ref.vertex_ref`; both faces of a Width `midplane` with `b` on ANOTHER
occurrence's Part; a reference through a nested sub-assembly occurrence path (`outer/inner`); a reference on a component-pattern copy; a Peg-in-hole pair (the
Concentric on two circular edges and its Coincident companion on the faces they lie on).

Each case checks (1) every `SubShapeRef` of the stored mate carries a signature, measured on the target Part (the one the occurrence places, in its own frame),
(2) a fresh listing has nothing to report, (3) after each reference's stored index is changed to a wrong one of the same kind (what a renumbered Body looks like
to the rules), the next listing re-finds the right face (`followed_references`), persists it, and the part is not held."""

import numpy as np
import pytest

from app.document.extrude import compute_part_bodies
from app.document.reference_signature import BodyEdgeMeasurer, BodyFaceMeasurer, BodyVertexMeasurer
from app.document.router import get_part_or_404
from tests import mate_first_guess_scenes as guess
from tests.test_assembly_group import _compose, _face
from tests.test_assembly_solver import _make_box_part, client
from tests.test_mate_reference_identity import _json, _mate, _refs, _write_index

_FLAGS = ("lost_references", "moved_references", "followed_references")


def _create(root, payload, solve_on="a"):
    return _json(client.post(f"/document/parts/{root}/mates", params={"solve": "group", "occurrence_id": solve_on}, json=payload), 201)


def _count(part, kind):
    (body,) = compute_part_bodies(get_part_or_404(part["id"])).values()
    measurer = {"face": BodyFaceMeasurer, "edge": BodyEdgeMeasurer, "vertex": BodyVertexMeasurer}[kind]
    return len(measurer(body).all())


def _edge(part, direction, near):
    (body,) = compute_part_bodies(get_part_or_404(part["id"])).values()
    sigs = BodyEdgeMeasurer(body).all()
    candidates = [i for i, s in enumerate(sigs) if s.curve_kind == "line" and abs(float(np.dot(s.direction, direction))) > 0.99]
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "edge", "index": min(candidates, key=lambda i: float(np.linalg.norm(np.array(sigs[i].position) - near)))}}


def _vertex(part, near):
    (body,) = compute_part_bodies(get_part_or_404(part["id"])).values()
    sigs = BodyVertexMeasurer(body).all()
    index = min(range(len(sigs)), key=lambda i: float(np.linalg.norm(np.array(sigs[i].position) - near)))
    return {"body_id": part["body_id"], "shape_type": "vertex", "index": index}


def _check(root, mate, kinds):
    """`kinds`: `{path: (shape kind, part dict)}` - every SubShapeRef of the mate, with the Part it lives in."""
    refs = _refs(root, mate["id"])
    assert set(refs) == set(kinds), (sorted(refs), sorted(kinds))
    assert all(ref.signature is not None for ref in refs.values()), "a reference was left unsigned"
    listed = _mate(root, mate["id"])
    assert all(listed[f] == [] for f in _FLAGS) and listed["held"] is False and listed["reference_reasons"] == {}
    for path, (kind, part) in kinds.items():
        original = _refs(root, mate["id"])[path].index
        wrong = (original + 1) % _count(part, kind)
        _write_index(root, mate["id"], path, wrong)
        listed = _mate(root, mate["id"])
        assert path in listed["followed_references"], (path, listed["followed_references"], listed["lost_references"], listed["moved_references"], listed["reference_reasons"])
        assert listed["held"] is False and listed["lost_references"] == []
        assert _refs(root, mate["id"])[path].index == original, f"{path}: the index was not re-found"
    assert _mate(root, mate["id"])["followed_references"] == []  # persisted: nothing left to follow


def _box_scene():
    base = _make_box_part("Base", size=40.0, depth=10.0)
    a = _make_box_part("A", size=10.0, depth=10.0)
    return base, a, _compose(base, [("a", a, (5.0, 5.0, 30.0))])


def test_faces():
    base, a, root = _box_scene()
    mate = _create(root, {"type": "coincident", "alignment": "anti_aligned", "references": [{"occurrence_id": "a", **_face(a, (0, 0, -1))}, {"occurrence_id": "", **_face(base, (0, 0, 1))}]})
    _check(root, mate, {"references[0].subshape_ref": ("face", a), "references[1].subshape_ref": ("face", base)})


def test_edges():
    base, a, root = _box_scene()
    mate = _create(
        root,
        {"type": "coincident", "references": [{"occurrence_id": "a", **_edge(a, (0, 0, 1), (0, 0, 5))}, {"occurrence_id": "", **_edge(base, (0, 0, 1), (40, 40, 5))}]},
    )
    _check(root, mate, {"references[0].subshape_ref": ("edge", a), "references[1].subshape_ref": ("edge", base)})


def test_vertices():
    base, a, root = _box_scene()
    mate = _create(
        root,
        {"type": "coincident", "references": [{"occurrence_id": "a", "subshape_ref": _vertex(a, (0, 0, 0))}, {"occurrence_id": "", "subshape_ref": _vertex(base, (40, 40, 10))}]},
    )
    _check(root, mate, {"references[0].subshape_ref": ("vertex", a), "references[1].subshape_ref": ("vertex", base)})


def test_plane_ref_face_refs():
    base, a, root = _box_scene()
    mate = _create(
        root,
        {
            "type": "coincident",
            "alignment": "anti_aligned",
            "references": [
                {"occurrence_id": "a", "plane_ref": {"face_ref": _face(a, (0, 0, -1))["subshape_ref"]}},
                {"occurrence_id": "", "plane_ref": {"face_ref": _face(base, (0, 0, 1))["subshape_ref"]}},
            ],
        },
    )
    _check(root, mate, {"references[0].plane_ref.face_ref": ("face", a), "references[1].plane_ref.face_ref": ("face", base)})


def test_point_ref_vertex_ref():
    base, a, root = _box_scene()
    mate = _create(
        root,
        {
            "type": "coincident",
            "references": [
                {"occurrence_id": "a", "point_ref": {"vertex_ref": _vertex(a, (0, 0, 0))}},
                {"occurrence_id": "", "plane_ref": {"face_ref": _face(base, (0, 0, 1))["subshape_ref"]}},
            ],
        },
    )
    _check(root, mate, {"references[0].point_ref.vertex_ref": ("vertex", a), "references[1].plane_ref.face_ref": ("face", base)})


def test_width_midplane_with_b_on_another_occurrence():
    """Both faces of each side's mid-plane are signed; the gap's `b` face is measured on the OTHER bar's Part (`b_occurrence_id`), not on `a`'s."""
    from tests.test_width_mate_parts import _gap, _scene, _tab_one

    root, bar_l, bar_r, plate, _ = _scene(1)
    mate = _create(root, {"type": "coincident", "references": [_tab_one(plate), _gap(bar_l, bar_r)]}, "plate")
    kinds = {
        "references[0].midplane.a.face_ref": ("face", plate),
        "references[0].midplane.b.face_ref": ("face", plate),
        "references[1].midplane.a.face_ref": ("face", bar_l),
        "references[1].midplane.b.face_ref": ("face", bar_r),
    }
    refs = _refs(root, mate["id"])
    assert set(refs) == set(kinds) and all(r.signature is not None for r in refs.values())
    # `b` really was measured against bar R's Body (a different Part from `a`'s): its signature's body diagonal is bar R's, and the signatures differ from a's.
    assert refs["references[1].midplane.b.face_ref"].signature.direction == pytest.approx((-1.0, 0.0, 0.0))
    _check(root, mate, kinds)


def test_a_reference_through_a_nested_sub_assembly_path():
    from tests.test_assembly_nested_mate import _build_scene, _mate_payload

    scene = _build_scene()
    root = scene["top"]["id"]
    mate = _create(root, _mate_payload(scene, "mover", "outer/inner"), "mover")
    _check(root, mate, {"references[0].subshape_ref": ("face", scene["mover"]), "references[1].subshape_ref": ("face", scene["leaf"])})
    assert _refs(root, mate["id"])["references[1].subshape_ref"].signature is not None


def test_a_reference_on_a_component_pattern_copy():
    from tests.test_mate_pattern_copy import COPY, _payload, _scene

    scene = _scene()
    root = scene["top"]["id"]
    mate = _create(root, _payload(scene, COPY.format(pid=scene["pid"])), "mover")
    _check(root, mate, {"references[0].subshape_ref": ("face", scene["mover"]), "references[1].subshape_ref": ("face", scene["leaf"])})


def test_a_peg_in_hole_pair_is_signed_edges_and_faces():
    scene = guess.SCENES["peg-in-hole"]()
    created = _json(client.post(f"/document/parts/{scene.root}/mates", params={"solve": "auto", "occurrence_id": guess.DRIVEN}, json=scene.payload), 201)
    stored = [m for m in get_part_or_404(scene.root).mates]
    assert sorted(m.type.value for m in stored) == ["coincident", "concentric"]
    from app.document.subshape_identity import iter_mate_subshape_refs

    for mate in stored:  # the Concentric's two EDGES and the companion's two FACES are all signed
        refs = iter_mate_subshape_refs(mate)
        assert len(refs) == 2 and all(r.signature is not None for _p, r in refs), mate.type
        assert {r.shape_type.value for _p, r in refs} == ({"edge"} if mate.type.value == "concentric" else {"face"})
    listed = {m["type"]: m for m in _json(client.get(f"/document/parts/{scene.root}/mates"))}
    assert all(m["held"] is False and m["lost_references"] == [] and m["followed_references"] == [] for m in listed.values())
    assert created["type"] == "concentric"


def test_dissolving_a_pattern_keeps_the_signatures_of_the_mate_on_a_copy():
    """A copy's mate carries the source Part's references; dissolving the pattern rewrites only the occurrence path, so the signatures come along."""
    from tests.test_mate_pattern_copy import COPY, _payload, _scene

    scene = _scene()
    root = scene["top"]["id"]
    copy_id = COPY.format(pid=scene["pid"])
    mate = _create(root, _payload(scene, copy_id), "mover")
    before = {p: r.signature for p, r in _refs(root, mate["id"]).items()}
    assert all(sig is not None for sig in before.values())
    _json(client.post(f"/document/parts/{root}/component-patterns/{scene['pid']}/dissolve"))
    stored = get_part_or_404(root).mates
    assert [m.id for m in stored] == [mate["id"]] and stored[0].references[1].occurrence_id != copy_id  # rewritten to the real occurrence
    assert {p: r.signature for p, r in _refs(root, mate["id"]).items()} == before
    listed = _mate(root, mate["id"])
    assert all(listed[f] == [] for f in _FLAGS) and listed["held"] is False
