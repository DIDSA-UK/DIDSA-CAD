"""OCCT geometry construction for MirrorFeature (Pattern/Mirror scoping's
Phase 1 - see `docs/pattern-mirror-scope.md` §2.1/§4) - reflects a single
Body across a `mirror_plane` via OCCT `gp_Trsf.SetMirror(gp_Ax2)` (the
plane-mirror overload - `gp_Ax1` mirrors about a *line*, not used here),
producing a brand-new, independent Body. Kept in its own module and
imported from `app.document.extrude`'s own `compute_part_bodies` via a
function-local import (see that function's own doc comment) to avoid a
circular import - same convention `app.document.fillet`/`chamfer` already
establish, since this module needs `compute_part_bodies` at module level.
"""

from fastapi import HTTPException
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import compute_part_bodies
from app.document.models import MirrorFeature, Part


def _mirror_source_not_found(body_id: str) -> HTTPException:
    """Phase 1: `source_body_ids`' single entry doesn't currently resolve
    to a Body in the accumulator - same structured 422 envelope as B1's
    `missing_reference` (`app.document.extrude._missing_reference`), just
    keyed by a bare Body id rather than a full `SubShapeRef`, since a
    Mirror references a whole Body, not one of its sub-shapes."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _mirror_failed(body_id: str) -> HTTPException:
    """Phase 1: `BRepBuilderAPI_Transform` produced an invalid result -
    rare for a rigid transform (unlike a boolean, a mirror essentially
    never fails geometrically the way a fillet/chamfer/fuse can), but kept
    for the same "never let a raw OCCT failure surface as an uncaught 500"
    reason every other structured geometry error in this codebase exists
    for (`fillet_failed`, `chamfer_failed`, ...)."""
    return HTTPException(status_code=422, detail={"type": "mirror_failed", "body_id": body_id})


def resolve_mirror_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MirrorFeature,
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The post-mirror shape `feature` produces, resolved against `bodies`
    - an already-in-progress `app.document.extrude.compute_part_bodies`
    accumulator, never a fresh recompute (same recursion-avoidance
    reasoning `app.document.fillet.resolve_fillet_from_bodies`'s own doc
    comment gives, since `resolve_plane_ref` may itself recurse into a
    referenced `CreatePlaneFeature`).

    Phase 1 scope: exactly one `source_body_ids` entry (enforced by
    `app.document.router._validate_mirror_source_body_ids` before this is
    ever called) - `source_feature_ids` (reserved for Phase 6) is not read
    yet.

    Unlike Fillet/Chamfer, this never modifies the source Body - it is
    read from `bodies` and left completely untouched; the mirrored copy is
    an entirely new, independent shape (Boss-with-no-target semantics -
    see `MirrorFeature`'s own docstring). The caller (`app.document.
    extrude.compute_part_bodies`) registers the returned shape under this
    Feature's own id."""
    body_id = feature.source_body_ids[0]
    source = bodies.get(body_id)
    if source is None:
        raise _mirror_source_not_found(body_id)

    resolved_plane = resolve_plane_ref(part, bodies, feature.mirror_plane, excluded_feature_ids)
    origin = gp_Pnt(*resolved_plane.origin)
    normal = gp_Dir(*resolved_plane.normal)
    trsf = gp_Trsf()
    trsf.SetMirror(gp_Ax2(origin, normal))

    transform = BRepBuilderAPI_Transform(source, trsf, True)
    if not transform.IsDone():
        raise _mirror_failed(body_id)
    return transform.Shape()


def resolve_mirror(
    part: Part, feature: MirrorFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), matching every other resolver's self-exclusion convention
    in this codebase (`app.document.fillet.resolve_fillet`, `app.document.
    revolve.resolve_revolve`, ...) for the same forward-looking reason
    `resolve_revolve`'s own doc comment gives even though it's Boss/Cut-
    shaped, not an in-place modify: Phase 1 alone (always a brand-new,
    never-merged Body - see `MirrorFeature`'s own docstring) has no actual
    double-application risk yet, since nothing this Mirror produces is
    ever fused back into anything else, but Phase 5's merge-into-source
    option will introduce exactly that risk, and self-excluding
    unconditionally now means Phase 5 doesn't have to remember to add it
    later."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_mirror_from_bodies(part, bodies, feature, all_excluded)
