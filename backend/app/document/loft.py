"""OCCT geometry construction for `LoftFeature`
(`docs/gear-design/04-helical-herringbone-loft.md`, part 4b) - the
OCCT-dependent counterpart of the general Loft's own payload-shape
validation in `app.document.router`. Mirrors `app.document.sweep`'s own
overall shape (a standalone Feature lofting/sweeping an existing Sketch
Profile, not gear-specific - see that module's own docstring) rather than
`app.document.gear`'s OCCT-free/OCCT-dependent split, since - like Sweep -
Loft has no gear-math-shaped pure computation of its own to split out; the
one piece of real math here (the reference-point alignment angle) is a
two-line `atan2`, folded directly into this module rather than a separate
`loft_math.py` with nothing else in it.

**Verification status**: like every other genuinely new OCCT technique in
this project, this module needs a real on-device/CI pass before being
trusted (this repo's dev sandbox has never had `pythonocc-core` installed -
see `docs/gear-design/01-gear-math-core.md`'s own note on this) - check
`docs/status.md`'s dated entries for whether that pass has actually run by
the time this is read.

**Thin/open-chain loft (`LoftFeature.thickness`)**: a second, later
addition alongside the original closed-profile solid loft above - lofts
between 2+ *open* chains (`app.sketch.profile.detect_open_chain`) into a
shell (`BRepOffsetAPI_ThruSections(isSolid=False, ...)`) and thickens that
shell into a solid via `BRepOffsetAPI_MakeThickSolid.MakeThickSolidBySimple`
- the standard OCCT idiom for turning an open surface into a genuine thin-
walled solid (the "Thicken" operation most CAD tools expose), used here
instead of a from-scratch offset-and-stitch implementation. This is its own
genuinely new OCCT technique, verified so far only by code review (same
`pythonocc-core`-unavailable sandbox constraint as the rest of this module)
- treat it with the same "needs a real on-device/CI pass" caution as
everything else in this docstring until `docs/status.md` says otherwise.
"""

import logging
import math
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Section
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakePolygon,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Transform,
)
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid, BRepOffsetAPI_ThruSections
from OCC.Core.Bnd import Bnd_Box
from OCC.Core.BRepBndLib import brepbndlib
from OCC.Core.Geom import Geom_BezierCurve
from OCC.Core.GProp import GProp_GProps
from OCC.Core.gp import gp_Ax1, gp_Circ, gp_Dir, gp_Pln, gp_Pnt, gp_Trsf
from OCC.Core.TColgp import TColgp_Array1OfPnt
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, TopoDS_Wire, topods

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    arc_axis,
    basis_point_to_world,
    compute_part_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.models import LoftFeature, LoftSection, Part, ResolvedPlane, SketchFeature
from app.document.plane_geometry import is_mirrored_basis
from app.sketch.models import Arc, Sketch, SketchEntityType, Spline
from app.sketch.profile import (
    OpenChain,
    OpenChainStatus,
    Profile,
    ProfileStatus,
    detect_open_chain,
    detect_profile,
)
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

logger = logging.getLogger(__name__)


def _invalid_loft_section(index: int, detail: str) -> HTTPException:
    """A `sections` entry that can't be resolved into one loftable wire -
    mirrors `app.document.sweep._invalid_path_ref`'s own "client-supplied-
    parameters problem" 422 convention, indexed so the client can point at
    which section is wrong (`LoftFeature.sections` has no id of its own to
    name instead - see that dataclass's own docstring)."""
    return HTTPException(status_code=422, detail={"type": "invalid_loft_section", "index": index, "detail": detail})


def _loft_failed(detail: str) -> HTTPException:
    """A structurally-valid set of sections that OCCT nonetheless couldn't
    loft between - mirrors `app.document.sweep._sweep_failed`'s own
    "resolvable parameters, unresolvable geometry" distinction."""
    return HTTPException(status_code=422, detail={"type": "loft_failed", "detail": detail})


@dataclass
class _ResolvedClosedSection:
    sketch: Sketch
    basis: ResolvedPlane
    profile: Profile
    reference_angle: float | None


def _resolve_closed_section(
    part: Part,
    section: LoftSection,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
    index: int,
) -> _ResolvedClosedSection:
    """Resolves one `LoftSection` into its own Sketch/basis/Profile/
    reference-angle - mirrors `app.document.sweep._resolve_path_segment`'s
    own per-entry resolution shape (each entry resolved entirely
    independently: its own owning SketchFeature, its own basis), narrowed
    (unlike a MultiProfile-tolerant Extrude/Sweep) to require selecting
    down to exactly one profile - a Loft section is a single 2D cross-
    section, not several disjoint ones.

    `section.reference_point`, if set, must be a `POINT` entity in this
    *same* section's own Sketch (never a different Sketch - there would be
    no shared local frame to measure an angle in otherwise) - resolved to
    its local `(x, y)` and reduced to `atan2(y, x)`, the angle from this
    Sketch's own local origin `LoftFeature`/`LoftSection`'s own docstrings
    describe as the alignment technique's rotation center."""
    sketch_feature = part.get_feature(section.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise _invalid_loft_section(index, "sketch_feature_id does not refer to a SketchFeature in this Part")

    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    # Sketcher-roadmap Phase 7 (2D Pattern/Mirror): see extrude.py's
    # identical call site for why this re-expansion is needed - a
    # no-instance Sketch is a no-op, returning the same object.
    sketch = sketch.expand_pattern_and_mirror_instances()
    if result.status not in EXTRUDABLE_STATUSES:
        raise _invalid_loft_section(index, f"sketch has no closed profile (status={result.status.value})")

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    profiles = select_profiles(candidates, section.profile_refs)
    if len(profiles) != 1:
        raise _invalid_loft_section(
            index, f"a Loft section must select exactly one profile, got {len(profiles)}"
        )
    profile = profiles[0]
    if profile.inner_loops:
        raise _invalid_loft_section(
            index, "a profile with holes is not supported as a Loft section (v1 scope)"
        )

    reference_angle = None
    if section.reference_point is not None:
        ref = section.reference_point
        if ref.entity_type != SketchEntityType.POINT:
            raise _invalid_loft_section(index, "reference_point must reference a Point entity")
        if ref.sketch_id != sketch_feature.sketch_id:
            raise _invalid_loft_section(index, "reference_point must belong to this section's own Sketch")
        try:
            point = resolve_sketch_entity(ref)
        except HTTPException:
            raise _invalid_loft_section(index, "reference_point does not resolve to a Point") from None
        reference_angle = math.atan2(point.y, point.x)

    return _ResolvedClosedSection(sketch=sketch, basis=basis, profile=profile, reference_angle=reference_angle)


@dataclass
class _ResolvedOpenSection:
    sketch: Sketch
    basis: ResolvedPlane
    chain: OpenChain
    reference_angle: float | None


def _resolve_open_section(
    part: Part,
    section: LoftSection,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
    index: int,
) -> _ResolvedOpenSection:
    """The open-chain counterpart to `_resolve_closed_section`, used only
    when `LoftFeature.thickness` is set (a thin/sheet Loft between open
    profiles rather than a solid Loft between closed ones) - same overall
    resolution shape (own SketchFeature, own basis, own `reference_point`
    alignment angle), narrowed to require a single open chain
    (`app.sketch.profile.detect_open_chain`) instead of a single closed
    Profile. `section.profile_refs` has no open-chain analogue (a sketch
    with 2+ disjoint open chains is rejected outright as ambiguous, rather
    than letting the caller disambiguate) - narrower than the closed-profile
    path deliberately, matching this being a newer, more conservatively
    scoped addition."""
    sketch_feature = part.get_feature(section.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise _invalid_loft_section(index, "sketch_feature_id does not refer to a SketchFeature in this Part")

    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_open_chain(sketch)
    sketch = sketch.expand_pattern_and_mirror_instances()
    if result.status != OpenChainStatus.SINGLE_CHAIN:
        raise _invalid_loft_section(
            index, f"sketch has no single open chain to loft (status={result.status.value})"
        )

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    chain = result.chain

    reference_angle = None
    if section.reference_point is not None:
        ref = section.reference_point
        if ref.entity_type != SketchEntityType.POINT:
            raise _invalid_loft_section(index, "reference_point must reference a Point entity")
        if ref.sketch_id != sketch_feature.sketch_id:
            raise _invalid_loft_section(index, "reference_point must belong to this section's own Sketch")
        try:
            point = resolve_sketch_entity(ref)
        except HTTPException:
            raise _invalid_loft_section(index, "reference_point does not resolve to a Point") from None
        reference_angle = math.atan2(point.y, point.x)

    return _ResolvedOpenSection(sketch=sketch, basis=basis, chain=chain, reference_angle=reference_angle)


def wire_for_open_chain(sketch: Sketch, chain: OpenChain, basis: ResolvedPlane) -> TopoDS_Wire:
    """Builds an *unclosed* wire from `chain` - the open-profile counterpart
    to `app.document.extrude.wire_for_profile`, used only for a thin/sheet
    Loft section (see `_resolve_open_section`). Reuses the identical
    Line/Arc/Spline per-hop edge construction `wire_for_profile`'s own
    mixed-chain branch uses, just walking `chain.line_ids` (one fewer entry
    than `chain.point_ids`, no wrap-around hop) instead of a closed
    Profile's `line_ids`/`point_ids` pair."""
    if not any(isinstance(sketch.entities.get(entity_id), (Arc, Spline)) for entity_id in chain.line_ids):
        polygon = BRepBuilderAPI_MakePolygon()
        for point_id in chain.point_ids:
            point = sketch.points[point_id]
            polygon.Add(basis_point_to_world(basis, point.x, point.y))
        return polygon.Wire()  # deliberately no .Close() - this is what leaves the wire open

    wire_maker = BRepBuilderAPI_MakeWire()
    for i, entity_id in enumerate(chain.line_ids):
        entity = sketch.entities[entity_id]
        if isinstance(entity, Arc):
            center = sketch.points[entity.center_point_id]
            radius = entity.radius(sketch.points)
            axis = arc_axis(basis, center.x, center.y)
            start = sketch.points[entity.start_point_id]
            end = sketch.points[entity.end_point_id]
            # Mirrors wire_for_profile's own identical P1/P2 swap - see
            # that function's own doc comment for why a mirrored basis
            # needs it.
            p1, p2 = (end, start) if is_mirrored_basis(basis) else (start, end)
            edge = BRepBuilderAPI_MakeEdge(
                gp_Circ(axis, radius),
                basis_point_to_world(basis, p1.x, p1.y),
                basis_point_to_world(basis, p2.x, p2.y),
            ).Edge()
            wire_maker.Add(edge)
        elif isinstance(entity, Spline):
            segments = entity.segments()
            if chain.point_ids[i] == entity.through_point_ids[-1]:
                segments = [(p3, p2, p1, p0) for (p0, p1, p2, p3) in reversed(segments)]
            for p0_id, p1_id, p2_id, p3_id in segments:
                poles = TColgp_Array1OfPnt(1, 4)
                for pole_index, point_id in enumerate((p0_id, p1_id, p2_id, p3_id), start=1):
                    point = sketch.points[point_id]
                    poles.SetValue(pole_index, basis_point_to_world(basis, point.x, point.y))
                curve = Geom_BezierCurve(poles)
                wire_maker.Add(BRepBuilderAPI_MakeEdge(curve).Edge())
        else:
            a = sketch.points[chain.point_ids[i]]
            b = sketch.points[chain.point_ids[i + 1]]
            edge = BRepBuilderAPI_MakeEdge(
                basis_point_to_world(basis, a.x, a.y),
                basis_point_to_world(basis, b.x, b.y),
            ).Edge()
            wire_maker.Add(edge)
    return wire_maker.Wire()


def _rotate_wire(wire: TopoDS_Wire, basis: ResolvedPlane, angle: float) -> TopoDS_Wire:
    """Rotates `wire` (already embedded in world space through `basis`) by
    `angle` radians about the axis through `basis.origin` in the direction
    `basis.normal` - i.e. about the section's own local origin, within its
    own plane. Mathematically identical to rotating the profile's real
    local (x, y) coordinates by `angle` *before* embedding through `basis`
    (`basis_point_to_world`'s embedding is linear in (x, y), and a
    rotation within the same plane the embedding's image lies in commutes
    with it) - this is the "explicit pre-alignment transform" `LoftSection.
    reference_point`'s own docstring describes, built by transforming the
    already-constructed wire (from the ordinary, unmodified `wire_for_
    profile` - no reordering, matching `docs/gear-design/04-helical-
    herringbone-loft.md`'s own spike finding that `ThruSections`'
    correspondence doesn't depend on wire order anyway) rather than
    rebuilding it from rotated points."""
    ox, oy, oz = basis.origin
    nx, ny, nz = basis.normal
    trsf = gp_Trsf()
    trsf.SetRotation(gp_Ax1(gp_Pnt(ox, oy, oz), gp_Dir(nx, ny, nz)), angle)
    return topods.Wire(BRepBuilderAPI_Transform(wire, trsf, True).Shape())


def _mid_section_warnings(solid: TopoDS_Shape, basis_a: ResolvedPlane, basis_b: ResolvedPlane) -> list[str]:
    """A real, best-effort geometric self-intersection check for the lofted
    `solid` - `docs/gear-design/04-helical-herringbone-loft.md`'s own spike
    (`Result 2`) found `IsDone()`/`BRepCheck_Analyzer`/`BOPAlgo_CheckerSI`
    are all weak signals for a twisted loft's self-intersection (all three
    passed on a case independently confirmed bad by a mid-height-section
    area check), so this project's own established response is a *real*
    geometric check, not those alone.

    Cuts `solid` at the representative plane through the midpoint between
    `basis_a`/`basis_b`'s own world origins, normal to `basis_a`'s own
    normal (the common, and gear-relevant, case of two parallel-plane
    sections - for a fully general non-parallel-plane Loft this specific
    plane may not be representative or may not intersect `solid` in a
    single clean loop at all, in which case this check simply produces no
    finding rather than a false alarm). Unlike the spike's own check (which
    could compare against a *known* expected area for two rotated copies
    of the identical profile), a general Loft has no such rotation-
    invariant reference value between two possibly-*different* profiles -
    this instead only flags the unambiguous failure modes the spike's own
    "blade" profile actually exhibited: the section not reassembling into
    one simple closed loop at all, or reassembling into a wire that cannot
    bound a face, or a resulting face degenerate (near-zero area) relative
    to the solid's own bounding-box scale. This is deliberately a coarser,
    honestly-partial check (it would not catch a section that stays a
    single simple loop but is grossly *inflated*, e.g. the spike's own
    5.5x-area case) - a non-blocking warning, never a hard failure, per
    `00-conventions.md`'s "geometrically-valid-but-questionable result"
    convention (`ThruSections` itself already reported `IsDone()`, so there
    is a real shape either way)."""
    try:
        ox_a, oy_a, oz_a = basis_a.origin
        ox_b, oy_b, oz_b = basis_b.origin
        mid_point = gp_Pnt((ox_a + ox_b) / 2, (oy_a + oy_b) / 2, (oz_a + oz_b) / 2)
        nx, ny, nz = basis_a.normal
        section = BRepAlgoAPI_Section(solid, gp_Pln(mid_point, gp_Dir(nx, ny, nz)))
        section.Build()
        if not section.IsDone():
            return []

        wire_maker = BRepBuilderAPI_MakeWire()
        explorer = TopExp_Explorer(section.Shape(), TopAbs_EDGE)
        edge_count = 0
        while explorer.More():
            wire_maker.Add(topods.Edge(explorer.Current()))
            edge_count += 1
            explorer.Next()
        if edge_count == 0:
            return []
        if not wire_maker.IsDone():
            return [
                "Loft's mid-height cross-section did not reassemble into a single closed loop - "
                "possible self-intersection between two of its sections"
            ]

        face_maker = BRepBuilderAPI_MakeFace(wire_maker.Wire())
        if not face_maker.IsDone():
            return [
                "Loft's mid-height cross-section is not a simple closed region - possible "
                "self-intersection between two of its sections"
            ]

        props = GProp_GProps()
        brepgprop.SurfaceProperties(face_maker.Face(), props)
        bbox = Bnd_Box()
        brepbndlib.Add(solid, bbox)
        xmin, ymin, zmin, xmax, ymax, zmax = bbox.Get()
        diagonal = math.dist((xmin, ymin, zmin), (xmax, ymax, zmax))
        if diagonal > 0 and props.Mass() < (diagonal**2) * 1e-6:
            return [
                "Loft's mid-height cross-section is degenerate (near-zero area) - likely "
                "self-intersection between two of its sections"
            ]
    except Exception:  # noqa: BLE001 - best-effort diagnostic only, never fails the Feature itself
        logger.warning("Loft self-intersection check itself failed - skipping (best-effort only)", exc_info=True)
    return []


def _wires_from_resolved(resolved: list) -> list[TopoDS_Wire]:
    """Shared twist-alignment + wire-building step for both the closed-solid
    and open-thickness paths below: each resolved section's own wire
    (`wire_for_profile` for a closed `_ResolvedClosedSection`,
    `wire_for_open_chain` for an open `_ResolvedOpenSection` - both entries
    carry a `.sketch`/`.basis`/`.reference_angle` in the same shape, only
    the middle field differs) is built, then rotated into alignment with
    the first section's own `reference_angle` if both are set (see
    `_rotate_wire`'s own docstring)."""
    reference_angle_0 = resolved[0].reference_angle
    wires: list[TopoDS_Wire] = []
    for index, entry in enumerate(resolved):
        wire = (
            wire_for_profile(entry.sketch, entry.profile, entry.basis)
            if isinstance(entry, _ResolvedClosedSection)
            else wire_for_open_chain(entry.sketch, entry.chain, entry.basis)
        )
        if index > 0 and reference_angle_0 is not None and entry.reference_angle is not None:
            twist = reference_angle_0 - entry.reference_angle
            wire = _rotate_wire(wire, entry.basis, twist)
        wires.append(wire)
    return wires


def resolve_loft_from_bodies(
    feature: LoftFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Shape, list[str]]:
    """The raw lofted solid for `feature`, plus any non-blocking self-
    intersection warnings (`_mid_section_warnings`) - Boss/Cut dispatch
    against `target_body_ids` is the caller's job (`app.document.extrude.
    _apply_boss_or_cut`, shared with every other Feature type), same
    contract as `app.document.sweep.resolve_sweep_from_bodies`, except this
    never returns `None` - unlike a Sketch-backed Sweep, a `LoftFeature`
    with fewer than 2 resolvable sections has no "temporarily nothing to
    build" state to tolerate (mirrors `resolve_gear_from_bodies`'s own
    "always raise" reasoning), so `sections` having at least 2 entries is
    validated eagerly by the router before this is ever reached, and each
    individual section either resolves or raises `invalid_loft_section`.

    `feature.thickness is None` is the original, closed-profile path: each
    section resolves to a closed Profile (`_resolve_closed_section`), and
    `BRepOffsetAPI_ThruSections(isSolid=True, ...)` lofts them directly into
    a solid. `feature.thickness is not None` is the newer open-chain path:
    each section resolves to a single open chain (`_resolve_open_section`),
    `ThruSections(isSolid=False, ...)` lofts them into an open shell
    instead, and `BRepOffsetAPI_MakeThickSolid.MakeThickSolidBySimple`
    thickens that shell into a solid by `feature.thickness` (its sign
    picking which side of the shell the material is added to) - the
    standard OCCT idiom for turning an open lofted surface into a genuine
    thin-walled solid, matching what every mainstream CAD tool calls
    "Thicken". The router (`_validate_loft_thickness`) already rejects a
    zero `thickness` before this is ever reached."""
    if len(feature.sections) < 2:
        raise _invalid_loft_section(0, "a Loft needs at least 2 sections")

    if feature.thickness is None:
        resolved = [
            _resolve_closed_section(part, section, bodies_so_far, excluded_feature_ids, index)
            for index, section in enumerate(feature.sections)
        ]
        wires = _wires_from_resolved(resolved)

        loft_maker = BRepOffsetAPI_ThruSections(True, feature.ruled)
        for wire in wires:
            loft_maker.AddWire(wire)
        loft_maker.Build()
        if not loft_maker.IsDone():
            raise _loft_failed("could not loft between the given sections")
        solid = loft_maker.Shape()

        warnings = _mid_section_warnings(solid, resolved[0].basis, resolved[-1].basis)
        return solid, warnings

    resolved = [
        _resolve_open_section(part, section, bodies_so_far, excluded_feature_ids, index)
        for index, section in enumerate(feature.sections)
    ]
    wires = _wires_from_resolved(resolved)

    loft_maker = BRepOffsetAPI_ThruSections(False, feature.ruled)
    for wire in wires:
        loft_maker.AddWire(wire)
    loft_maker.Build()
    if not loft_maker.IsDone():
        raise _loft_failed("could not loft a surface between the given open sections")
    shell = loft_maker.Shape()

    thicken = BRepOffsetAPI_MakeThickSolid()
    thicken.MakeThickSolidBySimple(shell, feature.thickness)
    thicken.Build()
    if not thicken.IsDone():
        raise _loft_failed("could not thicken the lofted surface by the given thickness")
    solid = thicken.Shape()

    warnings = _mid_section_warnings(solid, resolved[0].basis, resolved[-1].basis)
    return solid, warnings


def resolve_loft(
    part: Part, feature: LoftFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[TopoDS_Shape, list[str]]:
    """Fresh entry point for the router's create/update validation - mirrors
    `app.document.sweep.resolve_sweep`'s own self-exclusion convention
    exactly (computes `bodies` as if `feature` weren't in `part.features`
    yet)."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_loft_from_bodies(feature, part, bodies, all_excluded)
