"""Reference identity for `SubShapeRef` (docs/reference-identity-design.md, "SubShapeRef consumers").

A `SubShapeRef` is a body id plus a raw OCCT index; an upstream edit that renumbers the Body used to make it resolve, silently, to a different edge / face / vertex. The
sketch's external references got a geometric signature and a re-find rule (`app.sketch.reference_signature`); this module gives every other consumer of a
`SubShapeRef` (Fillet / Chamfer `edge_refs`, Create Plane, Pattern directions and axes, Mirror planes, Shell / Delete / Move Face selections, ...) the same:

* `decide_subshape` - where does one reference point now? (fast path: the index still names a sub-shape with the same fingerprint nearby; else the signature
  search; else lost);
* `resolve_subshape_from_bodies` (app.document.extrude, the one place every consumer resolves through) honours it: a signed reference is re-found, never
  silently rebound, and fails closed with the usual `missing_reference` 422 (now carrying a `reason`) when it cannot be found unambiguously;
* `refresh_feature_subshape_refs` - run when a Feature's response is built (create, update and every `GET .../features`): stamps a signature on any reference
  that has none (at creation that is exactly the moment the index is right; a file saved before signatures existed adopts on first view), re-validates the rest
  against the Bodies the Feature saw as its input, persists the re-found index and refreshed signature, and reports which references are lost / potentially moved
  so the response can flag them.

Not covered, by design: OCCT history lineage (sketch vertex references only), BODY references (no sub-shape), assembly mate references (a different
resolution context: another Part's Bodies).
"""

from __future__ import annotations

import dataclasses
import logging
from dataclasses import dataclass, field
from enum import Enum

from fastapi import HTTPException
from OCC.Core.TopoDS import TopoDS_Shape

from app.document import body_cache
from app.document.graph import build_feature_graph, topological_order
from app.document.models import Feature, Part, SubShapeRef, SubShapeType
from app.document.reference_signature import measurer_for
from app.sketch.reference_signature import (
    SEARCH_TOLERANCE_REL,
    ReferenceDecision,
    ReferenceStatus,
    ShapeSignature,
    decide_reference,
    shape_distance,
    fingerprint_matches,
)

logger = logging.getLogger(__name__)

_KIND_FOR_TYPE = {SubShapeType.VERTEX: "vertex", SubShapeType.EDGE: "edge", SubShapeType.FACE: "face"}


def signature_kind(ref: SubShapeRef) -> str | None:
    """"vertex" / "edge" / "face", or None for a BODY reference (nothing to sign)."""
    return _KIND_FOR_TYPE.get(ref.shape_type)


def decide_subshape(ref: SubShapeRef, body: TopoDS_Shape) -> ReferenceDecision:
    """Where does `ref` now point on `body`? Never raises; a BODY reference or one without a signature is `ok` at its own index when that index exists."""
    kind = signature_kind(ref)
    if kind is None:
        return ReferenceDecision(ReferenceStatus.OK, ref.index, method="index")
    measurer = measurer_for(body, kind)
    in_range = 0 <= ref.index < measurer.count
    if ref.signature is None:
        if in_range:
            return ReferenceDecision(ReferenceStatus.OK, ref.index, reason="signature_adopted", method="index")
        return ReferenceDecision(ReferenceStatus.LOST, None, reason="no_match")
    if in_range:
        here = measurer.signature(ref.index)
        tolerance = SEARCH_TOLERANCE_REL * (ref.signature.body_diagonal or measurer.diagonal)
        if fingerprint_matches(ref.signature, here) and shape_distance(ref.signature, here) <= tolerance:
            return ReferenceDecision(ReferenceStatus.OK, ref.index, method="index")
    return decide_reference(ref.signature, ref.index, measurer.all())


def measure_signature(body: TopoDS_Shape, ref: SubShapeRef, index: int) -> ShapeSignature | None:
    kind = signature_kind(ref)
    return None if kind is None else measurer_for(body, kind).signature(index)


# --- walking a Feature's references --------------------------------------------------------------------------------------------------


def _rebuild(value, path: str, fn):
    """`value` with every `SubShapeRef` inside it replaced by `fn(path, ref)`; the very same object when nothing changed. Descends dataclasses (frozen ones are
    rebuilt with `dataclasses.replace`), lists, tuples and dicts."""
    if isinstance(value, SubShapeRef):
        return fn(path, value)
    if value is None or isinstance(value, (str, int, float, bool, Enum)):
        return value
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        changes = {}
        for f in dataclasses.fields(value):
            current = getattr(value, f.name)
            rebuilt = _rebuild(current, f"{path}.{f.name}" if path else f.name, fn)
            if rebuilt is not current:
                changes[f.name] = rebuilt
        return dataclasses.replace(value, **changes) if changes else value
    if isinstance(value, list):
        rebuilt_items = [_rebuild(item, f"{path}[{i}]", fn) for i, item in enumerate(value)]
        return rebuilt_items if any(a is not b for a, b in zip(rebuilt_items, value)) else value
    if isinstance(value, tuple):
        rebuilt_items = tuple(_rebuild(item, f"{path}[{i}]", fn) for i, item in enumerate(value))
        return rebuilt_items if any(a is not b for a, b in zip(rebuilt_items, value)) else value
    if isinstance(value, dict):
        rebuilt_map = {k: _rebuild(v, f"{path}[{k}]", fn) for k, v in value.items()}
        return rebuilt_map if any(rebuilt_map[k] is not value[k] for k in value) else value
    return value


def map_subshape_refs(feature: Feature, fn) -> bool:
    """Replaces every `SubShapeRef` held anywhere in `feature` by `fn(path, ref)` (return `ref` itself to leave it), in place on the Feature (its identity in
    `Part.features` and the dependency graph is unchanged). Returns whether anything changed."""
    changed = False
    for f in dataclasses.fields(feature):
        current = getattr(feature, f.name)
        rebuilt = _rebuild(current, f.name, fn)
        if rebuilt is not current:
            setattr(feature, f.name, rebuilt)
            changed = True
    return changed


def iter_subshape_refs(feature: Feature) -> list[tuple[str, SubShapeRef]]:
    found: list[tuple[str, SubShapeRef]] = []

    def collect(path: str, ref: SubShapeRef) -> SubShapeRef:
        found.append((path, ref))
        return ref

    for f in dataclasses.fields(feature):
        _rebuild(getattr(feature, f.name), f.name, collect)
    return found


# --- the Bodies a Feature saw as its input --------------------------------------------------------------------------------------------


def bodies_before_feature(part: Part, feature_id: str) -> dict[str, TopoDS_Shape]:
    """The Part's Bodies as `feature_id` found them (the state its own references were made against), without replaying the Part when the checkpoint chain
    (`app.document.body_cache`) already holds it: snapshot `i` is the state after step `i`, so the input of step `p` is snapshot `p - 1`. Falls back to an
    uncached replay that excludes the Feature and everything after it. May raise `HTTPException` when the Part's earlier features do not compute."""
    from app.document.extrude import compute_part_bodies

    order = topological_order(build_feature_graph(part))
    position = order.index(feature_id)
    for attempt in range(2):
        chain = body_cache.chain_for(part.id)
        if chain is not None and chain.order[: position + 1] == order[: position + 1] and len(chain.snapshots) > position:
            fresh = [body_cache.feature_fingerprint(part.get_feature(order[i])) for i in range(position)]
            if chain.fingerprints[:position] == fresh:
                return dict(chain.snapshots[position - 1]) if position > 0 else {}
        if attempt == 0:
            try:
                compute_part_bodies(part)  # brings the chain up to date (cheap when it already is)
            except HTTPException:
                break
    return compute_part_bodies(part, frozenset(order[position:]))


# --- refreshing a Feature's references -----------------------------------------------------------------------------------------------


@dataclass
class FeatureRefState:
    """What a refresh found about one Feature's `SubShapeRef`s: reference paths (`edge_refs[0]`, `face_refs[1].face_ref`, ...) that are lost, potentially
    moved, or re-followed at a new index, and a machine-readable reason per flagged path."""

    lost: list[str] = field(default_factory=list)
    moved: list[str] = field(default_factory=list)
    followed: list[str] = field(default_factory=list)
    reasons: dict[str, str] = field(default_factory=dict)

    @property
    def has_lost(self) -> bool:
        return bool(self.lost)


def refresh_feature_subshape_refs(part: Part, feature: Feature) -> FeatureRefState | None:
    """Stamps / re-validates every sub-shape reference of `feature` against the Bodies it saw as input (see the module docstring). Returns None when the Feature has
    no sub-shape reference or the Part's earlier features do not compute (nothing to say, nothing changed)."""
    if not any(signature_kind(ref) is not None for _, ref in iter_subshape_refs(feature)):
        return None
    try:
        bodies = bodies_before_feature(part, feature.id)
    except ValueError:  # the Feature is not (yet) in the Part's graph
        return None
    except HTTPException:
        logger.warning("Feature %s: could not compute its input Bodies to check its references", feature.id)
        return None

    state = FeatureRefState()

    def refresh(path: str, ref: SubShapeRef) -> SubShapeRef:
        if signature_kind(ref) is None:
            return ref
        body = bodies.get(ref.body_id)
        if body is None:
            state.lost.append(path)
            state.reasons[path] = "body_missing"
            return ref
        decision = decide_subshape(ref, body)
        if decision.status == ReferenceStatus.LOST or decision.index is None:
            state.lost.append(path)
            state.reasons[path] = decision.reason or "no_match"
            return ref
        if decision.status == ReferenceStatus.POTENTIALLY_MOVED:
            state.moved.append(path)
            state.reasons[path] = decision.reason
            signature = ref.signature
        else:
            if decision.status == ReferenceStatus.FOLLOWED:
                state.followed.append(path)
                state.reasons[path] = decision.reason
            signature = measure_signature(body, ref, decision.index)
        if decision.index == ref.index and signature is ref.signature:
            return ref
        return dataclasses.replace(ref, index=decision.index, signature=signature)

    map_subshape_refs(feature, refresh)
    return state
