"""OCCT history for Sketch external references (docs/reference-identity-design.md (c)).

The signature search (`app.sketch.reference_signature`) re-finds a vertex by what it *looks like*. This module asks the kernel what *became* of it: while the
feature pipeline replays a Part, every operation that exposes OCCT's own history (`BRepFilletAPI_MakeFillet` / `MakeChamfer`, `BRepAlgoAPI_Cut` / `Fuse`,
`ShapeUpgrade_UnifySameDomain.History()`) reports itself through `note_operation`, and `app.document.extrude._apply_feature_to_bodies` closes each Feature
step into a `StepRecord` (the Body before, the Body after, the operations in between). Everything else (Shell, Mirror, Move Face, ...) has no hook and falls
back to matching a vertex by its exact position across that step.

How a vertex is carried across one step (`HistoryTrace.forward`): the same TShape still present in the result survives unchanged; otherwise whatever
`Modified()` / `Generated()` says it became; otherwise it was consumed. `IsDeleted()` is deliberately not used to decide survival: measured on OCCT 7.9
`BRepFilletAPI_MakeFillet.IsDeleted()` reports True for vertices the fillet did not touch at all.

A reference stores a `LineageOrigin` (found at creation by walking those steps backwards): the first Feature whose output *created* the vertex, and the vertex's
signature there. On a refresh whose index/fingerprint check failed, `ReferenceHistory.refine` rebuilds the Part with recording on (uncached, memoised per
Part + feature fingerprints), re-locates the origin vertex in the origin Feature's new output, and walks it forward through every later step to the final Body:
one survivor means "followed", none means "consumed by <feature>" (lost, never rebound to a look-alike), several means ambiguous (narrowed by signature).
This only runs on the slow path; the common refresh never rebuilds anything.
"""

from __future__ import annotations

import contextvars
import logging
from dataclasses import dataclass
from typing import Any

from OCC.Core.TopAbs import TopAbs_VERTEX
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import TopoDS_Shape
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.reference_signature import BodyVertexMeasurer
from app.sketch.reference_signature import (
    LineageOrigin,
    ReferenceDecision,
    ReferenceStatus,
    decide_reference,
    distance,
    fingerprint_matches,
    narrow_by_signature,
)

logger = logging.getLogger(__name__)


class HistoryOp:
    """One recorded OCCT operation, seen through the two calls the mapping needs. `source` is a `BRepBuilderAPI_MakeShape` / `BRepAlgoAPI_*` maker (both expose
    `Modified` / `Generated`) or a `BRepTools_History` (same names)."""

    def __init__(self, source: Any) -> None:
        self._source = source

    def successors(self, shape: TopoDS_Shape) -> list[TopoDS_Shape]:
        """The vertices `shape` (a vertex) was reported to have become (Modified then Generated); empty when the operation says nothing about it."""
        out: list[TopoDS_Shape] = []
        for call in (self._source.Modified, self._source.Generated):
            try:
                out.extend(s for s in call(shape) if s.ShapeType() == TopAbs_VERTEX)
            except Exception:  # an operation may refuse a shape that was never one of its arguments
                continue
        return out


class _Recorder:
    def __init__(self) -> None:
        self.pending: list[HistoryOp] = []
        self.steps: list[StepRecord] = []

    def drain(self) -> tuple[HistoryOp, ...]:
        ops, self.pending = tuple(self.pending), []
        return ops


_active: contextvars.ContextVar[_Recorder | None] = contextvars.ContextVar("reference_history_recorder", default=None)


def recording() -> bool:
    return _active.get() is not None


def note_operation(source: Any) -> None:
    """Called by an operation that has OCCT history to offer, right after it succeeded. A no-op unless a trace is being recorded."""
    recorder = _active.get()
    if recorder is not None:
        recorder.pending.append(HistoryOp(source))


def begin_step() -> None:
    recorder = _active.get()
    if recorder is not None:
        recorder.pending = []


def end_step(feature_id: str, before: dict[str, TopoDS_Shape], bodies: dict[str, TopoDS_Shape]) -> None:
    """Closes a Feature step: every Body whose shape object changed (or appeared) becomes a `StepRecord` carrying the operations noted since `begin_step`."""
    recorder = _active.get()
    if recorder is None:
        return
    ops = recorder.drain()
    for body_id, shape in bodies.items():
        if before.get(body_id) is shape:
            continue
        recorder.steps.append(StepRecord(feature_id, body_id, before.get(body_id), shape, ops))


@dataclass
class StepRecord:
    feature_id: str
    body_id: str
    before: TopoDS_Shape | None
    after: TopoDS_Shape
    ops: tuple[HistoryOp, ...]


@dataclass(frozen=True)
class HistoryOutcome:
    kind: str  # "found" | "consumed" | "unavailable"
    indices: tuple[int, ...] = ()  # in the numbering of the trace's final Body
    consumed_by: str | None = None


class HistoryTrace:
    """A recorded replay of a Part's features: the steps and the Bodies it ended with."""

    def __init__(self, steps: list[StepRecord], bodies: dict[str, TopoDS_Shape]) -> None:
        self.steps = steps
        self.bodies = bodies
        self._vertex_maps: dict[int, tuple[TopoDS_Shape, TopTools_IndexedMapOfShape]] = {}
        self._forward_cache: dict[tuple[int, int], tuple[int, ...]] = {}
        self._by_before: dict[int, list[StepRecord]] = {}
        self._produced_by: dict[int, StepRecord] = {}
        for step in steps:
            if step.before is not None:
                self._by_before.setdefault(id(step.before), []).append(step)
            self._produced_by[id(step.after)] = step

    def _vmap(self, shape: TopoDS_Shape) -> TopTools_IndexedMapOfShape:
        cached = self._vertex_maps.get(id(shape))
        if cached is None:
            vertex_map = TopTools_IndexedMapOfShape()
            topexp.MapShapes(shape, TopAbs_VERTEX, vertex_map)
            cached = self._vertex_maps[id(shape)] = (shape, vertex_map)  # keeping `shape` alive keeps id() unique
        return cached[1]

    def forward(self, step: StepRecord, old_index: int) -> tuple[int, ...]:
        """Indices in `step.after` that vertex `old_index` of `step.before` became (empty: consumed)."""
        key = (id(step), old_index)
        cached = self._forward_cache.get(key)
        if cached is not None:
            return cached
        assert step.before is not None
        before_map, after_map = self._vmap(step.before), self._vmap(step.after)
        current = [before_map.FindKey(old_index + 1)]
        for op in step.ops:
            current = [t for s in current for t in (op.successors(s) or [s])]
        found = sorted({after_map.FindIndex(s) - 1 for s in current if after_map.FindIndex(s) > 0})
        if not found:
            found = self._by_position(step, old_index)
        result = tuple(found)
        self._forward_cache[key] = result
        return result

    def _by_position(self, step: StepRecord, old_index: int) -> list[int]:
        """The step had no history for this vertex: a lone vertex of the result at exactly the same place (an operation we have no hook for)."""
        before = BodyVertexMeasurer(step.before).signature(old_index)
        after = BodyVertexMeasurer(step.after)
        eps = 1e-6 * (before.body_diagonal or 1.0)
        near = [i for i in range(after.count) if distance(after.signature(i).position, before.position) <= eps]
        return near if len(near) == 1 else []

    def preimages(self, step: StepRecord, new_index: int) -> list[int]:
        if step.before is None:
            return []
        count = self._vmap(step.before).Size()
        return [i for i in range(count) if new_index in self.forward(step, i)]

    def lineage_for(self, body_id: str, index: int) -> LineageOrigin | None:
        """Walks the recorded steps backwards from vertex `index` of the final Body `body_id` to the step that created it."""
        final = self.bodies.get(body_id)
        if final is None:
            return None
        step = self._produced_by.get(id(final))
        if step is None:
            return None
        while True:
            pre = self.preimages(step, index)
            previous = self._produced_by.get(id(step.before)) if step.before is not None else None
            if len(pre) != 1 or previous is None:
                break
            index, step = pre[0], previous
        signature = BodyVertexMeasurer(step.after).signature(index)
        return LineageOrigin(feature_id=step.feature_id, body_id=step.body_id, index=index, signature=signature)

    def forward_from_origin(self, origin: LineageOrigin, final_body_id: str) -> HistoryOutcome:
        origin_step = next((s for s in self.steps if s.feature_id == origin.feature_id and s.body_id == origin.body_id), None)
        if origin_step is None:
            return HistoryOutcome("unavailable")
        measurer = BodyVertexMeasurer(origin_step.after)
        located = decide_reference(origin.signature, origin.index, measurer.all())
        if located.status == ReferenceStatus.LOST or located.index is None:
            return HistoryOutcome("unavailable")
        queue: list[tuple[TopoDS_Shape, list[int]]] = [(origin_step.after, [located.index])]
        finals: list[tuple[TopoDS_Shape, list[int]]] = []
        consumed_by: str | None = None
        while queue:
            shape, indices = queue.pop()
            steps = self._by_before.get(id(shape), [])
            if not steps:
                finals.append((shape, indices))
                continue
            for step in steps:
                survivors = sorted({j for i in indices for j in self.forward(step, i)})
                if survivors:
                    queue.append((step.after, survivors))
                elif consumed_by is None:
                    consumed_by = step.feature_id
        target = self.bodies.get(final_body_id)
        for shape, indices in finals:
            if shape is target:
                return HistoryOutcome("found", tuple(indices))
        if not finals and consumed_by is not None:
            return HistoryOutcome("consumed", consumed_by=consumed_by)
        return HistoryOutcome("unavailable")


_TRACE_CACHE: dict[tuple, HistoryTrace] = {}
_TRACE_CACHE_SIZE = 4


def compute_history_trace(part, excluded_feature_ids: frozenset[str]) -> HistoryTrace:
    """Replays `part` uncached with recording on (the same walk `compute_part_bodies` does for a non-empty exclusion set)."""
    from app.document import body_cache
    from app.document.extrude import _apply_feature_to_bodies
    from app.document.graph import build_feature_graph, topological_order

    key = (part.id, excluded_feature_ids, tuple(body_cache.feature_fingerprint(f) for f in part.features))
    cached = _TRACE_CACHE.get(key)
    if cached is not None:
        return cached

    feature_index = {feature.id: i for i, feature in enumerate(part.features)}
    recorder = _Recorder()
    token = _active.set(recorder)
    bodies: dict[str, TopoDS_Shape] = {}
    try:
        for feature_id in topological_order(build_feature_graph(part)):
            feature = part.get_feature(feature_id)
            if feature.id in excluded_feature_ids:
                continue
            _apply_feature_to_bodies(feature, part, bodies, feature_index, excluded_feature_ids)
    finally:
        _active.reset(token)
    trace = HistoryTrace(recorder.steps, bodies)
    while len(_TRACE_CACHE) >= _TRACE_CACHE_SIZE:
        _TRACE_CACHE.pop(next(iter(_TRACE_CACHE)))
    _TRACE_CACHE[key] = trace
    return trace


class ReferenceHistory:
    """Lazy handle on the recorded trace of one Part (as of one causal snapshot): nothing is replayed until a reference actually needs it."""

    def __init__(self, part, excluded_feature_ids: frozenset[str]) -> None:
        self._part = part
        self._excluded = excluded_feature_ids
        self._trace: HistoryTrace | None = None
        self._failed = False

    def trace(self) -> HistoryTrace | None:
        if self._trace is None and not self._failed:
            try:
                self._trace = compute_history_trace(self._part, self._excluded)
            except Exception:  # history is an optimisation of identity, never a reason to fail a read
                logger.warning("Could not record OCCT history for part %s", self._part.id, exc_info=True)
                self._failed = True
        return self._trace

    def lineage_for(self, body_id: str, index: int) -> LineageOrigin | None:
        trace = self.trace()
        if trace is None:
            return None
        try:
            return trace.lineage_for(body_id, index)
        except Exception:
            logger.warning("Could not trace lineage of vertex %s of %s", index, body_id, exc_info=True)
            return None

    def refine(self, ref, signature_decision: ReferenceDecision, bodies: dict[str, TopoDS_Shape], measurer: BodyVertexMeasurer) -> ReferenceDecision:
        """Combine what OCCT history says with the signature search's `signature_decision` (docs/reference-identity-design.md, "Combining")."""
        trace = self.trace()
        if trace is None or ref.lineage is None:
            return signature_decision
        try:
            outcome = trace.forward_from_origin(ref.lineage, ref.body_id)
        except Exception:
            logger.warning("OCCT history lookup failed for a reference on %s", ref.body_id, exc_info=True)
            return signature_decision
        if outcome.kind == "consumed":
            return ReferenceDecision(ReferenceStatus.LOST, None, reason=f"consumed_by_{outcome.consumed_by}", method="history")
        if outcome.kind != "found":
            return signature_decision

        # Translate the trace's own numbering of the final Body into the caller's (the same shape rebuilt, so normally identical; matched by position).
        trace_measurer = BodyVertexMeasurer(trace.bodies[ref.body_id])
        eps = 1e-6 * (measurer.diagonal or 1.0)
        mapped: list[int] = []
        for i in outcome.indices:
            position = trace_measurer.signature(i).position
            mapped.extend(j for j in range(measurer.count) if distance(measurer.signature(j).position, position) <= eps and j not in mapped)
        if not mapped:
            return signature_decision
        if len(mapped) > 1 and ref.signature is not None:
            mapped = narrow_by_signature(ref.signature, mapped, measurer.all())
        if len(mapped) != 1:
            return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous", method="history", candidates=tuple(mapped))
        index = mapped[0]
        lineage = LineageOrigin(
            ref.lineage.feature_id, ref.lineage.body_id, ref.lineage.index, ref.lineage.signature
        )
        status = ReferenceStatus.OK if index == ref.vertex_index else ReferenceStatus.FOLLOWED
        reason = "" if status == ReferenceStatus.OK else "history"
        return ReferenceDecision(status, index, reason=reason, method="history", lineage=lineage)


def history_for_part(part, excluded_feature_ids: frozenset[str] = frozenset()) -> ReferenceHistory:
    return ReferenceHistory(part, excluded_feature_ids)
