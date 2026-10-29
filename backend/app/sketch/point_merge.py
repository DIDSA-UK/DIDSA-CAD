"""Point Merge (docs/point-merge-and-vr-sketcher-plan.md, M1): two or more Points of one Sketch become one.

The kept Point stays where it is; every reference to an absorbed Point (an entity's corner, a constraint's argument, a reference dimension's ref) is rewritten to
the kept one, the constraints that collapse are dropped (or the merge is refused), and the Sketch is solved. Unlike `Coincident`, which only ties two Points
together, the absorbed Point is gone afterwards: one Point to drag, select and dimension.

The whole operation is atomic: anything refused, or a merge that makes a converging Sketch stop converging, leaves the Sketch exactly as it was. The undo
snapshot (`before`) and the document-layer facts (which Points a Part feature references) are the router's business; this module only sees the Sketch.

Lives in its own module rather than on `Sketch` because the final step needs `app.sketch.solver`, which imports `app.sketch.models`."""

from __future__ import annotations

import copy
import dataclasses
from dataclasses import dataclass, field

from app.sketch.constraints import (
    AtMidpointConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    ConcentricConstraint,
    Constraint,
    CurveTangentConstraint,
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    FixedConstraint,
    HorizontalConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    PointOnCircleConstraint,
    PointOnEllipseConstraint,
    PointOnLineConstraint,
    TangentConstraint,
    VerticalConstraint,
)
from app.sketch.models import Circle, Ellipse, ReferenceDimension, Sketch
from app.sketch.solver import solve_sketch


class MergeRefused(Exception):
    """A merge that cannot happen. `reason` is a stable code (`too_few`, `origin`, `two_anchored`, `same_entity`, `quadrant`, `dimension_between`,
    `degenerate_constraint`, `stacked_entities`, `conflict`), `message` plain words for the user, `ids` the Points / constraints / entities concerned."""

    def __init__(self, reason: str, message: str, ids: list[str] | None = None) -> None:
        super().__init__(message)
        self.reason = reason
        self.message = message
        self.ids = list(ids or [])


@dataclass
class MergeResult:
    kept_id: str
    absorbed_ids: list[str]
    dropped_constraint_ids: list[str] = field(default_factory=list)
    dropped_reference_dimension_ids: list[str] = field(default_factory=list)
    converged: bool = True


def _distinct(point_ids: list[str]) -> list[str]:
    return list(dict.fromkeys(point_ids))


def _constraint_count(sketch: Sketch, point_id: str, selected: set[str]) -> int:
    """How many constraints hold `point_id`, not counting a provisional dimension (the solver skips it) or a Coincident between two selected Points (the merge
    removes it anyway)."""
    count = 0
    for constraint in sketch.constraints.values():
        if point_id not in constraint.point_ids():
            continue
        if isinstance(constraint, DistanceConstraint) and constraint.provisional:
            continue
        if isinstance(constraint, CoincidentConstraint) and constraint.point_a_id in selected and constraint.point_b_id in selected:
            continue
        count += 1
    return count


def merge_keep_order(sketch: Sketch, point_ids: list[str], anchored_ids: set[str] | frozenset[str]) -> list[str]:
    """`point_ids` ordered by who is kept: anchored Points first, then the most constraints, then selection order (a stable sort). The first entry is the
    kept Point. Both clients run the same rule locally to ring the Point that will stay (they do not know about Part feature references, so the server's
    answer wins in that rare case)."""
    ids = _distinct(point_ids)
    selected = set(ids)
    position = {pid: i for i, pid in enumerate(ids)}
    return sorted(ids, key=lambda pid: (pid not in anchored_ids, -_constraint_count(sketch, pid, selected), position[pid]))


def _quadrant_point_ids(sketch: Sketch) -> set[str]:
    """The Points a Circle or Ellipse owns as its quadrant (cardinal) Points. They are tied to the shape by constraints of its own and the trim and delete
    paths treat them as the shape's, so v1 refuses to merge them (use Coincident)."""
    ids: set[str] = set()
    for entity in sketch.entities.values():
        if isinstance(entity, Circle):
            ids.update(entity.cardinal_point_ids)
        elif isinstance(entity, Ellipse):
            ids.update((entity.major_point_id, entity.major_point_neg_id, entity.minor_point_id, entity.minor_point_neg_id))
    return ids


def _check_refusals(sketch: Sketch, ids: list[str], anchored_ids: set[str] | frozenset[str]) -> None:
    if len(ids) < 2:
        raise MergeRefused("too_few", "Select two or more points to merge.", ids)
    if sketch.origin_point_id in ids:
        raise MergeRefused("origin", "The origin can't be merged. Use Coincident to tie a point to it.", [sketch.origin_point_id])
    anchored = [pid for pid in ids if pid in anchored_ids]
    if len(anchored) >= 2:
        raise MergeRefused("two_anchored", "Two of these points are pinned (to the part, a Fix or a feature), so they can't become one.", anchored)
    chosen = set(ids)
    for entity in sketch.entities.values():
        shared = [pid for pid in dict.fromkeys(sketch._entity_defining_point_ids(entity)) if pid in chosen]
        if len(shared) >= 2:
            raise MergeRefused(
                "same_entity",
                f"These points both belong to the same {entity.type}: merging them would collapse it.",
                [entity.id, *shared],
            )
    quadrant = [pid for pid in ids if pid in _quadrant_point_ids(sketch)]
    if quadrant:
        raise MergeRefused("quadrant", "A circle's quadrant point can't be merged. Use Coincident.", quadrant)


def _rewrite_object(obj, absorbed: set[str], keep_id: str) -> bool:
    """Replaces every `str` field equal to an absorbed id with `keep_id`, and the same inside each `list`/`tuple` of `str`. Ids are uuid4s, so a string equal to a
    Point id *is* that Point whatever the field is called: no per-type field list to forget the next entity type in. Returns whether anything changed."""
    changed = False
    for f in dataclasses.fields(obj):
        value = getattr(obj, f.name)
        if isinstance(value, str):
            if value in absorbed:
                setattr(obj, f.name, keep_id)
                changed = True
        elif isinstance(value, (list, tuple)) and any(isinstance(item, str) and item in absorbed for item in value):
            rewritten = [keep_id if isinstance(item, str) and item in absorbed else item for item in value]
            setattr(obj, f.name, rewritten if isinstance(value, list) else tuple(rewritten))
            changed = True
    return changed


_DROP = "drop"
_KEEP = "keep"


def _collapse(constraint: Constraint) -> str:
    """What a constraint that was just rewritten becomes: `_DROP` (now trivially satisfied), `_KEEP`, or a `MergeRefused` (now degenerate or contradictory).
    One branch per row of the plan's collapse table. Two lines sharing the kept Point (a Parallel, an Angle, ...) is just two connected lines: kept."""
    if isinstance(constraint, CoincidentConstraint):
        return _DROP if constraint.point_a_id == constraint.point_b_id else _KEEP
    if isinstance(constraint, ConcentricConstraint):
        return _DROP if constraint.center1_point_id == constraint.center2_point_id else _KEEP
    if isinstance(constraint, PointOnLineConstraint):
        return _DROP if constraint.point_id in (constraint.line_start_id, constraint.line_end_id) else _KEEP
    if isinstance(constraint, PointOnCircleConstraint):
        if constraint.point_id == constraint.center_point_id:
            raise MergeRefused("degenerate_constraint", "This would break the point on circle on them (a zero radius).", [constraint.id])
        return _DROP if constraint.point_id == constraint.radius_point_id else _KEEP
    if isinstance(constraint, PointOnEllipseConstraint):
        if constraint.point_id == constraint.center_point_id:
            raise MergeRefused("degenerate_constraint", "This would break the point on ellipse on them (a zero radius).", [constraint.id])
        return _DROP if constraint.point_id in (constraint.major_point_id, constraint.minor_point_id) else _KEEP
    if isinstance(constraint, DistanceConstraint):
        if constraint.point_a_id != constraint.point_b_id:
            return _KEEP
        if constraint.provisional:
            return _DROP  # a shape tool's placeholder size, not a dimension the user wrote: the solver skips it
        raise MergeRefused("dimension_between", f"A dimension holds these points {constraint.distance:g} apart. Delete it first.", [constraint.id])
    if isinstance(constraint, PointLineDistanceConstraint):
        if constraint.point_id in (constraint.line_start_id, constraint.line_end_id):
            raise MergeRefused("dimension_between", f"A dimension holds this point {constraint.distance:g} from the line. Delete it first.", [constraint.id])
        return _KEEP
    if isinstance(constraint, AtMidpointConstraint):
        if constraint.point_id in (constraint.line_start_id, constraint.line_end_id):
            raise MergeRefused("degenerate_constraint", "This would break the midpoint on them (it would force a zero length).", [constraint.id])
        return _KEEP
    if isinstance(constraint, TangentConstraint):
        if constraint.center_point_id in (constraint.radius_point_id, constraint.line_start_id, constraint.line_end_id):
            raise MergeRefused("degenerate_constraint", "This would break the tangent on them.", [constraint.id])
        return _KEEP
    if isinstance(constraint, CurveTangentConstraint):
        if constraint.center1_point_id == constraint.center2_point_id or constraint.shared_point_id in (constraint.center1_point_id, constraint.center2_point_id):
            raise MergeRefused("degenerate_constraint", "This would break the tangent on them.", [constraint.id])
        return _KEEP
    if isinstance(constraint, EqualRadiusConstraint):
        if constraint.center1_point_id == constraint.radius1_point_id or constraint.center2_point_id == constraint.radius2_point_id:
            raise MergeRefused("degenerate_constraint", "This would break the equal radius on them (a zero radius).", [constraint.id])
        return _KEEP
    if isinstance(constraint, (HorizontalConstraint, VerticalConstraint)):
        if constraint.point_a_id == constraint.point_b_id:
            raise MergeRefused("degenerate_constraint", f"This would break the {constraint.type} on them.", [constraint.id])
        return _KEEP
    if isinstance(constraint, FixedConstraint):
        constraint.fixed_point_ids = list(dict.fromkeys(constraint.fixed_point_ids))
        return _KEEP
    return _KEEP


_LINE_PAIR_SYMMETRIC = (ParallelConstraint, PerpendicularConstraint, EqualLengthConstraint, CollinearConstraint)


def _duplicate_key(constraint: Constraint):
    """Two constraints with the same key say the same thing. Order-insensitive for the symmetric types (Coincident, Parallel, Perpendicular, Equal, Concentric,
    Collinear); every other type compares all its fields but the id."""
    if isinstance(constraint, CoincidentConstraint):
        return (constraint.type, frozenset((constraint.point_a_id, constraint.point_b_id)))
    if isinstance(constraint, _LINE_PAIR_SYMMETRIC):
        first = (constraint.line1_id, constraint.line1_start_id, constraint.line1_end_id)
        second = (constraint.line2_id, constraint.line2_start_id, constraint.line2_end_id)
        return (constraint.type, frozenset((first, second)))
    if isinstance(constraint, ConcentricConstraint):
        return (constraint.type, frozenset(((constraint.entity1_id, constraint.center1_point_id), (constraint.entity2_id, constraint.center2_point_id))))
    values = tuple((f.name, tuple(v) if isinstance(v, list) else v) for f in dataclasses.fields(constraint) if f.name != "id" for v in [getattr(constraint, f.name)])
    return (constraint.type, values)


def _restore(sketch: Sketch, backup: Sketch) -> None:
    sketch.copy_state_from(backup)


def merge_points(sketch: Sketch, point_ids: list[str], anchored_ids: set[str] | frozenset[str] = frozenset()) -> MergeResult:
    """Merges `point_ids` (in selection order, all of them in `sketch`) into one Point. `anchored_ids` are the Points that must be kept: the sketch's own
    locks are added here, the Part-feature references are the caller's (the sketch layer cannot see features). Raises `MergeRefused`, leaving `sketch`
    untouched."""
    ids = _distinct(point_ids)
    anchored = {pid for pid in ids if pid in anchored_ids or sketch.is_point_locked(pid)}
    _check_refusals(sketch, ids, anchored)
    keep_id, *absorbed_list = merge_keep_order(sketch, ids, anchored)
    absorbed = set(absorbed_list)

    backup = copy.deepcopy(sketch)
    converged_before = solve_sketch(copy.deepcopy(sketch)).converged
    try:
        return _apply(sketch, keep_id, absorbed_list, absorbed, converged_before)
    except MergeRefused:
        _restore(sketch, backup)
        raise


def _apply(sketch: Sketch, keep_id: str, absorbed_list: list[str], absorbed: set[str], converged_before: bool) -> MergeResult:
    result = MergeResult(kept_id=keep_id, absorbed_ids=absorbed_list)

    # 1. Entities and constraints, generically.
    touched_entities: list[str] = []
    for entity in sketch.entities.values():
        if _rewrite_object(entity, absorbed, keep_id):
            touched_entities.append(entity.id)
    touched_constraints: set[str] = set()
    for constraint in sketch.constraints.values():
        if _rewrite_object(constraint, absorbed, keep_id):
            touched_constraints.add(constraint.id)

    # 2. Constraints that collapsed.
    for constraint_id in list(touched_constraints):
        if _collapse(sketch.constraints[constraint_id]) == _DROP:
            del sketch.constraints[constraint_id]
            touched_constraints.discard(constraint_id)
            result.dropped_constraint_ids.append(constraint_id)

    # 3. Duplicates: two constraints that now say the same thing, at least one of them rewritten by this merge.
    seen: dict[object, str] = {}
    for constraint_id, constraint in list(sketch.constraints.items()):
        key = _duplicate_key(constraint)
        first_id = seen.get(key)
        if first_id is None:
            seen[key] = constraint_id
        elif constraint_id in touched_constraints or first_id in touched_constraints:
            del sketch.constraints[constraint_id]
            result.dropped_constraint_ids.append(constraint_id)

    # Two entities that now stand on the same Points.
    by_points: dict[tuple[str, frozenset[str]], str] = {}
    for entity in sketch.entities.values():
        key = (entity.type, frozenset(sketch._entity_defining_point_ids(entity)))
        other_id = by_points.get(key)
        if other_id is None:
            by_points[key] = entity.id
        elif entity.id in touched_entities or other_id in touched_entities:
            raise MergeRefused("stacked_entities", f"Two {entity.type}s would end up on top of each other. Delete one first.", [other_id, entity.id])

    # 4. Sketch-level state.
    if keep_id in sketch.reference_ids and any(pid not in sketch.reference_ids for pid in absorbed):
        sketch.reference_ids.discard(keep_id)  # real geometry took the helper over
    for point_id in absorbed:
        del sketch.points[point_id]
        sketch.external_references.pop(point_id, None)
        sketch.external_reference_decisions.pop(point_id, None)
        sketch.reference_ids.discard(point_id)
    for dimension_id, dimension in list(sketch.reference_dimensions.items()):
        refs = tuple((t, keep_id if t == "point" and i in absorbed else i) for t, i in dimension.refs)
        if refs == dimension.refs:
            continue
        if dimension.kind in ("distance", "horizontal", "vertical") and len(refs) == 2 and refs[0] == refs[1]:
            del sketch.reference_dimensions[dimension_id]  # driven, so it never constrained: safe to drop
            result.dropped_reference_dimension_ids.append(dimension_id)
        else:
            sketch.reference_dimensions[dimension_id] = ReferenceDimension(id=dimension.id, kind=dimension.kind, refs=refs)

    # 5. Solve. The kept Point holds its place; what hung on the absorbed ones follows.
    solved = solve_sketch(sketch, anchor_point_ids=frozenset({keep_id}))
    if converged_before and not solved.converged:
        raise MergeRefused("conflict", "That conflicts with the other constraints, so the points weren't merged.", [keep_id, *absorbed_list])
    result.converged = solved.converged
    return result
