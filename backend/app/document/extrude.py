"""OCCT geometry construction for ExtrudeFeature (Boss/Cut) - the Extrude
module described in the project brief's section 4.3, kept separate from
app.document.router the same way app.document.mesh's tessellation logic is.

Knows nothing about Sketch internals beyond what app.sketch already exposes
publicly (Profile, detect_profile, Sketch.points/entities) - mirrors the
brief's "Knows nothing about Sketch internals" requirement for Extrude.
"""

import logging
import math

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeFace,
    BRepBuilderAPI_MakePolygon,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Transform,
)
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.Geom import Geom_BezierCurve
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Elips, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.TColgp import TColgp_Array1OfPnt
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED, TopAbs_SOLID, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Vertex, TopoDS_Wire, topods
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.graph import base_feature_id, build_feature_graph, topological_order
from app.document.plane_geometry import is_mirrored_basis
from app.document.models import (
    ChamferFeature,
    ExtrudeFeature,
    ExtrudeType,
    FilletFeature,
    ImportFeature,
    Part,
    ResolvedPlane,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
    SweepFeature,
    SweepMode,
)
from app.sketch.models import (
    Arc,
    Circle,
    Ellipse,
    Line,
    Sketch,
    SketchEntityRef,
    SketchEntityType,
    Spline,
    TextEntity,
)
from app.sketch.profile import Profile, ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity
from app.sketch.text_geometry import text_contour_wire

logger = logging.getLogger(__name__)

# C1/C2: an ExtrudeFeature's backing Sketch is extrudable whenever its
# Profile detection reports a usable boundary - a single nested profile
# (holes folded in) or a MultiProfile of disjoint outer profiles (each with
# its own holes). Every other status (NO_LOOP, BRANCH, INVALID_NESTING) has
# nothing extrudable to offer.
#
# Prompt F: public (no leading underscore) since app.document.revolve needs
# the identical set for its own Profile-usability check - a RevolveFeature's
# backing Sketch is "revolvable" under exactly the same condition an
# ExtrudeFeature's is "extrudable" under.
EXTRUDABLE_STATUSES = frozenset({ProfileStatus.CLOSED_LOOP, ProfileStatus.MULTIPLE_LOOPS})


def basis_normal(basis: ResolvedPlane) -> gp_Dir:
    x, y, z = basis.normal
    return gp_Dir(x, y, z)


def _arc_axis(basis: ResolvedPlane, center_x: float, center_y: float) -> gp_Ax2:
    """The `gp_Ax2` an Arc's `gp_Circ` is built against - unlike Circle's
    own `axis` (built with the 2-argument `gp_Ax2(point, normal)`, whose X
    reference direction OCCT picks arbitrarily, harmless there since a full
    circle's edge construction never reads it), an Arc's edge is trimmed
    between two points via `BRepBuilderAPI_MakeEdge(gp_Circ, P1, P2)`,
    which *does* pick one of the circle's two possible arcs based on that
    reference direction (the trim always runs from P1 to P2 in the
    direction of increasing parameter/angle). Passing the sketch plane's
    own real local +X axis as the explicit 3rd argument pins that
    parametrization to exactly "standard CCW in the sketch's own local
    (x, y) coordinates" - the same convention the Arc class docstring
    documents and the client's 2D rendering must also use - rather than
    leaving it to whatever direction OCCT happens to auto-select.

    On a *mirrored* Sketch (`app.document.plane_geometry.apply_orientation`'s
    `flip`), `basis.x_axis` is itself negated - deliberately still used
    here as-is, not "corrected" back to a right-handed reference: a mirror
    transform is *supposed* to reverse apparent CCW/CW, and passing the
    real (possibly left-handed) `x_axis` straight through is what lets
    that reversal actually happen. See [wire_for_profile]'s own Arc branch
    for the other half of this - it swaps which Point is passed as P1 vs
    P2 whenever the basis is mirrored, which is the piece that actually
    needed fixing (confirmed by direct numeric simulation, not just
    reasoning about it - an earlier attempt at "fixing" *this* function
    instead, by deriving a canonicalized right-handed reference direction,
    produced the exact same wrong result the original code did)."""
    x, y, z = basis.x_axis
    return gp_Ax2(basis_point_to_world(basis, center_x, center_y), basis_normal(basis), gp_Dir(x, y, z))


def _ellipse_axis(basis: ResolvedPlane, center_x: float, center_y: float, rotation: float) -> gp_Ax2:
    """The `gp_Ax2` an Ellipse's `gp_Elips` is built against - `gp_Elips`
    always places its major axis along the `gp_Ax2`'s own X reference
    direction, so (mirroring `_arc_axis`'s identical reasoning) that
    reference direction must be pinned explicitly rather than left to
    OCCT's arbitrary default: the sketch plane's own local +X axis,
    rotated in-plane by the Ellipse's own `rotation()` (the angle from
    local +X to its major-axis Point), giving a deterministic major-axis
    direction that matches the Ellipse class's own convention and the
    client's 2D rendering. Unlike Arc, a full (untrimmed) ellipse has no
    CCW-vs-CW ambiguity for [wire_for_profile] to get backwards on a
    mirrored Sketch - `gp_Elips`'s own major-axis line is direction-
    symmetric, so this never needed the swap-based fix Arc did."""
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    dx, dy, dz = xx * cos_r + yx * sin_r, xy * cos_r + yy * sin_r, xz * cos_r + yz * sin_r
    return gp_Ax2(basis_point_to_world(basis, center_x, center_y), basis_normal(basis), gp_Dir(dx, dy, dz))


def basis_point_to_world(basis: ResolvedPlane, x: float, y: float) -> gp_Pnt:
    """C3: `basis`'s local (x, y) -> world-space embedding - generalizes the
    fixed-plane-only `sketch_point_to_world` this replaces (see
    app.document.plane_geometry.sketch_basis_for_plane/_basis_point, the
    pure-Python twin of this function, which this must stay in sync with)
    to any `ResolvedPlane`, fixed or (C3) custom. A fixed plane's own
    `ResolvedPlane` (from `sketch_basis_for_plane`) reproduces the exact
    same world point the old per-`Plane`-enum dict lookup did, so every
    existing fixed-plane Sketch/Extrude is unaffected by this
    generalization."""
    ox, oy, oz = basis.origin
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    return gp_Pnt(ox + x * xx + y * yx, oy + x * xy + y * yy, oz + x * xz + y * yz)


def _text_world_transform(text: TextEntity, sketch: Sketch, basis: ResolvedPlane) -> gp_Trsf:
    """The local(text_to_brep's own baseline-origin space) -> world
    transform for `text`'s own geometry: first rotated in-plane by
    `text.rotation_degrees` and translated to its anchor Point (both in
    the sketch's own local (x, y) space, mirroring `_ellipse_axis`'s
    identical "rotate the basis's own in-plane axes" composition), then
    embedded in world space via `basis` - composed directly into one 3x4
    affine matrix (`gp_Trsf.SetValues`) rather than two chained
    `BRepBuilderAPI_Transform` calls, avoiding a second full-shape copy.
    `text_to_brep`'s own shapes always lie flat at local Z=0 (confirmed
    by direct on-device testing), so this transform's Z-column
    coefficients (`basis.normal`) never actually get exercised by any
    coordinate this is applied to - included anyway to keep the matrix a
    genuine orthonormal 3D transform, not a degenerate 2D-only one.
    """
    anchor = sketch.points[text.anchor_point_id]
    rotation = math.radians(text.rotation_degrees)
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    nx, ny, nz = basis.normal
    # The world-space direction local +x/+y each map along, after the
    # in-plane rotation - same composition _ellipse_axis uses for its own
    # rotated major-axis direction.
    x_prime = (cos_r * xx + sin_r * yx, cos_r * xy + sin_r * yy, cos_r * xz + sin_r * yz)
    y_prime = (-sin_r * xx + cos_r * yx, -sin_r * xy + cos_r * yy, -sin_r * xz + cos_r * yz)
    translation = basis_point_to_world(basis, anchor.x, anchor.y)

    trsf = gp_Trsf()
    trsf.SetValues(
        x_prime[0], y_prime[0], nx, translation.X(),
        x_prime[1], y_prime[1], ny, translation.Y(),
        x_prime[2], y_prime[2], nz, translation.Z(),
    )
    return trsf


def wire_for_profile(sketch: Sketch, profile: Profile, basis: ResolvedPlane):
    """A Profile is a standalone Circle/Ellipse/Text contour (see
    app.sketch.profile._circle_profile/_ellipse_profile/_text_profile,
    which all pack the owning entity's own id into `line_ids` rather than
    a Line chain), a pure Line-chain polygon (the common case), or a
    Line/Arc/Spline-chain mixing straight and curved segments (e.g. a
    rounded-corner rectangle) - each needs a different OCCT wire
    construction.

    On-device feedback: public (no leading underscore) since
    `app.document.sweep` also needs a bare outer wire (not the full
    `face_for_profile` face) - `BRepOffsetAPI_MakePipeShell.Add` rejects a
    `TopoDS_Face` outright (`BRepFill_Section: bad shape type of section`),
    it only accepts a Wire/Edge/Vertex as one swept "section"."""
    if len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Circle):
        circle = sketch.entities[profile.line_ids[0]]
        center = sketch.points[circle.center_point_id]
        radius = circle.radius(sketch.points)
        axis = gp_Ax2(basis_point_to_world(basis, center.x, center.y), basis_normal(basis))
        edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, radius)).Edge()
        return BRepBuilderAPI_MakeWire(edge).Wire()

    if len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Ellipse):
        ellipse = sketch.entities[profile.line_ids[0]]
        center = sketch.points[ellipse.center_point_id]
        major_radius = ellipse.major_radius(sketch.points)
        rotation = ellipse.rotation(sketch.points)
        axis = _ellipse_axis(basis, center.x, center.y, rotation)
        # gp_Elips requires MajorRadius >= MinorRadius - already enforced at
        # creation time (see Sketch.add_ellipse); either radius can drift
        # past that once its own DistanceConstraint is edited post-creation,
        # same as any other solver-tracked dimension.
        edge = BRepBuilderAPI_MakeEdge(gp_Elips(axis, major_radius, ellipse.minor_radius(sketch.points))).Edge()
        return BRepBuilderAPI_MakeWire(edge).Wire()

    if len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), TextEntity):
        # A Text contour's own boundary (`profile.text_vertices`) is only
        # a coarse tessellation, used for profile.py's nesting/containment
        # classification, never for the actual solid - the real wire is
        # the EXACT curve `app.sketch.text_geometry.text_contour_wire`
        # re-derives directly from a fresh OCCT font-to-BRep conversion
        # (see that function's own docstring for why it can't just be
        # reconstructed from the tessellation), placed in world space via
        # `_text_world_transform` (see that function's own doc comment).
        text = sketch.entities[profile.line_ids[0]]
        local_wire = text_contour_wire(
            text.content, text.font, text.size, profile.text_contour_index, profile.text_hole_index
        )
        transform = _text_world_transform(text, sketch, basis)
        return topods.Wire(BRepBuilderAPI_Transform(local_wire, transform, True).Shape())

    if not any(
        isinstance(sketch.entities.get(entity_id), (Arc, Spline)) for entity_id in profile.line_ids
    ):
        polygon = BRepBuilderAPI_MakePolygon()
        for point_id in profile.point_ids:
            point = sketch.points[point_id]
            polygon.Add(basis_point_to_world(basis, point.x, point.y))
        polygon.Close()
        return polygon.Wire()

    # A Line/Arc/Spline-mixed chain: BRepBuilderAPI_MakePolygon has no
    # notion of a curved segment at all, so each hop is built as its own
    # edge(s) (straight for a Line, a trimmed circular arc for an Arc, one
    # cubic Bezier edge per internal segment for a Spline) and stitched
    # together via BRepBuilderAPI_MakeWire, which matches shared vertices
    # regardless of each edge's own parametric direction - so an Arc edge
    # is always built from its own canonical start->end Points (see the
    # Arc class docstring's CCW convention), never from
    # `point_ids[i]`/`point_ids[i+1]` order, which depends on which
    # direction profile.py's graph walk happened to trace this loop in and
    # would otherwise risk picking the circle's *other* (wrong) arc
    # between the same two points. A Spline's own internal through-points
    # (everything between its first and last) never appear in
    # `profile.point_ids` at all - only the two ends profile.py's walk
    # treats as this hop's connection points do - so its own `segments()`
    # (in the Spline's own through_point_ids order) is walked directly,
    # reversed when the walk traced it back-to-front (mirroring Arc's own
    # "never infer direction from point_ids order" reasoning).
    wire_maker = BRepBuilderAPI_MakeWire()
    point_count = len(profile.point_ids)
    for i in range(point_count):
        entity = sketch.entities[profile.line_ids[i]]
        if isinstance(entity, Arc):
            center = sketch.points[entity.center_point_id]
            radius = entity.radius(sketch.points)
            axis = _arc_axis(basis, center.x, center.y)
            start = sketch.points[entity.start_point_id]
            end = sketch.points[entity.end_point_id]
            # Bug fix (on-device feedback: a Slot's own semicircular
            # end-cap Arcs came out concave instead of convex, and a
            # Trim/Extend-closed Arc+Line loop extruded the wrong,
            # excluded side - both only on a *mirrored* Sketch): a mirror
            # transform genuinely does reverse apparent CCW/CW for
            # anything embedded through it, which `_arc_axis` (passing the
            # real, possibly left-handed `basis.x_axis` straight to OCCT)
            # already correctly allows for - what still needs to flip in
            # step with it is *which* Point plays P1 vs P2 for
            # `BRepBuilderAPI_MakeEdge(gp_Circ, P1, P2)`'s own "CCW from
            # P1 to P2" trim, matching how the same mirror reverses the
            # Arc's own local `start` -> `end` sweep once embedded in
            # world space. Confirmed by direct numeric simulation (see
            # `is_mirrored_basis`'s own doc comment) - not by reasoning
            # about it, since an earlier fix attempt (adjusting the axis's
            # own reference direction instead of swapping P1/P2) turned
            # out to reproduce the exact same wrong arc the original bug
            # did.
            p1, p2 = (end, start) if is_mirrored_basis(basis) else (start, end)
            edge = BRepBuilderAPI_MakeEdge(
                gp_Circ(axis, radius),
                basis_point_to_world(basis, p1.x, p1.y),
                basis_point_to_world(basis, p2.x, p2.y),
            ).Edge()
            wire_maker.Add(edge)
        elif isinstance(entity, Spline):
            segments = entity.segments()
            if profile.point_ids[i] == entity.through_point_ids[-1]:
                segments = [(p3, p2, p1, p0) for (p0, p1, p2, p3) in reversed(segments)]
            for p0_id, p1_id, p2_id, p3_id in segments:
                poles = TColgp_Array1OfPnt(1, 4)
                for index, point_id in enumerate((p0_id, p1_id, p2_id, p3_id), start=1):
                    point = sketch.points[point_id]
                    poles.SetValue(index, basis_point_to_world(basis, point.x, point.y))
                curve = Geom_BezierCurve(poles)
                wire_maker.Add(BRepBuilderAPI_MakeEdge(curve).Edge())
        else:
            a = sketch.points[profile.point_ids[i]]
            b = sketch.points[profile.point_ids[(i + 1) % point_count]]
            edge = BRepBuilderAPI_MakeEdge(
                basis_point_to_world(basis, a.x, a.y),
                basis_point_to_world(basis, b.x, b.y),
            ).Edge()
            wire_maker.Add(edge)
    return wire_maker.Wire()


def _wire_normal(wire: TopoDS_Wire) -> gp_Dir:
    """The outward normal of the planar face `wire` alone would bound, used
    only to compare relative winding direction between an outer wire and a
    candidate inner (hole) wire (see `face_for_profile`) - not a
    meaningful normal on its own once wires are combined into one face.

    `BRepBuilderAPI_MakeFace.Add` does not reorient wires for you: the
    caller is responsible for making sure each inner wire winds the
    opposite way around from the outer one. `wire_for_profile` gives no
    such guarantee (a Line-chain loop's winding direction is whatever
    order `profile.py`'s graph walk happened to trace it in, and a Circle's
    is fixed by `plane_normal`), so rather than trying to reason about
    winding direction analytically, this asks OCCT directly: build a
    standalone face from just this one wire and read back its actual
    surface normal (correcting for TopAbs_REVERSED, which flips a face's
    effective normal without changing its underlying surface).
    """
    face = BRepBuilderAPI_MakeFace(wire).Face()
    normal = BRepAdaptor_Surface(face, True).Plane().Axis().Direction()
    if face.Orientation() == TopAbs_REVERSED:
        normal = normal.Reversed()
    return normal


def face_for_profile(sketch: Sketch, profile: Profile, basis: ResolvedPlane):
    """Builds `profile`'s face, punching a hole for each of its
    `inner_loops` (C1) via `BRepBuilderAPI_MakeFace.Add` - the standard
    OCCT idiom for a face-with-holes (BRepBuilderAPI_MakeFace(outerWire)
    then .Add(innerWire) per inner boundary, before the face is passed to
    BRepPrimAPI_MakePrism). Each inner wire is reversed relative to the
    outer one first (see `_wire_normal`) since `.Add` does not do this
    itself and Add-ing a hole wire with the same winding as the outer
    produces an invalid/doubled face instead of a hole.

    Prompt F: public (no leading underscore) since app.document.revolve also
    builds a face-with-holes from a Profile before passing it to
    `BRepPrimAPI_MakeRevol`, the same shape `_prism_for_profile` below
    already needs before `BRepPrimAPI_MakePrism`."""
    outer_wire = wire_for_profile(sketch, profile, basis)
    face_maker = BRepBuilderAPI_MakeFace(outer_wire)
    if profile.inner_loops:
        outer_normal = _wire_normal(outer_wire)
        for inner_loop in profile.inner_loops:
            inner_wire = wire_for_profile(sketch, inner_loop, basis)
            if _wire_normal(inner_wire).Dot(outer_normal) > 0:
                inner_wire = inner_wire.Reversed()
            face_maker.Add(inner_wire)
    return face_maker.Face()


def _prism_for_profile(sketch: Sketch, profile: Profile, feature: ExtrudeFeature, basis: ResolvedPlane):
    """One profile's face, moved to `feature.start_distance` along the
    Sketch plane's normal and swept the remaining span to
    `feature.end_distance` - the single-profile half of what used to be
    `_solid_for_extrude_feature` before C2 split it out so it can be
    called once per sub-profile of a MultiProfile."""
    normal = basis_normal(basis)
    direction = gp_Vec(normal.X(), normal.Y(), normal.Z())

    # start_distance/end_distance are both signed offsets along `direction`
    # from the sketch plane - the solid spans literally from one to the
    # other, so the face is moved to start_distance first and the prism
    # then covers the remaining (end_distance - start_distance) span.
    start_transform = gp_Trsf()
    start_transform.SetTranslation(direction.Multiplied(feature.start_distance))
    face = face_for_profile(sketch, profile, basis)
    moved_face = BRepBuilderAPI_Transform(face, start_transform, True).Shape()

    prism_vector = direction.Multiplied(feature.end_distance - feature.start_distance)
    return BRepPrimAPI_MakePrism(moved_face, prism_vector).Shape()


def invalid_profile_ref(ref: SketchEntityRef) -> HTTPException:
    """Prompt G: the structured `invalid_profile_ref` error for a
    `profile_refs` anchor that cannot select a real outer profile - covers
    every way this can fail: the entity doesn't exist, isn't a Line/Circle/
    Arc (only those can anchor a profile - a Point can't), or exists but
    isn't part of any of `detect_profile`'s current outer profiles (it
    belongs to a hole, or to an unusable open-chain/branch component
    `detect_profile` already excluded). Public (no leading underscore) since
    `app.document.revolve` raises it too - a Revolve's Profile selection
    needs the identical check an Extrude's does.

    Mirrors `app.document.revolve._invalid_axis_ref`'s envelope shape
    exactly (422, a structured `detail` dict) - see that function's own
    doc comment for the general "structured, not generic missing_reference"
    reasoning."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_profile_ref",
            "sketch_id": ref.sketch_id,
            "entity_type": ref.entity_type.value,
            "entity_id": ref.entity_id,
        },
    )


def select_profiles(candidates: list[Profile], profile_refs: list[SketchEntityRef]) -> list[Profile]:
    """Prompt G: filters `candidates` - every outer profile `detect_profile`
    currently reports for one Sketch (either the single CLOSED_LOOP
    `profile`, wrapped in a list, or MULTIPLE_LOOPS' own `loops`) - down to
    just the ones named by `profile_refs`, or returns `candidates` unchanged
    when `profile_refs` is empty (the default: use every detected outer
    profile, exactly `compute_part_bodies`'s pre-Prompt-G behaviour - a
    Sketch with a stray open chain or branch alongside a genuinely closed
    loop is no longer an error at all, see `detect_profile`'s own Prompt G
    update, and picking a subset of 2+ closed loops is now possible instead
    of always using all of them).

    Each `profile_refs` entry names one anchor entity (a Line, Circle, Arc,
    Ellipse, Spline, or Text) expected to belong to one or more of
    `candidates`' own `line_ids` - resolved via `app.sketch.store.
    resolve_sketch_entity`, then matched by scanning each candidate's
    `line_ids` (a Circle/Ellipse/Spline/Text profile's `line_ids` holds its
    own single owning entity id - see `app.sketch.profile._circle_profile`/
    `_ellipse_profile`/`_text_profile` - so the same membership check works
    uniformly across every profile shape). A Text entity is the only one
    that can own more than one top-level candidate at once (one per glyph
    contour), so referencing it selects every one of its own loops, not
    just the first. Fails closed with `invalid_profile_ref` (never a
    generic `missing_reference` or an uncaught lookup error) for every way
    an anchor can fail to select a real outer profile - see
    `invalid_profile_ref`'s own doc comment.

    Selected profiles are deduplicated (two refs naming the same loop select
    it once) and returned in `candidates`' own order, not `profile_refs`'
    order, so the resulting compound's sub-shape ordering never depends on
    the order the caller happened to list its picks in."""
    if not profile_refs:
        return candidates

    selected_indices: set[int] = set()
    for ref in profile_refs:
        if ref.entity_type not in (
            SketchEntityType.LINE,
            SketchEntityType.CIRCLE,
            SketchEntityType.ARC,
            SketchEntityType.ELLIPSE,
            SketchEntityType.SPLINE,
            SketchEntityType.TEXT,
        ):
            raise invalid_profile_ref(ref)
        try:
            entity = resolve_sketch_entity(ref)
        except HTTPException:
            raise invalid_profile_ref(ref) from None
        if not isinstance(entity, (Line, Circle, Arc, Ellipse, Spline, TextEntity)):
            raise invalid_profile_ref(ref)

        # A Text entity can own several top-level candidates at once (one
        # per glyph contour - see app.sketch.profile._text_profile), so
        # every matching candidate is selected here, not just the first -
        # every other entity type only ever owns exactly one, so this is
        # a no-op generalization for them (a set of one match either way).
        matched_indices = [i for i, candidate in enumerate(candidates) if entity.id in candidate.line_ids]
        if not matched_indices:
            raise invalid_profile_ref(ref)
        selected_indices.update(matched_indices)

    return [candidates[i] for i in sorted(selected_indices)]


def _solid_for_extrude_feature(
    feature: ExtrudeFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The real OCCT solid for one ExtrudeFeature, or None if its backing
    Sketch no longer has an extrudable profile - callers skip rather than
    error in that case, per the brief (a stale/edited-away profile
    shouldn't fail the whole mesh request).

    C2: a MultiProfile (status MULTIPLE_LOOPS, one sub-profile per disjoint
    outer loop, each already carrying its own C1 holes) produces one prism
    per sub-profile, combined into a single TopoDS_Compound - transparent
    to every caller of this function, which already only cares that it
    gets back one TopoDS_Shape.

    Prompt G: `feature.profile_refs`, if non-empty, narrows the MultiProfile
    case down to just the named outer profile(s) instead of always using
    every one detected (see `select_profiles`) - empty (the default)
    preserves the exact pre-Prompt-G "use all of them" behaviour.

    C3: `sketch_feature`'s own anchor plane (fixed, or a custom Plane via
    `sketch_feature.plane_feature_id`) is resolved via `app.document.
    create_plane.resolve_sketch_basis` - imported here, function-local
    rather than at module level, to break the circular import that would
    otherwise result (`create_plane.py` already imports `resolve_subshape`
    from this module at module level for its own OFFSET_FACE/MIDPLANE
    resolution). `bodies_so_far` is `compute_part_bodies`'s in-progress
    accumulator, not a fresh recompute - passed through so resolving a
    custom plane that itself depends on an earlier ExtrudeFeature's face
    (already processed by the time `compute_part_bodies`'s topological-order
    loop reaches this Feature) never triggers another top-level `compute_
    part_bodies` call, which would recurse forever."""
    from app.document.create_plane import resolve_sketch_basis

    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    if result.status not in EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping ExtrudeFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    if result.status == ProfileStatus.CLOSED_LOOP:
        assert result.profile is not None
        candidates = [result.profile]
    else:
        candidates = result.loops
    profiles = select_profiles(candidates, feature.profile_refs)
    solids = [_prism_for_profile(sketch, profile, feature, basis) for profile in profiles]

    if len(solids) == 1:
        return solids[0]

    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for solid in solids:
        builder.Add(compound, solid)
    return compound


def _explode_solids(shape: TopoDS_Shape) -> list[TopoDS_Shape]:
    """Every maximally-connected `TopoDS_SOLID` inside `shape`, in
    `TopExp_Explorer`'s deterministic visitation order - a bare solid
    (not wrapped in a compound) is returned as its own single-element
    list, same as the existing `test_extruding_two_disjoint_squares_
    produces_a_compound_of_two_solids` test already relies on
    `TopExp_Explorer(shape, TopAbs_SOLID)` to count."""
    explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    solids: list[TopoDS_Shape] = []
    while explorer.More():
        solids.append(explorer.Current())
        explorer.Next()
    return solids


def _register_solids(bodies: dict[str, TopoDS_Shape], base_id: str, shape: TopoDS_Shape) -> None:
    """Splits `shape` into its maximally-connected solid components and
    (re)registers each as its own Body in `bodies`, keyed off `base_id` -
    a Body is always exactly one connected piece of material (this is an
    amendment to A1's original "one Feature = one Body" rule, made after
    on-device testing showed a single Boss over a multi-profile sketch
    with disjoint outer loops rendering/selecting as one Body spanning two
    unrelated-looking solids, which doesn't match mainstream CAD tool
    behaviour): a multi-profile Boss, or a Cut that severs a Body into
    disconnected pieces, now produces multiple Bodies from one operation,
    not one compound Body.

    `base_id` alone is used when there's exactly one connected solid (the
    common case) - this keeps every existing single-solid Body id exactly
    as it was before this amendment, no client-visible change for the
    vast majority of parts. N>1 pieces get `f"{base_id}#{i}"` suffixes, in
    `_explode_solids`'s deterministic order - see `base_feature_id` for
    how a composite id is resolved back to its owning Feature. Zero
    solids (e.g. a Cut that consumes a Body entirely) registers nothing -
    the Body simply stops existing, same as before this amendment."""
    solids = _explode_solids(shape)
    if len(solids) == 1:
        bodies[base_id] = solids[0]
    else:
        for i, solid in enumerate(solids):
            bodies[f"{base_id}#{i}"] = solid


def _apply_boss_or_cut(
    bodies: dict[str, TopoDS_Shape],
    feature_id: str,
    feature_index: dict[str, int],
    is_cut: bool,
    target_body_ids: list[str],
    solid: TopoDS_Shape,
) -> None:
    """Prompt F: the Boss/Cut fuse-into-targets/cut-from-targets/register-
    solids dispatch, extracted from `compute_part_bodies`'s own
    `ExtrudeFeature` handling (previously inline there, the only Feature
    type that needed it) so `RevolveFeature`'s identical Boss/Cut parity
    (Prompt F's own explicit "Boss/Cut parity with Extrude from day one"
    decision) can share the exact same fuse/cut/merge-tiebreak/body-split
    logic rather than duplicating it - unlike Fillet/Chamfer's simpler
    single-Body in-place modify, this merge logic (multi-target fuse, the
    `feature_index`-based survivor tie-break, `_register_solids`' handling
    of a multi-solid result) is intricate enough that copy-pasting it a
    second time would be a real duplication-of-subtle-logic risk, not just
    boilerplate.

    `feature_id`/`is_cut`/`target_body_ids`/`solid` are whichever Feature
    (Extrude or Revolve) just produced `solid` - see each call site in
    `compute_part_bodies` below."""
    if not is_cut:
        target_ids = [tid for tid in target_body_ids if tid in bodies]
        if target_body_ids and not target_ids:
            logger.warning(
                "Boss feature %s: none of its target_body_ids currently exist "
                "(likely hidden) - starting a new Body instead",
                feature_id,
            )
        if not target_ids:
            _register_solids(bodies, feature_id, solid)
            return

        merged = solid
        for target_id in target_ids:
            merged = BRepAlgoAPI_Fuse(merged, bodies[target_id]).Shape()

        survivor_id = min(target_ids, key=lambda tid: feature_index[base_feature_id(tid)])
        for target_id in target_ids:
            del bodies[target_id]
        _register_solids(bodies, survivor_id, merged)
    else:
        for target_id in target_body_ids:
            if target_id not in bodies:
                logger.warning(
                    "Skipping Cut feature %s: target body %s does not exist",
                    feature_id,
                    target_id,
                )
                continue
            cut_result = BRepAlgoAPI_Cut(bodies[target_id], solid).Shape()
            del bodies[target_id]
            _register_solids(bodies, target_id, cut_result)


def compute_part_bodies(
    part: Part, excluded_feature_ids: frozenset[str] = frozenset()
) -> dict[str, TopoDS_Shape]:
    """Recomputes every Body in `part`, keyed by stable Body id (A1) -
    replaces the old single-accumulated-solid `compute_part_solid`.

    Processes `part.features` in dependency-graph topological order (see
    `build_feature_graph`/app.document.graph.topological_order) rather than
    raw list order, though for every Part with no `target_body_ids` edge
    reaching back past its immediately preceding Feature this produces
    exactly the same order list order already did.

    Boss: fuses its new solid into every Body named in
    `feature.target_body_ids`. If that list is empty, the solid becomes a
    brand-new Body (or Bodies - see `_register_solids`) identified by
    `feature.id`. If it names 2+ existing Bodies, they are all fused
    together with the new solid - the merge result keeps whichever named
    id belongs to the Feature that appears earliest in `part.features` (a
    single, deterministic tie-break; see `base_feature_id`).

    Cut: subtracts its solid from every Body named in
    `feature.target_body_ids` (never empty by the time recompute runs - see
    app.document.router._validate_target_body_ids). A named Body that
    doesn't currently exist (e.g. excluded via `excluded_feature_ids`, or
    genuinely deleted) is skipped for that Body only (logged, not raised) -
    mirrors the old "Cut with nothing to cut from" skip behaviour.

    Amendment to A1's original rule: every Boss/Cut result (new, fused, or
    cut) is decomposed into its maximally-connected solid components (see
    `_register_solids`) before being (re)registered - a Body is always one
    connected piece of material, so a multi-profile Boss with disjoint
    outer loops, or a Cut that severs a Body into disconnected pieces,
    produces multiple Bodies from that one operation, not one compound
    Body. The common single-solid case is entirely unaffected (same ids as
    before this amendment).

    An ExtrudeFeature whose id is in `excluded_feature_ids` is skipped
    entirely, as if it weren't in the Part's history at all - used ONLY for
    B4 true-rollback ("pretend this Feature and everything after it doesn't
    exist yet while I edit an earlier one"), never for the client's plain
    Hide/Show. Bug fix (post-C4): those two were originally the same
    client-side set/query-param (`hidden_feature_ids`) on the theory that
    "hidden" and "doesn't exist for recompute purposes" were equivalent -
    true as long as nothing else could ever reference a hidden Body's own
    topology. Once Create Plane (C2) could anchor a Plane to a Body face,
    that stopped holding: hiding the Extrude that produced a Body used by a
    *different*, still-visible Plane (and anything built on that Plane -
    C3's Sketch-on-Plane/Extrude-on-that-Sketch) made the Plane's own
    face_ref resolve to nothing, throwing `missing_reference` and taking
    the *entire* `/mesh` response down with it - including unrelated Bodies
    that had nothing wrong with them. `excluded_feature_ids` now carries
    only the true-rollback set; a Body hidden via plain Hide/Show is always
    still fully computed here and only filtered out afterward, at the
    response layer - see app.document.router.get_part_mesh's own
    `hidden_feature_ids` (the renamed, now purely cosmetic parameter).

    Prompt D: a `FilletFeature` modifies a Body already in `bodies` in
    place (see `app.document.fillet.resolve_fillet_from_bodies`), rather
    than adding or replacing an entry the way Boss/Cut do - `bodies[body_id]`
    is simply reassigned to the post-fillet shape, keeping the same key. A
    Fillet that can't currently be resolved (its edges span more than one
    Body, its own topology drifted since creation, or the fillet geometry
    itself fails) is skipped with a warning rather than raising - the same
    resilience `compute_part_bodies` already gives a Cut naming a Body that
    no longer exists, since this function computes the *whole* Part's
    Bodies unconditionally for every `/mesh` fetch and one bad Fillet
    shouldn't take down every other Body's response. The router's own
    create/update endpoints validate a Fillet eagerly instead (see
    `app.document.fillet.resolve_fillet`), so a genuinely invalid Fillet is
    normally never persisted in the first place - this fallback only ever
    matters for topology drift after the fact.

    Prompt E: `ChamferFeature` gets the identical branch, one entry down -
    same in-place `bodies[body_id]` reassignment, same skip-with-warning
    resilience, same "router validates eagerly, this is only the topology-
    drift fallback" reasoning - see `app.document.chamfer.
    resolve_chamfer_from_bodies`.

    Prompt F: `RevolveFeature` gets the identical Boss/Cut handling
    `ExtrudeFeature` does (see `_apply_boss_or_cut`, shared by both
    branches) - a Revolve's raw solid comes from `app.document.revolve.
    resolve_revolve_from_bodies` instead of `_solid_for_extrude_feature`,
    but is then fused/cut/registered into `bodies` by the exact same code
    path. Same resilience convention as Fillet/Chamfer: a Revolve that can't
    currently be resolved (unresolvable axis, revolve geometry failure) is
    skipped with a warning rather than raising - the router's own create/
    update endpoints validate a Revolve eagerly instead (see
    `app.document.revolve.resolve_revolve`), so this fallback only ever
    matters for topology drift after the fact.

    `SweepFeature` gets the identical Boss/Cut handling one branch further
    down - a Sweep's raw solid comes from `app.document.sweep.resolve_
    sweep_from_bodies` instead, same resilience convention (unresolvable
    path/disconnected path/sweep geometry failure is skipped with a
    warning rather than raising - the router's own create/update endpoints
    validate a Sweep eagerly instead, see `app.document.sweep.
    resolve_sweep`)."""
    from app.document.chamfer import resolve_chamfer_from_bodies
    from app.document.fillet import resolve_fillet_from_bodies
    from app.document.import_geometry import resolve_import
    from app.document.revolve import resolve_revolve_from_bodies
    from app.document.sweep import resolve_sweep_from_bodies

    feature_index = {feature.id: i for i, feature in enumerate(part.features)}
    bodies: dict[str, TopoDS_Shape] = {}

    order = topological_order(build_feature_graph(part))
    for feature_id in order:
        feature = part.get_feature(feature_id)
        if feature.id in excluded_feature_ids:
            continue

        if isinstance(feature, FilletFeature):
            try:
                body_id, filleted_shape = resolve_fillet_from_bodies(bodies, feature)
            except HTTPException:
                logger.warning("Skipping FilletFeature %s: could not be resolved", feature.id)
                continue
            bodies[body_id] = filleted_shape
            continue

        if isinstance(feature, ChamferFeature):
            try:
                body_id, chamfered_shape = resolve_chamfer_from_bodies(bodies, feature)
            except HTTPException:
                logger.warning("Skipping ChamferFeature %s: could not be resolved", feature.id)
                continue
            bodies[body_id] = chamfered_shape
            continue

        if isinstance(feature, ImportFeature):
            try:
                solid = resolve_import(feature)
            except HTTPException as exc:
                # Mirrors the Sweep/Extrude branches' own narrow-catch fix:
                # only this Feature's own "bad file" failures are tolerated
                # (the router's create endpoint already validates eagerly,
                # so this only matters for a hand-crafted/legacy document);
                # anything else must still propagate.
                if not isinstance(exc.detail, dict) or exc.detail.get("type") not in (
                    "import_failed",
                    "invalid_import_data",
                ):
                    raise
                logger.warning("Skipping ImportFeature %s: could not be resolved", feature.id)
                continue
            # Deliberately not `_apply_boss_or_cut` (which registers via
            # `_register_solids`, splitting a result by walking its
            # `TopAbs_SOLID`s - correct for a real Extrude/Revolve/Sweep
            # boss, wrong here): a mesh import's own shape (see
            # `_shape_from_mesh_data`) is a bare, surface-less face with no
            # `TopoDS_Solid` at all, so that path would silently register
            # zero Bodies for it (caught by CI - an imported STL vanished
            # from `/mesh` entirely). ImportFeature has no Boss/Cut merge
            # concept of its own anyway (see its own docstring) - always
            # exactly one Body, keyed by this Feature's own id, whatever
            # `resolve_import` returned (a real B-rep solid for STEP, a
            # bare face for a mesh format) - never split even if a STEP
            # import happens to contain multiple disjoint solids.
            bodies[feature.id] = solid
            continue

        if isinstance(feature, RevolveFeature):
            sketch_feature = part.get_feature(feature.sketch_feature_id)
            if not isinstance(sketch_feature, SketchFeature):
                logger.warning(
                    "Skipping RevolveFeature %s: referenced sketch feature %s not found",
                    feature.id,
                    feature.sketch_feature_id,
                )
                continue
            try:
                solid = resolve_revolve_from_bodies(
                    feature, sketch_feature, part, bodies, excluded_feature_ids
                )
            except HTTPException:
                logger.warning("Skipping RevolveFeature %s: could not be resolved", feature.id)
                continue
            if solid is None:
                continue
            _apply_boss_or_cut(
                bodies, feature.id, feature_index, feature.mode == RevolveMode.CUT,
                feature.target_body_ids, solid,
            )
            continue

        if isinstance(feature, SweepFeature):
            sketch_feature = part.get_feature(feature.sketch_feature_id)
            if not isinstance(sketch_feature, SketchFeature):
                logger.warning(
                    "Skipping SweepFeature %s: referenced sketch feature %s not found",
                    feature.id,
                    feature.sketch_feature_id,
                )
                continue
            try:
                solid = resolve_sweep_from_bodies(
                    feature, sketch_feature, part, bodies, excluded_feature_ids
                )
            except HTTPException as exc:
                # Tolerates this Sweep's own stale/broken references
                # (an edited-away path segment, a disconnected path, a
                # geometrically-invalid sweep, a stale profile_refs pick) -
                # deliberately narrower than a blanket `except
                # HTTPException`, matching the fix applied to the
                # ExtrudeFeature branch below for the identical reason: a
                # `missing_reference` from `resolve_sketch_basis` (B4 true
                # rollback deliberately excluding an upstream Feature this
                # Sweep's Profile or path depends on) must still propagate
                # and fail the whole request, not be swallowed as "this
                # Sweep is just stale."
                if not isinstance(exc.detail, dict) or exc.detail.get("type") not in (
                    "invalid_path_ref",
                    "disconnected_path",
                    "sweep_failed",
                    "invalid_profile_ref",
                ):
                    raise
                logger.warning("Skipping SweepFeature %s: could not be resolved", feature.id)
                continue
            if solid is None:
                continue
            _apply_boss_or_cut(
                bodies, feature.id, feature_index, feature.mode == SweepMode.CUT,
                feature.target_body_ids, solid,
            )
            continue

        if not isinstance(feature, ExtrudeFeature):
            continue

        sketch_feature = part.get_feature(feature.sketch_feature_id)
        if not isinstance(sketch_feature, SketchFeature):
            logger.warning(
                "Skipping ExtrudeFeature %s: referenced sketch feature %s not found",
                feature.id,
                feature.sketch_feature_id,
            )
            continue

        try:
            solid = _solid_for_extrude_feature(feature, sketch_feature, part, bodies, excluded_feature_ids)
        except HTTPException as exc:
            # Prompt G: profile_refs can now raise invalid_profile_ref (e.g.
            # topology drift since creation) - tolerated here the same way
            # Fillet/Chamfer/Revolve's own branches tolerate their own
            # topology-drift failures, so one Extrude with a stale
            # profile_refs pick doesn't take down every other Body's
            # response. Deliberately narrower than a blanket `except
            # HTTPException`, though (bug fix: a blanket catch here briefly
            # regressed `test_rollback_excluded_feature_ids_still_breaks_a_
            # downstream_plane_as_intended` - a `missing_reference` raised
            # by `resolve_sketch_basis` because B4's true rollback
            # deliberately excluded an upstream Feature must still
            # propagate and fail the whole request, exactly as it did
            # before profile_refs existed; only `invalid_profile_ref`
            # itself is a "this Extrude specifically has stale data"
            # failure worth swallowing).
            if not isinstance(exc.detail, dict) or exc.detail.get("type") != "invalid_profile_ref":
                raise
            logger.warning("Skipping ExtrudeFeature %s: could not be resolved", feature.id)
            continue
        if solid is None:
            continue

        _apply_boss_or_cut(
            bodies, feature.id, feature_index, feature.extrude_type == ExtrudeType.CUT,
            feature.target_body_ids, solid,
        )

    return bodies


_TOPABS_FOR_SUBSHAPE_TYPE = {
    SubShapeType.EDGE: TopAbs_EDGE,
    SubShapeType.FACE: TopAbs_FACE,
    # C4: same 0-based topexp.MapShapes(body, TopAbs_VERTEX, ...) index
    # scheme app.document.mesh._extract_topology_vertices already assigns
    # the client's topology_vertex_ids from.
    SubShapeType.VERTEX: TopAbs_VERTEX,
}


def _missing_reference(ref: SubShapeRef) -> HTTPException:
    """B1: the structured `missing_reference` validation error `resolve_
    subshape` raises whenever `ref` can no longer be resolved - matches
    app.document.router._validate_target_body_ids's established envelope
    (a plain `HTTPException(status_code=..., detail=...)`, no custom wrapper
    type), just with a structured `detail` dict instead of a plain string,
    per B1's own testing checklist (the failure is specific enough - which
    body, which shape kind, which index - that a client can offer "please
    reselect" instead of a generic message). 422, matching Cut's own
    already-established "structurally invalid, not just malformed" use of
    422 in `_validate_target_body_ids`."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "missing_reference",
            "body_id": ref.body_id,
            "shape_type": ref.shape_type.value,
            "index": ref.index,
        },
    )


def resolve_subshape_from_bodies(bodies: dict[str, TopoDS_Shape], ref: SubShapeRef) -> TopoDS_Shape:
    """B1/C3: the core of `resolve_subshape` below, split out so a caller
    that already has an in-progress `bodies` dict on hand (C3: `app.document.
    create_plane`'s `_from_bodies` resolvers, called from inside `compute_
    part_bodies`'s own topological-order loop while resolving a custom
    plane's basis - see `_solid_for_extrude_feature`) can resolve a
    `SubShapeRef` without triggering another top-level `compute_part_bodies`
    call, which would recurse forever. `resolve_subshape` itself is now a
    thin "compute bodies, then look up" wrapper around this."""
    body = bodies.get(ref.body_id)
    if body is None:
        raise _missing_reference(ref)

    shape_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(body, _TOPABS_FOR_SUBSHAPE_TYPE[ref.shape_type], shape_map)
    if not (0 <= ref.index < shape_map.Size()):
        raise _missing_reference(ref)

    return shape_map.FindKey(ref.index + 1)


def edge_endpoint_vertex_refs(bodies: dict[str, TopoDS_Shape], ref: SubShapeRef) -> tuple[SubShapeRef, SubShapeRef]:
    """Sketcher-roadmap Phase 4.3 v2: the two Body vertices at `ref`'s (an
    EDGE) endpoints, as their own VERTEX `SubShapeRef`s against the same
    body. Lets an edge external reference reuse v1's vertex-materialize
    machinery (`create_plane.resolve_external_vertex_position` +
    `Sketch.add_external_vertex_reference`) twice rather than inventing
    any edge-specific solver/projection path - see the roadmap doc's own
    v2 scoping (item 6): an edge materializes as two Points plus a real
    Line between them, not a new constraint type.

    Indices are 0-based, into the same per-body `TopAbs_VERTEX` map
    `_TOPABS_FOR_SUBSHAPE_TYPE`/`app.document.mesh._extract_topology_
    vertices` already use, so they line up with a client's own
    `topology_vertex_ids` directly."""
    edge_shape = resolve_subshape_from_bodies(bodies, ref)
    edge = topods.Edge(edge_shape)
    start_vertex, end_vertex = TopoDS_Vertex(), TopoDS_Vertex()
    topexp.Vertices(edge, start_vertex, end_vertex)

    vertex_map = TopTools_IndexedMapOfShape()
    topexp.MapShapes(bodies[ref.body_id], TopAbs_VERTEX, vertex_map)
    return (
        SubShapeRef(body_id=ref.body_id, shape_type=SubShapeType.VERTEX, index=vertex_map.FindIndex(start_vertex) - 1),
        SubShapeRef(body_id=ref.body_id, shape_type=SubShapeType.VERTEX, index=vertex_map.FindIndex(end_vertex) - 1),
    )


def resolve_subshape(
    part: Part, ref: SubShapeRef, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """B1: resolves `ref` against `part`'s *current* recomputed bodies (via
    `compute_part_bodies`, not a cached shape from whenever `ref` was first
    captured) - re-walks the same `topexp.MapShapes` traversal used to
    capture `ref.index` in the first place, over whichever Body currently
    has that id. Works against any body_id in the Part's history, not just
    the most recently computed one, since `compute_part_bodies` already
    recomputes every Body regardless of how far upstream it sits.

    Fails closed - raises the structured `missing_reference` HTTPException
    above (see `_missing_reference`) rather than falling back to some
    "closest" sub-shape - whenever `ref.body_id` no longer exists among the
    Part's current Bodies (deleted, or hidden via `excluded_feature_ids`), or
    `ref.index` is out of range for that Body's current sub-shape count of
    `ref.shape_type` (its upstream topology changed since `ref` was
    captured). This is a deliberate product choice, not a placeholder - a
    cheap, deterministic enumeration index is cheap to ship and cheap to
    fall back from later if it proves too fragile in practice."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_subshape_from_bodies(bodies, ref)
