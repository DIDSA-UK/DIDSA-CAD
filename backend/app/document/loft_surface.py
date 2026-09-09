"""OCCT geometry construction for `LoftSurfaceFeature` - the Loft-Surface
counterpart of `app.document.loft`'s own `LoftFeature` construction:
directly reuses `app.document.loft`'s section-resolution helpers
(`_resolve_closed_section`, `_resolve_open_section`, `_wires_from_resolved`,
`_apply_alignment_point_translation`, `_mid_section_warnings`) unmodified -
all of them are already section/wire-shaped, never solid-shaped, so nothing
about them needs to change for a surface-only result.

Unlike `LoftFeature`, there is no `thickness` field here to switch between
the closed-profile and open-chain paths - `LoftSurfaceFeature`'s own
dispatcher instead *probes*: try `_resolve_closed_section` on every section
first (the common case), and if that raises for any section, fall back to
`_resolve_open_section` on every section instead (mirrors `LoftFeature`'s
own closed-vs-open split, just driven by what the sections actually resolve
to rather than a persisted flag - `LoftSurfaceFeature` has no equivalent
flag to switch on). `BRepOffsetAPI_ThruSections(False, ...)` - `isSolid`
always `False` - lofts either path into an open shell; there is no thicken
step here at all (a user wanting a solid chains the Thicken tool, Phase 2,
onto this Feature's own output afterward).

Follows `LoftFeature`'s own "always raise, never return None" contract
(`resolve_loft_from_bodies`'s own reasoning: fewer than 2 resolvable
sections, or a section that can't be resolved as either closed or open,
has no legitimate "temporarily nothing to build" state to tolerate)."""

import logging

from fastapi import HTTPException
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_ThruSections
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.extrude import compute_part_bodies
from app.document.loft import (
    _apply_alignment_point_translation,
    _harmonize_section_wire_edge_counts,
    _mid_section_warnings,
    _resolve_closed_or_edge_section,
    _resolve_open_or_edge_section,
    _wires_from_resolved,
)
from app.document.models import LoftSurfaceFeature, Part

logger = logging.getLogger(__name__)


def _invalid_loft_surface_section(index: int, detail: str) -> HTTPException:
    """Mirrors `app.document.loft._invalid_loft_section`'s own shape - a
    `sections` entry that can't be resolved into one loftable wire, indexed
    so the client can point at which section is wrong. Own distinct `type`
    string per this package's own convention (never `invalid_loft_section` -
    that belongs to `LoftFeature`)."""
    return HTTPException(
        status_code=422, detail={"type": "invalid_loft_surface_section", "index": index, "detail": detail}
    )


def _loft_surface_failed(detail: str) -> HTTPException:
    """Mirrors `app.document.loft._loft_failed`'s own "structurally-valid
    sections OCCT nonetheless couldn't loft between" distinction - own
    distinct `type` string."""
    return HTTPException(status_code=422, detail={"type": "loft_surface_failed", "detail": detail})


def _resolve_sections(
    part: Part,
    feature: LoftSurfaceFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> list:
    """Probes closed-profile resolution for every section first (the common
    case); falls back to open-chain resolution for every section only if
    that fails for at least one - see this module's own docstring for why
    this is a probe rather than a persisted flag the way `LoftFeature.
    thickness` drives its own closed-vs-open dispatch."""
    try:
        return [
            _resolve_closed_or_edge_section(part, section, bodies_so_far, excluded_feature_ids, index)
            for index, section in enumerate(feature.sections)
        ]
    except HTTPException:
        return [
            _resolve_open_or_edge_section(part, section, bodies_so_far, excluded_feature_ids, index)
            for index, section in enumerate(feature.sections)
        ]


def resolve_loft_surface_from_bodies(
    feature: LoftSurfaceFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The raw lofted shell for `feature`, plus any non-blocking self-
    intersection warnings (`app.document.loft._mid_section_warnings`) -
    mirrors `app.document.loft.resolve_loft_from_bodies`'s own contract
    exactly, except this never has a solid path at all: `sections` having
    at least 2 entries is validated eagerly by the router before this is
    ever reached, and each individual section either resolves (as closed or
    open, via `_resolve_sections`' own probe) or raises `invalid_loft_
    surface_section`."""
    if len(feature.sections) < 2:
        raise _invalid_loft_surface_section(0, "a Loft Surface needs at least 2 sections")

    resolved = _resolve_sections(part, feature, bodies_so_far, excluded_feature_ids)
    wires = _wires_from_resolved(resolved)
    wires = _apply_alignment_point_translation(
        feature, resolved, wires, part, bodies_so_far, excluded_feature_ids
    )
    wires = _harmonize_section_wire_edge_counts(wires)

    loft_maker = BRepOffsetAPI_ThruSections(False, feature.ruled)
    for wire in wires:
        loft_maker.AddWire(wire)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _loft_surface_failed("could not loft a surface between the given sections")
    shell = loft_maker.Shape()

    warnings = _mid_section_warnings(shell, resolved[0].basis, resolved[-1].basis)
    return shell, warnings


def resolve_loft_surface(
    part: Part, feature: LoftSurfaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.loft.resolve_loft`'s own self-exclusion convention
    exactly."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_loft_surface_from_bodies(feature, part, bodies, all_excluded)
