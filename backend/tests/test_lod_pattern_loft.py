"""Real-OCCT tests for the LOD coarse-mesh mechanism's Pattern/Loft
extension - `docs/lod-strategy/01-design.md` chunks 3/4 (SS8, items 3/4):
the new coarse builders in `app.document.pattern`/`app.document.loft`, their
`compute_part_bodies_coarse` dispatch, the two new coarse-preview endpoints,
and the new `PatternFeature` instance-count upper bound
(`app.document.router._PATTERN_MAX_TOTAL_INSTANCES`). Structurally mirrors
`test_lod_coarse_mesh.py`'s own shape (chunk 2) - same client/helper
conventions, same "deliberately loose" bounding-box comparisons.
"""

import time

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})

# Same generous, sandbox-relative ceiling `test_lod_coarse_mesh.py` uses - a
# coarse build here is either N cheap rigid `BRepBuilderAPI_Transform` calls
# (Pattern, no fuse) or a single 2-section `BRepOffsetAPI_ThruSections`
# (Loft), neither of which is anywhere near this ceiling even generously.
_COARSE_WALL_CLOCK_CEILING_SECONDS = 1.0


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str, **params) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh", params=params)
    assert response.status_code == 200, response.json()
    return response.json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _features(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/features")
    assert response.status_code == 200
    return response.json()


def _radial_extent(vertices: list[list[float]]) -> float:
    """Max distance from the Z axis - the natural "how wide" proxy for a
    Body built along Z (this app's default plane), same helper `test_lod_
    coarse_mesh.py` already uses for the gear-family coarse builders."""
    return max((x**2 + y**2) ** 0.5 for x, y, z in vertices)


# --- PatternFeature helpers ----------------------------------------------------


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )


def _boxy_part_and_body(*, size: float = 10.0) -> tuple[dict, str]:
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"], size=size)
    response = _create_extrude_feature(part["id"], sketch_feature["id"])
    assert response.status_code == 201, response.json()
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 1
    return part, body_ids[0]


def _fixed_axis_direction(axis: str) -> dict:
    return {"edge_ref": None, "sketch_line_ref": None, "fixed_axis": axis}


def _pattern_payload(
    source_body_ids: list[str],
    direction_1: dict,
    count_1: int,
    spacing_1: float,
    **overrides,
) -> dict:
    payload = {
        "source_body_ids": source_body_ids,
        "pattern_type": "rectangular",
        "direction_1": direction_1,
        "count_1": count_1,
        "spacing_1": spacing_1,
    }
    payload.update(overrides)
    return payload


def _create_pattern(part_id: str, payload: dict):
    return client.post(f"/document/parts/{part_id}/pattern-features", json=payload)


def _hole_cut(part_id: str, plate_id: str, *, x0: float, y0: float, size: float = 2.0) -> dict:
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    response = _create_extrude_feature(part_id, sketch["id"], extrude_type="cut", target_body_ids=[plate_id])
    assert response.status_code == 201, response.json()
    return response.json()


def _plate_with_hole(part_id: str, *, plate_size: float = 40.0, hole_size: float = 2.0) -> tuple[str, dict]:
    half = plate_size / 2.0
    sketch = _create_square_sketch_feature(part_id, x0=-half, y0=-half, size=plate_size)
    response = _create_extrude_feature(part_id, sketch["id"])
    assert response.status_code == 201, response.json()
    plate_id = response.json()["id"]
    cut = _hole_cut(part_id, plate_id, x0=1.0, y0=1.0, size=hole_size)
    return plate_id, cut


# --- PatternFeature: tier=coarse skips the fuse chain entirely ----------------


def test_pattern_tier_coarse_returns_every_instance_unfused_even_with_merge_fuse_into_one():
    """Overlapping instances (`spacing_1` well under the seed box's own
    10mm size) so the real `merge=fuse_into_one` construction's `BRepAlgoAPI_
    Fuse` chain genuinely merges every instance into *one* topologically-
    connected solid - `app.document.extrude._explode_solids` (which
    `_register_solids` uses to split a compound back into Bodies) counts
    real, shared-topology connectivity, not spatial overlap alone, so this
    is the only reliable way to make "real fuse merges to 1" and "coarse
    never fuses, always N+1" produce a genuinely different Body count."""
    part, seed_id = _boxy_part_and_body(size=10.0)
    payload = _pattern_payload([seed_id], _fixed_axis_direction("x"), 4, 4.0, merge="fuse_into_one")
    response = _create_pattern(part["id"], payload)
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 1  # every instance overlaps its neighbour -> one fused solid
    assert full_mesh[0]["source"] == "computed"

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    # Only the 3 new instances - the seed Body's own `base_feature_id` is
    # the *Extrude* that made it, not this Pattern, so `tier=coarse`'s own
    # `coarse_eligible_feature_ids` filter (`app.document.router.
    # get_part_mesh`) correctly leaves it out, matching the exact same
    # documented ambiguity chunk 2 already accepted for a Gear/BevelGear
    # bossed into an existing target Body.
    assert len(coarse_mesh) == 3
    assert all(entry["source"] == "coarse" for entry in coarse_mesh)


def test_pattern_coarse_preview_returns_the_new_instance_count_and_persists_nothing():
    part, seed_id = _boxy_part_and_body(size=10.0)
    features_before = _features(part["id"])
    payload = _pattern_payload([seed_id], _fixed_axis_direction("x"), 5, 20.0, merge="fuse_into_one")

    start = time.perf_counter()
    response = client.post(f"/document/parts/{part['id']}/pattern-features/coarse-preview", json=payload)
    elapsed = time.perf_counter() - start
    assert response.status_code == 200, response.json()
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    bodies = response.json()
    # Index 0 is the untouched seed, never part of either resolver's own
    # returned instance dict - count_1=5 means 4 *new* instances.
    assert len(bodies) == 4
    assert all(entry["source"] == "coarse" for entry in bodies)

    # Nothing persisted: no PatternFeature was added to the Part's own
    # Feature list (still just the seed's own sketch+extrude), and the
    # seed Body remains the only real Body.
    assert _features(part["id"]) == features_before
    assert len(_body_ids(part["id"])) == 1


def test_pattern_tool_feature_id_coarse_preview_returns_unfused_tool_copies_and_never_touches_the_target():
    """`resolve_pattern_coarse_from_bodies`'s own tool_feature_id branch
    never runs the real path's final `BRepAlgoAPI_Cut`/`Fuse` into the
    target - the coarse-preview response is the realized-but-unfused tool
    copies alone, and the plate's own real mesh (untouched by a preview
    call) still reflects only its original single hole."""
    part = _create_part()
    plate_id, cut = _plate_with_hole(part["id"], plate_size=40.0, hole_size=2.0)
    plate_mesh_before = _mesh(part["id"])
    assert len(plate_mesh_before) == 1
    feature_ids_before = [f["id"] for f in _features(part["id"])]

    payload = {
        "source_body_ids": [],
        "tool_feature_id": cut["id"],
        "pattern_type": "rectangular",
        "direction_1": _fixed_axis_direction("x"),
        "count_1": 3,
        "spacing_1": 5.0,
        "merge": "fuse_into_one",
    }
    response = client.post(f"/document/parts/{part['id']}/pattern-features/coarse-preview", json=payload)
    assert response.status_code == 200, response.json()

    bodies = response.json()
    # count_1=3 -> 2 *additional* tool copies (index 0 is already baked
    # into the target by the real Cut that already ran).
    assert len(bodies) == 2
    assert all(entry["source"] == "coarse" for entry in bodies)

    # The plate itself: still exactly one Body, unmodified by the preview.
    plate_mesh_after = _mesh(part["id"])
    assert len(plate_mesh_after) == 1
    assert plate_mesh_after[0]["body_id"] == plate_id

    # No PatternFeature added - the Feature list is exactly what it was
    # before this preview call, seed's own sketch+extrude and the hole's
    # own sketch+extrude and nothing else.
    assert [f["id"] for f in _features(part["id"])] == feature_ids_before


# --- PatternFeature: instance-count upper bound -------------------------------


def test_pattern_rectangular_over_limit_total_instances_returns_422():
    part, seed_id = _boxy_part_and_body()
    payload = _pattern_payload([seed_id], _fixed_axis_direction("x"), 501, 1.0)
    response = _create_pattern(part["id"], payload)
    assert response.status_code == 422, response.json()


def test_pattern_rectangular_product_over_limit_returns_422_even_when_neither_factor_looks_large():
    """Neither `count_1` nor `count_2` alone looks unreasonable (50 each),
    but their product (2500) is well over the cap - the check must compare
    the product, not either factor individually."""
    part, seed_id = _boxy_part_and_body()
    payload = _pattern_payload(
        [seed_id], _fixed_axis_direction("x"), 50, 1.0, count_2=50, direction_2=_fixed_axis_direction("y")
    )
    response = _create_pattern(part["id"], payload)
    assert response.status_code == 422, response.json()


def _standalone_axis_line(part_id: str, *, x: float, y0: float, y1: float) -> dict:
    """A Sketch containing just one Line, usable as a Circular Pattern
    axis independent of any Body geometry - mirrors test_stage_j_pattern.
    py's own `_create_standalone_direction_line`."""
    feature = _create_sketch_feature(part_id, "XY")
    p0 = _add_point(feature["sketch_id"], x, y0)
    p1 = _add_point(feature["sketch_id"], x, y1)
    line = _add_line(feature["sketch_id"], p0["id"], p1["id"])
    return {"sketch_id": feature["sketch_id"], "line_id": line["id"]}


def test_pattern_circular_over_limit_returns_422():
    part, seed_id = _boxy_part_and_body()
    axis_line = _standalone_axis_line(part["id"], x=50.0, y0=-10.0, y1=10.0)
    response = client.post(
        f"/document/parts/{part['id']}/pattern-features",
        json={
            "source_body_ids": [seed_id],
            "pattern_type": "circular",
            "axis": {
                "edge_ref": None,
                "face_ref": None,
                "sketch_line_ref": {
                    "sketch_id": axis_line["sketch_id"],
                    "entity_type": "line",
                    "entity_id": axis_line["line_id"],
                },
            },
            "count_angular": 501,
            "angle_total": 360.0,
        },
    )
    assert response.status_code == 422, response.json()
    detail = response.json()["detail"]
    assert isinstance(detail, str) and "count_angular" in detail


def test_pattern_rectangular_comfortably_under_limit_is_accepted():
    part, seed_id = _boxy_part_and_body()
    payload = _pattern_payload([seed_id], _fixed_axis_direction("x"), 50, 1.0)
    response = _create_pattern(part["id"], payload)
    assert response.status_code == 201, response.json()
    assert len(_body_ids(part["id"])) == 50


# --- LoftFeature helpers ---------------------------------------------------


def _add_polygon(sketch_id: str, points: list[tuple[float, float]]) -> None:
    corners = [_add_point(sketch_id, x, y) for x, y in points]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


def _square_sketch_at_plane(part_id: str, plane_feature_id: str | None, *, size: float) -> dict:
    if plane_feature_id is None:
        feature = _create_sketch_feature(part_id, "XY")
    else:
        response = client.post(
            f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_feature_id}
        )
        assert response.status_code == 201, response.json()
        feature = response.json()
    half = size / 2.0
    _add_polygon(feature["sketch_id"], [(-half, -half), (half, -half), (half, half), (-half, half)])
    return feature


def _offset_plane(part_id: str, height: float) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [{"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}],
            "offset": height,
        },
    )
    assert response.status_code == 201, response.json()
    return response.json()


def _section(sketch_feature: dict) -> dict:
    return {"sketch_feature_id": sketch_feature["id"]}


def _create_loft(part_id: str, sections: list[dict], **overrides) -> dict:
    payload = {"sections": sections, "mode": "boss"}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/loft-features", json=payload)


def _three_section_bulge_sketches(part_id: str) -> list[dict]:
    """bottom(10) -> mid(30, bulged outward) -> top(10) - a real loft whose
    mid-height cross-section is much wider than either end, so "first and
    last only" (the coarse shortcut) is trivially, honestly distinguishable
    from the real full-fidelity construction by bounding-box radius alone."""
    bottom = _square_sketch_at_plane(part_id, None, size=10.0)
    mid_plane = _offset_plane(part_id, 4.0)
    mid = _square_sketch_at_plane(part_id, mid_plane["id"], size=30.0)
    top_plane = _offset_plane(part_id, 8.0)
    top = _square_sketch_at_plane(part_id, top_plane["id"], size=10.0)
    return [bottom, mid, top]


# --- LoftFeature: tier=coarse uses only the first and last section ------------


def test_loft_tier_coarse_skips_the_bulging_middle_section():
    part = _create_part()
    sections = [_section(s) for s in _three_section_bulge_sketches(part["id"])]
    response = _create_loft(part["id"], sections, ruled=True)
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 1
    full_extent = _radial_extent(full_mesh[0]["mesh"]["vertices"])

    start = time.perf_counter()
    coarse_mesh = _mesh(part["id"], tier="coarse")
    elapsed = time.perf_counter() - start
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    assert len(coarse_mesh) == 1
    assert coarse_mesh[0]["source"] == "coarse"
    coarse_extent = _radial_extent(coarse_mesh[0]["mesh"]["vertices"])

    # The real loft's own bulging mid-section (30mm square, vs 10mm at
    # each end) genuinely widens its own bounding box; the coarse pass -
    # lofting directly between the two 10mm ends - never sees it.
    assert coarse_extent < 0.7 * full_extent


def test_loft_coarse_preview_returns_a_solid_and_persists_nothing():
    part = _create_part()
    sections = [_section(s) for s in _three_section_bulge_sketches(part["id"])]
    features_before = _features(part["id"])
    payload = {"sections": sections, "mode": "boss", "ruled": True}

    start = time.perf_counter()
    response = client.post(f"/document/parts/{part['id']}/loft-features/coarse-preview", json=payload)
    elapsed = time.perf_counter() - start
    assert response.status_code == 200, response.json()
    assert elapsed < _COARSE_WALL_CLOCK_CEILING_SECONDS

    bodies = response.json()
    assert len(bodies) == 1
    assert bodies[0]["source"] == "coarse"
    assert len(bodies[0]["mesh"]["vertices"]) > 0

    # No LoftFeature added - the Feature list is exactly the sketches/planes
    # set up above, unchanged.
    assert _features(part["id"]) == features_before
    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    assert mesh[0]["source"] == "placeholder"


def test_loft_coarse_with_exactly_two_sections_degrades_to_the_real_construction():
    """The minimum valid Loft input (2 sections) - "first and last" *is*
    the whole input, so the coarse pass must not error or diverge; it
    should produce something equivalent (here, bounding-box-identical) to
    the real construction, not a special case."""
    part = _create_part()
    bottom = _square_sketch_at_plane(part["id"], None, size=10.0)
    top_plane = _offset_plane(part["id"], 8.0)
    top = _square_sketch_at_plane(part["id"], top_plane["id"], size=16.0)
    sections = [_section(bottom), _section(top)]

    response = _create_loft(part["id"], sections, ruled=True)
    assert response.status_code == 201, response.json()

    full_mesh = _mesh(part["id"])
    assert len(full_mesh) == 1
    full_extent = _radial_extent(full_mesh[0]["mesh"]["vertices"])

    coarse_mesh = _mesh(part["id"], tier="coarse")
    assert len(coarse_mesh) == 1
    coarse_extent = _radial_extent(coarse_mesh[0]["mesh"]["vertices"])

    # Same 2 sections, same `ThruSections` call either way (see `resolve_
    # loft_coarse_from_bodies`'s own docstring) - expect the two builds to
    # agree closely, not necessarily bit-for-bit across two independent
    # tessellation passes.
    assert coarse_extent == pytest.approx(full_extent, rel=1e-6)
