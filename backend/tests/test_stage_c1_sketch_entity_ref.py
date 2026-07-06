"""C1: pure-Python tests for SketchEntityRef resolution (app.sketch.store.
resolve_sketch_entity) - Points/Lines/Circles are plain dataclasses with no
OCCT dependency at all, so unlike almost every backend Feature-resolver test
in this project, these run for real in this sandbox with no OCCT/pythonocc-
core environment needed.
"""

import pytest
from fastapi import HTTPException

from app.sketch.models import Plane, SketchEntityRef, SketchEntityType
from app.sketch.store import create_sketch, resolve_sketch_entity


def _sketch_with_a_line_and_circle():
    sketch = create_sketch(Plane.XY)
    start = sketch.add_point(0.0, 0.0)
    line = sketch.add_line(start.id, length=10.0, angle=0.0)
    circle = sketch.add_circle(start.id, radius=5.0, angle=0.0)
    return sketch, start, line, circle


def test_resolve_sketch_entity_resolves_a_real_point():
    sketch, start, _line, _circle = _sketch_with_a_line_and_circle()
    ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=start.id)
    assert resolve_sketch_entity(ref) is start


def test_resolve_sketch_entity_resolves_a_real_line():
    sketch, _start, line, _circle = _sketch_with_a_line_and_circle()
    ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=line.id)
    assert resolve_sketch_entity(ref) is line


def test_resolve_sketch_entity_resolves_a_real_circle():
    sketch, _start, _line, circle = _sketch_with_a_line_and_circle()
    ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.CIRCLE, entity_id=circle.id)
    assert resolve_sketch_entity(ref) is circle


def test_resolve_sketch_entity_raises_missing_reference_for_an_unknown_sketch_id():
    ref = SketchEntityRef(sketch_id="no-such-sketch", entity_type=SketchEntityType.POINT, entity_id="p1")
    with pytest.raises(HTTPException) as exc_info:
        resolve_sketch_entity(ref)
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail == {
        "type": "missing_reference",
        "sketch_id": "no-such-sketch",
        "entity_type": "point",
        "entity_id": "p1",
    }


def test_resolve_sketch_entity_raises_missing_reference_for_an_unknown_entity_id():
    sketch, _start, _line, _circle = _sketch_with_a_line_and_circle()
    ref = SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id="no-such-line")
    with pytest.raises(HTTPException) as exc_info:
        resolve_sketch_entity(ref)
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "missing_reference"


def test_resolve_sketch_entity_raises_missing_reference_for_a_type_mismatch():
    """Asking for a LINE at a Point's own id (or vice versa) must fail
    closed rather than returning the wrong entity - the one behavior that
    has no SubShapeRef analog, since a SubShapeRef's index is always
    re-derived per shape_type rather than looked up in a shared id space."""
    sketch, start, line, circle = _sketch_with_a_line_and_circle()

    with pytest.raises(HTTPException) as exc_info:
        resolve_sketch_entity(
            SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.LINE, entity_id=start.id)
        )
    assert exc_info.value.detail["type"] == "missing_reference"

    with pytest.raises(HTTPException) as exc_info:
        resolve_sketch_entity(
            SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.CIRCLE, entity_id=line.id)
        )
    assert exc_info.value.detail["type"] == "missing_reference"

    with pytest.raises(HTTPException) as exc_info:
        resolve_sketch_entity(
            SketchEntityRef(sketch_id=sketch.id, entity_type=SketchEntityType.POINT, entity_id=circle.id)
        )
    assert exc_info.value.detail["type"] == "missing_reference"
