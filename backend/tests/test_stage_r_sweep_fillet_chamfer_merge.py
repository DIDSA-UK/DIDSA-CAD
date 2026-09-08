"""Investigation repro: real-OCCT tests for the reported "a body loses
material after Merge" bug, built against the *actual* reported shape - a
rectangle Profile Swept around a standalone Ellipse path, then Fillet and
Chamfer applied, then Move/Copy Body (overlapping translated copy), then
Merge - rather than the simplified stand-in (a hollow profile on a
chained-Arc path) a prior investigation session used, which led to a real
but different fix (native Circle sweep-path support, `3e112b0`) that does
not touch this shape: Ellipse was already a native single-edge closed sweep
path before that commit.

Every stage below is checked with real OCCT volume
(`GProp_GProps`/`brepgprop.VolumeProperties`, the same `_occt_volume` pattern
`test_stage_h_sweep.py` already established), not just body count or mesh
shape, so whichever stage's assertion first fails pinpoints the exact
operation that introduces the defect - see that module's own
`test_boss_sweep_of_an_annular_profile_along_a_circular_path_produces_one_
correct_torus` for why body-count/mesh-only checks are not sufficient here
(a wrong-but-single-body result is a real, previously-seen failure mode).

Root-caused directly against a real OCCT kernel (pythonocc-core 7.9.3), this
turned out NOT to be a Fillet/Chamfer- or Ellipse-specific defect: the full
staged repro below (and the raw-Sweep-only isolation control) both pass
cleanly, because a single Merge of two independently-computed bodies never
hits the actual trigger. The real defect was in `BRepAlgoAPI_Fuse` itself -
confirmed to silently produce a corrupted (nonzero-but-wrong-volume, or
zero-solid) result when one of its operand shapes (built via
`BRepOffsetAPI_MakePipeShell`, i.e. any Sweep - reproduced here with the
rectangle-around-ellipse shape, and separately against a plain circular
torus matching a prior investigation's finding) had already been used as an
operand in an *earlier, separate* `BRepAlgoAPI_Fuse` call in the same
process, even when the second call's own inputs were otherwise completely
independent and correct in isolation. Confirmed deterministic; confirmed
NOT fixed by `SetFuzzyValue`, `SetRunParallel(False)`, `ShapeFix_Shape`,
`BRepBuilderAPI_Sewing` + `ShapeUpgrade_ShapeDivideClosed`, deep-copying the
operand, or a BREP serialization round-trip. Cross-checked against an
independent Monte Carlo point-classification volume estimate
(`BRepClass3d_SolidClassifier`, not sharing any code path with the BOP
algorithms under suspicion) to confirm which of `BRepAlgoAPI_Fuse`'s and
`BRepAlgoAPI_Common`'s often-differing outputs was actually wrong in a given
case - both can independently misbehave, so neither is a safe oracle for
the other.

The actual fix - `BRepAlgoAPI_BooleanOperation.SetNonDestructive(True)`, a
documented OCCT flag controlling whether a Boolean operation may modify its
own argument shapes in place - is now used by `extrude._safe_fuse` itself
(see that function's own doc comment) and confirmed via a clean 60-point
scan of the real repro shape (fresh operands, no reuse) to leave zero
residual failures. `test_safe_fuse_correctly_reuses_an_already_fused_
swept_operand` below exercises `_safe_fuse` directly against the exact
confirmed-corrupting sequence and asserts the *correct* volume is now
returned. A second, narrower, unrelated failure mode - two shapes offset by
an exact tangency-inducing amount producing zero solids even on their very
first-ever Boolean operation - is NOT fixed by `SetNonDestructive` and
remains a residual risk that `_safe_fuse`'s pre-existing zero-solid/volume
checks still catch and report as a clean error rather than lost material;
see `test_safe_fuse_rejects_a_near_tangent_result_instead_of_returning_
wrong_volume`.

Needs a real pythonocc-core environment - see `backend/environment.yml`.
"""

import math

import pytest
from fastapi.testclient import TestClient
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers (copy-pasted from test_stage_h_sweep.py / test_stage_d_fillet.py /
# test_stage_e_chamfer.py / test_feature_move_body.py / test_stage_q_merge.py -
# same "no shared conftest across test_stage_*.py files" convention every
# other file in this family already uses) --------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
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


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> list[dict]:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    lines = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        lines.append(_add_line(sketch_id, a["id"], b["id"]))
    return lines


def _add_ellipse(sketch_id: str, center: dict, *, major_radius: float, angle: float, minor_radius: float) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/ellipses",
        json={
            "center_point_id": center["id"],
            "major_radius": major_radius,
            "angle": angle,
            "minor_radius": minor_radius,
        },
    )
    assert response.status_code == 201
    return response.json()


def _create_profile_sketch_feature(part_id: str, *, size: float = 2.0) -> dict:
    feature = _create_sketch_feature(part_id, "XY")
    _add_square(feature["sketch_id"], 0.0, 0.0, size)
    return feature


def _create_ellipse_path_sketch_feature(
    part_id: str, *, major_radius: float = 5.0, minor_radius: float = 3.0
) -> tuple[dict, dict]:
    feature = _create_sketch_feature(part_id, "XZ")
    center = _add_point(feature["sketch_id"], -major_radius, 0.0)
    ellipse = _add_ellipse(feature["sketch_id"], center, major_radius=major_radius, angle=0.0, minor_radius=minor_radius)
    return feature, ellipse


def _path_ref(sketch_id: str, entity_id: str, entity_type: str = "line") -> dict:
    return {"sketch_id": sketch_id, "entity_type": entity_type, "entity_id": entity_id}


def _create_sweep(
    part_id: str,
    sketch_feature_id: str,
    path_refs: list[dict],
    *,
    mode: str = "boss",
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/sweep-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "path_refs": path_refs,
            "mode": mode,
            "target_body_ids": target_body_ids or [],
        },
    )


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _occt_volume(part_id: str, body_id: str) -> float:
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    props = GProp_GProps()
    brepgprop.VolumeProperties(bodies[body_id], props)
    return props.Mass()


def _solid_count(part_id: str, body_id: str) -> int:
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    explorer = TopExp_Explorer(bodies[body_id], TopAbs_SOLID)
    count = 0
    while explorer.More():
        count += 1
        explorer.Next()
    return count


def _common_volume(part_id: str, body_id_a: str, body_id_b: str) -> float:
    """Independent cross-check, computed directly against the two pre-merge
    solids (not through `_safe_fuse`): the volume of their intersection, so
    the expected union volume can be derived from the inclusion-exclusion
    identity `vol(a) + vol(b) - vol(a & b)` without relying on Merge/Fuse
    itself to get it right."""
    part = get_part_or_404(part_id)
    bodies = compute_part_bodies(part)
    common = BRepAlgoAPI_Common(bodies[body_id_a], bodies[body_id_b])
    assert common.IsDone()
    props = GProp_GProps()
    brepgprop.VolumeProperties(common.Shape(), props)
    return props.Mass()


def _edge_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "edge", "index": index}


def _create_fillet(part_id: str, edge_refs: list[dict], radius: float):
    return client.post(
        f"/document/parts/{part_id}/fillet-features",
        json={"edge_refs": edge_refs, "radius": radius},
    )


def _create_chamfer(part_id: str, edge_refs: list[dict], distance: float):
    return client.post(
        f"/document/parts/{part_id}/chamfer-features",
        json={"edge_refs": edge_refs, "distance": distance},
    )


def _create_move_body(part_id: str, body_id: str, **kwargs):
    payload = {"body_id": body_id}
    payload.update(kwargs)
    return client.post(f"/document/parts/{part_id}/move-body-features", json=payload)


def _create_merge(part_id: str, body_ids: list[str]):
    return client.post(f"/document/parts/{part_id}/merge-features", json={"body_ids": body_ids})


def _first_working_single_edge_op(create_fn, part_id: str, body_id: str, amount: float, *, max_index: int = 24):
    """Neither the swept-ellipse body's own edge indexing nor which edges
    are safe to fillet/chamfer at a given radius/distance are predictable
    without a real OCCT kernel (unlike a box's 12 well-known edges) - probe
    indices in order and use the first one that actually succeeds, mirroring
    the "hunt for a working index" pattern this codebase's own Create Plane
    tests already use for a similarly unpredictable-topology case. A failed
    attempt raises a structured 422 before ever calling `part.add_feature`
    (see `fillet.py`/`chamfer.py`'s own resolve-before-mutate discipline),
    so probing is side-effect-free on rejection."""
    for index in range(max_index):
        response = create_fn(part_id, [_edge_ref(body_id, index)], amount)
        if response.status_code == 201:
            return response
    raise AssertionError(f"no working edge index found in range(0, {max_index})")


# --- The real repro: rectangle Swept around an Ellipse, Filleted, --------------
# Chamfered, Move/Copied, Merged -------------------------------------------


def test_sweep_ellipse_fillet_chamfer_copy_merge_preserves_both_bodies_volume():
    part = _create_part()

    # Stage 0: raw Sweep (rectangle profile around a standalone Ellipse path).
    profile = _create_profile_sketch_feature(part["id"], size=2.0)
    path_feature, ellipse = _create_ellipse_path_sketch_feature(part["id"], major_radius=5.0, minor_radius=3.0)
    sweep_response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], ellipse["id"], "ellipse")]
    )
    assert sweep_response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 1
    body_id = body_ids[0]
    assert _solid_count(part["id"], body_id) == 1
    vol_raw = _occt_volume(part["id"], body_id)
    assert vol_raw > 0

    # Stage 1: Fillet one edge.
    fillet_response = _first_working_single_edge_op(_create_fillet, part["id"], body_id, 0.3)
    body_id = fillet_response.json()["body_id"] if "body_id" in fillet_response.json() else body_id
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 1
    body_id = body_ids[0]
    assert _solid_count(part["id"], body_id) == 1
    vol_filleted = _occt_volume(part["id"], body_id)
    assert 0 < vol_filleted < vol_raw

    # Stage 2: Chamfer a different edge of the now-filleted body.
    chamfer_response = _first_working_single_edge_op(_create_chamfer, part["id"], body_id, 0.2)
    assert chamfer_response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 1
    body_id = body_ids[0]
    assert _solid_count(part["id"], body_id) == 1
    vol_chamfered = _occt_volume(part["id"], body_id)
    assert 0 < vol_chamfered < vol_filleted

    # Stage 3: Move/Copy Body - an overlapping translated copy (the exact
    # repro shape: "use move/copy body to create copy of 1st body that
    # overlaps 1st body").
    move_response = _create_move_body(part["id"], body_id, delta=[5.0, 0.0, 0.0], make_copy=True)
    assert move_response.status_code == 201
    body_ids_after_copy = _body_ids(part["id"])
    assert len(body_ids_after_copy) == 2
    copy_id = next(bid for bid in body_ids_after_copy if bid != body_id)
    vol_copy = _occt_volume(part["id"], copy_id)
    assert vol_copy == pytest.approx(vol_chamfered, rel=1e-6)
    # The original must be untouched by making a copy of it.
    assert _occt_volume(part["id"], body_id) == pytest.approx(vol_chamfered, rel=1e-6)

    # Independent cross-check computed directly against the two pre-merge
    # solids, not through Merge/`_safe_fuse` itself.
    vol_common = _common_volume(part["id"], body_id, copy_id)
    assert vol_common > 0, "the translated copy must actually overlap the original for this repro to be meaningful"
    expected_union_volume = vol_chamfered + vol_copy - vol_common

    # Stage 4: Merge - the crux of the reported bug.
    merge_response = _create_merge(part["id"], [body_id, copy_id])
    assert merge_response.status_code == 201

    merged_body_ids = _body_ids(part["id"])
    assert len(merged_body_ids) == 1, "Merge of two overlapping bodies must produce exactly one Body"
    merged_id = merged_body_ids[0]
    assert _solid_count(part["id"], merged_id) == 1, "Merge must not fragment into disconnected solids"

    merged_volume = _occt_volume(part["id"], merged_id)
    # The reported symptom, stated as a hard geometric invariant: a fuse of
    # two non-degenerate solids can never legitimately produce a union
    # smaller than either individual operand.
    assert merged_volume > max(vol_chamfered, vol_copy), (
        "merged volume is not greater than either individual operand's volume - "
        "this is the reported symptom: one body's material effectively disappeared"
    )
    assert merged_volume < vol_chamfered + vol_copy
    assert merged_volume == pytest.approx(expected_union_volume, rel=1e-4)


def test_two_raw_swept_ellipse_stadium_tubes_merge_correctly():
    """Isolation control (i): Sweep+Merge alone, no Fillet/Chamfer - a raw
    rectangle-around-ellipse "stadium tube" and its overlapping translated
    copy. Isolates whether `BRepOffsetAPI_MakePipeShell` output alone
    (independent of Fillet/Chamfer) already reproduces the known
    zero/wrong-volume Merge bug for this (elliptical path, rectangular
    profile) combination - the prior investigation only confirmed this for
    a *circular*-path torus."""
    part = _create_part()

    profile = _create_profile_sketch_feature(part["id"], size=2.0)
    path_feature, ellipse = _create_ellipse_path_sketch_feature(part["id"], major_radius=5.0, minor_radius=3.0)
    sweep_response = _create_sweep(
        part["id"], profile["id"], [_path_ref(path_feature["sketch_id"], ellipse["id"], "ellipse")]
    )
    assert sweep_response.status_code == 201
    body_id = _body_ids(part["id"])[0]
    vol_raw = _occt_volume(part["id"], body_id)

    move_response = _create_move_body(part["id"], body_id, delta=[5.0, 0.0, 0.0], make_copy=True)
    assert move_response.status_code == 201
    body_ids_after_copy = _body_ids(part["id"])
    copy_id = next(bid for bid in body_ids_after_copy if bid != body_id)
    vol_copy = _occt_volume(part["id"], copy_id)

    vol_common = _common_volume(part["id"], body_id, copy_id)
    assert vol_common > 0
    expected_union_volume = vol_raw + vol_copy - vol_common

    merge_response = _create_merge(part["id"], [body_id, copy_id])
    assert merge_response.status_code == 201

    merged_id = _body_ids(part["id"])[0]
    assert len(_body_ids(part["id"])) == 1
    assert _solid_count(part["id"], merged_id) == 1
    merged_volume = _occt_volume(part["id"], merged_id)
    assert merged_volume > max(vol_raw, vol_copy)
    assert merged_volume == pytest.approx(expected_union_volume, rel=1e-4)


def test_native_torus_filleted_and_chamfered_merges_correctly_against_its_own_copy():
    """Isolation control (ii): a native `BRepPrimAPI_MakeTorus`-built solid
    (the confirmed-good control from the prior investigation - two
    overlapping native tori fuse correctly with plain `BRepAlgoAPI_Fuse`),
    run through Fillet then Chamfer, then merged against an overlapping
    translated copy of itself. Isolates whether Fillet/Chamfer's own raw,
    unnormalized `.Shape()` output (see `fillet.py`/`chamfer.py` - no
    `ShapeFix`/sewing anywhere) is *itself* sufficient to break
    Boolean-compatibility even when starting from a BOP-friendly primitive,
    independent of Sweep.

    Built directly at the OCCT level (bypassing the HTTP sketch/path
    pipeline, since there is no "native torus" sketch primitive in this
    app) but still exercised through the real `resolve_fillet_from_bodies`/
    `resolve_chamfer_from_bodies`/`_safe_fuse` production code paths, not a
    bare reimplementation - injects the torus directly into a Part's
    computed bodies via a Sweep-of-a-circle-profile-around-a-circle-path
    stand-in would reintroduce the very MakePipeShell surface this control
    is meant to exclude, so this control instead builds a "square torus"
    (a rectangle profile revolved 360 degrees around an axis via native
    `BRepPrimAPI_MakeRevol`, NOT `BRepOffsetAPI_MakePipeShell`) and drives
    Fillet/Chamfer/Fuse directly against OCCT shapes rather than through the
    HTTP part/body machinery. A smooth `BRepPrimAPI_MakeTorus` solid was
    tried first and rejected for this control: confirmed directly against a
    real OCCT kernel that all 4 of its edges are pure surface seams with no
    real corner ("There are no suitable edges for chamfer or fillet") - a
    smooth torus has nothing genuinely fillet-able in the first place, so it
    can't stand in for "a native solid that CAN be filleted/chamfered"."""
    from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Fuse
    from OCC.Core.BRepBuilderAPI import (
        BRepBuilderAPI_MakeFace,
        BRepBuilderAPI_MakePolygon,
        BRepBuilderAPI_Transform,
    )
    from OCC.Core.BRepFilletAPI import BRepFilletAPI_MakeChamfer, BRepFilletAPI_MakeFillet
    from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeRevol
    from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
    from OCC.Core.TopAbs import TopAbs_EDGE
    from OCC.Core.TopExp import TopExp_Explorer

    def torus_volume(shape) -> float:
        props = GProp_GProps()
        brepgprop.VolumeProperties(shape, props)
        return props.Mass()

    def first_working_fillet_or_chamfer(maker_cls, shape, amount, *, max_edges: int = 12):
        explorer = TopExp_Explorer(shape, TopAbs_EDGE)
        edges = []
        while explorer.More():
            edges.append(explorer.Current())
            explorer.Next()
        for edge in edges[:max_edges]:
            maker = maker_cls(shape)
            maker.Add(amount, edge)
            try:
                maker.Build()
            except RuntimeError:
                continue
            if maker.IsDone():
                return maker.Shape()
        raise AssertionError(f"no working edge found for {maker_cls.__name__}")

    polygon = BRepBuilderAPI_MakePolygon()
    for x, z in [(5.0, -1.0), (7.0, -1.0), (7.0, 1.0), (5.0, 1.0)]:
        polygon.Add(gp_Pnt(x, 0.0, z))
    polygon.Close()
    profile_face = BRepBuilderAPI_MakeFace(polygon.Wire()).Face()
    revolution_axis = gp_Ax1(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(0.0, 0.0, 1.0))
    torus = BRepPrimAPI_MakeRevol(profile_face, revolution_axis, 2 * math.pi, True).Shape()
    vol_raw_torus = torus_volume(torus)
    assert vol_raw_torus > 0

    filleted = first_working_fillet_or_chamfer(BRepFilletAPI_MakeFillet, torus, 0.3)
    vol_filleted = torus_volume(filleted)
    assert 0 < vol_filleted < vol_raw_torus

    chamfered = first_working_fillet_or_chamfer(BRepFilletAPI_MakeChamfer, filleted, 0.2)
    vol_chamfered = torus_volume(chamfered)
    assert 0 < vol_chamfered < vol_filleted

    translation = gp_Trsf()
    translation.SetTranslation(gp_Vec(5.0, 0.0, 0.0))
    transform = BRepBuilderAPI_Transform(chamfered, translation, True)
    assert transform.IsDone()
    copy = transform.Shape()
    vol_copy = torus_volume(copy)
    assert vol_copy == pytest.approx(vol_chamfered, rel=1e-6)

    common = BRepAlgoAPI_Common(chamfered, copy)
    assert common.IsDone()
    vol_common = torus_volume(common.Shape())
    assert vol_common > 0
    expected_union_volume = vol_chamfered + vol_copy - vol_common

    fuse = BRepAlgoAPI_Fuse(chamfered, copy)
    assert fuse.IsDone()
    fused_shape = fuse.Shape()

    solid_explorer = TopExp_Explorer(fused_shape, TopAbs_SOLID)
    solid_count = 0
    while solid_explorer.More():
        solid_count += 1
        solid_explorer.Next()
    assert solid_count == 1, "fillet/chamfer of a native torus fused against its own copy fragmented"

    merged_volume = torus_volume(fused_shape)
    assert merged_volume > max(vol_chamfered, vol_copy), (
        "merged volume is not greater than either individual operand's volume after "
        "Fillet/Chamfer on a native (non-Sweep) torus - Fillet/Chamfer's own output, "
        "not Sweep, would be implicated"
    )
    assert merged_volume == pytest.approx(expected_union_volume, rel=1e-4)


def test_safe_fuse_correctly_reuses_an_already_fused_swept_operand():
    """Direct unit test of `extrude._safe_fuse` against the exact
    confirmed-corrupting sequence this investigation root-caused: a
    `BRepOffsetAPI_MakePipeShell`-built shape that has already served as an
    operand in one `BRepAlgoAPI_Fuse` call previously (before this fix)
    silently corrupted a *second, separate* `BRepAlgoAPI_Fuse` call that
    reused it as an operand - even though the second call's own inputs were
    individually correct (confirmed directly against a real OCCT kernel: an
    isolated, freshly-built copy of the exact same second call always
    succeeded with the correct volume, ~151.22). Both calls individually
    reported `IsDone() == True` and a nonzero solid count, so neither of
    `_safe_fuse`'s zero-solid/`IsDone` checks would have caught the
    corruption - only `SetNonDestructive(True)` (now used by `_safe_fuse`
    itself, see its own doc comment) actually fixes it, confirmed here by
    asserting the second call now returns the *correct* volume rather than
    merely rejecting a wrong one."""
    from OCC.Core.BRepBuilderAPI import (
        BRepBuilderAPI_MakeEdge,
        BRepBuilderAPI_MakePolygon,
        BRepBuilderAPI_MakeWire,
        BRepBuilderAPI_Transform,
    )
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
    from OCC.Core.gp import gp_Ax2, gp_Dir, gp_Elips, gp_Pnt, gp_Trsf, gp_Vec
    from OCC.Core.GProp import GProp_GProps

    from app.document.extrude import _safe_fuse

    def volume(shape):
        props = GProp_GProps()
        brepgprop.VolumeProperties(shape, props)
        return props.Mass()

    center = gp_Pnt(-5.0, 0.0, 0.0)
    axis = gp_Ax2(center, gp_Dir(0, 1, 0), gp_Dir(1, 0, 0))
    ellipse_edge = BRepBuilderAPI_MakeEdge(gp_Elips(axis, 5.0, 3.0)).Edge()
    path_wire = BRepBuilderAPI_MakeWire(ellipse_edge).Wire()
    polygon = BRepBuilderAPI_MakePolygon()
    for x, y, z in [(0, 0, 0), (2, 0, 0), (2, 2, 0), (0, 2, 0)]:
        polygon.Add(gp_Pnt(x, y, z))
    polygon.Close()
    pipe = BRepOffsetAPI_MakePipeShell(path_wire)
    pipe.Add(polygon.Wire())
    pipe.Build()
    assert pipe.MakeSolid()
    raw = pipe.Shape()

    def translated(shape, vec):
        trsf = gp_Trsf()
        trsf.SetTranslation(gp_Vec(*vec))
        return BRepBuilderAPI_Transform(shape, trsf, True).Shape()

    # First Fuse call: uses `raw` as an operand (this is what used to
    # "poison" it before SetNonDestructive was added).
    first_copy = translated(raw, (0.0, 0.0, 0.25))
    _safe_fuse(raw, first_copy, "merge_fuse", ["body-a", "body-b"])

    # Second, separate Fuse call reusing the exact same `raw` object as an
    # operand - must now return the correct volume (~151.22, confirmed
    # against an isolated, never-reused copy of this exact call), not raise
    # boolean_op_failed and not silently return the previously-observed
    # corrupted (too-small) volume.
    second_copy = translated(raw, (0.0, 0.0, 0.5))
    result = _safe_fuse(raw, second_copy, "merge_fuse", ["body-c", "body-d"])
    assert volume(result) == pytest.approx(151.22375556568065, rel=1e-6)


def test_safe_fuse_rejects_a_near_tangent_result_instead_of_returning_wrong_volume():
    """A second, distinct and much narrower failure mode found during this
    investigation, NOT fixed by `SetNonDestructive`: two circular-profile
    tori translated by an exact tangency-inducing offset (here, exactly the
    tube's own profile radius) produce zero solids even as the very first
    Boolean operation ever run on otherwise-fresh, never-reused shapes - a
    near-tangent/degenerate intersection classification limitation. This is
    the residual case `_safe_fuse`'s own zero-solid check still needs to
    catch and report as a clean `boolean_op_failed` rather than silently
    losing all material."""
    from fastapi import HTTPException
    from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire, BRepBuilderAPI_Transform
    from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
    from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec

    from app.document.extrude import _safe_fuse

    path_edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 10.0)).Edge()
    path_wire = BRepBuilderAPI_MakeWire(path_edge).Wire()
    profile_edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(10, 0, 0), gp_Dir(0, 1, 0)), 2.0)).Edge()
    profile_wire = BRepBuilderAPI_MakeWire(profile_edge).Wire()
    pipe = BRepOffsetAPI_MakePipeShell(path_wire)
    pipe.Add(profile_wire)
    pipe.Build()
    assert pipe.MakeSolid()
    torus = pipe.Shape()

    trsf = gp_Trsf()
    trsf.SetTranslation(gp_Vec(0.0, 2.0, 0.0))  # exactly the tube's own profile radius
    copy = BRepBuilderAPI_Transform(torus, trsf, True).Shape()

    with pytest.raises(HTTPException) as exc_info:
        _safe_fuse(torus, copy, "merge_fuse", ["body-a", "body-b"])
    assert exc_info.value.status_code == 422
    assert exc_info.value.detail["type"] == "boolean_op_failed"
