"""B1: SubShapeRef resolution (resolve_subshape) against real OCCT geometry,
plus the `produces` tag on the Feature list/detail responses. Needs real
pythonocc-core, same as every other test_stage*.py file that imports
app.main - not runnable in a sandbox without it (see this prompt's status
doc entry). See test_stage_b1_model.py for the pure-Python slice of this
prompt (Produces/SubShapeRef/SubShapeType themselves), which is genuinely
executed.

Same helper conventions (copy-pasted, not shared via conftest) as every
other test_stage*.py file in this directory - see test_stage_a1_multibody.py.
"""

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.document.extrude import resolve_subshape
from app.document.models import SubShapeRef, SubShapeType
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )


def _boss_box(part_id: str) -> dict:
    """A single 10x10x10 box Body (6 faces, 12 edges, 8 vertices) - the same
    deterministic-by-construction primitive every other prompt in this
    project has relied on for exact topology counts, rather than a boolean
    result whose exact face/edge count would need real OCCT to verify."""
    sketch = _create_square_sketch_feature(part_id, size=10.0)
    response = _create_extrude_feature(part_id, sketch["id"], extrude_type="boss")
    assert response.status_code == 201
    return response.json()


# --- Success path: resolution is stable/correct across independent recomputes


def _vertex_points(shape) -> list[tuple[float, float, float]]:
    """Every real OCCT topology vertex under `shape`, rounded and sorted so
    two independently-recomputed-but-geometrically-identical shapes compare
    equal regardless of `topexp.MapShapes`' internal iteration order. Built
    entirely from APIs `app.document.mesh._extract_topology_vertices`
    already exercises for real in this exact CI environment (`BRep_Tool.
    Pnt`, `topods.Vertex`, `topexp.MapShapes`/`TopTools_IndexedMapOfShape`),
    rather than `BRepGProp`/`GProp_GProps`, whose exact call surface in this
    pythonocc-core version this test file got wrong on its first attempt
    (see this prompt's status doc) - this sticks to APIs already proven
    rather than risk a second unverified one."""
    from OCC.Core.BRep import BRep_Tool
    from OCC.Core.TopAbs import TopAbs_VERTEX
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape
    from OCC.Core.TopoDS import topods

    vertex_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(shape, TopAbs_VERTEX, vertex_map)
    points = []
    for i in range(1, vertex_map.Size() + 1):
        point = BRep_Tool.Pnt(topods.Vertex(vertex_map.FindKey(i)))
        points.append((round(point.X(), 6), round(point.Y(), 6), round(point.Z(), 6)))
    return sorted(points)


def test_resolve_subshape_face_matches_the_face_captured_at_creation():
    from OCC.Core.TopAbs import TopAbs_FACE
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape

    from app.document.extrude import compute_part_bodies

    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    # Ground truth: capture face index 0's corner vertices directly from an
    # independent recompute (this is "at creation" - nothing upstream has
    # changed since).
    bodies = compute_part_bodies(part)
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[boss["id"]], TopAbs_FACE, face_map)
    expected_points = _vertex_points(face_map.FindKey(1))

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.FACE, index=0)
    resolved = resolve_subshape(part, ref)

    # Same enumeration index, same unchanged topology -> the same face,
    # confirmed via a second, fully independent recompute+re-enumeration
    # (not object identity, since compute_part_bodies rebuilds fresh OCCT
    # shapes on every call).
    assert _vertex_points(resolved) == expected_points
    # A face of a 10x10x10 box is a 10x10 square - exactly 4 corners.
    assert len(expected_points) == 4


def test_resolve_subshape_edge_matches_the_edge_captured_at_creation():
    from OCC.Core.TopAbs import TopAbs_EDGE
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape

    from app.document.extrude import compute_part_bodies

    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    bodies = compute_part_bodies(part)
    edge_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[boss["id"]], TopAbs_EDGE, edge_map)
    expected_points = _vertex_points(edge_map.FindKey(1))

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.EDGE, index=0)
    resolved = resolve_subshape(part, ref)

    # Every edge of a 10x10x10 box runs between exactly 2 corners.
    assert _vertex_points(resolved) == expected_points
    assert len(expected_points) == 2


def test_resolve_subshape_body_and_solid_counts_are_the_documented_box_shape():
    """Sanity-checks the fixture itself, independent of resolve_subshape:
    a plain box has exactly 6 faces and 12 edges - the mathematical
    certainty this whole test file's index-bounds tests below lean on."""
    from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE
    from OCC.Core.TopExp import topexp
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape

    from app.document.extrude import compute_part_bodies

    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    bodies = compute_part_bodies(part)
    face_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[boss["id"]], TopAbs_FACE, face_map)
    edge_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[boss["id"]], TopAbs_EDGE, edge_map)

    assert face_map.Size() == 6
    assert edge_map.Size() == 12


# --- Failure path: fails closed with a structured missing_reference error --


def test_resolve_subshape_raises_missing_reference_for_an_unknown_body_id():
    part_dict = _create_part()
    _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    ref = SubShapeRef(body_id="does-not-exist", shape_type=SubShapeType.FACE, index=0)

    with pytest.raises(HTTPException) as exc_info:
        resolve_subshape(part, ref)

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {
        "type": "missing_reference",
        "body_id": "does-not-exist",
        "shape_type": "face",
        "index": 0,
    }


def test_resolve_subshape_raises_missing_reference_when_the_body_is_excluded():
    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.FACE, index=0)

    with pytest.raises(HTTPException) as exc_info:
        resolve_subshape(part, ref, excluded_feature_ids=frozenset({boss["id"]}))

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "missing_reference"
    assert exc_info.value.detail["body_id"] == boss["id"]


def test_resolve_subshape_raises_missing_reference_for_an_out_of_range_face_index():
    """A box only has 6 faces (0-5) - index 6 is already out of range with
    no upstream mutation needed, exercising the identical "ref.index is out
    of range for the current sub-shape count" branch a real topology-shrink
    would also hit (see this prompt's status doc for why a genuine
    shrinking-boolean-op fixture wasn't used here - it isn't something that
    can be asserted about with confidence without a real OCCT environment to
    verify against, unlike a plain box's exact face/edge count)."""
    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.FACE, index=6)

    with pytest.raises(HTTPException) as exc_info:
        resolve_subshape(part, ref)

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {
        "type": "missing_reference",
        "body_id": boss["id"],
        "shape_type": "face",
        "index": 6,
    }


def test_resolve_subshape_raises_missing_reference_for_an_out_of_range_edge_index():
    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.EDGE, index=12)

    with pytest.raises(HTTPException) as exc_info:
        resolve_subshape(part, ref)

    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["index"] == 12


def test_resolve_subshape_rejects_a_negative_index():
    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    part = get_part_or_404(part_dict["id"])

    ref = SubShapeRef(body_id=boss["id"], shape_type=SubShapeType.FACE, index=-1)

    with pytest.raises(HTTPException) as exc_info:
        resolve_subshape(part, ref)

    assert exc_info.value.status_code == 422


# --- `produces` tag over the API --------------------------------------------


def test_sketch_feature_response_reports_produces_sketch():
    part = _create_part()
    feature = _create_sketch_feature(part["id"])

    assert feature["produces"] == "sketch"

    response = client.get(f"/document/parts/{part['id']}/features/{feature['id']}")
    assert response.json()["produces"] == "sketch"


def test_boss_and_cut_feature_responses_report_produces_body():
    part_dict = _create_part()
    boss = _boss_box(part_dict["id"])
    assert boss["produces"] == "body"

    cut_sketch = _create_square_sketch_feature(part_dict["id"], x0=2.0, y0=2.0, size=4.0)
    cut_response = _create_extrude_feature(
        part_dict["id"],
        cut_sketch["id"],
        extrude_type="cut",
        target_body_ids=[boss["id"]],
    )
    assert cut_response.status_code == 201
    assert cut_response.json()["produces"] == "body"


def test_list_features_reports_produces_for_every_feature():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    extrude_response = _create_extrude_feature(part["id"], sketch["id"])
    assert extrude_response.status_code == 201

    features = client.get(f"/document/parts/{part['id']}/features").json()
    by_id = {f["id"]: f for f in features}

    assert by_id[sketch["id"]]["produces"] == "sketch"
    assert by_id[extrude_response.json()["id"]]["produces"] == "body"
