"""Regression tests for the plain `GET /parts/{id}/features` `body_cache`
bypass bug (LOD investigation §6, `docs/lod-strategy/00-status.md`):
`app.document.router`'s `_X_feature_response` helpers used to recompute a
Gear/Loft/BevelGear/BevelPair/GearChain Feature's own `warnings` by calling
straight back into the create/update entry point (`resolve_gear`/
`resolve_loft`/etc), which always self-excludes the Feature's own id and so
forces `app.document.extrude.compute_part_bodies` onto its always-uncached
branch - meaning every plain, non-mutating feature-list fetch rebuilt every
qualifying Feature in the Part from scratch, regardless of `body_cache`'s
existence. `test_bevel_pair_feature.py`'s own
`test_get_features_repeated_call_does_not_reopen_the_phase_search_pool_
after_the_first_read` proves the expensive half of this (a real
`ProcessPoolExecutor` that must not reopen); this file is its cheap,
call-counting sibling, at the granularity of the underlying
`resolve_gear_from_bodies`/`resolve_loft_from_bodies` construction functions
themselves - mirrors `test_body_cache.py`'s own "count real calls, not just
assert on the end result" style, and `test_body_cache_gear_integration.py`'s
own "drive the real router/`compute_part_bodies`, not a synthetic
`apply_step`" choice, but deliberately uses the cheapest possible Feature
configuration of each type (a small straight-tooth gear, a straight
2-section loft) - the call COUNT is what's under test here, not build cost.
"""

import app.document.gear as gear_module
import app.document.loft as loft_module
from fastapi.testclient import TestClient

from app.document import extrude
from app.document.models import Part
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _counting_wrapper(real_fn):
    """Wraps `real_fn` (a module's real `resolve_X_from_bodies`) with a call
    counter, still delegating to the real implementation - a spy, not a
    stub, so the Feature under test still resolves correctly and the
    response payload asserted on below is genuine, not faked."""
    calls: list[None] = []

    def _wrapped(*args, **kwargs):
        calls.append(None)
        return real_fn(*args, **kwargs)

    _wrapped.calls = calls
    return _wrapped


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_polygon(sketch_id: str, points: list[tuple[float, float]]) -> list[dict]:
    corners = [_add_point(sketch_id, x, y) for x, y in points]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    return corners


def _square_sketch(part_id: str, *, plane: str = "XY", size: float = 10.0) -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    feature = response.json()
    h = size / 2
    _add_polygon(feature["sketch_id"], [(-h, -h), (h, -h), (h, h), (-h, h)])
    return feature


def test_get_features_repeated_call_does_not_recompute_an_unchanged_gear(monkeypatch):
    """Cheap counterpart to `test_bevel_pair_feature.py`'s pool-counting
    test: a small straight-tooth `GearFeature` (no helix, no herringbone -
    the fast `BRepPrimAPI_MakePrism` path) is plenty to prove the CALL COUNT
    behaviour without needing an expensive build to make the point."""
    part = _create_part()
    response = client.post(
        f"/document/parts/{part['id']}/gear-features",
        json={
            "gear_type": "boss",
            "is_internal": False,
            "module": 2.0,
            "tooth_count": 12,
            "face_width": 5.0,
        },
    )
    assert response.status_code == 201, response.json()

    # Only wrap resolve_gear_from_bodies *after* creation - creation's own
    # eager validation (`resolve_gear`) doesn't need counting and this keeps
    # the counter scoped to exactly the calls this test cares about.
    real_resolve = gear_module.resolve_gear_from_bodies
    wrapped = _counting_wrapper(real_resolve)
    monkeypatch.setattr(gear_module, "resolve_gear_from_bodies", wrapped)

    first = client.get(f"/document/parts/{part['id']}/features")
    assert first.status_code == 200, first.json()
    calls_after_first_read = len(wrapped.calls)
    assert calls_after_first_read > 0, (
        "test setup expectation broken: the first read should have needed a real, "
        "uncached build (cold cache) - resolve_gear_from_bodies was never called"
    )

    second = client.get(f"/document/parts/{part['id']}/features")
    assert second.status_code == 200, second.json()
    assert len(wrapped.calls) == calls_after_first_read, (
        f"expected zero new resolve_gear_from_bodies calls on the second read "
        f"({len(wrapped.calls) - calls_after_first_read} happened) - a repeat GET "
        "of an unchanged Part should be served entirely from the cache"
    )
    assert first.json() == second.json()


def test_get_features_repeated_call_does_not_recompute_an_unchanged_loft(monkeypatch):
    """Identical shape to the Gear test above, for `LoftFeature` - a plain
    straight prism-equivalent loft between two identical squares (no guide
    curves, no thickness), the cheapest possible real `LoftFeature`."""
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    plane_response = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}],
            "offset": 8.0,
        },
    )
    assert plane_response.status_code == 201, plane_response.json()
    plane = plane_response.json()

    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    assert top_response.status_code == 201, top_response.json()
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])

    loft_response = client.post(
        f"/document/parts/{part['id']}/loft-features",
        json={
            "sections": [
                {"sketch_feature_id": bottom["id"]},
                {"sketch_feature_id": top["id"]},
            ],
            "mode": "boss",
        },
    )
    assert loft_response.status_code == 201, loft_response.json()

    real_resolve = loft_module.resolve_loft_from_bodies
    wrapped = _counting_wrapper(real_resolve)
    monkeypatch.setattr(loft_module, "resolve_loft_from_bodies", wrapped)

    first = client.get(f"/document/parts/{part['id']}/features")
    assert first.status_code == 200, first.json()
    calls_after_first_read = len(wrapped.calls)
    assert calls_after_first_read > 0, (
        "test setup expectation broken: the first read should have needed a real, "
        "uncached build (cold cache) - resolve_loft_from_bodies was never called"
    )

    second = client.get(f"/document/parts/{part['id']}/features")
    assert second.status_code == 200, second.json()
    assert len(wrapped.calls) == calls_after_first_read, (
        f"expected zero new resolve_loft_from_bodies calls on the second read "
        f"({len(wrapped.calls) - calls_after_first_read} happened) - a repeat GET "
        "of an unchanged Part should be served entirely from the cache"
    )
    assert first.json() == second.json()


# --- app.document.extrude._feature_warnings_cache (pure dict-level) --------
#
# Direct unit coverage of the cache functions themselves, mirroring
# `test_body_cache.py`'s own "test the mechanism in isolation, no real
# Feature/geometry needed" style - a plain `app.document.models.Part` (just
# a dataclass; no OCCT construction happens anywhere below) stands in for a
# real one, since these functions only ever read `part.id`.


def setup_function(_fn) -> None:
    extrude.clear_feature_warnings_cache()


def test_cached_feature_warnings_is_empty_for_a_never_recorded_feature():
    part = Part(id="part-1", name="Part 1")
    assert extrude.cached_feature_warnings(part, "feature-1") == []


def test_record_then_read_back_the_same_warnings():
    part = Part(id="part-1", name="Part 1")
    extrude._record_feature_warnings(part, "feature-1", ["a warning"], frozenset())
    assert extrude.cached_feature_warnings(part, "feature-1") == ["a warning"]


def test_recording_again_overwrites_the_previous_value():
    part = Part(id="part-1", name="Part 1")
    extrude._record_feature_warnings(part, "feature-1", ["stale"], frozenset())
    extrude._record_feature_warnings(part, "feature-1", ["fresh"], frozenset())
    assert extrude.cached_feature_warnings(part, "feature-1") == ["fresh"]


def test_a_non_empty_excluded_feature_ids_is_never_recorded():
    """The correctness-critical guard: a B4 true-rollback preview
    (`compute_part_bodies(part, rollback_excluded_feature_ids)`) or a
    create/update entry point's own self-exclusion validation
    (`resolve_gear(part, feature)` -> `compute_part_bodies(part,
    {feature.id})`) must never overwrite this cache's "real current state"
    entry with a value computed under a non-empty exclusion set - see
    `_record_feature_warnings`'s own docstring."""
    part = Part(id="part-1", name="Part 1")
    extrude._record_feature_warnings(part, "feature-1", ["real"], frozenset())
    extrude._record_feature_warnings(part, "feature-1", ["rollback-only"], frozenset({"some-other-feature"}))
    assert extrude.cached_feature_warnings(part, "feature-1") == ["real"]


def test_different_parts_are_cached_independently():
    part_a = Part(id="part-a", name="Part A")
    part_b = Part(id="part-b", name="Part B")
    extrude._record_feature_warnings(part_a, "feature-1", ["a"], frozenset())
    extrude._record_feature_warnings(part_b, "feature-1", ["b"], frozenset())
    assert extrude.cached_feature_warnings(part_a, "feature-1") == ["a"]
    assert extrude.cached_feature_warnings(part_b, "feature-1") == ["b"]


def test_clear_feature_warnings_cache_drops_everything():
    part = Part(id="part-1", name="Part 1")
    extrude._record_feature_warnings(part, "feature-1", ["a warning"], frozenset())
    extrude.clear_feature_warnings_cache()
    assert extrude.cached_feature_warnings(part, "feature-1") == []
