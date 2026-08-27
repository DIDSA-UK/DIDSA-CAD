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

Code-review follow-up (same branch, after `9da90f8`): the fix above traded
one bug for another - routing the read path through `compute_part_bodies
(part)` with no `try`/`except` of its own dropped the pre-existing "a
since-broken Feature is still shown, not one whose failure takes down the
whole feature list" resilience the old `resolve_gear`/`resolve_loft`/etc
call had (that call was *also* a whole-Part build, just with this Feature's
own id excluded, wrapped in a blanket `except HTTPException: warnings =
[]`). `compute_part_bodies(part)` processes every Feature in the Part, not
just the one whose response is currently being built, so a totally
unrelated Feature elsewhere that can no longer be resolved took the
*entire* `GET /parts/{id}/features` response down with it (whatever error
that unrelated Feature's own resolution raises - a 422 `missing_reference`,
confirmed below - propagating straight out as the *list* endpoint's own
response) instead of just losing its own row's warnings. `_gear_feature_response`/
`_bevel_gear_feature_response`/`_bevel_pair_feature_response`/
`_loft_feature_response`/`_gear_chain_feature_response` in `app.document.
router` now re-wrap their own `compute_part_bodies(part)` call in the same
`except HTTPException: warnings = []` fallback.
`test_get_features_survives_a_since_broken_unrelated_feature_elsewhere_in_
the_part` below proves it, built without any B4 rollback/hide trick
(`test_bugfix_hide_vs_rollback_exclusion.py`'s own scenario relies on
`rollback_excluded_feature_ids`, which the plain `GET .../features` path
never sets) and without deleting any Feature (`delete_feature` refuses to
remove one a later Feature depends on) - a custom Plane anchored to a Line
in a plain Sketch, with a second Sketch+Extrude anchored to that Plane;
deleting the Line via the standalone `/sketch` API (which knows nothing
about the Feature graph, so never checks for a dependent CreatePlaneFeature)
makes the Plane's own reference dangle from then on, on every ordinary
`compute_part_bodies(part)` call.
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


# --- Code-review follow-up: a since-broken unrelated Feature must not take -
# --- the whole `GET /features` response down with it -----------------------


def _create_gear_with_undercut_warning(part_id: str) -> dict:
    """A cheap straight-tooth external Gear guaranteed to carry a real,
    non-empty `warnings` entry - `app.document.gear_math.undercut_warning`
    - without needing an expensive helical/herringbone build: an explicit
    `profile_shift=0.0` (rather than the default `None`/auto) at
    `tooth_count=8` sits well below `minimum_tooth_count_without_undercut`'s
    own ~17-tooth threshold at the default 20-degree pressure angle, and
    `resolve_gear_from_bodies`'s own "explicit profile_shift always wins"
    rule means auto-resolution never clears it back to `None`/[]."""
    response = client.post(
        f"/document/parts/{part_id}/gear-features",
        json={
            "gear_type": "boss",
            "is_internal": False,
            "module": 2.0,
            "tooth_count": 8,
            "face_width": 5.0,
            "profile_shift": 0.0,
        },
    )
    assert response.status_code == 201, response.json()
    return response.json()


def test_get_features_survives_a_since_broken_unrelated_feature_elsewhere_in_the_part():
    """The literal reproduction of the code-review-found regression: a Gear
    that would normally carry `warnings`, alongside a completely separate,
    genuinely broken Feature chain - `GET /parts/{id}/features` must still
    return 200 and still render every Feature's row, the Gear's included,
    exactly like the pre-`9da90f8` code always did.

    The broken chain needs no B4 rollback/hide trick and no Feature
    deletion (`delete_feature` refuses to remove a Feature a later one
    depends on, and every Feature-creation endpoint here eagerly validates
    its own references at creation time - there is no way to *create* a
    Feature naming an already-dangling reference). Instead: a custom
    `normal_to_line_at_point` Plane anchored to a Line in a plain Sketch,
    with a second Sketch+Extrude anchored to that Plane. Once both exist,
    the Line is deleted via the standalone `/sketch` API (`DELETE /sketch/
    sketches/{sketch_id}/lines/{line_id}`) - a lower-level API that knows
    nothing about the Feature graph and so never checks whether any
    CreatePlaneFeature still references the Line, exactly the "topology
    drift after the fact" this codebase's own resilience conventions
    (Fillet/Chamfer/Revolve/Sweep/CreatePlaneFeature's own response) are
    built to tolerate. From that point on, `resolve_sketch_entity` fails
    closed with a structured `missing_reference` (`app.document.plane_
    geometry.resolve_normal_to_line_at_point`), on every ordinary
    `compute_part_bodies(part)` call - not just a B4 preview - and the
    Extrude built on the now-broken Plane re-raises it (`ExtrudeFeature`'s
    own branch in `app.document.extrude._apply_feature_to_bodies` only
    tolerates `invalid_profile_ref`, not `missing_reference` - see that
    branch's own comment)."""
    part = _create_part()

    # A totally independent Gear, nowhere near the broken chain below.
    gear = _create_gear_with_undercut_warning(part["id"])
    sanity = client.get(f"/document/parts/{part['id']}/features")
    assert sanity.status_code == 200, sanity.json()
    sanity_gear_row = next(f for f in sanity.json() if f["id"] == gear["id"])
    assert sanity_gear_row["warnings"], "test setup expectation broken: the Gear should already carry a warning"

    anchor_sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert anchor_sketch.status_code == 201, anchor_sketch.json()
    anchor_sketch = anchor_sketch.json()
    anchor_sketch_id = anchor_sketch["sketch_id"]
    start_point = _add_point(anchor_sketch_id, 0.0, 0.0)
    end_point = _add_point(anchor_sketch_id, 10.0, 0.0)
    line = _add_line(anchor_sketch_id, start_point["id"], end_point["id"])

    broken_plane = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "normal_to_line_at_point",
            "line_ref": {"sketch_id": anchor_sketch_id, "entity_type": "line", "entity_id": line["id"]},
            "point_ref": {"sketch_id": anchor_sketch_id, "entity_type": "point", "entity_id": start_point["id"]},
        },
    )
    assert broken_plane.status_code == 201, broken_plane.json()
    broken_plane = broken_plane.json()

    sketch_on_broken_plane = client.post(
        f"/document/parts/{part['id']}/features/sketch",
        json={"plane_feature_id": broken_plane["id"]},
    )
    assert sketch_on_broken_plane.status_code == 201, sketch_on_broken_plane.json()
    sketch_on_broken_plane = sketch_on_broken_plane.json()
    _add_polygon(sketch_on_broken_plane["sketch_id"], [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)])
    extrude_on_broken_plane = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_on_broken_plane["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 1.0,
            "target_body_ids": [],
        },
    )
    assert extrude_on_broken_plane.status_code == 201, extrude_on_broken_plane.json()
    extrude_on_broken_plane = extrude_on_broken_plane.json()

    # *Now* break it - the Feature graph itself has no idea this just
    # happened.
    delete_line_response = client.delete(f"/sketch/sketches/{anchor_sketch_id}/lines/{line['id']}")
    assert delete_line_response.status_code == 200, delete_line_response.json()

    # Sanity check that the chain is genuinely broken now, at the layer
    # that actually surfaces it (`/mesh`, which always calls the ordinary
    # `compute_part_bodies(part)`) - if this stops 422-ing, the scenario
    # below no longer exercises the regression at all.
    mesh_response = client.get(f"/document/parts/{part['id']}/mesh")
    assert mesh_response.status_code == 422, mesh_response.json()
    assert mesh_response.json()["detail"]["type"] == "missing_reference"

    list_response = client.get(f"/document/parts/{part['id']}/features")
    assert list_response.status_code == 200, list_response.json()
    listed_ids = {f["id"] for f in list_response.json()}
    assert listed_ids == {
        gear["id"],
        anchor_sketch["id"],
        broken_plane["id"],
        sketch_on_broken_plane["id"],
        extrude_on_broken_plane["id"],
    }
    gear_row = next(f for f in list_response.json() if f["id"] == gear["id"])
    assert gear_row["warnings"] == [], (
        "compute_part_bodies(part) fails for every read while the chain is broken, so this "
        "falls back to [] - same fallback value the pre-9da90f8 code used"
    )

    single_response = client.get(f"/document/parts/{part['id']}/features/{gear['id']}")
    assert single_response.status_code == 200, single_response.json()
    assert single_response.json()["warnings"] == []


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
