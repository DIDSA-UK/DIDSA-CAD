"""OCCT geometry construction for ExtrudeFeature (Boss/Cut) - the Extrude
module described in the project brief's section 4.3, kept separate from
app.document.router the same way app.document.mesh's tessellation logic is.

Knows nothing about Sketch internals beyond what app.sketch already exposes
publicly (Profile, detect_profile, Sketch.points/entities) - mirrors the
brief's "Knows nothing about Sketch internals" requirement for Extrude.
"""

import logging

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
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED, TopAbs_SOLID, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.graph import base_feature_id, build_feature_graph, topological_order
from app.document.models import (
    ChamferFeature,
    ExtrudeFeature,
    ExtrudeType,
    FilletFeature,
    Part,
    ResolvedPlane,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)
from app.sketch.models import Circle, Sketch
from app.sketch.profile import Profile, ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404

logger = logging.getLogger(__name__)

# C1/C2: an ExtrudeFeature's backing Sketch is extrudable whenever its
# Profile detection reports a usable boundary - a single nested profile
# (holes folded in) or a MultiProfile of disjoint outer profiles (each with
# its own holes). Every other status (NO_LOOP, BRANCH, INVALID_NESTING) has
# nothing extrudable to offer.
_EXTRUDABLE_STATUSES = frozenset({ProfileStatus.CLOSED_LOOP, ProfileStatus.MULTIPLE_LOOPS})


def basis_normal(basis: ResolvedPlane) -> gp_Dir:
    x, y, z = basis.normal
    return gp_Dir(x, y, z)


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


def _wire_for_profile(sketch: Sketch, profile: Profile, basis: ResolvedPlane):
    """A Profile is either a Line-chain polygon (the common case) or a
    standalone Circle (see app.sketch.profile._circle_profile, which packs
    the Circle's own entity id into `line_ids` rather than a Line chain) -
    each needs a different OCCT wire construction."""
    if len(profile.line_ids) == 1 and isinstance(sketch.entities.get(profile.line_ids[0]), Circle):
        circle = sketch.entities[profile.line_ids[0]]
        center = sketch.points[circle.center_point_id]
        radius = circle.radius(sketch.points)
        axis = gp_Ax2(basis_point_to_world(basis, center.x, center.y), basis_normal(basis))
        edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, radius)).Edge()
        return BRepBuilderAPI_MakeWire(edge).Wire()

    polygon = BRepBuilderAPI_MakePolygon()
    for point_id in profile.point_ids:
        point = sketch.points[point_id]
        polygon.Add(basis_point_to_world(basis, point.x, point.y))
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


def _face_for_profile(sketch: Sketch, profile: Profile, basis: ResolvedPlane):
    """Builds `profile`'s face, punching a hole for each of its
    `inner_loops` (C1) via `BRepBuilderAPI_MakeFace.Add` - the standard
    OCCT idiom for a face-with-holes (BRepBuilderAPI_MakeFace(outerWire)
    then .Add(innerWire) per inner boundary, before the face is passed to
    BRepPrimAPI_MakePrism). Each inner wire is reversed relative to the
    outer one first (see `_wire_normal`) since `.Add` does not do this
    itself and Add-ing a hole wire with the same winding as the outer
    produces an invalid/doubled face instead of a hole."""
    outer_wire = _wire_for_profile(sketch, profile, basis)
    face_maker = BRepBuilderAPI_MakeFace(outer_wire)
    if profile.inner_loops:
        outer_normal = _wire_normal(outer_wire)
        for inner_loop in profile.inner_loops:
            inner_wire = _wire_for_profile(sketch, inner_loop, basis)
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
    face = _face_for_profile(sketch, profile, basis)
    moved_face = BRepBuilderAPI_Transform(face, start_transform, True).Shape()

    prism_vector = direction.Multiplied(feature.end_distance - feature.start_distance)
    return BRepPrimAPI_MakePrism(moved_face, prism_vector).Shape()


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
    if result.status not in _EXTRUDABLE_STATUSES:
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
        profiles = [result.profile]
    else:
        profiles = result.loops
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
    resolve_chamfer_from_bodies`."""
    from app.document.chamfer import resolve_chamfer_from_bodies
    from app.document.fillet import resolve_fillet_from_bodies

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

        solid = _solid_for_extrude_feature(feature, sketch_feature, part, bodies, excluded_feature_ids)
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
