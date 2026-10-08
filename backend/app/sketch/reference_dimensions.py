"""DIDSA-VR plan, phase 3: what a `ReferenceDimension` measures (see `app.sketch.models.ReferenceDimension`). Pure geometry over a Sketch's current Point positions;
nothing here touches the solver, so a reference dimension can never move or over-constrain a sketch."""

from __future__ import annotations

import math
import uuid

from app.sketch.models import REFERENCE_DIMENSION_KINDS, Arc, Circle, Line, ReferenceDimension, Sketch

_ENTITY_TYPES = ("point", "line", "circle", "arc")


class ReferenceDimensionError(ValueError):
    """The kind and the entities do not make a dimension (a reason in words), or something it names is not in the Sketch."""


def _point(sketch: Sketch, point_id: str):
    point = sketch.points.get(point_id)
    if point is None:
        raise ReferenceDimensionError(f"Point not found: {point_id}")
    return point


def _line(sketch: Sketch, line_id: str) -> Line:
    line = sketch.entities.get(line_id)
    if not isinstance(line, Line):
        raise ReferenceDimensionError(f"Line not found: {line_id}")
    return line


def _round(sketch: Sketch, kind: str, entity_id: str):
    shape = sketch.entities.get(entity_id)
    if kind == "circle" and isinstance(shape, Circle):
        return shape
    if kind == "arc" and isinstance(shape, Arc):
        return shape
    raise ReferenceDimensionError(f"{kind.capitalize()} not found: {entity_id}")


def _ends(sketch: Sketch, line: Line):
    return _point(sketch, line.start_point_id), _point(sketch, line.end_point_id)


def check_refs(sketch: Sketch, kind: str, refs: list[tuple[str, str]]) -> None:
    """Raises `ReferenceDimensionError` unless `kind` with `refs` is something that can be measured in `sketch`."""
    if kind not in REFERENCE_DIMENSION_KINDS:
        raise ReferenceDimensionError(f"Unknown kind {kind!r}; one of {', '.join(REFERENCE_DIMENSION_KINDS)}")
    for entity_type, _ in refs:
        if entity_type not in _ENTITY_TYPES:
            raise ReferenceDimensionError(f"Unknown entity type {entity_type!r}")
    types = [t for t, _ in refs]
    allowed = {
        "distance": [["point", "point"], ["point", "line"], ["line", "point"], ["line"], ["line", "line"]],
        "horizontal": [["point", "point"], ["line"]],
        "vertical": [["point", "point"], ["line"]],
        "radius": [["circle"], ["arc"]],
        "diameter": [["circle"], ["arc"]],
        "angle": [["line", "line"]],
    }[kind]
    if types not in allowed:
        raise ReferenceDimensionError(f"A {kind} dimension measures {' or '.join(' + '.join(a) for a in allowed)}, not {' + '.join(types) or 'nothing'}")
    value = measure(sketch, kind, refs)
    if value is None:
        raise ReferenceDimensionError("Those two lines are not parallel, so there is no distance between them")


def measure(sketch: Sketch, kind: str, refs: list[tuple[str, str]]) -> float | None:
    """The current value, or None when the geometry has no such value (two lines that are not parallel have no distance between them). Raises
    `ReferenceDimensionError` for something missing."""
    types = [t for t, _ in refs]
    ids = [i for _, i in refs]
    if kind in ("radius", "diameter"):
        shape = _round(sketch, types[0], ids[0])
        far = shape.radius_point_id if isinstance(shape, Circle) else shape.start_point_id
        radius = math.dist((_point(sketch, shape.center_point_id).x, _point(sketch, shape.center_point_id).y), (_point(sketch, far).x, _point(sketch, far).y))
        return radius if kind == "radius" else 2.0 * radius
    if kind == "angle":
        a1, b1 = _ends(sketch, _line(sketch, ids[0]))
        a2, b2 = _ends(sketch, _line(sketch, ids[1]))
        d1, d2 = (b1.x - a1.x, b1.y - a1.y), (b2.x - a2.x, b2.y - a2.y)
        n1, n2 = math.hypot(*d1), math.hypot(*d2)
        if n1 < 1e-12 or n2 < 1e-12:
            return None
        cosine = max(-1.0, min(1.0, (d1[0] * d2[0] + d1[1] * d2[1]) / (n1 * n2)))
        return math.degrees(math.acos(cosine))
    if types == ["line"]:
        start, end = _ends(sketch, _line(sketch, ids[0]))
        dx, dy = end.x - start.x, end.y - start.y
        return {"distance": math.hypot(dx, dy), "horizontal": abs(dx), "vertical": abs(dy)}[kind]
    if types == ["point", "point"]:
        a, b = _point(sketch, ids[0]), _point(sketch, ids[1])
        return {"distance": math.dist((a.x, a.y), (b.x, b.y)), "horizontal": abs(b.x - a.x), "vertical": abs(b.y - a.y)}[kind]
    if types in (["point", "line"], ["line", "point"]):
        point = _point(sketch, ids[types.index("point")])
        start, end = _ends(sketch, _line(sketch, ids[types.index("line")]))
        dx, dy = end.x - start.x, end.y - start.y
        length = math.hypot(dx, dy)
        if length < 1e-12:
            return math.dist((point.x, point.y), (start.x, start.y))
        return abs((point.x - start.x) * dy - (point.y - start.y) * dx) / length
    if types == ["line", "line"]:
        a1, b1 = _ends(sketch, _line(sketch, ids[0]))
        a2, b2 = _ends(sketch, _line(sketch, ids[1]))
        d1 = (b1.x - a1.x, b1.y - a1.y)
        d2 = (b2.x - a2.x, b2.y - a2.y)
        n1, n2 = math.hypot(*d1), math.hypot(*d2)
        if n1 < 1e-12 or n2 < 1e-12 or abs(d1[0] * d2[1] - d1[1] * d2[0]) / (n1 * n2) > 1e-3:
            return None
        return abs((a2.x - a1.x) * d1[1] - (a2.y - a1.y) * d1[0]) / n1
    raise ReferenceDimensionError("Nothing to measure")


def add(sketch: Sketch, kind: str, refs: list[tuple[str, str]]) -> ReferenceDimension:
    """Adds a reference dimension; an identical one (same kind, same entities) is returned instead of making a second."""
    check_refs(sketch, kind, refs)
    wanted = tuple(refs)
    for existing in sketch.reference_dimensions.values():
        if existing.kind == kind and existing.refs == wanted:
            return existing
    dimension = ReferenceDimension(id=str(uuid.uuid4()), kind=kind, refs=wanted)
    sketch.reference_dimensions[dimension.id] = dimension
    return dimension


def replace(sketch: Sketch, dimension_id: str, kind: str | None, refs: list[tuple[str, str]] | None) -> ReferenceDimension:
    existing = sketch.reference_dimensions[dimension_id]
    new_kind = kind if kind is not None else existing.kind
    new_refs = list(refs) if refs is not None else list(existing.refs)
    check_refs(sketch, new_kind, new_refs)
    updated = ReferenceDimension(id=existing.id, kind=new_kind, refs=tuple(new_refs))
    sketch.reference_dimensions[dimension_id] = updated
    return updated


def valid(sketch: Sketch, dimension: ReferenceDimension) -> bool:
    """False when something the dimension measures is no longer in the Sketch (it was deleted): such a dimension is dropped (`drop_dangling`)."""
    try:
        measure(sketch, dimension.kind, list(dimension.refs))
    except ReferenceDimensionError:
        return False
    return True


def drop_dangling(sketch: Sketch) -> list[str]:
    """Removes the dimensions that measure something no longer in the Sketch; returns their ids."""
    gone = [i for i, d in sketch.reference_dimensions.items() if not valid(sketch, d)]
    for dimension_id in gone:
        del sketch.reference_dimensions[dimension_id]
    return gone


def used_ids(sketch: Sketch) -> set[str]:
    """Every entity id (and the Points those entities stand on) that a reference dimension measures: a reference helper such a dimension depends on must stay."""
    ids: set[str] = set()
    for dimension in sketch.reference_dimensions.values():
        for entity_type, entity_id in dimension.refs:
            ids.add(entity_id)
            entity = sketch.entities.get(entity_id)
            if entity is not None:
                ids.update(sketch._entity_defining_point_ids(entity))
    return ids
