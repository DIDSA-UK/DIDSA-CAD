import uuid

from fastapi import HTTPException

from app.sketch.models import Plane, Sketch

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


def delete_sketch(sketch_id: str) -> None:
    """Removes a Sketch from the store. Only intended to be called by
    app.document's cascade-delete, for a Sketch it has just confirmed is
    owned by a SketchFeature it is deleting - there is no other reference
    to a Sketch created via that flow, so no other caller should ever
    need this. Pops rather than 404ing on a missing id since cascade-delete
    is the sole caller and already knows the Sketch exists."""
    _sketches.pop(sketch_id, None)
