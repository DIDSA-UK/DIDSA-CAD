"""Pure-Python tests for `app.document.body_cache` (herringbone/complex-
gear timeout investigation) - the checkpoint-chain cache `compute_
part_bodies` now delegates to whenever `excluded_feature_ids` is empty (the
common case). Deliberately has zero pythonocc-core dependency of its own
(same as `body_cache.py` itself) - `feature_fingerprint`/`compute_with_
cache` only ever touch plain dataclasses and dicts, never a real
`TopoDS_Shape`, so these tests stand in a fake `bodies` value (a plain int
counter) rather than real OCCT geometry. The real-OCCT proof that this
actually skips rebuilding an untouched Gear Feature lives in
`test_body_cache_gear_integration.py` instead.
"""

from dataclasses import dataclass, field

from app.document import body_cache
from app.document.models import ExtrudeFeature, ExtrudeType
from app.sketch.models import Plane, Point, Sketch, SketchEntityRef, SketchEntityType
from app.sketch.store import add_sketch, all_sketches, replace_all_sketches

_saved_sketches: dict | None = None


def setup_function(_fn) -> None:
    """Every test starts from a clean slate - both this module's own cache
    (mirrors what `app.document.store.replace_document` calls in
    production) and the real Sketch store some tests populate directly.
    Mirrors the save/restore-in-finally convention every other real-Sketch
    test in this suite already uses (e.g. `test_bevel_gear_feature.py`'s
    own native-round-trip test)."""
    global _saved_sketches
    body_cache.clear()
    _saved_sketches = dict(all_sketches())
    replace_all_sketches({})


def teardown_function(_fn) -> None:
    assert _saved_sketches is not None
    replace_all_sketches(_saved_sketches)


# --- feature_fingerprint -----------------------------------------------------


def _extrude(id_: str, distance: float, target_body_ids: list[str] | None = None) -> ExtrudeFeature:
    return ExtrudeFeature(
        id=id_,
        sketch_feature_id="sketch-feature-1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=distance,
        target_body_ids=target_body_ids or [],
    )


def test_fingerprint_is_stable_for_an_unchanged_feature():
    feature = _extrude("f1", 10.0)
    assert body_cache.feature_fingerprint(feature) == body_cache.feature_fingerprint(feature)


def test_fingerprint_changes_when_a_features_own_field_changes():
    feature = _extrude("f1", 10.0)
    before = body_cache.feature_fingerprint(feature)
    feature.end_distance = 20.0
    after = body_cache.feature_fingerprint(feature)
    assert before != after


def test_fingerprint_is_the_same_for_two_separately_built_but_identical_features():
    a = _extrude("f1", 10.0)
    b = _extrude("f1", 10.0)
    assert body_cache.feature_fingerprint(a) == body_cache.feature_fingerprint(b)


def test_fingerprint_differs_for_features_with_different_target_body_ids():
    a = _extrude("f1", 10.0, target_body_ids=["body-a"])
    b = _extrude("f1", 10.0, target_body_ids=["body-b"])
    assert body_cache.feature_fingerprint(a) != body_cache.feature_fingerprint(b)


def test_fingerprint_changes_when_a_referenced_sketchs_content_changes():
    """The whole reason [feature_fingerprint] walks into referenced
    Sketches at all: an ExtrudeFeature's own dataclass fields only ever
    store a `sketch_feature_id`/`SketchEntityRef.sketch_id`, never the
    Sketch's actual point/line data - a Sketch edit must still be visible
    here, or a cached Body would silently go stale after one."""
    sketch = Sketch(id="sketch-1", plane=Plane.XY)
    add_sketch(sketch)
    feature = ExtrudeFeature(
        id="f1",
        sketch_feature_id="sketch-feature-1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
        profile_refs=[SketchEntityRef(sketch_id="sketch-1", entity_type=SketchEntityType.LINE, entity_id="line-1")],
    )
    before = body_cache.feature_fingerprint(feature)

    sketch.points["p1"] = Point(id="p1", x=1.0, y=2.0)
    after = body_cache.feature_fingerprint(feature)

    assert before != after


def test_fingerprint_finds_a_sketch_id_nested_inside_a_list_of_refs():
    sketch_a = Sketch(id="sketch-a", plane=Plane.XY)
    sketch_b = Sketch(id="sketch-b", plane=Plane.XY)
    add_sketch(sketch_a)
    add_sketch(sketch_b)
    feature = ExtrudeFeature(
        id="f1",
        sketch_feature_id="sketch-feature-1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
        profile_refs=[
            SketchEntityRef(sketch_id="sketch-a", entity_type=SketchEntityType.LINE, entity_id="l1"),
            SketchEntityRef(sketch_id="sketch-b", entity_type=SketchEntityType.LINE, entity_id="l2"),
        ],
    )
    before = body_cache.feature_fingerprint(feature)
    # Only sketch-b changes - must still be caught even though it's the
    # second entry in a list, not the Feature's own top-level sketch_id.
    sketch_b.points["p1"] = Point(id="p1", x=0.0, y=0.0)
    after = body_cache.feature_fingerprint(feature)
    assert before != after


def test_fingerprint_ignores_an_unrelated_sketchs_changes():
    sketch_a = Sketch(id="sketch-a", plane=Plane.XY)
    sketch_unrelated = Sketch(id="sketch-unrelated", plane=Plane.XY)
    add_sketch(sketch_a)
    add_sketch(sketch_unrelated)
    feature = ExtrudeFeature(
        id="f1",
        sketch_feature_id="sketch-feature-1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
        profile_refs=[SketchEntityRef(sketch_id="sketch-a", entity_type=SketchEntityType.LINE, entity_id="l1")],
    )
    before = body_cache.feature_fingerprint(feature)
    sketch_unrelated.points["p1"] = Point(id="p1", x=0.0, y=0.0)
    after = body_cache.feature_fingerprint(feature)
    assert before == after


# --- compute_with_cache ------------------------------------------------------


@dataclass
class _CountingApply:
    """A fake `apply_step` for `compute_with_cache` - `bodies[feature_id]`
    becomes an incrementing call count rather than real OCCT geometry, and
    `self.calls` records every feature id actually (re)computed, in order -
    exactly what these tests need to assert on."""

    calls: list[str] = field(default_factory=list)

    def __call__(self, feature_id: str, bodies: dict[str, object]) -> None:
        self.calls.append(feature_id)
        bodies[feature_id] = bodies.get(feature_id, 0) + 1


def test_first_call_computes_every_feature():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0), "c": _extrude("c", 3.0)}
    apply = _CountingApply()
    bodies = body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)
    assert apply.calls == ["a", "b", "c"]
    assert bodies == {"a": 1, "b": 1, "c": 1}


def test_identical_second_call_recomputes_nothing():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0), "c": _extrude("c", 3.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)

    bodies = body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)
    assert apply.calls == ["a", "b", "c"]  # no new entries appended
    assert bodies == {"a": 1, "b": 1, "c": 1}


def test_appending_a_new_feature_only_recomputes_the_new_one():
    """The exact scenario this module exists for: a new Feature (an
    Extrude cut, say) added after an existing, unchanged, expensive one
    (a complex Gear Feature, say) must not re-trigger the expensive one."""
    features = {"gear": _extrude("gear", 1.0), "b": _extrude("b", 2.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["gear", "b"], features, apply)
    assert apply.calls == ["gear", "b"]

    features = dict(features)
    features["cut"] = _extrude("cut", 3.0)
    bodies = body_cache.compute_with_cache("part-1", ["gear", "b", "cut"], features, apply)

    assert apply.calls == ["gear", "b", "cut"]  # "gear"/"b" not repeated
    assert bodies == {"gear": 1, "b": 1, "cut": 1}


def test_editing_the_last_feature_only_recomputes_it():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)
    assert apply.calls == ["a", "b"]

    features = dict(features)
    features["b"] = _extrude("b", 99.0)  # same id, different field
    body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)

    assert apply.calls == ["a", "b", "b"]  # "a" not repeated, "b" is


def test_editing_an_earlier_feature_recomputes_it_and_everything_after():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0), "c": _extrude("c", 3.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)
    assert apply.calls == ["a", "b", "c"]

    features = dict(features)
    features["a"] = _extrude("a", 99.0)
    body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)

    # "a" changed, so it and everything topologically after it (b, c) must
    # be rebuilt - never just "a" alone, since a later Feature could
    # legitimately depend on "a"'s own output Body.
    assert apply.calls == ["a", "b", "c", "a", "b", "c"]


def test_deleting_the_last_feature_reuses_everything_before_it():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)
    assert apply.calls == ["a", "b"]

    bodies = body_cache.compute_with_cache("part-1", ["a"], {"a": features["a"]}, apply)
    assert apply.calls == ["a", "b"]  # nothing new recomputed
    assert bodies == {"a": 1}


def test_different_part_ids_are_cached_independently():
    features = {"a": _extrude("a", 1.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a"], features, apply)
    body_cache.compute_with_cache("part-2", ["a"], features, apply)
    # Both parts' own first call for "a" - no cross-part reuse, and no
    # cross-part duplicate suppression either (each is its own real call).
    assert apply.calls == ["a", "a"]


def test_clear_forces_a_full_recompute():
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0)}
    apply = _CountingApply()
    body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)
    assert apply.calls == ["a", "b"]

    body_cache.clear()
    body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)
    assert apply.calls == ["a", "b", "a", "b"]


def test_a_snapshot_is_a_copy_not_a_live_view_of_the_returned_bodies_dict():
    """The whole point of snapshotting per step - mutating the dict a
    caller got back from one call must never corrupt what a later call
    reuses from the cache."""
    features = {"a": _extrude("a", 1.0), "b": _extrude("b", 2.0)}
    apply = _CountingApply()
    bodies = body_cache.compute_with_cache("part-1", ["a", "b"], features, apply)
    bodies["a"] = "corrupted"

    features = dict(features)
    features["c"] = _extrude("c", 3.0)
    fresh = body_cache.compute_with_cache("part-1", ["a", "b", "c"], features, apply)

    assert fresh["a"] == 1  # unaffected by the earlier mutation
    assert apply.calls == ["a", "b", "c"]  # "a"/"b" still not recomputed
