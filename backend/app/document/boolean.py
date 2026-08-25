"""OCCT geometry construction for BooleanFeature (Boolean family,
Subtract/Common - Merge was the first entry, handled inline in
app.document.extrude via `_fuse_realized_instances`; Split follows in
later work).

Closest existing ancestor is `app.document.extrude._apply_boss_or_cut`'s
own Cut branch: fold a solid into/out of a set of target Bodies via
`BRepAlgoAPI_Cut`, then re-split and (re)register the result via
`_register_solids`. The key difference here is that *both* sides are
already-existing, already-registered Bodies, not one freshly-computed
transient solid - so unlike Cut (which always implicitly discards its
transient solid, since it was never a registered Body to begin with),
Subtract/Common's own tool Bodies are real Bodies a user might want kept
around afterward, hence `BooleanFeature.consume_tool_bodies` (see that
class's own docstring).

This module needs `_register_solids` from extrude.py at module level, so
(mirroring app.document.chamfer/fillet's own identical circular-import
workaround - see chamfer.py's own doc comment) extrude.py imports this
module back via a function-local import inside `_apply_feature_to_bodies`
instead.
"""

import logging

from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common, BRepAlgoAPI_Cut
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import _register_solids
from app.document.models import BooleanFeature, BooleanOperation

logger = logging.getLogger(__name__)

_OCCT_BOOLEAN_OP = {
    BooleanOperation.SUBTRACT: BRepAlgoAPI_Cut,
    BooleanOperation.COMMON: BRepAlgoAPI_Common,
}


def apply_boolean_to_bodies(bodies: dict[str, TopoDS_Shape], feature: BooleanFeature) -> None:
    """Applies `feature` in place against `bodies` - for each of `feature.
    target_body_ids` that currently exists, folds in every currently-
    existing `feature.tool_body_ids` entry's *current* shape in turn (via
    `BRepAlgoAPI_Cut` for SUBTRACT, `BRepAlgoAPI_Common` for COMMON), then
    re-splits and (re)registers the result under that same target id via
    `_register_solids` - identical to `_apply_boss_or_cut`'s own Cut
    branch's own delete-then-`_register_solids` sequencing, generalized
    from "one transient solid" to "every tool Body's shape, folded in
    turn". Every target is folded against the *same* pre-fold tool shapes
    (tool bodies are never touched mid-loop, only afterward - see below),
    so which target happens to be processed first never changes the
    result for any other target.

    A `target_body_ids`/`tool_body_ids` entry not currently present in
    `bodies` (hidden via `excluded_feature_ids`, or genuinely deleted) is
    skipped with a warning rather than raising - the router's own create/
    update endpoints validate eagerly instead (`_validate_boolean_body_
    ids`), so this fallback only ever matters for topology drift after the
    fact, same resilience convention as Merge/Fillet/Chamfer/Revolve/Sweep
    (see `app.document.extrude._apply_feature_to_bodies`'s own docstring).
    If every tool body is currently missing, there is nothing to fold in
    for any target, so the whole Feature is skipped.

    `consume_tool_bodies` (default True) is applied once, after every
    target has been processed: True deletes each currently-existing tool
    body from `bodies` (generalizing `_apply_boss_or_cut`'s Cut branch,
    which always implicitly discards its own transient tool solid, to be
    conditional here); False leaves every tool body registered and
    untouched, exactly as it already was before this Feature ran."""
    tool_ids = [tid for tid in feature.tool_body_ids if tid in bodies]
    if len(tool_ids) < len(feature.tool_body_ids):
        missing_tool_ids = [tid for tid in feature.tool_body_ids if tid not in bodies]
        logger.warning(
            "BooleanFeature %s: tool body ids %s currently do not exist", feature.id, missing_tool_ids
        )
    if not tool_ids:
        logger.warning("Skipping BooleanFeature %s: no tool bodies currently exist", feature.id)
        return

    occt_op = _OCCT_BOOLEAN_OP[feature.operation]
    for target_id in feature.target_body_ids:
        if target_id not in bodies:
            logger.warning(
                "Skipping BooleanFeature %s: target body %s does not exist", feature.id, target_id
            )
            continue
        shape = bodies[target_id]
        for tool_id in tool_ids:
            shape = occt_op(shape, bodies[tool_id]).Shape()
        del bodies[target_id]
        _register_solids(bodies, target_id, shape)

    if feature.consume_tool_bodies:
        for tool_id in tool_ids:
            bodies.pop(tool_id, None)
