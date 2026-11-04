"""`face_selector` on a mate reference (AI Modelling, Assembly mode's mate turn): a face named by geometry in the
component's own frame - a planar face by outward normal, or a cylindrical face by radius, with `near` to pick
among several - resolved in the dry run against a placed occurrence's real geometry, like `edge_selector`."""
import pytest
from fastapi import HTTPException
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt

from app.document.ai_plan_edges import resolve_mate_face_selector
from app.document.ai_plan_schemas import CardinalDirection
from tests.test_ai_plan_assembly_steps import (
    _face_ref,
    _results_by_local_id,
    _setup_top_with_occurrence_target_having_its_own_body,
    _validate,
)


def _face_centre(shape, index):
    faces = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_FACE, faces)
    props = GProp_GProps()
    brepgprop.SurfaceProperties(topods.Face(faces.FindKey(index + 1)), props)
    c = props.CentreOfMass()
    return round(c.X(), 3), round(c.Y(), 3), round(c.Z(), 3)


def _stepped_block():
    """A 20x10x10 block with a 10x10x5 step on its right half: +z faces at z=10 (left) and z=15 (right)."""
    return BRepAlgoAPI_Fuse(
        BRepPrimAPI_MakeBox(20.0, 10.0, 10.0).Shape(), BRepPrimAPI_MakeBox(gp_Pnt(10, 0, 10), 10.0, 10.0, 5.0).Shape()
    ).Shape()


def _plate_with_two_holes():
    plate = BRepPrimAPI_MakeBox(40.0, 20.0, 5.0).Shape()
    for x in (10.0, 30.0):
        plate = BRepAlgoAPI_Cut(plate, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, 10, -1), gp_Dir(0, 0, 1)), 2.0, 7.0).Shape()).Shape()
    return plate


def test_a_direction_takes_the_outermost_face_unless_near_says_otherwise():
    block = _stepped_block()
    top = resolve_mate_face_selector(block, "b", direction=CardinalDirection.PLUS_Z)
    assert _face_centre(block, top.index)[2] == 15.0
    lower = resolve_mate_face_selector(block, "b", direction=CardinalDirection.PLUS_Z, near=(5.0, 5.0, 10.0))
    assert _face_centre(block, lower.index) == (5.0, 5.0, 10.0)


def test_a_cylinder_radius_needs_near_when_several_separate_faces_match():
    plate = _plate_with_two_holes()
    with pytest.raises(HTTPException) as error:
        resolve_mate_face_selector(plate, "b", cylinder_radius=2.0)
    assert error.value.detail["type"] == "face_selector_ambiguous"
    right = resolve_mate_face_selector(plate, "b", cylinder_radius=2.0, near=(31.0, 10.0, 2.5))
    assert _face_centre(plate, right.index)[0] == pytest.approx(30.0, abs=2.1)
    with pytest.raises(HTTPException) as error:
        resolve_mate_face_selector(plate, "b", cylinder_radius=3.0)
    assert error.value.detail["type"] == "face_selector_no_matching_face"


def test_the_dry_run_resolves_a_face_selector_on_a_placed_occurrence_without_a_body_id():
    """bolt_a's box is 10x10x15: its +z face is the top one, at z=15, resolved against bolt_a's own geometry."""
    top_id, bolt_a_id, bolt_a_body_id, occ_a = _setup_top_with_occurrence_target_having_its_own_body()
    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "coincident",
                "references": [
                    {"occurrence_id": f"existing:{occ_a}", "face_selector": {"direction": "+z"}},
                    _face_ref(""),
                ],
            }
        ],
    )
    result = _results_by_local_id(response)["mate1"]
    assert result["ok"] is True, result
    resolved = result["resolved_mate_references"][0]
    assert resolved["body_id"] == bolt_a_body_id
    assert resolved["shape_type"] == "face"
    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    body = compute_part_bodies(get_part_or_404(bolt_a_id))[bolt_a_body_id]
    assert _face_centre(body, resolved["index"]) == (5.0, 5.0, 15.0)


def test_a_face_selector_with_no_match_fails_the_step_with_a_clear_error():
    top_id, _, _, occ_a = _setup_top_with_occurrence_target_having_its_own_body()
    response = _validate(
        top_id,
        [
            {
                "local_id": "mate1",
                "kind": "mate",
                "type": "concentric",
                "references": [
                    {"occurrence_id": f"existing:{occ_a}", "face_selector": {"cylinder_radius": 5}},
                    _face_ref(""),
                ],
            }
        ],
    )
    result = _results_by_local_id(response)["mate1"]
    assert result["ok"] is False
    assert result["error"]["type"] == "face_selector_no_matching_face"


def test_a_face_selector_needs_exactly_one_of_direction_or_cylinder_radius():
    top_id, _, _, occ_a = _setup_top_with_occurrence_target_having_its_own_body()
    response = client_validate_raw(
        top_id,
        {"occurrence_id": f"existing:{occ_a}", "face_selector": {"direction": "+z", "cylinder_radius": 5}},
    )
    assert response.status_code == 422


def client_validate_raw(part_id, ref):
    from tests.test_ai_plan_assembly_steps import client

    return client.post(
        f"/document/parts/{part_id}/ai-plan/validate",
        json={"version": 1, "steps": [{"local_id": "m", "kind": "mate", "type": "coincident", "references": [ref, _face_ref("")]}]},
    )


def test_a_revolved_pins_flat_faces_read_their_true_outward_direction():
    """A pin revolved from a half-profile (shank r5 x 40, head r15 x 10, axis along z): its flat faces lie on surfaces
    of revolution, whose plane axis has no reliable sign. Reading the normal from that axis made every flat face
    face +z, so `direction: -z` could not find the shoulder (found by the AI-eval assembly runs)."""
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeRevol
    from OCC.Core.gp import gp_Ax1

    profile = BRepBuilderAPI_MakePolygon()
    for x, z in ((0, 0), (5, 0), (5, 40), (15, 40), (15, 50), (0, 50)):
        profile.Add(gp_Pnt(x, 0, z))
    profile.Close()
    face = BRepBuilderAPI_MakeFace(profile.Wire()).Face()
    pin = BRepPrimAPI_MakeRevol(face, gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1))).Shape()

    tip = resolve_mate_face_selector(pin, "b", direction=CardinalDirection.MINUS_Z)
    assert _face_centre(pin, tip.index)[2] == 0.0
    shoulder = resolve_mate_face_selector(pin, "b", direction=CardinalDirection.MINUS_Z, near=(10.0, 0.0, 40.0))
    assert _face_centre(pin, shoulder.index)[2] == 40.0
    top = resolve_mate_face_selector(pin, "b", direction=CardinalDirection.PLUS_Z)
    assert _face_centre(pin, top.index)[2] == 50.0


def test_the_mate_solver_reads_a_revolved_faces_normal_the_same_way():
    """`measure._outward_normal`, which the assembly solver's face geometry uses: a revolved pin's shoulder faces
    -z. With the old orientation-flag rule it read +z, and a mate seating that shoulder on a block could not be
    solved ("No placement satisfies these mates together")."""
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeRevol
    from OCC.Core.gp import gp_Ax1

    from app.document.measure import _outward_normal

    profile = BRepBuilderAPI_MakePolygon()
    for x, z in ((0, 0), (5, 0), (5, 40), (15, 40), (15, 50), (0, 50)):
        profile.Add(gp_Pnt(x, 0, z))
    profile.Close()
    pin = BRepPrimAPI_MakeRevol(BRepBuilderAPI_MakeFace(profile.Wire()).Face(), gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1))).Shape()
    shoulder = resolve_mate_face_selector(pin, "b", direction=CardinalDirection.MINUS_Z, near=(10.0, 0.0, 40.0))
    faces = TopTools_IndexedMapOfShape()
    topexp.MapShapes(pin, TopAbs_FACE, faces)
    normal = _outward_normal(topods.Face(faces.FindKey(shoulder.index + 1)))
    assert round(normal.Z(), 6) == -1.0


def test_a_normal_names_a_sloped_face():
    """A dovetail flank faces neither axis: `normal` names it by its own outward direction."""
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
    from OCC.Core.gp import gp_Vec

    # a dovetail tenon's section in YZ (20 wide at the top z=25, 50 at the bottom z=0), extruded 100 along x
    section = BRepBuilderAPI_MakePolygon()
    for y, z in ((-25, 0), (25, 0), (10, 25), (-10, 25)):
        section.Add(gp_Pnt(0, y, z))
    section.Close()
    tenon = BRepPrimAPI_MakePrism(BRepBuilderAPI_MakeFace(section.Wire()).Face(), gp_Vec(100, 0, 0)).Shape()
    # the +y flank runs from (25, 0) to (10, 25): its outward normal is (0, 25, 15) normalised
    flank = resolve_mate_face_selector(tenon, "b", normal=(0.0, 25.0, 15.0))
    assert _face_centre(tenon, flank.index)[1] == pytest.approx(17.5)
    with pytest.raises(HTTPException):
        resolve_mate_face_selector(tenon, "b", normal=(0.0, 1.0, 0.0))
