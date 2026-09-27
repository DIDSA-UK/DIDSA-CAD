"""OCCT geometry construction for `FillSurfaceFeature` - a single surface
filling the boundary curves named by `boundary_refs`, via OCCT
`BRepOffsetAPI_MakeFilling` (a constraint-based filling surface, not a
strict "assemble one closed wire first" construction - it tolerates small
gaps/non-planar boundaries by design, which is why this module doesn't
pre-chain `boundary_refs` into one wire the way `app.document.sweep.
resolve_path_wire` does for a Sweep path: `MakeFilling` wants a set of
boundary/constraint edges, not a pre-assembled wire, and already handles
connecting them itself).

Each `boundary_refs` entry independently resolves to one or more edges (a
Sketch entity, a Body edge, or - the new case this module exists to support
- a Curve feature, which may itself be a multi-edge wire, e.g. an
Intersection curve) via the same per-entry resolvers `app.document.sweep`
already uses for its own `path_refs`, reused here rather than duplicated.
"""

from fastapi import HTTPException
from OCC.Core.GeomAbs import GeomAbs_C0
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakeFilling
from OCC.Core.TopAbs import TopAbs_EDGE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Shape, topods

from app.document.curve import resolve_curve_feature_by_id
from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import FillSurfaceFeature, Part, SketchOrEdgeRef
from app.document.sweep import _resolve_path_segment


def _fill_surface_failed(feature_id: str) -> HTTPException:
    """`BRepOffsetAPI_MakeFilling.IsDone()` returned false - the boundary
    curves don't form a fillable surface (too few, degenerate, or wildly
    non-planar/disconnected). Mirrors `app.document.sweep._sweep_failed`'s
    identical "structured 422, not an uncaught OCCT exception" convention."""
    return HTTPException(status_code=422, detail={"type": "fill_surface_failed", "feature_id": feature_id})


def _edges_for_boundary_ref(
    part: Part,
    ref: SketchOrEdgeRef,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> list[TopoDS_Edge]:
    """One `boundary_refs` entry's own edge(s), regardless of which of the
    three `SketchOrEdgeRef` kinds it is - a Sketch entity may itself build
    more than one edge (a Spline's per-segment Bezier edges, via
    `app.document.sweep._resolve_path_segment`'s own `_PathSegment.edges`),
    and a Curve feature's own wire may hold more than one (an Intersection
    curve chained from several `BRepAlgoAPI_Section` pieces)."""
    if ref.curve_feature_id is not None:
        resolved = resolve_curve_feature_by_id(part, ref.curve_feature_id, bodies_so_far, excluded_feature_ids)
        explorer = TopExp_Explorer(resolved.wire, TopAbs_EDGE)
        edges = []
        while explorer.More():
            edges.append(topods.Edge(explorer.Current()))
            explorer.Next()
        return edges
    if ref.edge_ref is not None:
        return [topods.Edge(resolve_subshape_from_bodies(bodies_so_far, ref.edge_ref))]
    assert ref.sketch_entity_ref is not None
    return _resolve_path_segment(part, ref.sketch_entity_ref, bodies_so_far, excluded_feature_ids).edges


def resolve_fill_surface_from_bodies(
    feature: FillSurfaceFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The real OCCT filling surface for one `FillSurfaceFeature` - every
    `boundary_refs` entry's own edge(s) become one `BRepOffsetAPI_
    MakeFilling` constraint each (`GeomAbs_C0`: position-only continuity -
    v1 scope, no tangent/curvature-matching option yet)."""
    filling = BRepOffsetAPI_MakeFilling()
    for ref in feature.boundary_refs:
        for edge in _edges_for_boundary_ref(part, ref, bodies_so_far, excluded_feature_ids):
            filling.Add(edge, GeomAbs_C0)
    filling.Build()
    if not filling.IsDone():
        raise _fill_surface_failed(feature.id)
    return filling.Shape()


def resolve_fill_surface(
    part: Part,
    feature: FillSurfaceFeature,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> TopoDS_Shape:
    """Resolves a `FillSurfaceFeature` - fresh wrapper around `resolve_fill_
    surface_from_bodies`, mirroring every other surface feature's own
    fresh-vs-`_from_bodies` split (e.g. `app.document.create_plane.
    resolve_offset_face`)."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_fill_surface_from_bodies(feature, part, bodies, excluded_feature_ids)
