"""OCCT geometry construction for ScaleBodyFeature (Direct Editing family,
second entry - see `docs/direct-editing-scope.md`) - scales `body_id`
uniformly by `factor` about its own current bounding-box centre, via OCCT
`gp_Trsf.SetScale(gp_Pnt, factor)` + `BRepBuilderAPI_Transform` - the same
rigid-transform idiom `app.document.mirror` already establishes for
`gp_Trsf.SetMirror`, just a different `gp_Trsf` setter. Modifies `body_id`
in place (Fillet/Chamfer's "keep the same id" pattern - see `fillet.py`'s
own docstring), unlike Mirror, which always mints a brand-new Body.

The scale origin is always the Body's own current bounding-box centre,
recomputed fresh at every resolve (not a stored reference) - v1 deliberately
ships without a user-pickable origin point (see `docs/direct-editing-
scope.md`). Only uniform scale is supported in v1 - non-uniform (independent
X/Y/Z factors) needs `gp_GTrsf`/`BRepBuilderAPI_GTransform` instead of
`gp_Trsf`/`BRepBuilderAPI_Transform`, genuinely new API surface for this
codebase, not yet spiked - deferred rather than guessed at.

This module needs `compute_part_bodies` from extrude.py at module level, so
(mirroring app.document.chamfer/fillet's own identical circular-import
workaround) extrude.py imports this module back via a function-local import
inside `_apply_feature_to_bodies` instead.
"""

from fastapi import HTTPException
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Pnt, gp_Trsf
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.models import Part, ScaleBodyFeature


def _scale_body_not_found(body_id: str) -> HTTPException:
    """`feature.body_id` doesn't currently resolve to a real Body - same
    `missing_reference` shape every other dangling-reference error in this
    codebase uses."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _scale_body_failed(body_id: str) -> HTTPException:
    """`BRepBuilderAPI_Transform` produced an invalid result for `body_id` -
    rare for a rigid+scale transform (mirrors Mirror's own `_mirror_failed`,
    kept for the same "never let a raw OCCT failure surface as an
    uncaught 500" reason every other structured geometry error in this
    codebase exists for)."""
    return HTTPException(status_code=422, detail={"type": "scale_body_failed", "body_id": body_id})


def _bbox_center(shape: TopoDS_Shape) -> tuple[float, float, float]:
    """The centre of `shape`'s own axis-aligned `Bnd_Box` - the scale
    origin every `ScaleBodyFeature` resolve uses, same `Bnd_Box`/
    `BRepBndLib.brepbndlib.Add` idiom `app.document.split._bbox_corners_
    and_diagonal` already establishes."""
    box = Bnd_Box()
    brepbndlib.Add(shape, box)
    xmin, ymin, zmin, xmax, ymax, zmax = box.Get()
    return ((xmin + xmax) / 2.0, (ymin + ymax) / 2.0, (zmin + zmax) / 2.0)


def resolve_scale_body_from_bodies(
    bodies: dict[str, TopoDS_Shape],
    feature: ScaleBodyFeature,
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-scale shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (same reason
    `resolve_fillet_from_bodies`'s own doc comment gives)."""
    source = bodies.get(feature.body_id)
    if source is None:
        raise _scale_body_not_found(feature.body_id)
    origin = gp_Pnt(*_bbox_center(source))
    trsf = gp_Trsf()
    trsf.SetScale(origin, feature.factor)
    transform = BRepBuilderAPI_Transform(source, trsf, True)
    if not transform.IsDone():
        raise _scale_body_failed(feature.body_id)
    return feature.body_id, transform.Shape()


def resolve_scale_body(
    part: Part, feature: ScaleBodyFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `resolve_fillet`'s own self-exclusion shape exactly (a Scale modifies a
    Body in place, so re-resolving against its own prior output would
    double-apply it - re-scaling an already-scaled Body, not re-deriving
    the original candidate)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_scale_body_from_bodies(bodies, feature)
