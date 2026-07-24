"""Native Save/Load: pure-Python round-trip tests for
`app.document.native_format` - construct a Document/Part/Feature tree plus a
Sketch directly (no OCCT, no HTTP), export it, put it through a real
`json.dumps`/`json.loads` cycle (this must genuinely be JSON, not just a
Python dict of arbitrary objects), import it back, and assert the result is
equivalent to the original. Has zero OCCT dependency - `native_format.py`
itself never imports pythonocc-core - so this runs for real in this sandbox,
unlike almost every other Feature-touching test in this suite.

`test_export_import_native_over_http` is the one exception: it goes through
the real FastAPI app (which does pull in OCCT at import time via other
routers), so it only runs for real in CI, mirroring every other TestClient-
based test here. It saves and restores the process-global Document/Sketch
store around itself, since a native import is a deliberate full replace and
this test suite otherwise shares that global state across every test
module in one pytest session.
"""

import json

from app.document.models import (
    ChamferFeature,
    CreatePlaneFeature,
    Document,
    ExtrudeFeature,
    ExtrudeType,
    FilletFeature,
    ImportFeature,
    ImportSourceFormat,
    MirrorFeature,
    Part,
    PlaneRef,
    PlaneType,
    PointRef,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
    SweepFeature,
    SweepMode,
)
from app.document.native_format import NativeFormatError, export_native, import_native
from app.sketch.models import Plane, Sketch, SketchEntityRef, SketchEntityType


def _line_ref(sketch_id: str, entity_id: str) -> SketchEntityRef:
    return SketchEntityRef(sketch_id=sketch_id, entity_type=SketchEntityType.LINE, entity_id=entity_id)


def _build_sketch() -> Sketch:
    """A Sketch exercising every entity/constraint kind - two Lines forming
    an L, a Circle, and one constraint of every type this codebase has."""
    sketch = Sketch(id="sketch-1", plane=Plane.XY)
    origin = sketch.origin_point()
    p1 = sketch.add_point(10.0, 0.0)
    p2 = sketch.add_point(10.0, 10.0)
    p3 = sketch.add_point(20.0, 10.0)
    line1 = sketch.add_line(origin.id, p1.id)
    line2 = sketch.add_line(p1.id, p2.id)
    line3 = sketch.add_line(p2.id, p3.id)
    circle = sketch.add_circle(origin.id, radius=5.0, angle=0.0)

    sketch.add_distance_constraint(origin.id, p1.id, 10.0)
    sketch.add_horizontal_constraint(line1.id)
    sketch.add_vertical_constraint(line2.id)
    sketch.add_angle_constraint(line1.id, line2.id, 90.0)
    sketch.add_coincident_constraint(p2.id, p3.id) if p2.id != p3.id else None
    sketch.add_parallel_constraint(line1.id, line3.id)
    sketch.add_perpendicular_constraint(line1.id, line2.id)
    sketch.add_equal_length_constraint(line2.id, line3.id)
    sketch.add_collinear_constraint(line1.id, line3.id)
    sketch.add_line_distance_constraint(line1.id, line3.id, 15.0)
    sketch.add_point_line_distance_constraint(p3.id, line1.id, 12.0)
    midpoint = sketch.add_point(15.0, 5.0)
    sketch.add_at_midpoint_constraint(midpoint.id, line2.id)

    # Keep the circle's own entity referenced so it round-trips too.
    assert circle.id in sketch.entities
    return sketch


def _build_document_with_every_feature_type(sketch: Sketch) -> Document:
    part = Part(id="part-1", name="Everything Part")

    sketch_feature = SketchFeature(id="feat-sketch", sketch_id=sketch.id)
    part.add_feature(sketch_feature)

    extrude = ExtrudeFeature(
        id="feat-extrude",
        sketch_feature_id=sketch_feature.id,
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=25.0,
        profile_refs=[_line_ref(sketch.id, next(iter(sketch.lines())).id)],
    )
    part.add_feature(extrude)

    plane_feature = CreatePlaneFeature(
        id="feat-plane",
        plane_type=PlaneType.MIDPLANE,
        face_refs=[
            PlaneRef(fixed_plane=Plane.XY),
            PlaneRef(face_ref=SubShapeRef(body_id=extrude.id, shape_type=SubShapeType.FACE, index=0)),
        ],
    )
    part.add_feature(plane_feature)

    fillet = FilletFeature(
        id="feat-fillet",
        edge_refs=[SubShapeRef(body_id=extrude.id, shape_type=SubShapeType.EDGE, index=0)],
        radius=1.5,
    )
    part.add_feature(fillet)

    chamfer = ChamferFeature(
        id="feat-chamfer",
        edge_refs=[SubShapeRef(body_id=extrude.id, shape_type=SubShapeType.EDGE, index=1)],
        distance=0.75,
    )
    part.add_feature(chamfer)

    lines = sketch.lines()
    revolve = RevolveFeature(
        id="feat-revolve",
        sketch_feature_id=sketch_feature.id,
        axis_ref=_line_ref(sketch.id, lines[0].id),
        angle=270.0,
        mode=RevolveMode.BOSS,
        target_body_ids=[extrude.id],
        profile_refs=[_line_ref(sketch.id, lines[1].id)],
    )
    part.add_feature(revolve)

    sweep = SweepFeature(
        id="feat-sweep",
        sketch_feature_id=sketch_feature.id,
        path_refs=[_line_ref(sketch.id, lines[0].id), _line_ref(sketch.id, lines[1].id)],
        mode=SweepMode.CUT,
        target_body_ids=[f"{extrude.id}#0"],
    )
    part.add_feature(sweep)

    mirror = MirrorFeature(
        id="feat-mirror",
        source_body_ids=[extrude.id],
        mirror_plane=PlaneRef(plane_feature_id=plane_feature.id),
    )
    part.add_feature(mirror)

    document = Document(id="doc-1")
    document.parts[part.id] = part
    return document


def _three_points_plane_feature(sketch: Sketch) -> CreatePlaneFeature:
    """Separately exercises THREE_POINTS' PointRef (both a sketch_point_ref
    and a vertex_ref variant), plus NORMAL_TO_LINE_AT_POINT's line_ref/
    point_ref pair - not part of the main "everything" tree above since a
    Part only makes sense with one CreatePlaneFeature per plane_type here."""
    lines = sketch.lines()
    line = lines[0]
    return CreatePlaneFeature(
        id="feat-plane-3pt",
        plane_type=PlaneType.THREE_POINTS,
        point_refs=[
            PointRef(sketch_point_ref=SketchEntityRef(
                sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=line.start_point_id
            )),
            PointRef(sketch_point_ref=SketchEntityRef(
                sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=line.end_point_id
            )),
            PointRef(vertex_ref=SubShapeRef(body_id="feat-extrude", shape_type=SubShapeType.VERTEX, index=0)),
        ],
    )


def test_round_trips_every_feature_type_through_real_json():
    sketch = _build_sketch()
    document = _build_document_with_every_feature_type(sketch)

    exported = export_native(document, {sketch.id: sketch})
    # Must be genuinely JSON-serializable, not just a plain Python dict of
    # arbitrary objects - round-trip through the real encoder/decoder.
    reloaded = json.loads(json.dumps(exported))

    assert reloaded["schema_version"] == 1

    imported_document, imported_sketches = import_native(reloaded)

    assert imported_document.id == document.id
    assert set(imported_document.parts.keys()) == {"part-1"}
    original_part = document.parts["part-1"]
    imported_part = imported_document.parts["part-1"]
    assert [f.id for f in imported_part.features] == [f.id for f in original_part.features]
    assert [f.type for f in imported_part.features] == [f.type for f in original_part.features]

    original_by_id = {f.id: f for f in original_part.features}
    imported_by_id = {f.id: f for f in imported_part.features}

    sketch_feature = imported_by_id["feat-sketch"]
    assert sketch_feature.sketch_id == sketch.id
    assert sketch_feature.plane_feature_id is None

    extrude = imported_by_id["feat-extrude"]
    original_extrude = original_by_id["feat-extrude"]
    assert extrude.extrude_type == original_extrude.extrude_type
    assert extrude.start_distance == original_extrude.start_distance
    assert extrude.end_distance == original_extrude.end_distance
    assert extrude.profile_refs == original_extrude.profile_refs

    plane_feature = imported_by_id["feat-plane"]
    original_plane_feature = original_by_id["feat-plane"]
    assert plane_feature.plane_type == PlaneType.MIDPLANE
    assert plane_feature.face_refs == original_plane_feature.face_refs

    fillet = imported_by_id["feat-fillet"]
    original_fillet = original_by_id["feat-fillet"]
    assert fillet.edge_refs == original_fillet.edge_refs
    assert fillet.radius == original_fillet.radius

    chamfer = imported_by_id["feat-chamfer"]
    original_chamfer = original_by_id["feat-chamfer"]
    assert chamfer.edge_refs == original_chamfer.edge_refs
    assert chamfer.distance == original_chamfer.distance

    revolve = imported_by_id["feat-revolve"]
    original_revolve = original_by_id["feat-revolve"]
    assert revolve.axis_ref == original_revolve.axis_ref
    assert revolve.angle == original_revolve.angle
    assert revolve.mode == original_revolve.mode
    assert revolve.target_body_ids == original_revolve.target_body_ids
    assert revolve.profile_refs == original_revolve.profile_refs

    sweep = imported_by_id["feat-sweep"]
    original_sweep = original_by_id["feat-sweep"]
    assert sweep.path_refs == original_sweep.path_refs
    assert sweep.mode == original_sweep.mode
    assert sweep.target_body_ids == original_sweep.target_body_ids

    mirror = imported_by_id["feat-mirror"]
    original_mirror = original_by_id["feat-mirror"]
    assert mirror.source_body_ids == original_mirror.source_body_ids
    assert mirror.mirror_plane == original_mirror.mirror_plane
    assert mirror.source_feature_ids == original_mirror.source_feature_ids

    assert set(imported_sketches.keys()) == {sketch.id}
    imported_sketch = imported_sketches[sketch.id]
    assert imported_sketch.plane == sketch.plane
    assert imported_sketch.origin_point_id == sketch.origin_point_id
    assert set(imported_sketch.points.keys()) == set(sketch.points.keys())
    for point_id, point in sketch.points.items():
        imported_point = imported_sketch.points[point_id]
        assert (imported_point.x, imported_point.y) == (point.x, point.y)
    assert set(imported_sketch.entities.keys()) == set(sketch.entities.keys())
    for entity_id, entity in sketch.entities.items():
        assert imported_sketch.entities[entity_id].type == entity.type
    assert set(imported_sketch.constraints.keys()) == set(sketch.constraints.keys())
    for constraint_id, constraint in sketch.constraints.items():
        imported_constraint = imported_sketch.constraints[constraint_id]
        assert imported_constraint.type == constraint.type
        assert imported_constraint.point_ids() == constraint.point_ids()


def test_three_points_and_normal_to_line_plane_features_round_trip():
    sketch = _build_sketch()
    part = Part(id="part-2", name="Plane Feature Part")
    sketch_feature = SketchFeature(id="feat-sketch", sketch_id=sketch.id)
    part.add_feature(sketch_feature)
    three_points = _three_points_plane_feature(sketch)
    part.add_feature(three_points)

    lines = sketch.lines()
    normal_to_line = CreatePlaneFeature(
        id="feat-plane-normal",
        plane_type=PlaneType.NORMAL_TO_LINE_AT_POINT,
        line_ref=_line_ref(sketch.id, lines[0].id),
        point_ref=SketchEntityRef(
            sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=lines[0].start_point_id
        ),
    )
    part.add_feature(normal_to_line)

    document = Document(id="doc-2")
    document.parts[part.id] = part

    exported = json.loads(json.dumps(export_native(document, {sketch.id: sketch})))
    imported_document, _ = import_native(exported)
    imported_part = imported_document.parts["part-2"]
    imported_by_id = {f.id: f for f in imported_part.features}

    reimported_three_points = imported_by_id["feat-plane-3pt"]
    assert reimported_three_points.plane_type == PlaneType.THREE_POINTS
    assert reimported_three_points.point_refs == three_points.point_refs

    reimported_normal = imported_by_id["feat-plane-normal"]
    assert reimported_normal.line_ref == normal_to_line.line_ref
    assert reimported_normal.point_ref == normal_to_line.point_ref


def test_sketch_feature_anchored_to_a_custom_plane_round_trips_plane_feature_id():
    sketch = Sketch(id="sketch-anchored", plane=None)
    sketch.origin_point()
    part = Part(id="part-3", name="Anchored Sketch Part")
    plane_feature = CreatePlaneFeature(
        id="feat-plane", plane_type=PlaneType.OFFSET_FACE, face_refs=[PlaneRef(fixed_plane=Plane.XY)], offset=3.0
    )
    part.add_feature(plane_feature)
    sketch_feature = SketchFeature(id="feat-sketch", sketch_id=sketch.id, plane_feature_id=plane_feature.id)
    part.add_feature(sketch_feature)

    document = Document(id="doc-3")
    document.parts[part.id] = part

    exported = json.loads(json.dumps(export_native(document, {sketch.id: sketch})))
    imported_document, imported_sketches = import_native(exported)
    imported_sketch_feature = imported_document.parts["part-3"].get_feature("feat-sketch")
    assert imported_sketch_feature.plane_feature_id == plane_feature.id
    assert imported_sketches[sketch.id].plane is None


def test_export_only_includes_sketches_actually_referenced_by_a_sketch_feature():
    sketch = _build_sketch()
    orphan_sketch = Sketch(id="orphan", plane=Plane.XY)
    document = _build_document_with_every_feature_type(sketch)

    exported = export_native(document, {sketch.id: sketch, orphan_sketch.id: orphan_sketch})
    exported_sketch_ids = {entry["id"] for entry in exported["sketches"]}
    assert exported_sketch_ids == {sketch.id}


def test_import_rejects_unsupported_schema_version():
    try:
        import_native({"schema_version": 999, "document": {"id": "d", "parts": []}})
        raise AssertionError("expected NativeFormatError")
    except NativeFormatError as exc:
        assert "schema_version" in str(exc)


def test_import_rejects_missing_document_key():
    try:
        import_native({"schema_version": 1})
        raise AssertionError("expected NativeFormatError")
    except NativeFormatError as exc:
        assert "document" in str(exc)


def test_import_rejects_unknown_feature_type():
    payload = {
        "schema_version": 1,
        "document": {"id": "d", "parts": [{"id": "p1", "name": "P", "features": [{"type": "not_a_real_type", "id": "f1"}]}]},
        "sketches": [],
    }
    try:
        import_native(payload)
        raise AssertionError("expected NativeFormatError")
    except NativeFormatError as exc:
        assert "not_a_real_type" in str(exc)


def test_import_rejects_unknown_constraint_type():
    payload = {
        "schema_version": 1,
        "document": {"id": "d", "parts": []},
        "sketches": [
            {
                "id": "sk1",
                "plane": "XY",
                "origin_point_id": None,
                "points": [],
                "entities": [],
                "constraints": [{"type": "not_a_real_constraint", "id": "c1"}],
            }
        ],
    }
    try:
        import_native(payload)
        raise AssertionError("expected NativeFormatError")
    except NativeFormatError as exc:
        assert "not_a_real_constraint" in str(exc)


def test_import_feature_round_trips_source_bytes_through_base64():
    part = Part(id="part-import", name="Import Part")
    raw_bytes = bytes(range(256)) * 4  # arbitrary binary content, not valid UTF-8
    feature = ImportFeature(id="feat-import", source_format=ImportSourceFormat.STEP, source_data=raw_bytes)
    part.add_feature(feature)

    document = Document(id="doc-import")
    document.parts[part.id] = part

    exported = json.loads(json.dumps(export_native(document, {})))
    imported_document, _ = import_native(exported)
    imported_feature = imported_document.parts["part-import"].get_feature("feat-import")

    assert imported_feature.source_format == ImportSourceFormat.STEP
    assert imported_feature.source_data == raw_bytes


def test_export_import_native_over_http():
    """End-to-end smoke test through the real FastAPI app - only meaningful
    with a real pythonocc-core available (CI), since `app.main` pulls in
    OCCT-dependent routers at import time. Saves and restores the process-
    global Document/Sketch store around itself: a native import is a
    deliberate full replace, and this test suite otherwise shares that
    global state across every test module within one pytest session."""
    from fastapi.testclient import TestClient

    from app.document.store import get_document, replace_document
    from app.main import app
    from app.sketch.store import all_sketches, replace_all_sketches
    from tests.conftest import TEST_API_KEY

    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part_response = client.post("/document/parts", json={"name": "HTTP Native Test"})
        assert part_response.status_code == 201
        part_id = part_response.json()["id"]

        sketch_feature_response = client.post(
            f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}
        )
        assert sketch_feature_response.status_code == 201
        sketch_id = sketch_feature_response.json()["sketch_id"]

        point_a = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0}).json()
        point_b = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 10.0, "y": 0.0}).json()
        line_response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": point_a["id"], "end_point_id": point_b["id"]},
        )
        assert line_response.status_code == 201

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        assert exported["schema_version"] == 1
        assert any(sketch["id"] == sketch_id for sketch in exported["sketches"])

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200
        # Not `== [part_id]`: the process-global Document this test suite
        # shares across every test module in one pytest session may already
        # hold Parts from earlier-run test files by this point - `exported`
        # (and thus what gets re-imported) legitimately contains all of
        # them, not just this test's own Part.
        assert part_id in import_response.json()["part_ids"]

        # The document/sketch stores were fully replaced with exactly what
        # was just re-imported - re-fetching the same part must still work.
        refetch_response = client.get(f"/document/parts/{part_id}")
        assert refetch_response.status_code == 200

        bad_import_response = client.post(
            "/document/import/native", json={"schema_version": 999, "document": {"id": "x", "parts": []}}
        )
        assert bad_import_response.status_code == 422
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
