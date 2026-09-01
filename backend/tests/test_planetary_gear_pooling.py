"""Real-OCCT tests for LOD Phase 2 chunk 1: `ProcessPoolExecutor` pooling
added to `app.document.planetary_gear`, mirroring `app.document.bevel_pair`'s
own already-established pattern (`docs/lod-strategy/02-phase2-design.md`
SS3, `00-status.md` Finding 2). Structurally mirrors the equivalent
`ProcessPoolExecutor`-counting/worker-exception coverage in `test_bevel_
pair_feature.py`.
"""

import multiprocessing
from concurrent.futures import ProcessPoolExecutor

import pytest
from fastapi import HTTPException

import app.document.planetary_gear as planetary_gear_module
from app.document.gear_math import SpurGearGeometry, spur_gear_geometry
from app.document.models import PlaneRef, PlanetaryGearFeature
from app.document.planetary_gear import (
    _build_member_solid,
    _build_member_solid_worker,
    _MemberBuildFailed,
    resolve_planetary_from_bodies,
)
from app.sketch.models import Plane


def _feature(**overrides) -> PlanetaryGearFeature:
    payload = dict(
        id="planetary-pool-test",
        plane_ref=PlaneRef(fixed_plane=Plane.XY),
        module=3.0,
        sun_tooth_count=40,
        ring_tooth_count=120,
        planet_count=4,
        pressure_angle_degrees=20.0,
        face_width=10.0,
        ring_outer_diameter=3.0 * (120 + 10),
    )
    payload.update(overrides)
    return PlanetaryGearFeature(**payload)


def test_pool_construction_counting_opens_exactly_one_pool_for_the_whole_assembly():
    """`resolve_planetary_from_bodies` should submit every member build
    (sun + ring + every planet) to a single, shared `ProcessPoolExecutor`
    construction, not one pool per member - counted the same way `test_
    bevel_pair_feature.py`'s own `ProcessPoolExecutor`-counting tests
    already confirm `resolve_bevel_pair_from_bodies` opens exactly one pool
    for its own 2-member build."""
    construct_count = 0
    real_pool_executor = planetary_gear_module.ProcessPoolExecutor

    def _counting_pool_executor(*args, **kwargs):
        nonlocal construct_count
        construct_count += 1
        return real_pool_executor(*args, **kwargs)

    mp = pytest.MonkeyPatch()
    mp.setattr(planetary_gear_module, "ProcessPoolExecutor", _counting_pool_executor)
    try:
        feature = _feature()
        compound = resolve_planetary_from_bodies(feature, None, {}, frozenset())
    finally:
        mp.undo()

    assert compound is not None
    assert construct_count == 1, f"expected exactly 1 ProcessPoolExecutor construction, got {construct_count}"


def test_planetary_pool_worker_count_scales_with_member_count_and_cpu_count(monkeypatch):
    monkeypatch.setattr(planetary_gear_module.os, "cpu_count", lambda: 4)
    # member_count=6 (sun+ring+4 planets): cpu_count-1=3, capped at member_count=6 -> 3.
    assert planetary_gear_module._planetary_pool_worker_count(6) == 3
    # member_count=2 (sun+ring only, 0 planets): floored at 2 even though cpu_count-1=3 > 2.
    assert planetary_gear_module._planetary_pool_worker_count(2) == 2

    monkeypatch.setattr(planetary_gear_module.os, "cpu_count", lambda: 1)
    # cpu_count-1=0 would be below the floor - clamped to 2.
    assert planetary_gear_module._planetary_pool_worker_count(6) == 2


def test_worker_raised_http_exception_survives_the_spawn_pickle_round_trip_as_member_build_failed():
    """`_gear_face`'s own internal-gear branch raises a structured
    `HTTPException` when `outer_diameter` doesn't exceed the tooth
    profile's own dedendum reach - in practice unreachable from `resolve_
    planetary_from_bodies` itself (its own pre-flight `ring_outer_diameter`
    check enforces the identical condition first), but `_build_member_
    solid_worker` must still convert it into the picklable `_MemberBuild
    Failed` before it can cross a real `ProcessPoolExecutor` `spawn`
    boundary - confirmed here directly, not assumed, by driving a real
    worker process into this exact failure and checking what actually
    comes back in the main process."""
    geometry: SpurGearGeometry = spur_gear_geometry(
        module=3.0, tooth_count=40, pressure_angle_degrees=20.0, is_internal=True
    )
    basis = planetary_gear_module.resolve_plane_ref(None, {}, PlaneRef(fixed_plane=Plane.XY), frozenset())

    # Sanity check: the identical call, made directly (no pool), raises the
    # real HTTPException - confirms the test input genuinely reproduces the
    # failure `_build_member_solid_worker` must convert, not some other bug.
    with pytest.raises(HTTPException) as direct_exc_info:
        _build_member_solid(basis, geometry, True, 1.0, 10.0)
    assert direct_exc_info.value.detail["type"] == "invalid_gear_parameters"

    mp_context = multiprocessing.get_context("spawn")
    with ProcessPoolExecutor(max_workers=1, mp_context=mp_context) as executor:
        future = executor.submit(_build_member_solid_worker, basis, geometry, True, 1.0, 10.0)
        with pytest.raises(_MemberBuildFailed):
            future.result()


def test_resolve_planetary_surfaces_a_worker_build_failure_as_invalid_planetary_parameters(monkeypatch):
    """End-to-end: if a worker ever raised `_MemberBuildFailed` for real
    (the real pre-flight guard makes this otherwise unreachable),
    `resolve_planetary_from_bodies` must surface it as the same structured
    `invalid_planetary_parameters` 422 every other planetary validation
    failure already uses - not an unhandled `_MemberBuildFailed` leaking out
    of this module.

    A real forced-`ProcessPoolExecutor`-worker-failure test isn't practical
    here, same reason `test_bevel_pair_feature.py`'s own equivalent comment
    gives: a `spawn`ed worker re-imports this whole module fresh in its own
    process, so a local test closure isn't even picklable to submit, let
    alone able to reach code already running inside one. Instead, this
    swaps in a fake `ProcessPoolExecutor` whose `Future.result()` raises
    `_MemberBuildFailed` directly - no pickling, no subprocess - exercising
    `resolve_planetary_from_bodies`'s own real exception-wrapping logic
    in-process, the same granularity `_best_of_scored`'s own direct-call
    coverage already uses in `test_bevel_pair_feature.py` for its analogous
    case."""

    class _ImmediateFailingFuture:
        def result(self):
            raise _MemberBuildFailed("outer_diameter too small")

    class _FakeExecutor:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *exc_info):
            return False

        def submit(self, fn, *args, **kwargs):
            return _ImmediateFailingFuture()

    monkeypatch.setattr(planetary_gear_module, "ProcessPoolExecutor", _FakeExecutor)

    feature = _feature()
    with pytest.raises(HTTPException) as exc_info:
        resolve_planetary_from_bodies(feature, None, {}, frozenset())
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "invalid_planetary_parameters"


def test_pooled_build_produces_the_same_result_as_a_direct_serial_build():
    """Same-result-as-before: the pooled construction must produce
    geometrically identical output to calling `_build_member_solid`
    directly in-process (the pre-pooling code path) for the identical
    inputs - proving the BREP-bytes round-trip and pool submission
    introduced no geometry drift. Compares real tessellated bounding boxes
    (position + size) for sun/ring/every planet, not just body counts."""
    from OCC.Core.Bnd import Bnd_Box
    from OCC.Core.BRepBndLib import brepbndlib
    from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh

    from app.document.extrude import _explode_solids

    feature = _feature(sun_tooth_count=40, ring_tooth_count=120, planet_count=4, module=3.0)

    def _bboxes_via_direct_serial_build() -> list[tuple[float, ...]]:
        # Reconstructs exactly what `resolve_planetary_from_bodies` computed
        # before pooling: same geometry/basis math, but each member built
        # directly (serially, in this process) via `_build_member_solid`
        # rather than through the pool.
        import math

        from app.document.gear_chain import _positioned_basis
        from app.document.gear_chain_math import ChainMemberKind, meshing_phase_base, propagate_meshing_phase
        from app.document.gear_math import planetary_planet_tooth_count

        planet_tooth_count = planetary_planet_tooth_count(feature.sun_tooth_count, feature.ring_tooth_count)
        sun_geometry = spur_gear_geometry(
            module=feature.module, tooth_count=feature.sun_tooth_count, pressure_angle_degrees=20.0, is_internal=False
        )
        ring_geometry = spur_gear_geometry(
            module=feature.module, tooth_count=feature.ring_tooth_count, pressure_angle_degrees=20.0, is_internal=True
        )
        planet_geometry = spur_gear_geometry(
            module=feature.module, tooth_count=planet_tooth_count, pressure_angle_degrees=20.0, is_internal=False
        )
        basis = planetary_gear_module.resolve_plane_ref(None, {}, feature.plane_ref, frozenset())
        sun_rotation = 0.0
        sun_solid = _build_member_solid(basis, sun_geometry, False, None, feature.face_width)

        planet_0_azimuth = 0.0
        planet_0_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, planet_0_azimuth)
        planet_0_rotation = propagate_meshing_phase(
            ChainMemberKind.EXTERNAL, sun_geometry.pitch_radius, sun_rotation,
            ChainMemberKind.EXTERNAL, planet_geometry.pitch_radius, planet_0_azimuth, planet_0_base,
        )
        ring_azimuth = planet_0_azimuth + math.pi
        ring_base = meshing_phase_base(feature.ring_tooth_count, ChainMemberKind.EXTERNAL, ring_azimuth)
        ring_rotation = propagate_meshing_phase(
            ChainMemberKind.EXTERNAL, planet_geometry.pitch_radius, planet_0_rotation,
            ChainMemberKind.INTERNAL, ring_geometry.pitch_radius, ring_azimuth, ring_base,
        )
        ring_basis = _positioned_basis(basis, 0.0, 0.0, rotation=ring_rotation)
        ring_solid = _build_member_solid(ring_basis, ring_geometry, True, feature.ring_outer_diameter, feature.face_width)

        orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
        planet_solids = []
        for i in range(feature.planet_count):
            phi = 2 * math.pi * i / feature.planet_count
            planet_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, phi)
            planet_rotation = propagate_meshing_phase(
                ChainMemberKind.EXTERNAL, sun_geometry.pitch_radius, sun_rotation,
                ChainMemberKind.EXTERNAL, planet_geometry.pitch_radius, phi, planet_base,
            )
            px, py = orbit_radius * math.cos(phi), orbit_radius * math.sin(phi)
            planet_basis = _positioned_basis(basis, px, py, rotation=planet_rotation)
            planet_solids.append(_build_member_solid(planet_basis, planet_geometry, False, None, feature.face_width))
        return [sun_solid, ring_solid, *planet_solids]

    def _bbox(shape) -> tuple[float, float, float, float, float, float]:
        BRepMesh_IncrementalMesh(shape, 0.5)
        box = Bnd_Box()
        brepbndlib.Add(shape, box)
        return box.Get()

    direct_shapes = _bboxes_via_direct_serial_build()
    pooled_compound = resolve_planetary_from_bodies(feature, None, {}, frozenset())
    pooled_shapes = _explode_solids(pooled_compound)

    assert len(pooled_shapes) == len(direct_shapes) == 6

    direct_bboxes = sorted(_bbox(s) for s in direct_shapes)
    pooled_bboxes = sorted(_bbox(s) for s in pooled_shapes)
    for direct_box, pooled_box in zip(direct_bboxes, pooled_bboxes):
        for direct_v, pooled_v in zip(direct_box, pooled_box):
            assert direct_v == pytest.approx(pooled_v, abs=1e-6)
