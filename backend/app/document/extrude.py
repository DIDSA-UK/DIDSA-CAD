"""OCCT geometry construction for ExtrudeFeature (Boss/Cut) - the Extrude
module described in the project brief's section 4.3, kept separate from
app.document.router the same way app.document.mesh's tessellation logic is.

Knows nothing about Sketch internals beyond what app.sketch already exposes
publicly (Profile, detect_profile, Sketch.points/entities) - mirrors the
brief's "Knows nothing about Sketch internals" requirement for Extrude.
"""

import logging

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
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.models import ExtrudeFeature, ExtrudeType, Part, SketchFeature
from app.sketch.models import Circle, Plane, Sketch
from app.sketch.profile import Profile, ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)

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


def _face_for_profile(sketch: Sketch, profile: Profile, plane: Plane):
    wire = _wire_for_profile(sketch, profile, plane)
    return BRepBuilderAPI_MakeFace(wire).Face()


def _solid_for_extrude_feature(
    feature: ExtrudeFeature, sketch_feature: SketchFeature
) -> TopoDS_Shape | None:
    """The real OCCT solid for one ExtrudeFeature, or None if its backing
    Sketch no longer has a closed profile - callers skip rather than error
    in that case, per the brief (a stale/edited-away profile shouldn't fail
    the whole mesh request)."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    if result.status != ProfileStatus.CLOSED_LOOP or result.profile is None:
        logger.warning(
            "Skipping ExtrudeFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    plane = sketch.plane
    face = _face_for_profile(sketch, result.profile, plane)
    normal = plane_normal(plane)
    direction = gp_Vec(normal.X(), normal.Y(), normal.Z())

    # start_distance/end_distance are both signed offsets along `direction`
    # from the sketch plane - the solid spans literally from one to the
    # other, so the face is moved to start_distance first and the prism
    # then covers the remaining (end_distance - start_distance) span.
    start_transform = gp_Trsf()
    start_transform.SetTranslation(direction.Multiplied(feature.start_distance))
    moved_face = BRepBuilderAPI_Transform(face, start_transform, True).Shape()

    prism_vector = direction.Multiplied(feature.end_distance - feature.start_distance)
    return BRepPrimAPI_MakePrism(moved_face, prism_vector).Shape()


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
