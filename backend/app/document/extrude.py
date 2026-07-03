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
from OCC.Core.TopAbs import TopAbs_REVERSED, TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.graph import GraphNode, topological_order
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


def base_feature_id(body_id: str) -> str:
    """The original creating ExtrudeFeature's id for `body_id` - strips the
    `#N` split-index suffix `_register_solids` appends when a single
    operation produces more than one maximally-connected solid (a
    multi-profile Boss, or a Cut that severs a Body into disconnected
    pieces - see `_register_solids`'s own docstring). A plain, unsuffixed
    `body_id` (the common single-solid case) is returned unchanged.

    Used anywhere a composite Body id needs to be resolved back to "which
    Feature does this ultimately trace back to" - the merge-survivor
    tie-break below, `build_feature_graph`'s dependency edges, and
    `app.document.router._validate_target_body_ids`, which all only care
    about the owning Feature, not the exact (possibly split) Body id."""
    return body_id.split("#", 1)[0]


def build_feature_graph(part: Part) -> list[GraphNode]:
    """The dependency edges recompute is driven by (A1) - every
    ExtrudeFeature depends on the SketchFeature it extrudes plus every Body
    it names in `target_body_ids`. A Body's id is always derived from the
    id of the ExtrudeFeature that created it (see `base_feature_id`), so a
    `target_body_ids` entry always resolves to a real Feature id once split
    suffixes are stripped - no separate Feature<->Body lookup table is
    needed to build these edges, the graph is entirely over `part.features`
    ids.

    SketchFeatures have no dependencies (they don't reference any other
    Feature). Feature ids that don't resolve to anything (already invalid
    input, rejected at creation time - see
    app.document.router._validate_target_body_ids) are simply ignored by
    app.document.graph.topological_order rather than raising here."""
    nodes = []
    for feature in part.features:
        depends_on: tuple[str, ...] = ()
        if isinstance(feature, ExtrudeFeature):
            depends_on = (
                feature.sketch_feature_id,
                *(base_feature_id(tid) for tid in feature.target_body_ids),
            )
        nodes.append(GraphNode(id=feature.id, depends_on=depends_on))
    return nodes


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


def compute_part_bodies(
    part: Part, hidden_feature_ids: frozenset[str] = frozenset()
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
    doesn't currently exist (e.g. hidden away via `hidden_feature_ids`) is
    skipped for that Body only (logged, not raised) - mirrors the old
    "Cut with nothing to cut from" skip behaviour.

    Amendment to A1's original rule: every Boss/Cut result (new, fused, or
    cut) is decomposed into its maximally-connected solid components (see
    `_register_solids`) before being (re)registered - a Body is always one
    connected piece of material, so a multi-profile Boss with disjoint
    outer loops, or a Cut that severs a Body into disconnected pieces,
    produces multiple Bodies from that one operation, not one compound
    Body. The common single-solid case is entirely unaffected (same ids as
    before this amendment).

    An ExtrudeFeature whose id is in `hidden_feature_ids` (client-side
    Hide/Show, see app.document.router.get_part_mesh) is skipped entirely,
    as if it weren't in the Part's history at all."""
    feature_index = {feature.id: i for i, feature in enumerate(part.features)}
    bodies: dict[str, TopoDS_Shape] = {}

    order = topological_order(build_feature_graph(part))
    for feature_id in order:
        feature = part.get_feature(feature_id)
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
            target_ids = [tid for tid in feature.target_body_ids if tid in bodies]
            if feature.target_body_ids and not target_ids:
                logger.warning(
                    "Boss ExtrudeFeature %s: none of its target_body_ids currently exist "
                    "(likely hidden) - starting a new Body instead",
                    feature.id,
                )
            if not target_ids:
                _register_solids(bodies, feature.id, solid)
                continue

            merged = solid
            for target_id in target_ids:
                merged = BRepAlgoAPI_Fuse(merged, bodies[target_id]).Shape()

            survivor_id = min(target_ids, key=lambda tid: feature_index[base_feature_id(tid)])
            for target_id in target_ids:
                del bodies[target_id]
            _register_solids(bodies, survivor_id, merged)
        else:
            for target_id in feature.target_body_ids:
                if target_id not in bodies:
                    logger.warning(
                        "Skipping Cut ExtrudeFeature %s: target body %s does not exist",
                        feature.id,
                        target_id,
                    )
                    continue
                cut_result = BRepAlgoAPI_Cut(bodies[target_id], solid).Shape()
                del bodies[target_id]
                _register_solids(bodies, target_id, cut_result)

    return bodies
