"""Spring feature (`SpringFeature`, `app.document.spring`): a compression spring as one solid, with
open, closed or closed-and-ground ends (owner's request: "flat ends for springs ... ground flat",
as a dedicated Spring feature). Real OCCT through the router.

Sizes are measured from a fine triangulation, and volumes with OCCT's adaptive integration: the
`AddOptimal` bounding box of a trimmed BSpline face and the default volume integration are not
accurate enough on a ground end (both checked while building this)."""

import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _payload(**overrides) -> dict:
    payload = {"mean_diameter": 10.0, "wire_diameter": 1.0, "free_length": 20.0, "active_coils": 5.0}
    payload.update(overrides)
    return payload


def _create_spring(part_id: str, **overrides) -> dict:
    response = client.post(f"/document/parts/{part_id}/spring-features", json=_payload(**overrides))
    assert response.status_code == 201, response.text
    return response.json()


def _spring_shape(part_id: str, feature_id: str):
    from app.document.extrude import compute_part_bodies
    from app.document.store import get_part_or_404

    bodies = compute_part_bodies(get_part_or_404(part_id), frozenset())
    return bodies[feature_id]


def _extent(shape, deflection: float):
    """(xmin, ymin, zmin, xmax, ymax, zmax) from a fine triangulation."""
    from OCC.Core.Bnd import Bnd_Box
    from OCC.Core.BRepBndLib import brepbndlib
    from OCC.Core.BRepMesh import BRepMesh_IncrementalMesh
    from OCC.Core.BRepTools import breptools

    breptools.Clean(shape)
    BRepMesh_IncrementalMesh(shape, deflection, False, 0.1, True)
    box = Bnd_Box()
    brepbndlib.Add(shape, box, True)
    box.SetGap(0.0)
    return box.Get()


def _volume(shape) -> float:
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps

    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props, 1e-7)
    return props.Mass()


def _is_valid_single_solid(shape) -> bool:
    from OCC.Core.BRepCheck import BRepCheck_Analyzer
    from OCC.Core.TopAbs import TopAbs_SOLID
    from OCC.Core.TopExp import TopExp_Explorer

    explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    count = 0
    while explorer.More():
        count += 1
        explorer.Next()
    return count == 1 and BRepCheck_Analyzer(shape).IsValid()


def _ground_off_volume(mean: float, wire: float, active_pitch: float) -> float:
    """What grinding takes off one closed end, integrated along the dead coil and transition:
    the area of the wire's (tilted) circle below the grind plane, along the centreline."""
    from app.document.spring import GRIND_DEPTH, TRANSITION_TURNS

    rho, radius, plane = wire / 2, mean / 2, GRIND_DEPTH * wire

    def pitch(t: float) -> float:
        if t < 1.0:
            return wire
        s = min(1.0, (t - 1.0) / TRANSITION_TURNS)
        return wire + (active_pitch - wire) * s * s * (3 - 2 * s)

    def below(offset: float) -> float:  # circle area below a chord `offset` from its centre
        if offset <= -rho:
            return 0.0
        if offset >= rho:
            return math.pi * rho * rho
        return rho * rho * math.acos(-offset / rho) + offset * math.sqrt(rho * rho - offset * offset)

    steps, z, volume = 40000, 0.0, 0.0
    dt = 2.0 / steps
    for i in range(steps):
        p = pitch((i + 0.5) * dt)
        centre = z + p * dt / 2
        cos_slope = 1 / math.sqrt(1 + (p / (2 * math.pi * radius)) ** 2)
        volume += below((plane - centre) / cos_slope) * math.hypot(2 * math.pi * radius, p) * dt
        z += p * dt
    return volume


# --- Layout ------------------------------------------------------------------


def test_closed_and_ground_spring_is_the_free_length_tall_and_stands_on_the_plane():
    part = _create_part()
    spring = _create_spring(part["id"])
    assert spring["type"] == "spring" and spring["produces"] == "body"
    assert spring["start_end"] == "closed_ground" and spring["finish_end"] == "closed_ground"
    # Ground both ends: free length = centreline - 2 x grind depth, so p = (L - 2d) / (N - 1/2).
    assert spring["active_pitch"] == pytest.approx((20.0 - 2.0) / 4.5)
    assert spring["total_coils"] == pytest.approx(7.0)
    shape = _spring_shape(part["id"], spring["id"])
    assert _is_valid_single_solid(shape)
    x0, y0, z0, x1, y1, z1 = _extent(shape, 0.002)
    assert z0 == pytest.approx(0.0, abs=1e-4) and z1 == pytest.approx(20.0, abs=1e-4)
    assert x1 - x0 == pytest.approx(11.0, abs=5e-3) and y1 - y0 == pytest.approx(11.0, abs=5e-3)


def test_grinding_takes_off_exactly_the_wire_below_the_grind_planes():
    part = _create_part()
    ground = _create_spring(part["id"])
    closed = _create_spring(part["id"], start_end="closed", finish_end="closed")
    pitch = ground["active_pitch"]
    # Same coils (the same centreline once the closed spring's pitch is matched to it).
    unground = client.patch(
        f"/document/parts/{part['id']}/spring-features/{closed['id']}",
        json={"free_length": 20.0 + 2 * 0.25 + 2 * 0.5 * math.cos(math.atan(1.0 / (math.pi * 10.0)))},
    ).json()
    assert unground["active_pitch"] == pytest.approx(pitch, rel=1e-9)
    removed = _volume(_spring_shape(part["id"], closed["id"])) - _volume(_spring_shape(part["id"], ground["id"]))
    assert removed == pytest.approx(2 * _ground_off_volume(10.0, 1.0, pitch), rel=2e-3)


def test_closed_unground_and_open_ends():
    part = _create_part()
    closed = _create_spring(part["id"], start_end="closed", finish_end="closed")
    _, _, z0, _, _, z1 = _extent(_spring_shape(part["id"], closed["id"]), 0.002)
    assert z0 == pytest.approx(0.0, abs=2e-3) and z1 == pytest.approx(20.0, abs=2e-3)
    open_spring = _create_spring(part["id"], start_end="open", finish_end="open")
    assert open_spring["total_coils"] == pytest.approx(5.0)
    shape = _spring_shape(part["id"], open_spring["id"])
    assert _is_valid_single_solid(shape)
    _, _, z0, _, _, z1 = _extent(shape, 0.002)
    assert z0 == pytest.approx(0.0, abs=2e-3) and z1 == pytest.approx(20.0, abs=2e-3)
    mixed = _create_spring(part["id"], start_end="closed_ground", finish_end="open")
    assert mixed["total_coils"] == pytest.approx(6.0)
    assert _is_valid_single_solid(_spring_shape(part["id"], mixed["id"]))


@pytest.mark.parametrize(
    "mean, wire, length, coils",
    [(10.0, 0.3, 20.0, 10.0), (4.0, 0.2, 30.0, 25.0), (20.0, 2.0, 40.0, 6.0), (6.0, 1.5, 25.0, 6.0)],
)
def test_thin_and_thick_wire_springs_build_valid_and_to_length(mean, wire, length, coils):
    """The bug report's 0.3 mm wire on a 10 mm spring among them."""
    part = _create_part()
    spring = _create_spring(
        part["id"], mean_diameter=mean, wire_diameter=wire, free_length=length, active_coils=coils
    )
    shape = _spring_shape(part["id"], spring["id"])
    assert _is_valid_single_solid(shape)
    _, _, z0, _, _, z1 = _extent(shape, wire / 200)
    assert z0 == pytest.approx(0.0, abs=wire / 100) and z1 == pytest.approx(length, abs=wire / 100)


def test_the_mesh_returns_the_spring_as_a_body():
    part = _create_part()
    spring = _create_spring(part["id"])
    bodies = client.get(f"/document/parts/{part['id']}/mesh").json()
    body = next(b for b in bodies if b["body_id"] == spring["id"])
    assert body["is_curve"] is False and body["is_surface"] is False
    assert len(body["mesh"]["vertices"]) > 0


def test_left_handed_winds_the_other_way_and_a_plane_sets_the_axis():
    part = _create_part()
    right = _create_spring(part["id"], start_end="open", finish_end="open")
    left = _create_spring(part["id"], start_end="open", finish_end="open", right_handed=False)
    on_xz = _create_spring(part["id"], plane_ref={"fixed_plane": "XZ"})
    assert left["right_handed"] is False
    # Same spring mirrored: the same volume, and its extent in z is unchanged.
    assert _volume(_spring_shape(part["id"], left["id"])) == pytest.approx(
        _volume(_spring_shape(part["id"], right["id"])), rel=1e-6
    )
    from app.document.create_plane import resolve_plane_ref
    from app.document.models import PlaneRef
    from app.document.store import get_part_or_404

    normal = resolve_plane_ref(get_part_or_404(part["id"]), {}, PlaneRef(fixed_plane="XZ"), frozenset()).normal
    x0, y0, z0, x1, y1, z1 = _extent(_spring_shape(part["id"], on_xz["id"]), 0.002)
    lows, highs = (x0, y0, z0), (x1, y1, z1)
    axis = max(range(3), key=lambda i: abs(normal[i]))
    assert highs[axis] - lows[axis] == pytest.approx(20.0, abs=1e-3)
    assert (highs[axis] if normal[axis] > 0 else -lows[axis]) == pytest.approx(20.0, abs=1e-3)


@pytest.mark.parametrize(
    "overrides, message",
    [
        ({"mean_diameter": 1.0}, "bigger than the wire diameter"),
        ({"wire_diameter": 0.0}, "wire diameter must be more than 0"),
        ({"active_coils": 0.5}, "at least 1 active coil"),
        ({"free_length": 6.0}, "too short"),
    ],
)
def test_numbers_that_make_no_spring_are_refused_with_the_reason(overrides, message):
    part = _create_part()
    response = client.post(f"/document/parts/{part['id']}/spring-features", json=_payload(**overrides))
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "invalid_spring_parameters"
    assert message in response.json()["detail"]["detail"]


def test_too_short_names_the_solid_length():
    part = _create_part()
    detail = client.post(
        f"/document/parts/{part['id']}/spring-features", json=_payload(free_length=6.0)
    ).json()["detail"]["detail"]
    # 7 coils of 1 mm wire, ground 0.25 mm each end: solid at 6.5 mm.
    assert "6.500 mm" in detail


def test_update_keeps_what_it_is_not_sent_and_refuses_a_bad_change():
    part = _create_part()
    spring = _create_spring(part["id"])
    url = f"/document/parts/{part['id']}/spring-features/{spring['id']}"
    updated = client.patch(url, json={"active_coils": 8.0, "finish_end": "open"})
    assert updated.status_code == 200, updated.text
    body = updated.json()
    assert body["active_coils"] == 8.0 and body["finish_end"] == "open" and body["free_length"] == 20.0
    refused = client.patch(url, json={"free_length": 3.0})
    assert refused.status_code == 422
    again = next(f for f in client.get(f"/document/parts/{part['id']}/features").json() if f["id"] == spring["id"])
    assert again["free_length"] == 20.0


def test_spring_survives_the_native_round_trip():
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native spring")
        spring = _create_spring(part["id"], start_end="closed", right_handed=False)
        exported = client.get("/document/export/native").json()
        stored = next(f for p in exported["document"]["parts"] for f in p["features"] if f["id"] == spring["id"])
        assert stored["type"] == "spring" and stored["start_end"] == "closed" and stored["right_handed"] is False
        assert client.post("/document/import/native", json=exported).status_code == 200
        again = next(f for f in client.get(f"/document/parts/{part['id']}/features").json() if f["id"] == spring["id"])
        assert again["active_pitch"] == pytest.approx(spring["active_pitch"])
        assert again["start_end"] == "closed" and again["finish_end"] == "closed_ground"
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


def test_a_spring_can_be_deleted():
    part = _create_part()
    spring = _create_spring(part["id"])
    assert client.delete(f"/document/parts/{part['id']}/features/{spring['id']}").status_code == 204
