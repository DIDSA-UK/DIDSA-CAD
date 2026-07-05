"""Generic dependency-graph topological sort used to drive Part recompute
(A1), plus the graph-building (`build_feature_graph`) and cascade-delete
(`transitive_dependents`) logic that walks it (B2) - deliberately has no
OCCT/pythonocc-core import anywhere in this file (only `app.document.models`,
which is itself OCCT-free) so all of it can be unit-tested without the real
OCCT environment.

Recompute used to be driven by `part.features`' list order directly (a
single flat fold - see the old app.document.extrude.compute_part_solid).
A1 replaces that with an explicit dependency graph over Feature ids
(edges built by `build_feature_graph` below) and a real topological sort
over it, so a Feature can depend on more than just "the Feature immediately
before it in the list" - e.g. an ExtrudeFeature's `target_body_ids` (A1's
multi-body identity) can name a body produced far earlier in the history.

Kahn's algorithm is used with one deliberate choice: among all nodes
currently ready to run, the one that appears earliest in the original
input order is picked first. For every part.features history that has no
"reach back past the immediately preceding Feature" edges (i.e. every
single-body scenario that existed before A1), this reduces to exactly the
original list order, satisfying A1's regression requirement by
construction rather than by coincidence.

B2 (`build_feature_graph`/`base_feature_id`, moved here from
app.document.extrude; `transitive_dependents`, new) reuses these same
`GraphNode`/edges for graph-aware cascade delete - deleting a Feature now
deletes exactly its real transitive dependents, not "everything after it
in the list" (see `transitive_dependents`'s own docstring)."""

from __future__ import annotations

from dataclasses import dataclass

from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    Part,
    PlaneRef,
    PlaneType,
    SketchFeature,
)


class CycleError(ValueError):
    """Raised when the graph has no valid topological order - a Feature
    (directly or transitively) depends on itself. Should not be reachable
    through the client-facing API today (a Feature can only ever reference
    ids that already exist by the time it is created), but recompute stays
    defensive against malformed/hand-crafted documents rather than
    recursing forever or silently dropping nodes."""


@dataclass(frozen=True)
class GraphNode:
    """One node in a Feature dependency graph. `depends_on` holds the ids
    of every node that must be processed before this one - duplicates and
    ids that don't correspond to any node in the graph are both tolerated
    (the latter simply never contributes an edge), so callers don't need
    to pre-filter."""

    id: str
    depends_on: tuple[str, ...] = ()


def topological_order(nodes: list[GraphNode]) -> list[str]:
    """Returns node ids in an order where every id appears after all of its
    `depends_on` ids - Kahn's algorithm, with ties among simultaneously
    "ready" nodes broken by original input order (see module docstring).

    Raises CycleError if no valid order exists. Dependency ids with no
    matching node are ignored (not an error) - only edges between two
    known nodes are ever enforced."""
    index_of_id = {node.id: i for i, node in enumerate(nodes)}
    known_ids = set(index_of_id)

    dependents: dict[str, list[str]] = {node.id: [] for node in nodes}
    remaining_dep_count: dict[str, int] = {}
    for node in nodes:
        deps = {dep for dep in node.depends_on if dep in known_ids and dep != node.id}
        remaining_dep_count[node.id] = len(deps)
        for dep in deps:
            dependents[dep].append(node.id)

    ready = sorted(
        (node.id for node in nodes if remaining_dep_count[node.id] == 0),
        key=lambda node_id: index_of_id[node_id],
    )

    order: list[str] = []
    while ready:
        ready.sort(key=lambda node_id: index_of_id[node_id])
        current = ready.pop(0)
        order.append(current)
        for dependent in dependents[current]:
            remaining_dep_count[dependent] -= 1
            if remaining_dep_count[dependent] == 0:
                ready.append(dependent)

    if len(order) != len(nodes):
        raise CycleError("Feature dependency graph has a cycle - no valid recompute order exists")

    return order


def base_feature_id(body_id: str) -> str:
    """The original creating ExtrudeFeature's id for `body_id` - strips the
    `#N` split-index suffix `app.document.extrude._register_solids` appends
    when a single operation produces more than one maximally-connected solid
    (a multi-profile Boss, or a Cut that severs a Body into disconnected
    pieces - see `_register_solids`'s own docstring). A plain, unsuffixed
    `body_id` (the common single-solid case) is returned unchanged.

    Used anywhere a composite Body id needs to be resolved back to "which
    Feature does this ultimately trace back to" - the merge-survivor
    tie-break in `app.document.extrude.compute_part_bodies`,
    `build_feature_graph`'s dependency edges below, and
    `app.document.router._validate_target_body_ids`, which all only care
    about the owning Feature, not the exact (possibly split) Body id.

    B2: moved here from app.document.extrude (which imports OCCT/pythonocc-
    core at module level for unrelated geometry-construction reasons) since
    this function - like `build_feature_graph` below - touches no OCCT API
    at all and B2's cascade-delete graph walk needs to unit-test it without
    a real OCCT environment, the same way `topological_order` already is."""
    return body_id.split("#", 1)[0]


def sketch_feature_id_for_sketch(part: Part, sketch_id: str) -> str | None:
    """C2: resolves a `SketchEntityRef.sketch_id` (an `app.sketch.models.
    Sketch` id) back to the `SketchFeature` id that wraps it in `part` - the
    two are different ids (a Feature's own id vs. the Sketch it wraps, see
    `SketchFeature`'s own docstring), so a `CreatePlaneFeature`'s
    `NORMAL_TO_LINE_AT_POINT` dependency edge (below) can't just reuse
    `sketch_id` directly the way an ExtrudeFeature's `sketch_feature_id`
    already is a Feature id. Returns None (never raises) if no such
    SketchFeature exists - `build_feature_graph`'s caller already tolerates
    unresolvable dependency ids, same as `target_body_ids` entries that
    don't resolve to a real ExtrudeFeature.

    C3: public (no leading underscore) since `app.document.create_plane.
    _basis_for_sketch` now also needs it, to find a Sketch's owning
    SketchFeature (and so its `plane_feature_id`, if any) starting from just
    a bare `Sketch` - the same lookup this module's own `build_feature_graph`
    already needed for a `NORMAL_TO_LINE_AT_POINT` CreatePlaneFeature's
    dependency edge."""
    for feature in part.features:
        if isinstance(feature, SketchFeature) and feature.sketch_id == sketch_id:
            return feature.id
    return None


def build_feature_graph(part: Part) -> list[GraphNode]:
    """The dependency edges recompute is driven by (A1) - every
    ExtrudeFeature depends on the SketchFeature it extrudes plus every Body
    it names in `target_body_ids`. A Body's id is always derived from the
    id of the ExtrudeFeature that created it (see `base_feature_id`), so a
    `target_body_ids` entry always resolves to a real Feature id once split
    suffixes are stripped - no separate Feature<->Body lookup table is
    needed to build these edges, the graph is entirely over `part.features`
    ids.

    C3: a `SketchFeature` anchored to a custom plane (`plane_feature_id` set
    - see its own docstring) depends on that `CreatePlaneFeature` too - a
    fixed-plane Sketch (the common case, `plane_feature_id` is None) still
    has no dependencies of its own.

    Feature ids that don't resolve to anything (already invalid input,
    rejected at creation time - see
    app.document.router._validate_target_body_ids) are simply ignored by
    `topological_order`/`transitive_dependents` rather than raising here.

    C2/C3/C4: a `CreatePlaneFeature` depends on whatever it references too -
    the owning ExtrudeFeature(s) of any Body face/edge/vertex it names, or
    the SketchFeature wrapping any Sketch entity it names (see
    `_create_plane_dependencies` for the full per-`plane_type` breakdown) -
    without this, cascade-deleting the Feature a Plane references would
    silently leave it dangling instead of taking it down too, the exact
    "everything after it in the list" bug class B2 fixed for Boss/Cut's
    `target_body_ids`, just for a new reference kind.

    B2: also the graph cascade delete walks (see `transitive_dependents`)
    - moved here from app.document.extrude alongside `base_feature_id` for
    the same OCCT-free-testability reason (see that function's docstring)."""
    nodes = []
    for feature in part.features:
        depends_on: tuple[str, ...] = ()
        if isinstance(feature, SketchFeature):
            depends_on = (feature.plane_feature_id,) if feature.plane_feature_id else ()
        elif isinstance(feature, ExtrudeFeature):
            depends_on = (
                feature.sketch_feature_id,
                *(base_feature_id(tid) for tid in feature.target_body_ids),
            )
        elif isinstance(feature, CreatePlaneFeature):
            depends_on = _create_plane_dependencies(part, feature)
        nodes.append(GraphNode(id=feature.id, depends_on=depends_on))
    return nodes


def _plane_ref_dependency(ref: PlaneRef) -> str | None:
    """C5: the single Feature id `ref` depends on, or `None` if it depends
    on nothing - a `face_ref` depends on the owning ExtrudeFeature of its
    Body (`base_feature_id`), a `plane_feature_id` depends on that Plane
    Feature directly (already a Feature id, no `base_feature_id` mapping
    needed), and a `fixed_plane` depends on nothing at all - one of the
    three fixed reference planes always exists, no Feature produces it."""
    if ref.face_ref is not None:
        return base_feature_id(ref.face_ref.body_id)
    if ref.plane_feature_id is not None:
        return ref.plane_feature_id
    return None


def _create_plane_dependencies(part: Part, feature: CreatePlaneFeature) -> tuple[str, ...]:
    """C2/C3/C4/C5: `build_feature_graph`'s per-`plane_type` dependency-edge
    logic for a `CreatePlaneFeature`, split out since C4 added three more
    types (each with their own reference shape) to C2/C3's original two:
    - `OFFSET_FACE`/`MIDPLANE`: whatever each `face_refs` entry depends on
      (see `_plane_ref_dependency` - a Body's owning ExtrudeFeature, an
      existing Plane's own Feature id, or nothing for a fixed reference
      plane), one entry for `OFFSET_FACE`, two for `MIDPLANE`.
    - `NORMAL_TO_EDGE_THROUGH_VERTEX`: the owning ExtrudeFeature(s) of
      `edge_ref`'s and `vertex_ref`'s `body_id`s (deduplicated - normally
      the same Body, but not required to be).
    - `PARALLEL_TO_FACE_THROUGH_VERTEX`: whatever `face_refs[0]` depends on
      (see `_plane_ref_dependency`) plus the owning ExtrudeFeature of
      `vertex_ref`'s `body_id` (same dedup).
    - `THREE_POINTS`: for each of `point_refs`' three entries, either the
      owning ExtrudeFeature of its `vertex_ref`'s `body_id`, or the
      SketchFeature wrapping its `sketch_point_ref`'s `sketch_id`.
    - `NORMAL_TO_LINE_AT_POINT`: the SketchFeature wrapping `line_ref`'s
      `sketch_id` (`line_ref`/`point_ref` always share one Sketch by
      construction - see `app.document.router._validate_create_plane_payload`).
    """
    if feature.plane_type in (PlaneType.OFFSET_FACE, PlaneType.MIDPLANE) and feature.face_refs:
        deps = {_plane_ref_dependency(ref) for ref in feature.face_refs}
        return tuple(dep for dep in deps if dep is not None)
    if feature.plane_type == PlaneType.NORMAL_TO_EDGE_THROUGH_VERTEX:
        if feature.edge_ref is None or feature.vertex_ref is None:
            return ()
        return tuple({base_feature_id(feature.edge_ref.body_id), base_feature_id(feature.vertex_ref.body_id)})
    if feature.plane_type == PlaneType.PARALLEL_TO_FACE_THROUGH_VERTEX:
        if not feature.face_refs or feature.vertex_ref is None:
            return ()
        deps = {_plane_ref_dependency(feature.face_refs[0]), base_feature_id(feature.vertex_ref.body_id)}
        return tuple(dep for dep in deps if dep is not None)
    if feature.plane_type == PlaneType.THREE_POINTS:
        deps: set[str] = set()
        for point_ref in feature.point_refs:
            if point_ref.vertex_ref is not None:
                deps.add(base_feature_id(point_ref.vertex_ref.body_id))
            elif point_ref.sketch_point_ref is not None:
                sketch_feature_id = sketch_feature_id_for_sketch(
                    part, point_ref.sketch_point_ref.sketch_id
                )
                if sketch_feature_id is not None:
                    deps.add(sketch_feature_id)
        return tuple(deps)
    if feature.line_ref is not None:
        sketch_feature_id = sketch_feature_id_for_sketch(part, feature.line_ref.sketch_id)
        return (sketch_feature_id,) if sketch_feature_id is not None else ()
    return ()


def transitive_dependents(nodes: list[GraphNode], feature_id: str) -> set[str]:
    """B2: every node that transitively depends on `feature_id` - directly,
    or via a chain of `depends_on` edges - plus `feature_id` itself. This is
    the graph-aware cascade-delete set: deleting `feature_id` must also
    delete everything that would be left dangling by its absence, and
    nothing else (not "everything after it in the list", which is what
    cascade delete did before B2 and which only happened to look correct
    for every pre-A1 single-body scenario, where list order and dependency
    order coincide).

    Walks the *reverse* of the `depends_on` edges `topological_order` itself
    walks forward - built once as a `dependents` adjacency map, then a
    plain worklist traversal from `feature_id`. A Sketch feeding two
    independent Extrudes: deleting one Extrude only ever reaches that
    Extrude (it has no dependents of its own) - the Sketch and the sibling
    Extrude are never visited, since nothing depends on the deleted
    Extrude. Deleting the Sketch itself reaches both Extrudes (each has the
    Sketch in its own `depends_on`) and, transitively, anything depending on
    either of them.

    `feature_id` not corresponding to any node returns an empty set - there
    is nothing to cascade from a node that isn't there, mirroring
    `topological_order`'s existing tolerance of unknown ids elsewhere in
    this module."""
    dependents: dict[str, list[str]] = {node.id: [] for node in nodes}
    known_ids = set(dependents)
    for node in nodes:
        for dep in node.depends_on:
            if dep in known_ids:
                dependents[dep].append(node.id)

    if feature_id not in known_ids:
        return set()

    to_delete: set[str] = set()
    worklist = [feature_id]
    while worklist:
        current = worklist.pop()
        if current in to_delete:
            continue
        to_delete.add(current)
        worklist.extend(dependents[current])

    return to_delete
