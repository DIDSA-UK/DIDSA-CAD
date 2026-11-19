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


# --- sketch sources (plan part C2) -----------------------------------------------------------------------------------------

# Entity types a Sketch draws as one curve each. Polygon / Slot / Rectangle are groups of these (their own Lines / Arcs are entities too, converted one
# by one); Text is outlines from a font, not sketch geometry, so it is skipped with a note.
CURVE_ENTITY_TYPES = ("line", "circle", "arc", "ellipse", "ellipse_arc", "spline")
GROUP_ENTITY_TYPES = ("polygon", "slot", "rectangle")


def _group_members(entity) -> list[str]:
    """The Line / Arc ids a Polygon, Slot or Rectangle is made of."""
    if entity.type == "slot":
        return [entity.arc1_id, entity.arc2_id, entity.line1_id, entity.line2_id]
    return list(entity.line_ids)


def sketch_entity_edge(sketch: Sketch, entity, basis) -> "TopoDS_Edge | None":
    """`entity` of `sketch` (already pattern / mirror expanded) as one OCCT edge in world space through `basis`: the same constructions the Intersection
    curve, Loft and Extrude use (`app.document.loft.wire_for_open_chain`'s Line / Arc / EllipseArc hops, `wire_for_profile`'s Circle / Ellipse), and a Spline
    as ONE cubic B-spline whose poles are its through and control points with triple inner knots (exactly its Bezier segments, so the projection gives the
    same points back). None for a shape OCCT cannot build (a zero-length line, a zero radius)."""
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge
    from OCC.Core.Geom import Geom_BSplineCurve
    from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Elips
    from OCC.Core.TColgp import TColgp_Array1OfPnt
    from OCC.Core.TColStd import TColStd_Array1OfInteger, TColStd_Array1OfReal

    from app.document.extrude import _ellipse_axis, arc_axis, basis_normal, basis_point_to_world
    from app.document.plane_geometry import is_mirrored_basis

    points = sketch.points

    def world(point_id: str):
        p = points[point_id]
        return basis_point_to_world(basis, p.x, p.y)

    try:
        if isinstance(entity, Line):
            a, b = points[entity.start_point_id], points[entity.end_point_id]
            if math.hypot(a.x - b.x, a.y - b.y) <= POINT_MATCH:
                return None
            return BRepBuilderAPI_MakeEdge(world(entity.start_point_id), world(entity.end_point_id)).Edge()
        if isinstance(entity, Circle):
            radius = entity.radius(points)
            if radius <= POINT_MATCH:
                return None
            return BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(world(entity.center_point_id), basis_normal(basis)), radius)).Edge()
        if isinstance(entity, Arc):
            c = points[entity.center_point_id]
            radius = entity.radius(points)
            if radius <= POINT_MATCH:
                return None
            p1, p2 = (entity.end_point_id, entity.start_point_id) if is_mirrored_basis(basis) else (entity.start_point_id, entity.end_point_id)
            return BRepBuilderAPI_MakeEdge(gp_Circ(arc_axis(basis, c.x, c.y), radius), world(p1), world(p2)).Edge()
        if isinstance(entity, (Ellipse, EllipseArc)):
            c = points[entity.center_point_id]
            major, minor = entity.major_radius(points), entity.minor_radius(points)
            if minor <= POINT_MATCH or major < minor:
                return None
            elips = gp_Elips(_ellipse_axis(basis, c.x, c.y, entity.rotation(points)), major, minor)
            if isinstance(entity, Ellipse):
                return BRepBuilderAPI_MakeEdge(elips).Edge()
            p1, p2 = (entity.end_point_id, entity.start_point_id) if is_mirrored_basis(basis) else (entity.start_point_id, entity.end_point_id)
            return BRepBuilderAPI_MakeEdge(elips, world(p1), world(p2)).Edge()
        if isinstance(entity, Spline):
            segments = entity.segments()
            poles = TColgp_Array1OfPnt(1, 3 * len(segments) + 1)
            ids = [segments[0][0]] + [pid for (_, c1, c2, end) in segments for pid in (c1, c2, end)]
            for i, point_id in enumerate(ids, start=1):
                poles.SetValue(i, world(point_id))
            knots = TColStd_Array1OfReal(1, len(segments) + 1)
            mults = TColStd_Array1OfInteger(1, len(segments) + 1)
            for i in range(len(segments) + 1):
                knots.SetValue(i + 1, float(i))
                mults.SetValue(i + 1, 4 if i in (0, len(segments)) else 3)
            return BRepBuilderAPI_MakeEdge(Geom_BSplineCurve(poles, knots, mults, 3)).Edge()
    except (RuntimeError, ValueError, KeyError):
        return None  # OCCT refused the shape (StdFail / Standard_ConstructionError surface as RuntimeError), or a Point it names is gone
    return None


def _source_sketch_feature(part, source_feature_id: str):
    from app.document.models import SketchFeature

    feature = part.get_feature(source_feature_id)
    return feature if isinstance(feature, SketchFeature) else None


def source_is_upstream(part, target_feature_id: str | None, source_feature_id: str) -> bool:
    """Whether SketchFeature `source_feature_id` comes before `target_feature_id` in the Part's feature list: only an earlier Sketch can be converted into
    this one (`excluded_feature_ids_after`), or a rebuild could loop."""
    from app.document.graph import excluded_feature_ids_after

    if target_feature_id is None or source_feature_id == target_feature_id:
        return False
    return source_feature_id not in excluded_feature_ids_after(part, target_feature_id) and part.get_feature(source_feature_id) is not None


def source_sketch_basis(part, source_feature):
    """The basis of the source Sketch, resolved against the Part as it stood right after that Sketch (the snapshot its own plane references name)."""
    from app.document.create_plane import resolve_sketch_basis
    from app.document.extrude import compute_part_bodies
    from app.document.graph import excluded_feature_ids_after

    excluded = excluded_feature_ids_after(part, source_feature.id)
    return resolve_sketch_basis(part, source_feature, compute_part_bodies(part, excluded), excluded)


def sketch_edges(part, sketch_feature, *, construction: bool = False, basis=None) -> dict:
    """Every curve entity of `sketch_feature`'s Sketch (pattern and mirror instances expanded first, by their expanded ids) as a 3D edge in world space,
    keyed by entity id: the "sketch -> 3D edges" half of a sketch source, generalised from the Intersection curve's one-profile / one-chain wire builders to
    EVERY entity. Construction geometry is included only when `construction` is true; reference helpers (`Sketch.reference_ids`), Polygon / Slot / Rectangle
    groups (their Lines and Arcs are entities of their own) and Text are never included. `basis` defaults to the Sketch's own."""
    from app.sketch.store import get_sketch_or_404

    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    expanded = sketch.expand_pattern_and_mirror_instances()
    basis = basis if basis is not None else source_sketch_basis(part, sketch_feature)
    edges = {}
    for entity_id, entity in expanded.entities.items():
        if entity.type not in CURVE_ENTITY_TYPES or entity_id in sketch.reference_ids or (entity.construction and not construction):
            continue
        edge = sketch_entity_edge(expanded, entity, basis)
        if edge is not None:
            edges[entity_id] = edge
    return edges


def loose_point_ids(sketch: Sketch) -> list[str]:
    """The Points of `sketch` (expanded) that belong to no entity: projected as Points. The origin and reference helpers are not among them."""
    used: set[str] = set()
    for entity in sketch.entities.values():
        used.update(sketch._entity_defining_point_ids(entity))
    return [
        pid for pid in sketch.points if pid not in used and pid != sketch.origin_point_id and pid not in sketch.reference_ids
    ]


def project_source_entity(
    part, target_sketch: Sketch, source_feature_id: str, source_entity_id: str, basis, *, sampled_segments: int | None = None, cache: dict | None = None
):
    """(lost reason or None, projection) of entity or loose Point `source_entity_id` of SketchFeature `source_feature_id`'s Sketch onto `basis` (the target
    Sketch's). Reasons: `source_sketch_missing`, `source_after_sketch` (the source no longer comes first), `source_entity_deleted`, `source_degenerate`."""
    from app.document.graph import sketch_feature_id_for_sketch
    from app.document.plane_geometry import world_point_to_basis
    from app.document.extrude import basis_point_to_world
    from app.sketch.projection import ProjectedEntity, project_edge_onto_sketch
    from app.sketch.store import all_sketches

    feature = _source_sketch_feature(part, source_feature_id)
    source = all_sketches().get(feature.sketch_id) if feature is not None else None
    if source is None:
        return "source_sketch_missing", None
    if not source_is_upstream(part, sketch_feature_id_for_sketch(part, target_sketch.id), source_feature_id):
        return "source_after_sketch", None
    # `cache` (one refresh or one convert call): the expanded source and its basis, worked out once per source Sketch rather than once per entity.
    cache = {} if cache is None else cache
    if source_feature_id not in cache:
        cache[source_feature_id] = (source.expand_pattern_and_mirror_instances(), source_sketch_basis(part, feature))
    expanded, source_basis = cache[source_feature_id]
    entity = expanded.entities.get(source_entity_id)
    if entity is not None:
        edge = sketch_entity_edge(expanded, entity, source_basis)
        if edge is None:
            return "source_degenerate", None
        return None, project_edge_onto_sketch(edge, basis, sampled_segments=sampled_segments)
    point = expanded.points.get(source_entity_id)
    if point is None:
        return "source_entity_deleted", None
    world = basis_point_to_world(source_basis, point.x, point.y)
    return None, [ProjectedEntity(kind="point", start=world_point_to_basis(basis, (world.X(), world.Y(), world.Z())))]
