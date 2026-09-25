"""OCCT geometry construction for ShellFeature - hollows a solid Body into a
thin-walled shell, opening up the faces named in `faces_to_remove` and
giving every remaining face a uniform wall `thickness`.

Reuses `app.document.extrude._thin_wall_solid_for_direction` (the helper
the thin-wall Extrude path already uses) rather than calling
`app.document.shell_ops.thicken_capped_solid_to_solid` directly: that
helper is already generic over "a closed solid + a `TopTools_ListOfShape`
of faces to open + a signed thickness + a `ThicknessDirection`", with no
Extrude-specific state, so Shell gets the kernel-confirmed OUTWARD/INWARD/
SYMMETRIC handling (including SYMMETRIC's fuse-and-sanity-check) for free.
Underneath, it is `BRepOffsetAPI_MakeThickSolid.MakeThickSolidByJoin` with
real `ClosingFaces` - OCCT's textbook "shell this solid" call.

Mirrors `app.document.chamfer`'s two-function shape and its circular-import
workaround exactly: this module needs `compute_part_bodies`/
`resolve_subshape_from_bodies` from extrude.py at module level, so
extrude.py imports this module back via a function-local import inside
`_apply_feature_to_bodies_impl` instead.
"""

from fastapi import HTTPException
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopoDS import TopoDS_Shape
from OCC.Core.TopTools import TopTools_ListOfShape

from app.document.extrude import (
    _thin_wall_solid_for_direction,
    compute_part_bodies,
    resolve_subshape_from_bodies,
)
from app.document.models import Part, ShellFeature, SubShapeRef, SubShapeType, ThicknessDirection

# An INWARD Shell must remove at least this fraction of the Body's own
# volume - see the check at the end of `resolve_shell_from_bodies`.
_INWARD_MIN_REMOVED_FRACTION = 1e-6


def _volume(shape: TopoDS_Shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return abs(props.Mass())


def _shell_mixed_body_selection(body_ids: set[str]) -> HTTPException:
    """Every `faces_to_remove` entry must name a face of `feature.body_id`
    itself - `MakeThickSolidByJoin` hollows one solid at a time, so a face
    from any other Body can never be one of its closing faces. Same error
    shape as `app.document.chamfer._mixed_body_selection`."""
    return HTTPException(
        status_code=422,
        detail={"type": "mixed_body_selection", "body_ids": sorted(body_ids)},
    )


def _shell_failed(body_id: str, detail: str) -> HTTPException:
    """A structurally-valid Shell (real faces on a real Body, a positive
    thickness) that OCCT nonetheless couldn't hollow - most commonly a
    wall thickness too large for the Body's own geometry (INWARD walls
    colliding), or a face selection `MakeThickSolidByJoin` can't offset.
    422, not an uncaught OCCT exception - mirrors `app.document.chamfer.
    _chamfer_failed`."""
    return HTTPException(
        status_code=422, detail={"type": "shell_failed", "body_id": body_id, "detail": detail}
    )


def resolve_shell_from_bodies(
    bodies: dict[str, TopoDS_Shape],
    feature: ShellFeature,
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-shell shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (mirrors
    `app.document.chamfer.resolve_chamfer_from_bodies`). The cross-body
    check runs before any ref is resolved, same order as Chamfer."""
    ref_body_ids = {ref.body_id for ref in feature.faces_to_remove}
    if ref_body_ids and ref_body_ids != {feature.body_id}:
        raise _shell_mixed_body_selection(ref_body_ids | {feature.body_id})

    closing_faces = TopTools_ListOfShape()
    for ref in feature.faces_to_remove:
        closing_faces.Append(resolve_subshape_from_bodies(bodies, ref))

    # A BODY ref resolves to the whole Body's shape, or raises the same
    # structured `missing_reference` 422 every other stale ref does.
    solid = resolve_subshape_from_bodies(
        bodies, SubShapeRef(body_id=feature.body_id, shape_type=SubShapeType.BODY, index=0)
    )

    try:
        result = _thin_wall_solid_for_direction(
            solid, closing_faces, feature.thickness, feature.thickness_direction
        )
    except (ValueError, RuntimeError) as exc:
        raise _shell_failed(feature.body_id, str(exc)) from None
    if result is None:
        raise _shell_failed(feature.body_id, "symmetric shell did not produce a valid solid")
    if feature.thickness_direction == ThicknessDirection.INWARD and _volume(result) >= _volume(solid) * (
        1 - _INWARD_MIN_REMOVED_FRACTION
    ):
        # Confirmed against a real kernel (20x20x10 box, top face open):
        # an INWARD wall at/past the Body's own half-width either fails
        # outright or - for a much larger value, e.g. 50mm - silently comes
        # back "valid" with the *original, unhollowed* volume. A Shell that
        # removed no material is never what was asked for, so fail closed.
        raise _shell_failed(feature.body_id, "wall thickness leaves no cavity inside the body")
    return feature.body_id, result


def resolve_shell(
    part: Part, feature: ShellFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.chamfer.resolve_chamfer` exactly, including the self-
    exclusion of `feature.id` (a Shell modifies a Body in place, so
    re-resolving against its own prior output would double-apply it)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_shell_from_bodies(bodies, feature)
