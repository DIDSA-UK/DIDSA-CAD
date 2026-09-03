"""Direct Editing family, first entry (see `docs/direct-editing-scope.md`):
DeleteBodyFeature removes every currently-existing `body_ids` entry from a
Part's Bodies.

Closest existing ancestor is `app.document.boolean.apply_boolean_to_bodies`'s
own `consume_tool_bodies` branch (a plain `bodies.pop(...)` loop) -
generalized here to be the Feature's entire effect rather than a side
option of a fold. Unlike every other Direct Editing Feature (Scale/Move
Body/Move Face/Delete Face), a DeleteBodyFeature has no OCCT geometry of
its own to construct or fail, so (mirroring `app.document.boolean`'s own
"no per-instance geometry to fail" reasoning) there is no `resolve_*`
function here - the router's create/update endpoints validate payload shape
only (`app.document.router._validate_delete_body_ids`), and this module's
sole function is the recompute-time application.
"""

import logging

from OCC.Core.TopoDS import TopoDS_Shape

from app.document.models import DeleteBodyFeature

logger = logging.getLogger(__name__)


def apply_delete_body_to_bodies(bodies: dict[str, TopoDS_Shape], feature: DeleteBodyFeature) -> None:
    """Removes every currently-existing `feature.body_ids` entry from
    `bodies` in place. A `body_ids` entry not currently present (hidden via
    `excluded_feature_ids`, or genuinely already removed by an earlier
    Delete Body/Boolean-consume) is skipped with a warning rather than
    raising - same resilience convention as `apply_boolean_to_bodies`'s own
    tool-body removal and every other Direct Editing/Boolean-family
    function in `app.document.extrude._apply_feature_to_bodies`. The
    router's own create/update endpoints validate eagerly instead (`_
    validate_delete_body_ids`), so this fallback only ever matters for
    topology drift after the fact."""
    missing = [bid for bid in feature.body_ids if bid not in bodies]
    if missing:
        logger.warning("DeleteBodyFeature %s: body ids %s currently do not exist", feature.id, missing)
    for body_id in feature.body_ids:
        bodies.pop(body_id, None)
