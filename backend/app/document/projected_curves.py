"""Convert Entities, real projection (bug report 2026-11-18, plan part C; docs/bug-report-2026-11-18-plan.md): turning a `ProjectedEntity`
(`app.sketch.projection`) into real Sketch entities, and moving those entities again when their source has moved.

A projected copy is pinned: every Point of it that is not a live vertex reference is covered by a FixedConstraint where it was put, and the shape's own
holding constraints (radius, axis, on-ellipse, spline tangency) are dropped, as for the converted Circle / Arc / Ellipse before (each would only relate
pinned Points, which py-slvs reports as redundant). Following the source is `apply_projection`: it writes the newly projected positions into the same
Points (the Fix pins a Point where it is, so the next solve keeps it there). `app.document.create_plane.refresh_external_references` calls it for every
`Sketch.external_curves` entry."""

from __future__ import annotations

import math

from app.sketch.models import Arc, Circle, Ellipse, EllipseArc, Line, Spline, Sketch
from app.sketch.projection import ProjectedEntity, Vec2

# Two positions closer than this (mm) are the same Point: the ends a copy shares with a vertex reference or with another copy made by the same convert.
POINT_MATCH = 1e-6


class PointPool:
    """The Points one convert call may reuse, found by position: the live vertex-reference ends of a body edge, and the Points earlier copies of the same
    call made (so a converted chain stays connected, as its source was). New Points join the pool."""

    def __init__(self, sketch: Sketch, point_ids: list[str] | tuple[str, ...] = ()):
        self.sketch = sketch
        self.point_ids: list[str] = [pid for pid in point_ids if pid in sketch.points]

    def find(self, xy: Vec2) -> str | None:
        for pid in self.point_ids:
            p = self.sketch.points.get(pid)
            if p is not None and math.hypot(p.x - xy[0], p.y - xy[1]) <= POINT_MATCH:
                return pid
        return None

    def get(self, xy: Vec2) -> str:
        found = self.find(xy)
        if found is not None:
            return found
        point = self.sketch.add_point(xy[0], xy[1])
        self.point_ids.append(point.id)
        return point.id


def _fix(sketch: Sketch, item_id: str) -> None:
    try:
        sketch.add_fixed_constraint(item_id)
    except ValueError:
        pass  # every Point of it is already pinned (a vertex reference, or fixed by a copy it shares a Point with)


def _drop(sketch: Sketch, constraint_ids) -> None:
    for constraint_id in constraint_ids:
        sketch.constraints.pop(constraint_id, None)


def _axes(rotation: float) -> tuple[Vec2, Vec2]:
    e1 = (math.cos(rotation), math.sin(rotation))
    return e1, (-e1[1], e1[0])


def _at(centre: Vec2, direction: Vec2, distance: float) -> Vec2:
    return (centre[0] + direction[0] * distance, centre[1] + direction[1] * distance)


def make_projected_entity(sketch: Sketch, projected: ProjectedEntity, *, construction: bool, pool: PointPool) -> str:
    """Makes the pinned Sketch entity `projected` describes and returns its id (a projected Point: the Point's id). Ends are taken from `pool` where one is
    already at that position."""
    kind = projected.kind
    if kind == "point":
        point_id = pool.get(projected.start)
        _fix(sketch, point_id)
        return point_id
    if kind == "line":
        start_id, end_id = pool.get(projected.start), pool.get(projected.end)
        line = next((l for l in sketch.lines() if {l.start_point_id, l.end_point_id} == {start_id, end_id}), None)
        if line is None:
            line = sketch.add_line(start_id, end_id, construction=construction)
        _fix(sketch, line.id)
        return line.id
    if kind == "circle":
        centre_id = pool.get(projected.centre)
        circle = sketch.add_circle(centre_id, radius=projected.radius, construction=construction)
        _fix(sketch, circle.id)
        _drop(sketch, [circle.radius_constraint_id, *circle.cardinal_constraint_ids])
        return circle.id
    if kind == "arc":
        centre_id = pool.get(projected.centre)
        start_id, end_id = pool.get(projected.start), pool.get(projected.end)
        arc = sketch.add_arc(centre_id, start_id, end_id, construction=construction)
        _fix(sketch, arc.id)
        _drop(sketch, [arc.radius_constraint_id, arc.end_radius_constraint_id])
        return arc.id
    if kind == "ellipse":
        centre_id = pool.get(projected.centre)
        ellipse = sketch.add_ellipse(
            centre_id, major_radius=projected.major_radius, angle=projected.rotation, minor_radius=projected.minor_radius, construction=construction
        )
        _fix(sketch, ellipse.id)
        _drop(
            sketch,
            [ellipse.major_constraint_id, ellipse.minor_constraint_id, ellipse.major_midpoint_constraint_id, ellipse.minor_midpoint_constraint_id, ellipse.perpendicular_constraint_id],
        )
        return ellipse.id
    if kind == "ellipse_arc":
        centre_id = pool.get(projected.centre)
        e1, _ = _axes(projected.rotation)
        major_id = sketch.add_point(*_at(projected.centre, e1, projected.major_radius)).id
        arc = sketch.add_ellipse_arc(
            centre_id,
            major_id,
            projected.minor_radius,
            projected.start_angle,
            projected.end_angle,
            construction=construction,
            existing_start_point_id=pool.get(projected.start),
            existing_end_point_id=pool.get(projected.end),
        )
        _fix(sketch, arc.id)
        _drop(
            sketch,
            [arc.major_constraint_id, arc.minor_constraint_id, arc.perpendicular_constraint_id, arc.start_on_ellipse_constraint_id, arc.end_on_ellipse_constraint_id],
        )
        return arc.id
    if kind == "spline":
        through_ids = [pool.get(projected.through[0])]
        through_ids += [sketch.add_point(*xy).id for xy in projected.through[1:-1]]
        through_ids.append(pool.get(projected.through[-1]))
        spline = sketch.add_spline(through_ids, construction=construction)
        for point_id, xy in zip(spline.control_point_ids, projected.controls):
            sketch.points[point_id].x, sketch.points[point_id].y = xy
        _fix(sketch, spline.id)
        _drop(sketch, spline.tangent_constraint_ids)
        return spline.id
    raise ValueError(f"unknown projected kind {kind!r}")


def made_kind(sketch: Sketch, made_id: str) -> str | None:
    """The projection kind of what `made_id` names in `sketch` now (None if it is gone)."""
    if made_id in sketch.points and made_id not in sketch.entities:
        return "point"
    entity = sketch.entities.get(made_id)
    return None if entity is None else entity.type


def copy_point_ids(sketch: Sketch, made_id: str) -> list[str]:
    """Every Point of the copy `made_id` (the Point itself for a projected Point)."""
    if made_id in sketch.points and made_id not in sketch.entities:
        return [made_id]
    entity = sketch.entities.get(made_id)
    if entity is None:
        return []
    return [pid for pid in dict.fromkeys(sketch._entity_defining_point_ids(entity)) if pid in sketch.points]


def apply_projection(sketch: Sketch, made_id: str, projected: ProjectedEntity) -> bool:
    """Moves the copy `made_id` onto `projected` (its source, projected again). Points that are live vertex references are left to their own refresh. False
    (nothing moved) when the copy cannot take that shape: another kind, or a Spline with another number of points."""
    if made_kind(sketch, made_id) != projected.kind:
        return False
    moves: dict[str, Vec2] = {}
    kind = projected.kind
    if kind == "point":
        moves[made_id] = projected.start
    elif kind == "line":
        line = sketch.entities[made_id]
        assert isinstance(line, Line)
        moves[line.start_point_id], moves[line.end_point_id] = projected.start, projected.end
    elif kind == "circle":
        circle = sketch.entities[made_id]
        assert isinstance(circle, Circle)
        centre, radius = projected.centre, projected.radius
        old_c, old_r = sketch.points[circle.center_point_id], sketch.points[circle.radius_point_id]
        angle = math.atan2(old_r.y - old_c.y, old_r.x - old_c.x)
        moves[circle.center_point_id] = centre
        north, east, south, west = circle.cardinal_point_ids
        moves[north], moves[east] = (centre[0], centre[1] + radius), (centre[0] + radius, centre[1])
        moves[south], moves[west] = (centre[0], centre[1] - radius), (centre[0] - radius, centre[1])
        moves.setdefault(circle.radius_point_id, (centre[0] + radius * math.cos(angle), centre[1] + radius * math.sin(angle)))
    elif kind == "arc":
        arc = sketch.entities[made_id]
        assert isinstance(arc, Arc)
        moves[arc.center_point_id], moves[arc.start_point_id], moves[arc.end_point_id] = projected.centre, projected.start, projected.end
    elif kind == "ellipse":
        ellipse = sketch.entities[made_id]
        assert isinstance(ellipse, Ellipse)
        e1, e2 = _axes(projected.rotation)
        c, a, b = projected.centre, projected.major_radius, projected.minor_radius
        moves[ellipse.center_point_id] = c
        moves[ellipse.major_point_id], moves[ellipse.major_point_neg_id] = _at(c, e1, a), _at(c, e1, -a)
        moves[ellipse.minor_point_id], moves[ellipse.minor_point_neg_id] = _at(c, e2, b), _at(c, e2, -b)
    elif kind == "ellipse_arc":
        arc = sketch.entities[made_id]
        assert isinstance(arc, EllipseArc)
        e1, e2 = _axes(projected.rotation)
        c = projected.centre
        moves[arc.center_point_id] = c
        moves[arc.major_point_id], moves[arc.minor_point_id] = _at(c, e1, projected.major_radius), _at(c, e2, projected.minor_radius)
        moves[arc.start_point_id], moves[arc.end_point_id] = projected.start, projected.end
    elif kind == "spline":
        spline = sketch.entities[made_id]
        assert isinstance(spline, Spline)
        if len(spline.through_point_ids) != len(projected.through) or len(spline.control_point_ids) != len(projected.controls):
            return False
        moves.update(zip(spline.through_point_ids, projected.through))
        moves.update(zip(spline.control_point_ids, projected.controls))
    for point_id, (x, y) in moves.items():
        if point_id in sketch.external_references or point_id not in sketch.points:
            continue
        point = sketch.points[point_id]
        point.x, point.y = x, y
    return True
