"""Shared helpers for the part D dimension-type tests (bug report 2026-11-18): a sketch with an origin, the HTTP client, a file round trip,
and the delete-cascade / point-merge checks every new type gets."""

from __future__ import annotations

import json
import uuid

from fastapi.testclient import TestClient

from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.main import app
from app.sketch.models import Plane, Sketch
from app.sketch.store import all_sketches
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def new_sketch() -> Sketch:
    sketch = Sketch(id=str(uuid.uuid4()), plane=Plane.XY)
    sketch.origin_point()
    return sketch


def http_sketch() -> tuple[str, Sketch]:
    """A sketch made through the API (so the routes can reach it) and the live object behind it."""
    response = client.post("/sketch/sketches", json={"plane": "XY"})
    assert response.status_code == 201, response.text
    sketch_id = response.json()["id"]
    return sketch_id, all_sketches()[sketch_id]


def round_trip(sketch: Sketch) -> Sketch:
    """Through the saved-file shape and back (as JSON text, so nothing survives that a file would not carry)."""
    return sketch_from_dict(json.loads(json.dumps(sketch_to_dict(sketch))))


def blockers(sketch: Sketch, point_ids) -> dict[str, str | None]:
    """What stops each Point from being deleted (None: nothing)."""
    return {point_id: sketch._point_deletion_blocker(point_id) for point_id in point_ids}


def fixed_circle(sketch: Sketch, x: float = 0.0, y: float = 0.0, radius: float = 5.0):
    """A Circle about (x, y) with a confirmed radius and its centre fixed: only what a test adds can move."""
    center = sketch.add_point(x, y)
    circle = sketch.add_circle(center.id, radius=radius, angle=0.0)
    sketch.constraints[circle.radius_constraint_id].provisional = False
    sketch.constraints[circle.radius_constraint_id].distance = radius
    sketch.add_fixed_constraint(center.id)
    return circle
