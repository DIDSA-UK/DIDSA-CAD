"""OCCT geometry construction for MirrorFeature (Pattern/Mirror scoping's
Phase 1 - see `docs/pattern-mirror-scope.md` §2.1/§4) - reflects one or more
Bodies across a `mirror_plane` via OCCT `gp_Trsf.SetMirror(gp_Ax2)` (the
plane-mirror overload - `gp_Ax1` mirrors about a *line*, not used here),
producing one brand-new, independent Body per source. Kept in its own module
and imported from `app.document.extrude`'s own `compute_part_bodies` via a
function-local import (see that function's own doc comment) to avoid a
circular import - same convention `app.document.fillet`/`chamfer` already
establish, since this module needs `compute_part_bodies` at module level.

On-device feedback (same day as Phase 1's initial ship): multi-body seeding
was originally scoped as Phase 6 (`docs/pattern-mirror-scope.md`), but the
guided "New > Mirror" flow's own UX ask ("select body/bodies (multiple
bodies should be supported)") pulled it forward into Phase 1 directly - see
that doc's own updated Phase 1/6 entries for the full reasoning.
"""

from fastapi import HTTPException
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import compute_part_bodies
from app.document.graph import body_ids_for_feature_id, tool_feature_qualifies
from app.document.models import MirrorFeature, Part


def _mirror_source_not_found(body_id: str) -> HTTPException:
    """One of `source_body_ids`' entries doesn't currently resolve to a
    Body in the accumulator - same structured 422 envelope as B1's
    `missing_reference` (`app.document.extrude._missing_reference`), just
    keyed by a bare Body id rather than a full `SubShapeRef`, since a
    Mirror references a whole Body, not one of its sub-shapes."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _mirror_source_feature_not_found(feature_id: str) -> HTTPException:
    """Pattern/Mirror Phase 6: one of `source_feature_ids`' entries doesn't
    currently resolve to any Body at all (`body_ids_for_feature_id` returned
    empty - the Feature was deleted, or its own topology has drifted to
    produce zero Bodies). Same structured 422 envelope as `_mirror_source_
    not_found`, keyed by `feature_id` (a `type: "missing_reference"` shape
    with a `feature_id` field instead of `body_id`, so a client can tell
    the two failure modes apart)."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "feature_id": feature_id})


def effective_mirror_source_body_ids(bodies: dict[str, TopoDS_Shape], feature: MirrorFeature) -> list[str]:
    """Pattern/Mirror Phase 6 (`docs/pattern-mirror-scope.md` §2.8/§4):
    `feature.source_body_ids` (explicit Body picks) combined with every
    Body each `feature.source_feature_ids` entry (a Feature-tree pick)
    currently resolves to (`app.document.graph.body_ids_for_feature_id`,
    the scope doc's own one-line lookup) - deduplicated, preserving first-
    occurrence order, so a Body named both directly and via its own owning
    Feature is only ever mirrored once. Raises `_mirror_source_feature_not_
    found` for a `source_feature_ids` entry that currently resolves to no
    Body at all - `source_body_ids` entries are left unvalidated here (the
    caller, `resolve_mirror_from_bodies`, already raises its own `_mirror_
    source_not_found` per entry as it iterates)."""
    seen: set[str] = set()
    ordered: list[str] = []
    for body_id in feature.source_body_ids:
        if body_id not in seen:
            seen.add(body_id)
            ordered.append(body_id)
    for feature_id in feature.source_feature_ids:
        matches = body_ids_for_feature_id(bodies, feature_id)
        if not matches:
            raise _mirror_source_feature_not_found(feature_id)
        for body_id in matches:
            if body_id not in seen:
                seen.add(body_id)
                ordered.append(body_id)
    return ordered


def _mirror_failed(body_id: str) -> HTTPException:
    """`BRepBuilderAPI_Transform` produced an invalid result for the Body
    named by `body_id` - rare for a rigid transform (unlike a boolean, a
    mirror essentially never fails geometrically the way a fillet/chamfer/
    fuse can), but kept for the same "never let a raw OCCT failure surface
    as an uncaught 500" reason every other structured geometry error in
    this codebase exists for (`fillet_failed`, `chamfer_failed`, ...)."""
    return HTTPException(status_code=422, detail={"type": "mirror_failed", "body_id": body_id})


def resolve_mirror_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MirrorFeature,
    excluded_feature_ids: frozenset[str],
) -> list[TopoDS_Shape]:
    """The post-mirror shapes `feature` produces, one per effective source
    (`effective_mirror_source_body_ids` - `source_body_ids` combined with
    every Body each `source_feature_ids` entry currently resolves to,
    Phase 6, same order), resolved against `bodies` - an already-in-progress
    `app.document.extrude.compute_part_bodies` accumulator, never a fresh
    recompute (same recursion-avoidance reasoning `app.document.fillet.
    resolve_fillet_from_bodies`'s own doc comment gives, since `resolve_
    plane_ref` may itself recurse into a referenced `CreatePlaneFeature`).

    `mirror_plane` is resolved once and reused for every source Body -
    every mirrored instance reflects across the exact same plane. Unlike
    Fillet/Chamfer, this never modifies any source Body - each is read from
    `bodies` and left completely untouched; every mirrored copy is an
    entirely new, independent shape (Boss-with-no-target semantics - see
    `MirrorFeature`'s own docstring). The caller (`app.document.extrude.
    compute_part_bodies`) registers the returned shapes: under this
    Feature's own id directly if there's exactly one, or `f"{feature.id}#
    {i}"` per entry (mirroring `_register_solids`'s own single-vs-multiple
    naming convention) if there are several."""
    resolved_plane = resolve_plane_ref(part, bodies, feature.mirror_plane, excluded_feature_ids)
    origin = gp_Pnt(*resolved_plane.origin)
    normal = gp_Dir(*resolved_plane.normal)
    trsf = gp_Trsf()
    trsf.SetMirror(gp_Ax2(origin, normal))

    mirrored_shapes = []
    for body_id in effective_mirror_source_body_ids(bodies, feature):
        source = bodies.get(body_id)
        if source is None:
            raise _mirror_source_not_found(body_id)
        transform = BRepBuilderAPI_Transform(source, trsf, True)
        if not transform.IsDone():
            raise _mirror_failed(body_id)
        mirrored_shapes.append(transform.Shape())
    return mirrored_shapes


def _invalid_tool_feature_ref(tool_feature_id: str) -> HTTPException:
    """Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
    §2.11/§4): `tool_feature_id` doesn't currently resolve to a qualifying
    Feature - missing entirely, the wrong Feature type, or a Cut/Boss whose
    own shape doesn't qualify (see `app.document.graph.tool_feature_
    qualifies`). Same structured 422 envelope `app.document.router._
    validate_tool_feature_id`'s own eager check raises - reused here for
    the same "tolerate reference drift after the fact" reasoning every
    other reference kind in this codebase already gets (mirrors `_mirror_
    source_not_found`'s own shape, keyed by `feature_id` instead of
    `body_id`)."""
    return HTTPException(
        status_code=422, detail={"type": "invalid_tool_feature_ref", "feature_id": tool_feature_id}
    )


def resolve_mirror_tool_feature_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MirrorFeature,
    excluded_feature_ids: frozenset[str],
) -> tuple[str, TopoDS_Shape]:
    """Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
    §2.11/§4): `MirrorFeature.tool_feature_id` mode - mirrors the referenced
    upstream Cut/Boss-into-target Feature's own standalone, pre-boolean
    tool shape (`app.document.extrude.resolve_feature_tool_shape`) once
    across `mirror_plane` (resolved exactly like the ordinary Body-seed
    path above), then applies a single `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse`
    (matching the referenced Feature's own Cut/Boss mode) against that
    Feature's own single target Body's *current* shape in `bodies` - the
    actual fix for "mirror an asymmetric hole pattern into the same part":
    the target ends up with both the original hole(s) and their mirror
    image, correctly subtracted, not unioned-and-refilled (see `docs/
    pattern-mirror-scope.md` §2.11's own "why FUSE_INTO_ONE doesn't cover
    this" reasoning).

    Re-checks `tool_feature_qualifies` here (not just at router-validation
    time) for the same "validate eagerly, tolerate drift at recompute"
    split every other reference kind in this codebase already follows - the
    referenced Feature's own mode/`target_body_ids` can drift after this
    Mirror was created (e.g. edited via B4 rollback), and a `tool_feature_
    id` that no longer qualifies must fail closed as `invalid_tool_feature_
    ref`, not silently misbehave.

    v1 scope: exactly one target - `target_body_ids[0]` (see `docs/pattern-
    mirror-scope.md` §2.11's own note on why multi-target feature-mirror is
    deferred). Returns `(target_body_id, new_shape)` for the caller
    (`app.document.extrude.compute_part_bodies`'s own `MirrorFeature`
    branch) to register in place, mirroring `_apply_boss_or_cut`'s own
    Cut-mode `del bodies[target_id]; _register_solids(bodies, target_id,
    ...)` shape exactly."""
    from app.document.extrude import resolve_feature_tool_shape

    tool_feature_id = feature.tool_feature_id
    assert tool_feature_id is not None

    tool_feature = part.get_feature(tool_feature_id)
    if not tool_feature_qualifies(tool_feature):
        raise _invalid_tool_feature_ref(tool_feature_id)

    result = resolve_feature_tool_shape(part, bodies, tool_feature_id, excluded_feature_ids)
    if result is None:
        raise _invalid_tool_feature_ref(tool_feature_id)
    tool_shape, target_body_ids, is_cut = result
    if not target_body_ids:
        raise _invalid_tool_feature_ref(tool_feature_id)
    target_id = target_body_ids[0]
    if target_id not in bodies:
        raise _invalid_tool_feature_ref(tool_feature_id)

    resolved_plane = resolve_plane_ref(part, bodies, feature.mirror_plane, excluded_feature_ids)
    origin = gp_Pnt(*resolved_plane.origin)
    normal = gp_Dir(*resolved_plane.normal)
    trsf = gp_Trsf()
    trsf.SetMirror(gp_Ax2(origin, normal))

    transform = BRepBuilderAPI_Transform(tool_shape, trsf, True)
    if not transform.IsDone():
        raise _mirror_failed(target_id)
    mirrored_tool = transform.Shape()

    if is_cut:
        new_shape = BRepAlgoAPI_Cut(bodies[target_id], mirrored_tool).Shape()
    else:
        new_shape = BRepAlgoAPI_Fuse(bodies[target_id], mirrored_tool).Shape()
    return target_id, new_shape


def resolve_mirror(
    part: Part, feature: MirrorFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> list[TopoDS_Shape] | tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), matching every other resolver's self-exclusion convention
    in this codebase (`app.document.fillet.resolve_fillet`, `app.document.
    revolve.resolve_revolve`, ...) for the same forward-looking reason
    `resolve_revolve`'s own doc comment gives even though it's Boss/Cut-
    shaped, not an in-place modify: Phase 1 alone (always brand-new,
    never-merged Bodies - see `MirrorFeature`'s own docstring) has no actual
    double-application risk yet, since nothing this Mirror produces is
    ever fused back into anything else, but Phase 5's merge-into-source
    option will introduce exactly that risk, and self-excluding
    unconditionally now means Phase 5 doesn't have to remember to add it
    later.

    Phase 8 (§2.11): dispatches to `resolve_mirror_tool_feature_from_bodies`
    when `feature.tool_feature_id` is set, mirroring `resolve_mirror_from_
    bodies`'s own ordinary-mode call otherwise - both raise on an
    unresolvable reference, which is all every call site (the router's own
    eager-resolve-to-validate calls) actually needs; the differing return
    shape is never inspected by any of them."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    if feature.tool_feature_id is not None:
        return resolve_mirror_tool_feature_from_bodies(part, bodies, feature, all_excluded)
    return resolve_mirror_from_bodies(part, bodies, feature, all_excluded)
