"""On-device feedback (herringbone/complex-gear timeout investigation):
`app.document.extrude.compute_part_bodies` used to replay a Part's *entire*
Feature history from scratch on every single call - every Feature
create/update's own eager validation, and every subsequent `GET /mesh`
fetch, recomputed every Body unconditionally. That's expensive but at least
bounded for an ordinary Part; it becomes a real problem once a Part
contains one genuinely slow Feature (a complex helical/herringbone
`GearFeature` - two twisted `BRepOffsetAPI_ThruSections` lofts fused
together, `app.document.gear._helical_or_herringbone_solid`) - every later,
otherwise-unrelated edit to that same Part (an Extrude cut added
afterward, say) pays that same large cost again, forever, on top of its
own.

This module is a generic (no OCCT/Feature-type knowledge of its own),
Part-keyed checkpoint chain: [compute_with_cache] remembers, per Part id,
the ordered Feature-id sequence, each Feature's own [feature_fingerprint],
and a `bodies` snapshot taken after each step of the *last* call that
processed that Part. A later call for the same Part id only re-runs
`apply_step` for the suffix starting at the first point where the new
sequence's ids or fingerprints diverge from what's cached - everything
before that point is guaranteed byte-identical in both id and complete
content, so its old `bodies` snapshot is reused untouched rather than
rebuilt.

**Never-wrong-direction guarantee**: a cache hit only ever *skips
otherwise-identical work*, never produces different output than an
uncached call would. [feature_fingerprint] captures a Feature's own
complete field values (via `repr`, which walks every nested dataclass
field) plus the complete content of every Sketch it references anywhere
within those fields (see [_collect_sketch_ids] - a Feature's own dataclass
fields only ever store a `sketch_id`/`SketchEntityRef`, never the Sketch's
actual point/line/constraint data, so a Sketch edit wouldn't otherwise be
visible to a fingerprint built from the Feature alone). Any real change -
to the Feature itself, to a Sketch it depends on, to the Feature-id order,
or to which Features exist at all - changes the fingerprint sequence at or
before the affected position, forcing a real recompute from there onward.
The worst case for a fingerprinting mistake this analysis missed is a
false-negative (an unnecessary recompute, i.e. no worse than before this
module existed) - there is no code path that reuses a snapshot without a
preceding fingerprint-equality check first.

**Concurrency**: matches the rest of `app.document.store`'s existing
single-process, no-locking assumption (the in-memory `_document` global
itself has no locking anywhere) - this module doesn't add a new category
of risk beyond what every other mutation of that same global already has,
and adding real locking here alone wouldn't close that gap anywhere else.
"""

from __future__ import annotations

import dataclasses
from typing import Callable

from app.document.models import Feature
from app.sketch.store import all_sketches


def _collect_sketch_ids(obj: object, seen: set[int], found: set[str]) -> None:
    """Recursively walks `obj`'s own dataclass fields (and into any nested
    dataclass/list/tuple/set/frozenset/dict along the way) collecting every
    string value assigned to an attribute literally named `sketch_id` -
    the one, uniformly-used convention this whole codebase's DTOs and
    domain models follow for "this points into `app.sketch.store`"
    (`SketchEntityRef.sketch_id`, `SketchFeature.sketch_id`, and every
    other reference type built on top of `SketchEntityRef`). Generic by
    attribute name rather than hardcoded per Feature type, so a new
    Feature type or a new reference field on an existing one is covered
    automatically as long as it keeps using that same convention - the
    established norm everywhere else in this codebase.

    `seen` guards against a reference cycle via `id(obj)` - cheap
    insurance; nothing in this data model is actually expected to cycle."""
    if obj is None or isinstance(obj, (str, int, float, bool)):
        return
    obj_id = id(obj)
    if obj_id in seen:
        return
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        seen.add(obj_id)
        for f in dataclasses.fields(obj):
            value = getattr(obj, f.name)
            if f.name == "sketch_id" and isinstance(value, str):
                found.add(value)
            _collect_sketch_ids(value, seen, found)
        return
    if isinstance(obj, (list, tuple, set, frozenset)):
        seen.add(obj_id)
        for item in obj:
            _collect_sketch_ids(item, seen, found)
        return
    if isinstance(obj, dict):
        seen.add(obj_id)
        for value in obj.values():
            _collect_sketch_ids(value, seen, found)
        return
    # Anything else (a plain str-Enum value, e.g.) - nothing to recurse
    # into, and not a sketch_id itself (caught by the isinstance(str) guard
    # on the field check above).


def feature_fingerprint(feature: Feature) -> str:
    """A deterministic string capturing `feature`'s own complete current
    field values plus the complete current content of every Sketch it
    references anywhere within those fields (see [_collect_sketch_ids]).
    Two calls made with nothing relevant changed in between always return
    the same string; any real change to the Feature's own fields, or to a
    Sketch it depends on, always changes it.

    Built from plain `repr()` (deterministic for a `@dataclass`'s default
    `__repr__`, which includes every field, recursively for nested
    dataclasses) rather than any kind of hash - collisions are irrelevant
    here (this is compared for equality against the exact same string built
    the exact same way, never stored/transmitted anywhere space-sensitive)
    and a plain string is trivial to reason about/debug."""
    found: set[str] = set()
    _collect_sketch_ids(feature, set(), found)
    sketches = all_sketches()
    sketch_reprs = "|".join(repr(sketches.get(sketch_id)) for sketch_id in sorted(found))
    return f"{feature!r}::{sketch_reprs}"


@dataclasses.dataclass
class _CheckpointChain:
    order: list[str]
    fingerprints: list[str]
    # snapshots[i]: a shallow copy of the `bodies` dict immediately after
    # processing order[i] - shallow is sufficient (never deep) because
    # every OCCT operation used anywhere in `app.document`'s feature
    # resolvers builds a *new* TopoDS_Shape from its inputs rather than
    # mutating an existing one in place (the standard OCCT idiom - a
    # TopoDS_Shape is treated as an immutable value handle throughout this
    # codebase already, e.g. `bodies[body_id] = filleted_shape` always
    # *reassigns* the dict entry, never mutates the old shape) - so an
    # older snapshot's shape references stay valid and unaffected by
    # whatever a later step goes on to do with that same body id.
    snapshots: list[dict[str, object]]


_cache: dict[str, _CheckpointChain] = {}


def clear() -> None:
    """Drops every Part's cached checkpoint chain - called by
    `app.document.store.replace_document` (native import's full-document
    replace), since a freshly-imported Part can reuse an id a stale cache
    entry still references with completely different content. Safe to
    call at any other time too (just forces the next `compute_with_cache`
    call for every Part to recompute from scratch, same as a cold start)."""
    _cache.clear()


def compute_with_cache(
    part_id: str,
    order: list[str],
    features_by_id: dict[str, Feature],
    apply_step: Callable[[str, dict[str, object]], None],
) -> dict[str, object]:
    """The generic checkpoint-chain cache itself - see this module's own
    docstring for the full design/correctness argument. `order` is the
    already-topologically-sorted Feature id sequence for this call;
    `apply_step(feature_id, bodies)` mutates `bodies` in place for exactly
    one Feature (the caller's own OCCT-aware per-Feature-type dispatch -
    this module has no knowledge of what it does, only that it's
    deterministic given `bodies`' current state and that one Feature's
    current fields/dependencies).

    Finds the longest prefix of `order` whose ids *and*
    [feature_fingerprint]s exactly match the previous call's own cached
    sequence for this same `part_id`, seeds `bodies` from that prefix's own
    final snapshot (or starts from `{}` if nothing matches), and only
    invokes `apply_step` for the remaining suffix - then stores the full,
    now-current chain back into the cache for the next call to build on."""
    fingerprints = [feature_fingerprint(features_by_id[feature_id]) for feature_id in order]

    cached = _cache.get(part_id)
    reuse_count = 0
    if cached is not None:
        limit = min(len(cached.order), len(order))
        while (
            reuse_count < limit
            and cached.order[reuse_count] == order[reuse_count]
            and cached.fingerprints[reuse_count] == fingerprints[reuse_count]
        ):
            reuse_count += 1

    if cached is not None and reuse_count > 0:
        bodies: dict[str, object] = dict(cached.snapshots[reuse_count - 1])
        snapshots = list(cached.snapshots[:reuse_count])
    else:
        bodies = {}
        snapshots = []

    for feature_id in order[reuse_count:]:
        apply_step(feature_id, bodies)
        snapshots.append(dict(bodies))

    _cache[part_id] = _CheckpointChain(order=list(order), fingerprints=fingerprints, snapshots=snapshots)
    return bodies
