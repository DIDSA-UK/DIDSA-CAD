"""OCCT geometry construction for MoveBodyFeature (Direct Editing family,
third entry - "Move/Copy Body" - see `docs/direct-editing-scope.md`) -
translates `body_id` by `delta` and/or rotates it around `rotation_axis`,
via two independent, sequential `BRepBuilderAPI_Transform` calls (rotate
first, if any, then translate, if any) rather than composing a single
`gp_Trsf` via `Multiplied()` - deliberately avoids relying on this
codebase's own confidence in OCCT's `gp_Trsf` composition/multiplication
ordering convention (never exercised anywhere else in this codebase), in
favour of two calls whose own individual, unambiguous meaning ("apply this
transform to this shape") this codebase already relies on throughout
(`app.document.mirror`, `app.document.pattern`). Rotate-before-translate
matches SolidWorks' own Move/Copy Body composition order - see
`MoveBodyFeature`'s own docstring for why this specific order (the axis
reference is a fixed world-space pivot resolved once, before any
translation moves the Body away from it).

Reuses `app.document.pattern._axis_from_ref` verbatim for `rotation_axis`
resolution - the exact same `PatternAxisRef` type Circular Pattern already
resolves to a world-space `gp_Ax1`, no new axis-resolution logic needed.

`copy=False` (default) modifies `body_id` in place (Fillet/Chamfer's "keep
the same id" pattern - see `fillet.py`'s own docstring); `copy=True` is
handled by the caller (`app.document.extrude._apply_feature_to_bodies`),
which registers the returned shape under a brand-new id instead of
reassigning `body_id` - this module always returns `(body_id, new_shape)`
regardless, the same tuple shape Fillet/Chamfer/Scale Body return.

This module needs `compute_part_bodies` from extrude.py at module level, so
(mirroring app.document.chamfer/fillet's own identical circular-import
workaround) extrude.py imports this module back via a function-local import
inside `_apply_feature_to_bodies` instead.
"""

import math

from fastapi import HTTPException
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Trsf, gp_Vec
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.models import MoveBodyFeature, Part
from app.document.pattern import _axis_from_ref


def _move_body_not_found(body_id: str) -> HTTPException:
    """`feature.body_id` doesn't currently resolve to a real Body - same
    `missing_reference` shape every other dangling-reference error in this
    codebase uses."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _move_body_failed(body_id: str) -> HTTPException:
    """`BRepBuilderAPI_Transform` produced an invalid result for `body_id` -
    rare for a rigid transform (mirrors Mirror's own `_mirror_failed`, kept
    for the same "never let a raw OCCT failure surface as an uncaught 500"
    reason every other structured geometry error in this codebase exists
    for)."""
    return HTTPException(status_code=422, detail={"type": "move_body_failed", "body_id": body_id})


def resolve_move_body_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MoveBodyFeature,
    excluded_feature_ids: frozenset[str],
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies (always `feature.body_id`, regardless
    of `feature.copy` - see this module's own top-level docstring for who
    decides what to do with that id) and its post-move shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (same reason
    `resolve_fillet_from_bodies`'s own doc comment gives). Needs `part`/
    `excluded_feature_ids` (unlike Fillet/Chamfer/Scale Body's simpler two-
    argument shape) only because `rotation_axis` resolution
    (`_axis_from_ref`) needs them, mirroring `resolve_pattern_from_bodies`'s
    identical four-argument shape for the same reason."""
    shape = bodies.get(feature.body_id)
    if shape is None:
        raise _move_body_not_found(feature.body_id)

    if feature.rotation_axis is not None and feature.rotation_angle_degrees != 0:
        axis = _axis_from_ref(part, bodies, feature.rotation_axis, excluded_feature_ids)
        rotation = gp_Trsf()
        rotation.SetRotation(axis, math.radians(feature.rotation_angle_degrees))
        rotated = BRepBuilderAPI_Transform(shape, rotation, True)
        if not rotated.IsDone():
            raise _move_body_failed(feature.body_id)
        shape = rotated.Shape()

    dx, dy, dz = feature.delta
    if (dx, dy, dz) != (0.0, 0.0, 0.0):
        translation = gp_Trsf()
        translation.SetTranslation(gp_Vec(dx, dy, dz))
        translated = BRepBuilderAPI_Transform(shape, translation, True)
        if not translated.IsDone():
            raise _move_body_failed(feature.body_id)
        shape = translated.Shape()

    return feature.body_id, shape


def resolve_move_body(
    part: Part, feature: MoveBodyFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `resolve_fillet`'s own self-exclusion shape exactly. Correct for both
    `copy=False` (modifies `body_id` in place, so re-resolving against its
    own prior output would double-apply it) and `copy=True` (this Feature's
    own `id` isn't `body_id`, so excluding it is a no-op for the source
    Body's own resolution - harmless, and keeps this one code path uniform
    for both modes rather than branching)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_move_body_from_bodies(part, bodies, feature, excluded_feature_ids | {feature.id})
