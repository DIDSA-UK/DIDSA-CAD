import uuid

from fastapi import HTTPException

from app.sketch.models import Circle, Line, Point, Plane, Sketch, SketchEntityRef, SketchEntityType

# Temporary in-memory store, Stage 2 only - see the note in router.py. Pulled
# out of router.py in Stage 7 so other modules (the Document/Part/Feature
# model in app.document) can create and look up Sketches without reaching
# into router internals.
_sketches: dict[str, Sketch] = {}


def create_sketch(plane: Plane) -> Sketch:
    sketch = Sketch(id=str(uuid.uuid4()), plane=plane)
    _sketches[sketch.id] = sketch
    return sketch


def get_sketch_or_404(sketch_id: str) -> Sketch:
    sketch = _sketches.get(sketch_id)
    if sketch is None:
        raise HTTPException(status_code=404, detail="Sketch not found")
    return sketch


def _missing_sketch_entity_reference(ref: SketchEntityRef) -> HTTPException:
    """C1: the structured `missing_reference` validation error `resolve_
    sketch_entity` raises whenever `ref` cannot be resolved - same envelope
    as `app.document.extrude._missing_reference` (a plain `HTTPException`
    with a structured `detail` dict, 422), just with this ref's own fields."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "missing_reference",
            "sketch_id": ref.sketch_id,
            "entity_type": ref.entity_type.value,
            "entity_id": ref.entity_id,
        },
    )


def resolve_sketch_entity(ref: SketchEntityRef) -> Point | Line | Circle:
    """C1: resolves `ref` against the current store - a direct dict lookup
    (`Sketch.points` for POINT, `Sketch.entities` for LINE/CIRCLE, with an
    `isinstance` check so asking for a LINE at a Point/Circle's own id fails
    closed rather than returning the wrong type), unlike `resolve_subshape`'s
    OCCT re-derivation. Fails closed with the structured `missing_reference`
    error above for an unknown `sketch_id`, an unknown `entity_id`, or an
    `entity_id` that exists but is the wrong `entity_type`."""
    sketch = _sketches.get(ref.sketch_id)
    if sketch is None:
        raise _missing_sketch_entity_reference(ref)

    if ref.entity_type == SketchEntityType.POINT:
        point = sketch.points.get(ref.entity_id)
        if point is not None:
            return point
    else:
        entity = sketch.entities.get(ref.entity_id)
        expected_type = Line if ref.entity_type == SketchEntityType.LINE else Circle
        if isinstance(entity, expected_type):
            return entity

    raise _missing_sketch_entity_reference(ref)


def delete_sketch(sketch_id: str) -> None:
    """Removes a Sketch from the store. Only intended to be called by
    app.document's cascade-delete, for a Sketch it has just confirmed is
    owned by a SketchFeature it is deleting - there is no other reference
    to a Sketch created via that flow, so no other caller should ever
    need this. Pops rather than 404ing on a missing id since cascade-delete
    is the sole caller and already knows the Sketch exists."""
    _sketches.pop(sketch_id, None)
