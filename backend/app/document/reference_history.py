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

from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_VERTEX
from OCC.Core.TopExp import topexp
from OCC.Core.TopoDS import TopoDS_Shape
from OCC.Core.TopTools import TopTools_IndexedMapOfShape

from app.document.reference_signature import measurer_for
from app.sketch.reference_signature import (
    LineageOrigin,
    ReferenceDecision,
    ReferenceStatus,
    ShapeSignature,
    decide_reference,
    distance,
    fingerprint_matches,
    narrow_by_signature,
    shape_distance,
)

logger = logging.getLogger(__name__)


class HistoryOp:
    """One recorded OCCT operation, seen through the one call the mapping needs. `source` is a `BRepBuilderAPI_MakeShape` / `BRepAlgoAPI_*` maker (both expose
    `Modified`), a `BRepTools_History`, or any object with `Modified(shape)` (see `ReShapeHistory`).

    `authoritative` is False for an operation that only ever *merges or simplifies* (the unify pass that runs after every step): its silence about a sub-shape
    does not mean the sub-shape was consumed, so a step with no authoritative operation cannot say what became of anything (see `StepRecord.covered`)."""

    def __init__(self, source: Any, authoritative: bool = True) -> None:
        self._source = source
        self.authoritative = authoritative

    def successors(self, shape: TopoDS_Shape) -> list[TopoDS_Shape]:
        """The sub-shapes of `shape`'s own kind (vertex / edge / face) that `shape` was reported to have been MODIFIED into; empty when the operation says nothing
        about it (it survived untouched, or it is gone). `Generated()` is deliberately not read: it lists NEW sub-shapes derived from `shape` (a Fillet's face
        from the rounded edge, a Shell's inner offset face from the outer face), which are not what `shape` became."""
        kind = shape.ShapeType()
        try:
            return [s for s in self._source.Modified(shape) if s.ShapeType() == kind]
        except Exception:  # an operation may refuse a shape that was never one of its arguments
            return []


class ReShapeHistory:
    """Adapts a `ShapeBuild_ReShape` context (what `ShapeUpgrade_ShapeConvertToBezier` and friends replace sub-shapes through) to the `Modified(shape)` call."""

    def __init__(self, context: Any) -> None:
        self._context = context

    def Modified(self, shape: TopoDS_Shape) -> list[TopoDS_Shape]:  # noqa: N802 - mirrors OCCT's name
        replaced = self._context.Value(shape)
        return [] if replaced is None or replaced.IsNull() or replaced.IsSame(shape) else [replaced]


class _Recorder:
    def __init__(self) -> None:
        self.pending: list[HistoryOp] = []
        self.steps: list[StepRecord] = []
        # feature id -> the Bodies as that Feature found them (a shallow copy of the accumulator at the start of its step): the shape objects a reference made by
        # that Feature points into, so `HistoryTrace.lineage_before_feature` can start a backward walk from them.
        self.inputs: dict[str, dict[str, TopoDS_Shape]] = {}

    def drain(self) -> tuple[HistoryOp, ...]:
        ops, self.pending = tuple(self.pending), []
        return ops


_active: contextvars.ContextVar[_Recorder | None] = contextvars.ContextVar("reference_history_recorder", default=None)


def recording() -> bool:
    return _active.get() is not None


def note_operation(source: Any, authoritative: bool = True) -> None:
    """Called by an operation that has OCCT history to offer, right after it succeeded. A no-op unless a trace is being recorded."""
    recorder = _active.get()
    if recorder is not None:
        recorder.pending.append(HistoryOp(source, authoritative))


def begin_step(feature_id: str | None = None, bodies: dict[str, TopoDS_Shape] | None = None) -> None:
    recorder = _active.get()
    if recorder is not None:
        recorder.pending = []
        if feature_id is not None and bodies is not None:
            recorder.inputs[feature_id] = dict(bodies)


def end_step(feature_id: str, before: dict[str, TopoDS_Shape], bodies: dict[str, TopoDS_Shape]) -> None:
    """Closes a Feature step: every Body whose shape object changed (or appeared) becomes a `StepRecord` carrying the operations noted since `begin_step`."""
    recorder = _active.get()
    if recorder is None:
        return
    ops = recorder.drain()
    # A Body that did not exist before the step but came out of an operation that works on exactly one pre-existing Body this step changed or removed (a Split's
    # second piece, the second half of a Cut that severs a Body) is derived from it: its history starts from that Body, not from nothing.
    changed_sources = [shape for body_id, shape in before.items() if bodies.get(body_id) is not shape]
    derived_from = changed_sources[0] if len(changed_sources) == 1 and any(op.authoritative for op in ops) else None
    for body_id, shape in bodies.items():
        if before.get(body_id) is shape:
            continue
        source = before.get(body_id)
        if source is None:
            source = derived_from
        recorder.steps.append(StepRecord(feature_id, body_id, source, shape, ops))


@dataclass
class StepRecord:
    feature_id: str
    body_id: str
    before: TopoDS_Shape | None
    after: TopoDS_Shape
    ops: tuple[HistoryOp, ...]

    @property
    def covered(self) -> bool:
        """Whether the step ran at least one operation that reports history authoritatively. An uncovered step (Move Face, Pattern internals, ... anything
        without a hook) can still carry a sub-shape across when it survives by identity or sits at exactly the same place, but when it finds nothing it must
        say "unknown", never "consumed"."""
        return any(op.authoritative for op in self.ops)


@dataclass(frozen=True)
class HistoryOutcome:
    kind: str  # "found" | "consumed" | "unavailable"
    indices: tuple[int, ...] = ()  # in the numbering of the trace's final Body
    consumed_by: str | None = None


_TOPABS_FOR_KIND = {"vertex": TopAbs_VERTEX, "edge": TopAbs_EDGE, "face": TopAbs_FACE}


class HistoryTrace:
    """A recorded replay of a Part's features: the steps, the Bodies it ended with and the Bodies each Feature found as its input. Everything is per sub-shape
    `kind` ("vertex" / "edge" / "face"; the index of a sub-shape is its `topexp.MapShapes` index within its Body)."""

    def __init__(self, steps: list[StepRecord], bodies: dict[str, TopoDS_Shape], inputs: dict[str, dict[str, TopoDS_Shape]] | None = None) -> None:
        self.steps = steps
        self.bodies = bodies
        self.inputs = inputs or {}
        self._maps: dict[tuple[int, str], tuple[TopoDS_Shape, TopTools_IndexedMapOfShape]] = {}
        self._forward_cache: dict[tuple[int, int, str], tuple[int, ...]] = {}
        self._by_before: dict[int, list[StepRecord]] = {}
        self._produced_by: dict[int, StepRecord] = {}
        for step in steps:
            if step.before is not None:
                self._by_before.setdefault(id(step.before), []).append(step)
            self._produced_by[id(step.after)] = step

    def _map(self, shape: TopoDS_Shape, kind: str) -> TopTools_IndexedMapOfShape:
        cached = self._maps.get((id(shape), kind))
        if cached is None:
            sub_shapes = TopTools_IndexedMapOfShape()
            topexp.MapShapes(shape, _TOPABS_FOR_KIND[kind], sub_shapes)
            cached = self._maps[(id(shape), kind)] = (shape, sub_shapes)  # keeping `shape` alive keeps id() unique
        return cached[1]

    def forward(self, step: StepRecord, old_index: int, kind: str = "vertex") -> tuple[int, ...]:
        """Indices in `step.after` that sub-shape `old_index` of `step.before` became (empty: consumed)."""
        key = (id(step), old_index, kind)
        cached = self._forward_cache.get(key)
        if cached is not None:
            return cached
        assert step.before is not None
        before_map, after_map = self._map(step.before, kind), self._map(step.after, kind)
        current = [before_map.FindKey(old_index + 1)]
        for op in step.ops:
            # untouched (kept as it is) and/or modified into something: both stay candidates; whatever is not in the result is dropped at the end
            current = [t for s in current for t in (s, *op.successors(s))]
        found = sorted({after_map.FindIndex(s) - 1 for s in current if after_map.FindIndex(s) > 0})
        if not found:
            found = self._by_position(step, old_index, kind)
        result = tuple(found)
        self._forward_cache[key] = result
        return result

    def _by_position(self, step: StepRecord, old_index: int, kind: str) -> list[int]:
        """The step had no history for this sub-shape: a lone sub-shape of the result with the same fingerprint at exactly the same place (an operation we have
        no hook for)."""
        before = measurer_for(step.before, kind).signature(old_index)
        after = measurer_for(step.after, kind)
        eps = 1e-6 * (before.body_diagonal or 1.0)
        near = [
            i
            for i in range(after.count)
            if distance(after.signature(i).position, before.position) <= eps and fingerprint_matches(before, after.signature(i))
        ]
        return near if len(near) == 1 else []

    def preimages(self, step: StepRecord, new_index: int, kind: str = "vertex") -> list[int]:
        if step.before is None:
            return []
        count = self._map(step.before, kind).Size()
        return [i for i in range(count) if new_index in self.forward(step, i, kind)]

    def _walk_back(self, final: TopoDS_Shape | None, index: int, kind: str) -> LineageOrigin | None:
        if final is None:
            return None
        step = self._produced_by.get(id(final))
        if step is None:
            return None
        while True:
            pre = self.preimages(step, index, kind)
            previous = self._produced_by.get(id(step.before)) if step.before is not None else None
            if len(pre) != 1 or previous is None:
                break
            index, step = pre[0], previous
        signature = measurer_for(step.after, kind).signature(index)
        return LineageOrigin(feature_id=step.feature_id, body_id=step.body_id, index=index, signature=signature, kind=kind)

    def lineage_for(self, body_id: str, index: int, kind: str = "vertex") -> LineageOrigin | None:
        """Walks the recorded steps backwards from sub-shape `index` of the final Body `body_id` to the step that created it."""
        return self._walk_back(self.bodies.get(body_id), index, kind)

    def lineage_before_feature(self, feature_id: str, body_id: str, index: int, kind: str) -> LineageOrigin | None:
        """The same walk, from sub-shape `index` of Body `body_id` as `feature_id` found it (a reference made by that Feature names a sub-shape of its input)."""
        return self._walk_back(self.inputs.get(feature_id, {}).get(body_id), index, kind)

    def forward_from_origin(self, origin: LineageOrigin, final_body_id: str | None = None, target: TopoDS_Shape | None = None) -> HistoryOutcome:
        """Where did the sub-shape `origin` names end up? Walked forward from the origin Feature's output to `target` (default: this trace's final Body
        `final_body_id`); the walk stops when it reaches `target`, so a reference made mid-history is not carried past the Feature that holds it."""
        kind = origin.kind
        origin_step = next((s for s in self.steps if s.feature_id == origin.feature_id and s.body_id == origin.body_id), None)
        if origin_step is None:
            return HistoryOutcome("unavailable")
        measurer = measurer_for(origin_step.after, kind)
        located = decide_reference(origin.signature, origin.index, measurer.all())
        if located.status == ReferenceStatus.LOST or located.index is None:
            return HistoryOutcome("unavailable")
        if target is None:
            target = self.bodies.get(final_body_id) if final_body_id is not None else None
        queue: list[tuple[TopoDS_Shape, list[int]]] = [(origin_step.after, [located.index])]
        finals: list[tuple[TopoDS_Shape, list[int]]] = []
        consumed_by: str | None = None
        unknown = False
        while queue:
            shape, indices = queue.pop()
            steps = [] if shape is target else self._by_before.get(id(shape), [])
            if not steps:
                finals.append((shape, indices))
                continue
            for step in steps:
                survivors = sorted({j for i in indices for j in self.forward(step, i, kind)})
                if survivors:
                    queue.append((step.after, survivors))
                elif not step.covered:
                    unknown = True  # nothing found, but this step reports no history of its own: that is not evidence of consumption
                elif consumed_by is None:
                    consumed_by = step.feature_id
        for shape, indices in finals:
            if shape is target:
                return HistoryOutcome("found", tuple(indices))
        if not finals and consumed_by is not None and not unknown:
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
    trace = HistoryTrace(recorder.steps, bodies, recorder.inputs)
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

    def lineage_for(self, body_id: str, index: int, kind: str = "vertex") -> LineageOrigin | None:
        trace = self.trace()
        if trace is None:
            return None
        try:
            return trace.lineage_for(body_id, index, kind)
        except Exception:
            logger.warning("Could not trace lineage of %s %s of %s", kind, index, body_id, exc_info=True)
            return None

    def lineage_before_feature(self, feature_id: str, body_id: str, index: int, kind: str) -> LineageOrigin | None:
        """Lineage of a sub-shape named by `feature_id` (see `HistoryTrace.lineage_before_feature`); needs a trace of the whole Part (`excluded` empty)."""
        trace = self.trace()
        if trace is None:
            return None
        try:
            return trace.lineage_before_feature(feature_id, body_id, index, kind)
        except Exception:
            logger.warning("Could not trace lineage of %s %s of %s before %s", kind, index, body_id, feature_id, exc_info=True)
            return None

    def refine(self, ref, signature_decision: ReferenceDecision, bodies: dict[str, TopoDS_Shape], measurer) -> ReferenceDecision:
        """A sketch vertex reference: combine what OCCT history says with the signature search's `signature_decision` (see `refine_lineage`)."""
        return self.refine_lineage(
            ref.lineage, ref.body_id, ref.vertex_index, ref.signature, signature_decision, measurer, final_body_id=ref.body_id, kind="vertex"
        )

    def refine_lineage(
        self,
        lineage: LineageOrigin | None,
        body_id: str,
        current_index: int,
        stored_signature: ShapeSignature | None,
        signature_decision: ReferenceDecision,
        measurer,
        *,
        final_body_id: str | None = None,
        target_feature_id: str | None = None,
        kind: str = "vertex",
    ) -> ReferenceDecision:
        """Combine what OCCT history says with the signature search's `signature_decision` (docs/reference-identity-design.md, "Combining"): history carries the
        origin sub-shape forward to the target Body (this trace's final Body `final_body_id`, or the input of Feature `target_feature_id`); one survivor is
        followed, none is consumed (lost, never rebound to a look-alike), several are narrowed by signature."""
        trace = self.trace()
        if trace is None or lineage is None:
            return signature_decision
        target = trace.inputs.get(target_feature_id, {}).get(body_id) if target_feature_id is not None else None
        try:
            outcome = trace.forward_from_origin(lineage, final_body_id=final_body_id, target=target)
        except Exception:
            logger.warning("OCCT history lookup failed for a reference on %s", body_id, exc_info=True)
            return signature_decision
        if outcome.kind == "consumed":
            return ReferenceDecision(ReferenceStatus.LOST, None, reason=f"consumed_by_{outcome.consumed_by}", method="history")
        if outcome.kind != "found":
            return signature_decision

        # Translate the trace's own numbering of the target Body into the caller's (the same shape rebuilt, so normally identical; matched by position).
        target_shape = target if target is not None else trace.bodies[body_id]
        trace_measurer = measurer_for(target_shape, kind)
        eps = 1e-6 * (measurer.diagonal or 1.0)
        mapped: list[int] = []
        for i in outcome.indices:
            expected = trace_measurer.signature(i)
            mapped.extend(
                j
                for j in range(measurer.count)
                if j not in mapped
                and distance(measurer.signature(j).position, expected.position) <= eps
                and fingerprint_matches(expected, measurer.signature(j))
            )
        if not mapped:
            return signature_decision
        if len(mapped) > 1 and stored_signature is not None:
            mapped = narrow_by_signature(stored_signature, mapped, measurer.all())
        if len(mapped) != 1:
            return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous", method="history", candidates=tuple(mapped))
        index = mapped[0]
        status = ReferenceStatus.OK if index == current_index else ReferenceStatus.FOLLOWED
        reason = "" if status == ReferenceStatus.OK else "history"
        return ReferenceDecision(status, index, reason=reason, method="history", lineage=lineage)


def history_for_part(part, excluded_feature_ids: frozenset[str] = frozenset()) -> ReferenceHistory:
    return ReferenceHistory(part, excluded_feature_ids)
