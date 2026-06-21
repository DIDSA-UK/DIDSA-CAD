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
