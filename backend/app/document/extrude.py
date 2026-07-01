"""OCCT geometry construction for ExtrudeFeature (Boss/Cut) - the Extrude
module described in the project brief's section 4.3, kept separate from
app.document.router the same way app.document.mesh's tessellation logic is.

Knows nothing about Sketch internals beyond what app.sketch already exposes
publicly (Profile, detect_profile, Sketch.points/entities) - mirrors the
brief's "Knows nothing about Sketch internals" requirement for Extrude.
"""

import logging

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
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.models import ExtrudeFeature, ExtrudeType, Part, SketchFeature
from app.sketch.models import Circle, Plane, Sketch
from app.sketch.profile import Profile, ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)

# C1/C2: an ExtrudeFeature's backing Sketch is extrudable whenever its
# Profile detection reports a usable boundary - a single nested profile
# (holes folded in) or a MultiProfile of disjoint outer profiles (each with
# its own holes). Every other status (NO_LOOP, BRANCH, INVALID_NESTING) has
# nothing extrudable to offer.
_EXTRUDABLE_STATUSES = frozenset({ProfileStatus.CLOSED_LOOP, ProfileStatus.MULTIPLE_LOOPS})

# Maps each fixed reference plane to its outward normal and to the
# Sketch-local-(x, y) -> world-(x, y, z) embedding - the same convention
# client/lib/viewport3d/sketch_geometry_3d.dart's `sketchPointToWorld` uses
# for rendering a Sketch's own geometry in 3D, kept identical here so a
# Sketch's solid lines up with where its own Lines/Circles are already drawn.
_PLANE_NORMAL: dict[Plane, tuple[float, float, float]] = {
    Plane.XY: (0.0, 0.0, 1.0),
    Plane.XZ: (0.0, 1.0, 0.0),
    Plane.YZ: (1.0, 0.0, 0.0),
}


def plane_normal(plane: Plane) -> gp_Dir:
    x, y, z = _PLANE_NORMAL[plane]
    return gp_Dir(x, y, z)


def sketch_point_to_world(plane: Plane, x: float, y: float) -> gp_Pnt:
    return {
        Plane.XY: gp_Pnt(x, y, 0.0),
        Plane.XZ: gp_Pnt(x, 0.0, y),
        Plane.YZ: gp_Pnt(0.0, x, y),
    }[plane]


def _wire_for_profile(sketch: Sketch, profile: Profile, plane: Plane):
    """A Profile is either a Line-chain polygon (the common case) or a
    standalone Circle (see app.sketch.profile._circle_profile, which packs
    the Circle's own entity id into `line_ids` rather than a Line chain) -
    each needs a different OCCT wire construction."""
    if len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Circle):
        circle = sketch.entities[profile.line_ids[0]]
        center = sketch.points[circle.center_point_id]
        radius = circle.radius(sketch.points)
        axis = gp_Ax2(sketch_point_to_world(plane, center.x, center.y), plane_normal(plane))
        edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, radius)).Edge()
        return BRepBuilderAPI_MakeWire(edge).Wire()

    polygon = BRepBuilderAPI_MakePolygon()
    for point_id in profile.point_ids:
        point = sketch.points[point_id]
        polygon.Add(sketch_point_to_world(plane, point.x, point.y))
    polygon.Close()
    return polygon.Wire()


def _wire_normal(wire: TopoDS_Wire) -> gp_Dir:
    """The outward normal of the planar face `wire` alone would bound, used
    only to compare relative winding direction between an outer wire and a
    candidate inner (hole) wire (see `_face_for_profile`) - not a
    meaningful normal on its own once wires are combined into one face.

    `BRepBuilderAPI_MakeFace.Add` does not reorient wires for you: the
    caller is responsible for making sure each inner wire winds the
    opposite way around from the outer one. `_wire_for_profile` gives no
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


def _face_for_profile(sketch: Sketch, profile: Profile, plane: Plane):
    """Builds `profile`'s face, punching a hole for each of its
    `inner_loops` (C1) via `BRepBuilderAPI_MakeFace.Add` - the standard
    OCCT idiom for a face-with-holes (BRepBuilderAPI_MakeFace(outerWire)
    then .Add(innerWire) per inner boundary, before the face is passed to
    BRepPrimAPI_MakePrism). Each inner wire is reversed relative to the
    outer one first (see `_wire_normal`) since `.Add` does not do this
    itself and Add-ing a hole wire with the same winding as the outer
    produces an invalid/doubled face instead of a hole."""
    outer_wire = _wire_for_profile(sketch, profile, plane)
    face_maker = BRepBuilderAPI_MakeFace(outer_wire)
    if profile.inner_loops:
        outer_normal = _wire_normal(outer_wire)
        for inner_loop in profile.inner_loops:
            inner_wire = _wire_for_profile(sketch, inner_loop, plane)
            if _wire_normal(inner_wire).Dot(outer_normal) > 0:
                inner_wire = inner_wire.Reversed()
            face_maker.Add(inner_wire)
    return face_maker.Face()


def _prism_for_profile(sketch: Sketch, profile: Profile, feature: ExtrudeFeature, plane: Plane):
    """One profile's face, moved to `feature.start_distance` along the
    Sketch plane's normal and swept the remaining span to
    `feature.end_distance` - the single-profile half of what used to be
    `_solid_for_extrude_feature` before C2 split it out so it can be
    called once per sub-profile of a MultiProfile."""
    normal = plane_normal(plane)
    direction = gp_Vec(normal.X(), normal.Y(), normal.Z())

    # start_distance/end_distance are both signed offsets along `direction`
    # from the sketch plane - the solid spans literally from one to the
    # other, so the face is moved to start_distance first and the prism
    # then covers the remaining (end_distance - start_distance) span.
    start_transform = gp_Trsf()
    start_transform.SetTranslation(direction.Multiplied(feature.start_distance))
    face = _face_for_profile(sketch, profile, plane)
    moved_face = BRepBuilderAPI_Transform(face, start_transform, True).Shape()

    prism_vector = direction.Multiplied(feature.end_distance - feature.start_distance)
    return BRepPrimAPI_MakePrism(moved_face, prism_vector).Shape()


def _solid_for_extrude_feature(
    feature: ExtrudeFeature, sketch_feature: SketchFeature
) -> TopoDS_Shape | None:
    """The real OCCT solid for one ExtrudeFeature, or None if its backing
    Sketch no longer has an extrudable profile - callers skip rather than
    error in that case, per the brief (a stale/edited-away profile
    shouldn't fail the whole mesh request).

    C2: a MultiProfile (status MULTIPLE_LOOPS, one sub-profile per disjoint
    outer loop, each already carrying its own C1 holes) produces one prism
    per sub-profile, combined into a single TopoDS_Compound - transparent
    to every caller of this function, which already only cares that it
    gets back one TopoDS_Shape."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    if result.status not in _EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping ExtrudeFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    plane = sketch.plane
    if result.status == ProfileStatus.CLOSED_LOOP:
        assert result.profile is not None
        profiles = [result.profile]
    else:
        profiles = result.loops
    solids = [_prism_for_profile(sketch, profile, feature, plane) for profile in profiles]

    if len(solids) == 1:
        return solids[0]

    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for solid in solids:
        builder.Add(compound, solid)
    return compound


def compute_part_solid(
    part: Part, hidden_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape | None:
    """Accumulates every ExtrudeFeature in `part.features`, in order, into a
    single solid: Boss fuses, Cut subtracts. A Cut with nothing yet
    accumulated is skipped (logged, not raised) since there is nothing to
    cut from. Returns None if no ExtrudeFeature contributed any geometry.

    An ExtrudeFeature whose id is in `hidden_feature_ids` (client-side
    Hide/Show, see app.document.router.get_part_mesh) is skipped entirely,
    as if it weren't in the Part's history at all - so hiding a Boss drops
    its volume and hiding a Cut un-subtracts it, in accumulation order."""
    accumulated: TopoDS_Shape | None = None
    for feature in part.features:
        if not isinstance(feature, ExtrudeFeature):
            continue
        if feature.id in hidden_feature_ids:
            continue

        sketch_feature = part.get_feature(feature.sketch_feature_id)
        if not isinstance(sketch_feature, SketchFeature):
            logger.warning(
                "Skipping ExtrudeFeature %s: referenced sketch feature %s not found",
                feature.id,
                feature.sketch_feature_id,
            )
            continue

        solid = _solid_for_extrude_feature(feature, sketch_feature)
        if solid is None:
            continue

        if feature.extrude_type == ExtrudeType.BOSS:
            accumulated = solid if accumulated is None else BRepAlgoAPI_Fuse(accumulated, solid).Shape()
        else:
            if accumulated is None:
                logger.warning(
                    "Skipping Cut ExtrudeFeature %s: no base solid exists yet to cut from",
                    feature.id,
                )
                continue
            accumulated = BRepAlgoAPI_Cut(accumulated, solid).Shape()

    return accumulated
