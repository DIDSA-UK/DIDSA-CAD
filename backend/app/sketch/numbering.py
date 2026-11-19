"""Parity follow-ups F4 / A1: the number every sketch entity, dimension and relation carries, and the name built from it.

The backend is the one place both apps (and a live session's observers) share, so it is where a name lives. Each new thing gets the next number of its
kind in its sketch (`Line 3`, `Point 12`, `Circle 2`, ...), the number is stored with the sketch and **never reused**: delete Line 2 and Line 3 stays Line 3,
a new line is Line 4. Dimensions (and reference dimensions) share one counter (`D4`, `(D5)`); relations are numbered per type (`Coincident 2`); a Point that
tracks the part is `Part corner 2` / `Hole centre 1`; the sketch's own origin Point is `Origin` and has no number.

Where the numbers live: two small maps on the `Sketch` (`numbers`: id -> number, `number_counters`: kind -> the highest number given), not a field on every
entity class, so the dozens of places that build entities need no change. `ensure_numbers` gives a number to everything that has none, in the stored
(insertion) order, which is the creation order: so a sketch made before numbers existed gets them on first use in the order the flat app already counted
by, and a new thing is numbered by the response that first shows it. `set_number` lets a create route restore an old number (an undo that re-creates).
"""

import dataclasses
import threading

# Lazily numbering from two requests at once would hand out one number twice; the lock is module-wide (a sketch is edited by one client at a time, the
# lock only has to make the two-readers case safe).
_LOCK = threading.RLock()

_ENTITY_LABELS = {
    "line": "Line",
    "circle": "Circle",
    "arc": "Arc",
    "ellipse": "Ellipse",
    "ellipse_arc": "Ellipse Arc",
    "polygon": "Polygon",
    "slot": "Slot",
    "rectangle": "Rectangle",
    "spline": "Spline",
    "text": "Text",
}

# Constraint types that are dimensions: they carry a value and share the one `D` counter.
DIMENSION_CONSTRAINT_TYPES = frozenset(
    {
        "distance",
        "angle",
        "line_distance",
        "point_line_distance",
        "arc_length",
        "horizontal_angle",
        "point_angle",
        "point_circle_distance",
        "circle_distance",
        "line_circle_distance",
    }
)

_RELATION_LABELS = {
    "horizontal": "Horizontal",
    "vertical": "Vertical",
    "coincident": "Coincident",
    "parallel": "Parallel",
    "perpendicular": "Perpendicular",
    "equal_length": "Equal length",
    "tangent": "Tangent",
    "curve_tangent": "Curve tangent",
    "equal_radius": "Equal radius",
    "concentric": "Concentric",
    "collinear": "Collinear",
    "at_midpoint": "Midpoint",
    "spline_tangent": "Spline tangent",
    "point_on_line": "Point on line",
    "point_on_circle": "Point on circle",
    "point_on_ellipse": "Point on ellipse",
    "fixed": "Fixed",
}

_REFERENCE_POINT_LABELS = {"vertex": ("part_corner", "Part corner"), "circle_centre": ("hole_centre", "Hole centre")}

# The entity fields that record a constraint id and hold the shape's own *size* dimension (a circle's radius, an ellipse's axes): the user sees and edits
# those, so they are dimensions like any other. Every other constraint an entity records on itself is glue that makes the shape what it is (a circle's
# cardinal points, a slot's tangents, a rectangle's horizontals) and takes no number: the user never selects or names it.
_SIZE_CONSTRAINT_FIELDS = frozenset({"radius_constraint_id", "end_radius_constraint_id", "major_constraint_id", "minor_constraint_id"})

DIMENSION_KEY = "dimension"
REFERENCE_DIMENSION_PREFIX = "("


def _structural_constraint_ids(sketch) -> set[str]:
    """Ids of the constraints the entities record on themselves as glue (not as a size dimension): see `_SIZE_CONSTRAINT_FIELDS`."""
    ids: set[str] = set()
    for entity in sketch.entities.values():
        for field in dataclasses.fields(entity):
            if field.name in _SIZE_CONSTRAINT_FIELDS:
                continue
            value = getattr(entity, field.name)
            if field.name.endswith("_constraint_id") and isinstance(value, str) and value:
                ids.add(value)
            elif field.name.endswith("_constraint_ids") and isinstance(value, list):
                ids.update(item for item in value if isinstance(item, str) and item)
    return ids


def _walk(sketch):
    """`(id, counter key, label)` for everything that is numbered, in stored order: points, entities, constraints, reference dimensions."""
    origin_id = sketch.origin_point_id
    structural = _structural_constraint_ids(sketch)
    for point_id in sketch.points:
        if point_id == origin_id:
            continue
        reference = sketch.external_references.get(point_id)
        if reference is not None:
            key, label = _REFERENCE_POINT_LABELS.get(reference.kind, ("part_corner", "Part corner"))
            yield point_id, key, label
        else:
            yield point_id, "point", "Point"
    for entity_id, entity in sketch.entities.items():
        yield entity_id, entity.type, _ENTITY_LABELS.get(entity.type, entity.type.replace("_", " ").capitalize())
    for constraint_id, constraint in sketch.constraints.items():
        if constraint_id in structural:
            continue  # shape glue (see `_SIZE_CONSTRAINT_FIELDS`): never named
        if getattr(constraint, "provisional", False):
            continue  # a shape tool's placeholder size: it is not a dimension the user sees, so it takes no `D` number until it is confirmed
        if constraint.type in DIMENSION_CONSTRAINT_TYPES:
            yield constraint_id, DIMENSION_KEY, "D"
        else:
            yield constraint_id, constraint.type, _RELATION_LABELS.get(constraint.type, constraint.type.replace("_", " ").capitalize())
    for dimension_id in sketch.reference_dimensions:
        yield dimension_id, DIMENSION_KEY, "(D"


def ensure_numbers(sketch) -> None:
    """Gives every unnumbered point / entity / constraint / reference dimension the next number of its kind, in stored order, and forgets numbers of things
    that are gone (the counters stay, so a number is never reused). Idempotent."""
    with _LOCK:
        items = list(_walk(sketch))
        numbers = sketch.numbers
        counters = sketch.number_counters
        # A file that carries numbers but not counters (or counters that fell behind): never hand out a number a live item already has.
        for item_id, key, _label in items:
            number = numbers.get(item_id)
            if number is not None and number > counters.get(key, 0):
                counters[key] = number
        live = set()
        for item_id, key, _label in items:
            live.add(item_id)
            if item_id not in numbers:
                counters[key] = counters.get(key, 0) + 1
                numbers[item_id] = counters[key]
        for stale in [item_id for item_id in numbers if item_id not in live]:
            del numbers[stale]


def number_of(sketch, item_id: str) -> int | None:
    """The number of `item_id`, assigning numbers first when it has none yet. None for the origin Point and for ids that are not in the sketch."""
    number = sketch.numbers.get(item_id)
    if number is not None:
        return number
    ensure_numbers(sketch)
    return sketch.numbers.get(item_id)


def name_of(sketch, item_id: str) -> str | None:
    """`Line 3`, `D4`, `(D5)`, `Coincident 2`, `Part corner 2`, `Origin`; None when `item_id` is not in the sketch."""
    if item_id == sketch.origin_point_id:
        return "Origin"
    number = number_of(sketch, item_id)
    if number is None:
        return None
    for found_id, _key, label in _walk(sketch):
        if found_id == item_id:
            if label == "D":
                return f"D{number}"
            if label == "(D":
                return f"(D{number})"
            return f"{label} {number}"
    return None


def describe(sketch, item_id: str, fallback: str = "that item") -> str:
    """`name_of`, or `fallback` for an id the sketch does not have: what an error text puts where it used to put the id."""
    return name_of(sketch, item_id) or fallback


def set_number(sketch, item_id: str, number: int) -> bool:
    """Restores an earlier number on `item_id` (an undo that re-creates a deleted thing passes the number it had). Refused (False) when another live item of
    the same kind already has that number or `number` is not positive: the item keeps the number it was given. Never lowers a counter below a number in use;
    when `item_id` had just been given the highest number, that number is handed back so an undo does not leave a gap."""
    if number < 1 or item_id == sketch.origin_point_id:
        return False
    with _LOCK:
        ensure_numbers(sketch)
        key = next((k for found_id, k, _label in _walk(sketch) if found_id == item_id), None)
        if key is None:
            return False
        current = sketch.numbers.get(item_id)
        for found_id, k, _label in _walk(sketch):
            if found_id != item_id and k == key and sketch.numbers.get(found_id) == number:
                return False
        if current == number:
            return True
        if current is not None and current == sketch.number_counters.get(key, 0):
            sketch.number_counters[key] = current - 1
        sketch.numbers[item_id] = number
        if number > sketch.number_counters.get(key, 0):
            sketch.number_counters[key] = number
        return True
