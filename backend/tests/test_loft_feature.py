"""Real-OCCT tests for `LoftFeature`'s full router/HTTP surface -
`docs/gear-design/04-helical-herringbone-loft.md` (4b). Structurally
mirrors `test_stage_h_sweep.py`'s own shape (a Feature lofting/sweeping
existing Sketch Profile(s), not gear-specific) - see that file for the same
helper-function conventions this reuses.
"""

import math

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


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


def _add_polygon(sketch_id: str, points: list[tuple[float, float]]) -> list[dict]:
    corners = [_add_point(sketch_id, x, y) for x, y in points]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return corners


def _square_sketch(part_id: str, *, plane: str = "XY", size: float = 10.0, center: tuple[float, float] = (0, 0)) -> dict:
    feature = _create_sketch_feature(part_id, plane)
    cx, cy = center
    h = size / 2
    _add_polygon(feature["sketch_id"], [(cx - h, cy - h), (cx + h, cy - h), (cx + h, cy + h), (cx - h, cy + h)])
    return feature


def _profile_ref(sketch_id: str, entity_id: str, entity_type: str = "line") -> dict:
    return {"sketch_id": sketch_id, "entity_type": entity_type, "entity_id": entity_id}


def _section(sketch_feature: dict, *, reference_point_id: str | None = None) -> dict:
    section = {"sketch_feature_id": sketch_feature["id"]}
    if reference_point_id is not None:
        section["reference_point"] = _profile_ref(sketch_feature["sketch_id"], reference_point_id, "point")
    return section


def _create_loft(part_id: str, sections: list[dict], **overrides) -> dict:
    payload = {"sections": sections, "mode": "boss"}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/loft-features", json=payload)


def _move_sketch_feature_up(part_id: str, sketch_feature: dict, height: float) -> dict:
    """A second square/hexagon Sketch, offset `height` along Z, via a
    `CreatePlaneFeature` (`OFFSET_FACE` from the fixed XY plane) - the
    standard way any Feature in this codebase puts a Sketch at a real 3D
    height above another one."""
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


# --- Basic construction --------------------------------------------------


def test_loft_between_two_squares_produces_one_solid_body():
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    # top sketch anchored to the offset plane requires plane_feature_id -
    # app.document.router's SketchFeatureCreate needs plane_feature_id, not
    # a fixed plane, for a custom-plane Sketch.
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    assert top_response.status_code == 201, top_response.json()
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])

    response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "loft"
    assert body["warnings"] == []

    mesh = _mesh(part["id"])
    assert len(mesh) == 1
    vertices = mesh[0]["mesh"]["vertices"]
    z_values = sorted({round(z, 3) for _, _, z in vertices})
    assert z_values[0] == 0.0
    assert z_values[-1] == 8.0
    # A straight prism between two identical 10x10 squares 8mm apart -
    # volume should be exactly 10*10*8 = 800 (known volume check, not just
    # "it runs").
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps

    from app.document.store import get_part_or_404
    from app.document.extrude import compute_part_bodies

    real_part = get_part_or_404(part["id"])
    bodies = compute_part_bodies(real_part)
    (solid,) = bodies.values()
    props = GProp_GProps()
    brepgprop.VolumeProperties(solid, props)
    assert abs(props.Mass() - 800.0) < 1.0


def test_loft_between_square_and_hexagon_produces_valid_geometry():
    """A genuinely dissimilar-profile Loft (4b's own "not simply rotated
    copies of the same profile" case) - a real, non-degenerate solid whose
    bounding box spans both profiles' own extents."""
    part = _create_part()
    bottom = _square_sketch(part["id"], size=10.0)
    plane = _move_sketch_feature_up(part["id"], bottom, 6.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    assert top_response.status_code == 201, top_response.json()
    top = top_response.json()
    hex_points = [(6 * math.cos(2 * math.pi * i / 6), 6 * math.sin(2 * math.pi * i / 6)) for i in range(6)]
    _add_polygon(top["sketch_id"], hex_points)

    response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert response.status_code == 201, response.json()

    mesh = _mesh(part["id"])
    vertices = mesh[0]["mesh"]["vertices"]
    assert len(vertices) > 0
    z_values = sorted({round(z, 3) for _, _, z in vertices})
    assert z_values[0] == 0.0
    assert z_values[-1] == 6.0
    max_radius = max(math.hypot(x, y) for x, y, z in vertices)
    # Square's own corner radius (10/sqrt(2) ~= 7.07) is the widest point of
    # either profile - the loft shouldn't wildly overshoot it.
    assert max_radius < 8.0


# --- reference_point alignment -------------------------------------------


def _rectangle_sketch(part_id: str, *, plane: str | None = None, plane_feature_id: str | None = None) -> tuple[dict, list[dict]]:
    """A 10x4 rectangle (asymmetric aspect ratio - only 180deg rotational
    symmetry, unlike a square's 90deg symmetry) - the "genuinely dissimilar
    reference angle" alignment test below needs a shape where rotating by
    an arbitrary angle actually changes the resulting point set."""
    if plane_feature_id is not None:
        response = client.post(
            f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_feature_id}
        )
    else:
        response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane or "XY"})
    assert response.status_code == 201, response.json()
    feature = response.json()
    corners = _add_polygon(feature["sketch_id"], [(-5, -2), (5, -2), (5, 2), (-5, 2)])
    return feature, corners


def test_reference_point_alignment_changes_the_lofted_geometry():
    """Two lofts between the exact same pair of rectangles (identical
    coordinates in both runs, only translated up in Z for the top section)
    - the only difference between the two runs is whether `reference_point`
    is set at all. With no `reference_point`, `ThruSections`' own default
    correspondence applies to two coordinate-identical wires unmodified
    (effectively a straight prism). With a `reference_point` naming one
    corner on the bottom and a *different* corner on the top, the top
    section is rotated about its own local origin so its own reference
    point's local angle matches the bottom's - a real, non-trivial rotation
    for a rectangle (no 90deg symmetry the way a square has), so the two
    lofts must differ - confirming the alignment transform is actually
    applied, not a silent no-op."""

    def _build(part_name: str, *, use_reference_points: bool) -> list[tuple[float, float, float]]:
        part = _create_part(part_name)
        bottom, bottom_corners = _rectangle_sketch(part["id"], plane="XY")
        plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
        top, top_corners = _rectangle_sketch(part["id"], plane_feature_id=plane["id"])
        if use_reference_points:
            # bottom_corners[0] = (-5, -2) (local angle ~201.8deg);
            # top_corners[1] = (5, -2) (local angle ~-21.8deg) - genuinely
            # different local angles.
            sections = [
                _section(bottom, reference_point_id=bottom_corners[0]["id"]),
                _section(top, reference_point_id=top_corners[1]["id"]),
            ]
        else:
            sections = [_section(bottom), _section(top)]
        response = _create_loft(part["id"], sections)
        assert response.status_code == 201, response.json()
        return _mesh(part["id"])[0]["mesh"]["vertices"]

    unaligned_vertices = _build("Unaligned", use_reference_points=False)
    aligned_vertices = _build("Aligned", use_reference_points=True)
    assert aligned_vertices != unaligned_vertices


# --- Validation ------------------------------------------------------------


def test_loft_requires_at_least_two_sections():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    response = _create_loft(part["id"], [_section(bottom)])
    assert response.status_code == 422


def test_loft_rejects_a_profile_with_holes():
    part = _create_part()
    bottom = _create_sketch_feature(part["id"], "XY")
    center = _add_point(bottom["sketch_id"], 0.0, 0.0)
    outer_edge = _add_point(bottom["sketch_id"], 5.0, 0.0)
    inner_edge = _add_point(bottom["sketch_id"], 2.0, 0.0)
    client.post(
        f"/sketch/sketches/{bottom['sketch_id']}/circles",
        json={"center_point_id": center["id"], "radius_point_id": outer_edge["id"]},
    )
    client.post(
        f"/sketch/sketches/{bottom['sketch_id']}/circles",
        json={"center_point_id": center["id"], "radius_point_id": inner_edge["id"]},
    )
    plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])

    response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_loft_section"


def test_loft_rejects_a_sketch_feature_id_that_does_not_exist():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    response = _create_loft(
        part["id"], [_section(bottom), {"sketch_feature_id": "does-not-exist"}]
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_loft_section"


# --- Composability: Boss/Cut, and being a valid target/source for other Features --


def test_cut_loft_requires_a_target_body():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)], mode="cut")
    assert response.status_code == 422


def test_update_loft_feature_changing_ruled_updates_the_response():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    create_response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/loft-features/{feature_id}", json={"ruled": True}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["ruled"] is True


def test_update_loft_feature_rejects_an_invalid_change():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    create_response = _create_loft(part["id"], [_section(bottom), _section(top)])
    feature_id = create_response.json()["id"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/loft-features/{feature_id}", json={"sections": []}
    )
    assert patch_response.status_code == 422
    assert _mesh(part["id"])[0]["mesh"]["vertices"]


def test_step_export_succeeds_for_a_loft_body():
    part = _create_part()
    bottom = _square_sketch(part["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert len(export_response.content) > 1000
    assert b"ISO-10303-21" in export_response.content


def test_native_export_import_round_trips_a_loft_feature():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Loft Test")
        bottom = _square_sketch(part["id"])
        plane = _move_sketch_feature_up(part["id"], bottom, 5.0)
        top_response = client.post(
            f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
        )
        top = top_response.json()
        _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
        loft_response = _create_loft(part["id"], [_section(bottom), _section(top)])
        assert loft_response.status_code == 201, loft_response.json()
        feature_id = loft_response.json()["id"]
        vertices_before = _mesh(part["id"])[0]["mesh"]["vertices"]

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        loft_dicts = [f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "loft"]
        assert any(f["id"] == feature_id for f in loft_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = _mesh(part["id"])[0]["mesh"]["vertices"]
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_loft_body_can_be_cut_afterward_via_a_new_sketch():
    """`00-conventions.md`'s "downstream Features already work on any gear
    Body" claim, generalized: exercised here for a plain Loft Body."""
    part = _create_part()
    bottom = _square_sketch(part["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top_response = client.post(
        f"/document/parts/{part['id']}/features/sketch", json={"plane_feature_id": plane["id"]}
    )
    top = top_response.json()
    _add_polygon(top["sketch_id"], [(-5, -5), (5, -5), (5, 5), (-5, 5)])
    loft_response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert loft_response.status_code == 201, loft_response.json()
    loft_body_id = _mesh(part["id"])[0]["body_id"]

    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    center = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 0.0, "y": 0.0})
    radius_point = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 1.0, "y": 0.0})
    client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center.json()["id"], "radius_point_id": radius_point.json()["id"]},
    )

    cut_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "cut",
            "start_distance": -1.0,
            "end_distance": 10.0,
            "target_body_ids": [loft_body_id],
        },
    )
    assert cut_response.status_code == 201, cut_response.json()
    mesh = _mesh(part["id"])
    assert len(mesh) == 1


# --- Thin/open-chain loft (`thickness`) -------------------------------------
#
# A second, later addition alongside the closed-profile solid loft tested
# above - lofts between open chains instead of closed profiles, thickening
# the resulting lofted shell into a solid (see app.document.loft's own
# module docstring). Same real-OCCT-required status as every test above.


def _open_line_sketch(
    part_id: str, points: list[tuple[float, float]], *, plane: str | None = None, plane_feature_id: str | None = None
) -> dict:
    """A deliberately *unclosed* polyline (no wrap-around line back to the
    first point) - the open-chain counterpart to `_square_sketch`/
    `_add_polygon` above."""
    if plane_feature_id is not None:
        response = client.post(
            f"/document/parts/{part_id}/features/sketch", json={"plane_feature_id": plane_feature_id}
        )
    else:
        response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane or "XY"})
    assert response.status_code == 201, response.json()
    feature = response.json()
    corners = [_add_point(feature["sketch_id"], x, y) for x, y in points]
    for a, b in zip(corners, corners[1:]):
        _add_line(feature["sketch_id"], a["id"], b["id"])
    return feature


def test_loft_between_two_open_lines_with_thickness_produces_a_solid():
    """Two identical single-segment open chains, directly stacked 8mm apart
    in Z, loft into a single flat 10x8 rectangular face (no cross-section
    area of its own - an open chain, unlike a closed Profile, has none)
    which `thickness=1.0` then thickens into a real box - known volume
    10 * 8 * 1 = 80, the open-chain counterpart to `test_loft_between_two_
    squares_produces_one_solid_body`'s own known-volume check above."""
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])

    response = _create_loft(part["id"], [_section(bottom), _section(top)], thickness=1.0)
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "loft"
    assert body["thickness"] == 1.0

    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps

    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    real_part = get_part_or_404(part["id"])
    bodies = compute_part_bodies(real_part)
    (solid,) = bodies.values()
    props = GProp_GProps()
    brepgprop.VolumeProperties(solid, props)
    assert abs(props.Mass() - 80.0) < 1.0


def test_loft_negative_thickness_flips_direction_and_still_succeeds():
    """`thickness`'s sign only picks which side of the lofted shell the
    material is added to (see `app.document.loft.resolve_loft_from_bodies`'s
    own docstring) - a negative value is not itself an error the way 0 is
    (`test_loft_thickness_zero_is_rejected` below)."""
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])

    response = _create_loft(part["id"], [_section(bottom), _section(top)], thickness=-1.0)
    assert response.status_code == 201, response.json()
    assert response.json()["thickness"] == -1.0


def test_loft_thickness_zero_is_rejected():
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])

    response = _create_loft(part["id"], [_section(bottom), _section(top)], thickness=0.0)
    assert response.status_code == 400


def test_loft_open_chain_sections_without_thickness_are_rejected():
    """Without `thickness` set, `_resolve_closed_section` (the original
    closed-profile path) still runs, and an open chain has no closed
    Profile for it to find - confirms omitting `thickness` doesn't silently
    fall back to treating open sections as loftable solid cross-sections."""
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])

    response = _create_loft(part["id"], [_section(bottom), _section(top)])
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_loft_section"


def test_loft_rejects_a_sketch_with_multiple_disjoint_open_chains():
    """Two unconnected line segments in the same Sketch - `detect_open_
    chain` reports `MULTIPLE_CHAINS` rather than picking one arbitrarily,
    since a Loft section needs exactly one chain to loft."""
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    extra_a = _add_point(bottom["sketch_id"], -5.0, 5.0)
    extra_b = _add_point(bottom["sketch_id"], 5.0, 5.0)
    _add_line(bottom["sketch_id"], extra_a["id"], extra_b["id"])
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])

    response = _create_loft(part["id"], [_section(bottom), _section(top)], thickness=1.0)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_loft_section"


def test_update_loft_feature_can_change_thickness():
    part = _create_part()
    bottom = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane="XY")
    plane = _move_sketch_feature_up(part["id"], bottom, 8.0)
    top = _open_line_sketch(part["id"], [(-5.0, 0.0), (5.0, 0.0)], plane_feature_id=plane["id"])
    create_response = _create_loft(part["id"], [_section(bottom), _section(top)], thickness=1.0)
    assert create_response.status_code == 201, create_response.json()
    feature_id = create_response.json()["id"]

    patch_response = client.patch(
        f"/document/parts/{part['id']}/loft-features/{feature_id}", json={"thickness": 2.0}
    )
    assert patch_response.status_code == 200, patch_response.json()
    assert patch_response.json()["thickness"] == 2.0
