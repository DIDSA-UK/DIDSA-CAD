"""Reference identity for `SubShapeRef` (docs/reference-identity-design.md, "SubShapeRef consumers").

A `SubShapeRef` is a body id plus a raw OCCT index; an upstream edit that renumbers the Body used to make it resolve, silently, to a different edge / face / vertex. The
sketch's external references got a geometric signature and a re-find rule (`app.sketch.reference_signature`); this module gives every other consumer of a
`SubShapeRef` (Fillet / Chamfer `edge_refs`, Create Plane, Pattern directions and axes, Mirror planes, Shell / Delete / Move Face selections, ...) the same:

* `decide_subshape` - where does one reference point now? (fast path: the index still names a sub-shape with the same fingerprint nearby and, for a face that
  carries one, the same radius / cone half-angle; else the signature search, where a face's size breaks ties among coaxial faces; else lost);
* `resolve_subshape_from_bodies` (app.document.extrude, the one place every consumer resolves through) honours it: a signed reference is re-found, never
  silently rebound, and fails closed with the usual `missing_reference` 422 (now carrying a `reason`) when it cannot be found unambiguously;
* `refresh_feature_subshape_refs` - run when a Feature's response is built (create, update and every `GET .../features`): stamps a signature on any reference
  that has none (at creation that is exactly the moment the index is right; a file saved before signatures existed adopts on first view), re-validates the rest
  against the Bodies the Feature saw as its input, persists the re-found index and refreshed signature, and reports which references are lost / potentially moved
  so the response can flag them.

OCCT history (docs/reference-identity-design.md, "OCCT history"): a reference stamped while the Part is small enough to trace also carries a `LineageOrigin` - the
Feature whose output created the sub-shape - for edges and faces exactly as for sketch vertices. When the stored index goes stale, the refresh asks the recorded trace
what became of it (`Modified()` / `Generated()` through Fillet, Chamfer, Cut, Fuse and unify): one survivor is followed, none is "consumed by <feature>" (and the
reference is marked so replay fails closed on it instead of binding a look-alike), several are narrowed by signature. Replay itself stays signature-only.

Assembly mate references (N1b, docs/mates-storage-sessions-plan-2026-11-12.md "N1 plan") have the same treatment in a different resolution context: the Bodies
of the Part the mate's occurrence places, not of the Part holding the mate. `stamp_mate_references` signs every `SubShapeRef` of a new mate;
`refresh_mate_references` re-validates them (the plan's rules N-2 and N-3, below), persists the re-found index and signature for `ok` / `followed`, and reports
per mate what it found; `confirm` is the user's answer to a held mate.

Not covered, by design: BODY references (no sub-shape).
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
from app.document.models import Document, Feature, Mate, MateEntityRef, Part, SubShapeRef, SubShapeType
from app.document.reference_history import ReferenceHistory
from app.document.reference_signature import measurer_for
from app.sketch.reference_signature import (
    SEARCH_TOLERANCE_REL,
    ReferenceDecision,
    ReferenceStatus,
    ShapeSignature,
    UNAMBIGUOUS_RATIO,
    decide_reference,
    shape_distance,
    fingerprint_matches,
    size_unchanged,
)

logger = logging.getLogger(__name__)

_KIND_FOR_TYPE = {SubShapeType.VERTEX: "vertex", SubShapeType.EDGE: "edge", SubShapeType.FACE: "face"}


def signature_kind(ref: SubShapeRef) -> str | None:
    """"vertex" / "edge" / "face", or None for a BODY reference (nothing to sign)."""
    return _KIND_FOR_TYPE.get(ref.shape_type)


# Tracing replays the whole Part once (uncached, recording); a Part with more Features than this is not traced, so a very large Part never pays for lineage at
# creation and its references fall back to the signature search alone (see the design doc).
HISTORY_MAX_FEATURES = 80


def decide_subshape(
    ref: SubShapeRef,
    body: TopoDS_Shape,
    history: ReferenceHistory | None = None,
    feature_id: str | None = None,
) -> ReferenceDecision:
    """Where does `ref` now point on `body`? Never raises; a BODY reference or one without a signature is `ok` at its own index when that index exists.
    With `history` (and `feature_id`, the Feature holding the reference) a stale index is refined by OCCT history when the reference carries a lineage."""
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
        # N1a: and the same size (radius / cone half-angle) when the signature has one. A face whose size changed goes through `decide_reference`, which
        # keeps it unless a coaxial twin's size is clearly nearer the stored one (a bore's index now naming the boss around it is never `ok`).
        if fingerprint_matches(ref.signature, here) and shape_distance(ref.signature, here) <= tolerance and size_unchanged(ref.signature, here):
            return ReferenceDecision(ReferenceStatus.OK, ref.index, method="index")
    signature_decision = decide_reference(ref.signature, ref.index, measurer.all())
    if history is not None and ref.lineage is not None and feature_id is not None:
        return history.refine_lineage(
            ref.lineage, ref.body_id, ref.index, ref.signature, signature_decision, measurer, target_feature_id=feature_id, kind=kind
        )
    return signature_decision


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

    # The recorded replay is only made when a reference needs it (a new reference wanting a lineage, or a stale index wanting history), then shared by every
    # reference of every Feature through the trace memo.
    history = ReferenceHistory(part, frozenset()) if len(part.features) <= HISTORY_MAX_FEATURES else None
    state = FeatureRefState()

    def refresh(path: str, ref: SubShapeRef) -> SubShapeRef:
        kind = signature_kind(ref)
        if kind is None:
            return ref
        body = bodies.get(ref.body_id)
        if body is None:
            state.lost.append(path)
            state.reasons[path] = "body_missing"
            return ref
        decision = decide_subshape(ref, body, history, feature.id)
        if decision.status == ReferenceStatus.LOST or decision.index is None:
            state.lost.append(path)
            state.reasons[path] = decision.reason or "no_match"
            # Only a verdict that came from OCCT history is recorded on the reference: it can disagree with what replay's signature search alone would do (a
            # consumed sub-shape with a look-alike left), and replay must then fail closed too. A signature-only loss replay finds out for itself.
            if decision.method == "history" and ref.lost_reason != decision.reason:
                return dataclasses.replace(ref, lost_reason=decision.reason)
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
        lineage = decision.lineage or ref.lineage
        if ref.signature is None and lineage is None and history is not None:
            # Stamped for the first time (creation, or a file saved before signatures existed): remember where the sub-shape came from.
            lineage = history.lineage_before_feature(feature.id, ref.body_id, decision.index, kind)
        if decision.index == ref.index and signature is ref.signature and lineage is ref.lineage and ref.lost_reason is None:
            return ref
        return dataclasses.replace(ref, index=decision.index, signature=signature, lineage=lineage, lost_reason=None)

    map_subshape_refs(feature, refresh)
    return state


# --- mate references (N1b) -----------------------------------------------------------------------------------------------------------
#
# A Mate's `MateEntityRef`s name sub-shapes of the Parts its occurrences place. They are stamped when the mate is made (`stamp_mate_references`: the index is
# right at that moment) and re-validated by `refresh_mate_references` against the target Part's FINAL Bodies in the Part-local frame, so a placement never
# disturbs a signature. Two rules differ from a Feature's (plan decisions N-2 and N-3), because a mate's binding MOVES PARTS where a Feature's only changes
# geometry:
#   * a `potentially_moved` reference is bound for display (the listing shows the face it would take) but the mate is HELD out of solves until the user
#     confirms it (`confirm=True`); the stored reference is left as it was, so it stays moved on every refresh until then. Exception, for mates only: of
#     several identical twins, the one sitting exactly where the stored one was (distance about 0, every other twin beyond the search tolerance) is `followed`:
#     the plate's hole pattern after a fillet renumbered it, which would otherwise hold every mate on a part with a hole pattern;
#   * an UNSIGNED reference (a file saved before signatures, or a mate made by a bare test) adopts the face its index names only when the stored placement
#     confirms it (the mate reads ok / near at the stored poses; a coupler / limit: the face is the kind it needs). Otherwise it is held, reason `unconfirmed`.

# "About 0" of the exact-place rule, of the Body's diagonal. A hole pattern renumbered by an edit keeps every hole where it was (a few 1e-9 mm of OCCT noise);
# 0.1 % of the diagonal still reads a hole nudged by a rounding as in place, and a hole moved by a dimension edit as moved.
MATE_EXACT_PLACE_REL = 1e-3


@dataclass
class MateReferenceState:
    """What a refresh found about one Mate's references, keyed by path (`references[0].subshape_ref`, `references[1].midplane.b.face_ref`, ...).
    `lost`: not found (or ambiguous). `moved`: bound on weak evidence, or unsigned and not confirmed by the stored placement: the mate is HELD.
    `followed`: re-found at a new index (persisted). `reasons`: a machine-readable reason per flagged path. `bound`: for each `moved` path, the index the
    reference would take if confirmed (what a listing shows)."""

    lost: list[str] = field(default_factory=list)
    moved: list[str] = field(default_factory=list)
    followed: list[str] = field(default_factory=list)
    reasons: dict[str, str] = field(default_factory=dict)
    bound: dict[str, int] = field(default_factory=dict)

    @property
    def has_lost(self) -> bool:
        return bool(self.lost)

    @property
    def held(self) -> bool:
        """The mate waits for the user's confirmation: some reference is bound weakly or unconfirmed (a lost one is `broken`, not held)."""
        return bool(self.moved)

    @property
    def left_out_of_solves(self) -> bool:
        return bool(self.moved) or bool(self.lost)


def _mate_occurrence_for_path(ref: MateEntityRef, path: str) -> str:
    """The occurrence whose Part holds the sub-shape at `path` (a Width mid-plane's `b` face may sit on `b_occurrence_id`)."""
    if ".midplane.b." in path and ref.midplane is not None and ref.midplane.b_occurrence_id is not None:
        return ref.midplane.b_occurrence_id
    return ref.occurrence_id


def _mate_bodies(document: Document, part: Part, occurrence_id: str, cache: dict[str, dict]) -> dict[str, TopoDS_Shape] | None:
    """The Bodies (Part-local) of the Part `occurrence_id` places; None when the occurrence does not resolve or the Part does not compute (nothing to say)."""
    from app.document.assembly import resolve_occurrence_target
    from app.document.extrude import compute_part_bodies

    try:
        target, _ = resolve_occurrence_target(document, part, occurrence_id)
    except KeyError:
        return None
    if target.id not in cache:
        try:
            cache[target.id] = compute_part_bodies(target)
        except HTTPException:
            return None
    return cache[target.id]


def iter_mate_subshape_refs(mate: Mate) -> list[tuple[str, SubShapeRef]]:
    """`(path, ref)` for every `SubShapeRef` in the mate's references, with the paths `refresh_mate_references` reports."""
    found: list[tuple[str, SubShapeRef]] = []

    def collect(path: str, ref: SubShapeRef) -> SubShapeRef:
        found.append((path, ref))
        return ref

    for i, entity in enumerate(mate.references):
        _rebuild(entity, f"references[{i}]", collect)
    return found


def stamp_mate_references(document: Document, part: Part, mate: Mate, cache: dict[str, dict] | None = None) -> bool:
    """Signs every `SubShapeRef` of `mate` that has no signature, against the target Part's final Bodies (Part-local frame). For a NEW mate: the index is right at
    this moment, so no placement check is wanted. A reference whose occurrence or Body does not resolve (or whose index is out of range) is left unsigned: the
    caller's own validation reports it. Returns whether anything changed; sets `mate.references`."""
    cache = {} if cache is None else cache
    rebuilt: list[MateEntityRef] = []
    changed = False
    for i, entity in enumerate(mate.references):

        def stamp(path: str, ref: SubShapeRef, entity=entity) -> SubShapeRef:
            kind = signature_kind(ref)
            if kind is None or ref.signature is not None:
                return ref
            bodies = _mate_bodies(document, part, _mate_occurrence_for_path(entity, path), cache)
            body = None if bodies is None else bodies.get(ref.body_id)
            if body is None or not 0 <= ref.index < measurer_for(body, kind).count:
                return ref
            return dataclasses.replace(ref, signature=measure_signature(body, ref, ref.index))

        out = _rebuild(entity, f"references[{i}]", stamp)
        changed = changed or out is not entity
        rebuilt.append(out)
    if changed:
        mate.references = rebuilt
    return changed


def _decide_mate_subshape(ref: SubShapeRef, body: TopoDS_Shape) -> ReferenceDecision:
    """`decide_subshape` with the mate-only exact-place rule (N-2 (c)): of several identical twins, the one at distance about 0 whose runner-up is beyond the
    search tolerance is `followed` (reason `exact_place_among_twins`), not merely `potentially_moved`."""
    decision = decide_subshape(ref, body)
    if (
        decision.status == ReferenceStatus.POTENTIALLY_MOVED
        and decision.reason == "nearest_of_identical_vertices"
        and len(decision.candidates) >= 2
        and decision.index is not None
        and ref.signature is not None
    ):
        measurer = measurer_for(body, signature_kind(ref))
        diagonal = ref.signature.body_diagonal or measurer.diagonal
        nearest = shape_distance(ref.signature, measurer.signature(decision.candidates[0]))
        runner_up = shape_distance(ref.signature, measurer.signature(decision.candidates[1]))
        if nearest <= MATE_EXACT_PLACE_REL * diagonal and runner_up > SEARCH_TOLERANCE_REL * diagonal and runner_up >= UNAMBIGUOUS_RATIO * max(nearest, 1e-12):
            return ReferenceDecision(ReferenceStatus.FOLLOWED, decision.index, reason="exact_place_among_twins", method="signature", candidates=decision.candidates)
    return decision


def refresh_mate_references(
    document: Document,
    part: Part,
    mates: list[Mate] | None = None,
    *,
    persist: bool = True,
    confirm: bool = False,
    cache: dict[str, dict] | None = None,
) -> dict[str, MateReferenceState]:
    """Stamps / re-validates every sub-shape reference of `mates` (default: every mate of `part`) against the Bodies of the Parts their occurrences place; see the
    section comment above for the rules. Returns `{mate id: MateReferenceState}` (an entry for every mate, empty when nothing is flagged). Never raises: a
    reference whose occurrence or Part cannot be resolved is left alone (the mate's status reports it).

    `persist` writes the re-found index and refreshed signature of `ok` / `followed` references (and the adopted signature of a confirmed unsigned one) into
    the mates, so the next save carries them; False (a solve deciding what to hold) changes nothing. `confirm` is the user's answer to a held mate: the bound
    faces are taken as right (`potentially_moved` is bound and re-stamped, an unsigned reference adopted without the placement check)."""
    cache = {} if cache is None else cache
    results: dict[str, MateReferenceState] = {}
    for mate in part.mates if mates is None else mates:
        try:
            results[mate.id] = _refresh_one_mate(document, part, mate, persist, confirm, cache)
        except HTTPException:  # a reference that cannot be resolved at all: the status says so
            logger.warning("Mate %s: could not check its references", mate.id)
            results[mate.id] = MateReferenceState()
    return results


def _refresh_one_mate(document: Document, part: Part, mate: Mate, persist: bool, confirm: bool, cache: dict[str, dict]) -> MateReferenceState:
    state = MateReferenceState()
    unsigned: set[str] = set()
    pass_one: list[MateEntityRef] = []
    for i, entity in enumerate(mate.references):

        def refresh(path: str, ref: SubShapeRef, entity=entity) -> SubShapeRef:
            kind = signature_kind(ref)
            if kind is None:
                return ref
            bodies = _mate_bodies(document, part, _mate_occurrence_for_path(entity, path), cache)
            if bodies is None:
                return ref
            body = bodies.get(ref.body_id)
            if body is None:
                state.lost.append(path)
                state.reasons[path] = "body_missing"
                return ref
            if ref.signature is None:
                unsigned.add(path)
                return ref
            decision = _decide_mate_subshape(ref, body)
            if decision.status == ReferenceStatus.LOST or decision.index is None:
                state.lost.append(path)
                state.reasons[path] = decision.reason or "no_match"
                return ref
            if decision.status == ReferenceStatus.POTENTIALLY_MOVED and not confirm:
                state.moved.append(path)
                state.reasons[path] = decision.reason
                state.bound[path] = decision.index
                return ref
            if decision.status == ReferenceStatus.FOLLOWED:
                state.followed.append(path)
                state.reasons[path] = decision.reason
            signature = measure_signature(body, ref, decision.index)
            if decision.index == ref.index and signature == ref.signature:
                return ref
            return dataclasses.replace(ref, index=decision.index, signature=signature)

        pass_one.append(_rebuild(entity, f"references[{i}]", refresh))

    refs = pass_one
    if unsigned:
        refs = _adopt_unsigned(document, part, mate, pass_one, unsigned, state, confirm, cache)
    if persist and any(a is not b for a, b in zip(refs, mate.references)):
        mate.references = refs
    return state


def _adopt_unsigned(
    document: Document, part: Part, mate: Mate, refs: list[MateEntityRef], unsigned: set[str], state: MateReferenceState, confirm: bool, cache: dict[str, dict]
) -> list[MateEntityRef]:
    """The N-3 rule: the unsigned references adopt the face their index names when the stored placement confirms it (or the user confirmed); else they are held."""
    from app.document.mate_status import placement_confirms

    # Out of range for its Body: nothing for the index to name, so nothing to confirm.
    confirmed = confirm or placement_confirms(document, part, dataclasses.replace(mate, references=refs), cache)
    out: list[MateEntityRef] = []
    for i, entity in enumerate(refs):

        def adopt(path: str, ref: SubShapeRef, entity=entity) -> SubShapeRef:
            if path not in unsigned or ref.signature is not None:
                return ref
            kind = signature_kind(ref)
            bodies = _mate_bodies(document, part, _mate_occurrence_for_path(entity, path), cache)
            body = None if bodies is None else bodies.get(ref.body_id)
            if body is None or not 0 <= ref.index < measurer_for(body, kind).count:
                state.lost.append(path)
                state.reasons[path] = "no_match"
                return ref
            if not confirmed:
                state.moved.append(path)
                state.reasons[path] = "unconfirmed"
                state.bound[path] = ref.index
                return ref
            return dataclasses.replace(ref, signature=measure_signature(body, ref, ref.index))

        out.append(_rebuild(entity, f"references[{i}]", adopt))
    return out


def apply_bound_indices(references: list[MateEntityRef], state: MateReferenceState | None) -> list[MateEntityRef]:
    """`references` with each `moved` reference showing the index it would take if confirmed (what a listing reports: a client highlights by the listed index).
    The stored references are not changed."""
    if state is None or not state.bound:
        return references
    out = []
    for i, entity in enumerate(references):
        out.append(_rebuild(entity, f"references[{i}]", lambda path, ref: dataclasses.replace(ref, index=state.bound[path]) if path in state.bound else ref))
    return out
