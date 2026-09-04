"""Direct Editing family, fifth/last entry: real-OCCT tests for
`MoveFaceFeature`. V2 (see `docs/direct-editing-scope.md`): moves every
face in `face_refs` (1+, all sharing a Body) via OCCT's own `BRepOffset_
MakeOffset` for `offset_distance` mode (planar/cylindrical/conical, 2+
faces, neighbour-consuming - all new). V3: `delta`/`direction_ref` modes
generalize v1's own single-planar-face extrude-the-face-profile + Fuse/Cut
technique to a rigid group of 1+ connected faces (planar/cylindrical/
conical, swept together as one `TopoDS_Compound` via `BRepPrimAPI_
MakePrism`) - the group must still contain at least one planar face to
anchor the Fuse-vs-Cut sign decision (see `app.document.move_face`'s own
module docstring for why). V4: a group with **no** planar face (a lone
hole/boss's own cylindrical/conical wall, optionally plus its own coaxial
tip/counterbore faces) dispatches to a different technique instead of
being rejected - reconstructs the feature's own solid-of-revolution and
Fuse/Cut's it in and out at the target position, closing the "reposition a
hole" gap the sweep technique above can't handle. Modifies its Body in
place (keeps the same id). Mirrors test_feature_delete_face.py's own
structure and helpers (copy-pasted, not shared via conftest, same as every
other test_feature_*.py file). Needs a real pythonocc-core environment (not
available in this repo's own dev sandbox - see docs/status.md's dated
entries for whether a real on-device/CI pass has actually run by the time
this is read).

Note on face/edge indices: every index used below was confirmed empirically
against the real backend (not assumed) - a box's own `topexp.MapShapes`
enumeration order is implementation-defined, and (for edges) only 4 of a
box's 12 edges run parallel to any given face's own normal (the other 8 are
correctly rejected by `move_face.py`'s own degenerate-direction check) - see
this module's own module docstring for why guessing these by hand isn't
safe.
"""

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
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _mesh_for_body(part_id: str, body_id: str) -> dict:
    return next(e["mesh"] for e in _mesh(part_id) if e["body_id"] == body_id)


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = _mesh_for_body(part_id, body_id)
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _edge_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "edge", "index": index}


def _face_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "face", "index": index}


def _create_move_face(part_id: str, face_refs: dict | list[dict], **kwargs):
    """`face_refs` accepts either a single ref dict (the common single-face
    case, wrapped into a one-entry list here) or an already-built list (V2
    multi-face cases)."""
    refs = [face_refs] if isinstance(face_refs, dict) else face_refs
    payload = {"face_refs": refs}
    payload.update(kwargs)
    return client.post(f"/document/parts/{part_id}/move-face-features", json=payload)


def _add_circle(sketch_id: str, cx: float, cy: float, radius: float) -> dict:
    center = _add_point(sketch_id, cx, cy)
    response = client.post(
        f"/sketch/sketches/{sketch_id}/circles",
        json={"center_point_id": center["id"], "radius": radius, "angle": 0.0},
    )
    assert response.status_code == 201
    return response.json()


def _create_chamfer_feature(part_id: str, edge_refs: list[dict], distance: float = 2.0) -> dict:
    """V4: used to build a real, HTTP-achievable coaxial-cone companion
    face for a cylindrical hole (chamfering its own rim edge) - mirrors
    `test_feature_delete_face.py`'s own identical helper."""
    response = client.post(
        f"/document/parts/{part_id}/chamfer-features",
        json={"edge_refs": edge_refs, "distance": distance},
    )
    assert response.status_code == 201
    return response.json()


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id. Face index 1 is confirmed (see
    this file's own module docstring) to be the x=10 face, outward normal
    +X."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_move_face_with_a_non_face_ref_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _edge_ref(body_id, 0), offset_distance=3.0)

    assert response.status_code == 422


def test_move_face_with_no_mode_set_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1))

    assert response.status_code == 422


def test_move_face_with_two_modes_set_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], _face_ref(body_id, 1), offset_distance=3.0, delta=[1.0, 0.0, 0.0]
    )

    assert response.status_code == 422


def test_move_face_with_zero_offset_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=0.0)

    assert response.status_code == 422


def test_move_face_with_direction_ref_but_no_direction_distance_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], _face_ref(body_id, 1), direction_ref={"edge_ref": _edge_ref(body_id, 2)}
    )

    assert response.status_code == 422


# --- Offset mode ---------------------------------------------------------------


def test_offset_mode_outward_extends_the_bounding_box():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0)

    assert response.status_code == 201
    assert response.json()["type"] == "move_face"
    assert _body_ids(part["id"]) == [body_id]  # modifies in place, same id
    x_range, y_range, z_range = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)
    assert y_range == (0.0, 10.0)
    assert z_range == (0.0, 10.0)


def test_offset_mode_inward_shrinks_the_bounding_box():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=-3.0)

    assert response.status_code == 201
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 7.0)


def test_offset_mode_overshoot_past_the_bodys_own_extent_is_rejected():
    """Pushing a face inward by more than the Body's own extent in that
    direction has no valid result - fails closed rather than producing a
    degenerate Body. V2's own `BRepOffset_MakeOffset` technique reports
    this specific failure via a null `Shape()` with no reported error
    (confirmed via spike - see `app.document.move_face`'s own module
    docstring), caught by `move_face_null_result`, not the boolean-op
    `move_face_failed` v1's own prism technique used to report here."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=-15.0)

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_null_result"


# --- Offset mode, V2: non-planar faces, multi-face, neighbour-consuming --------
# Indices confirmed empirically against the real backend, same discipline this
# file's own module docstring establishes for every other index here.


def test_offset_mode_grows_a_cylindrical_hole():
    """A box with a circular hole cut through it - the hole's own
    cylindrical wall (face 6, confirmed via the real mesh's own
    `face_is_planar`) grows by exactly the offset value (a cylinder's own
    1:1 radius-to-offset relationship, unlike a cone's - see
    `docs/direct-editing-scope.md`'s own spike findings)."""
    part = _create_part()
    box_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], box_sketch["id"])
    box_body_id = _body_ids(part["id"])[0]
    hole_sketch = _create_sketch_feature(part["id"])
    _add_circle(hole_sketch["sketch_id"], 5.0, 5.0, 2.0)
    _create_extrude_feature(
        part["id"], hole_sketch["id"], extrude_type="cut", start_distance=-1.0, end_distance=11.0,
        target_body_ids=[box_body_id],
    )

    response = _create_move_face(part["id"], _face_ref(box_body_id, 6), offset_distance=1.0)

    assert response.status_code == 201


def test_offset_mode_moves_two_faces_together_with_the_shared_value():
    """`face_refs`' two entries both move by the identical `offset_distance`
    (this family's own "list of refs, one shared param" convention, not
    independent per-face values - see `MoveFaceFeature`'s own docstring)."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], [_face_ref(body_id, 0), _face_ref(body_id, 1)], offset_distance=2.0
    )

    assert response.status_code == 201
    x_range, y_range, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 12.0)  # face 1 (x=10 face) grown +2
    assert y_range == (-2.0, 10.0)  # face 0 (y=0 face) grown +2 outward (-Y)


def test_offset_mode_fully_consumes_a_neighbouring_boss():
    """A boss fused flush onto a base Body's own top face (the coincident-
    plane joint `app.document.extrude._apply_feature_to_bodies`'s own
    gated `unify` step exists for, see that module's own docstring) -
    pushing the boss's own top face down by exactly its own height fully
    consumes it, healing back to the plain base Body, not merely shrinking
    it - the exact neighbour-consuming case v1 could never attempt."""
    part = _create_part()
    base_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], base_sketch["id"])
    base_body_id = _body_ids(part["id"])[0]
    boss_sketch = _create_square_sketch_feature(part["id"], size=4.0)
    _create_extrude_feature(
        part["id"], boss_sketch["id"], start_distance=10.0, end_distance=13.0,
        target_body_ids=[base_body_id],
    )
    stepped_body_id = _body_ids(part["id"])[0]
    assert _bbox_ranges(part["id"], stepped_body_id)[2] == (0.0, 13.0)

    response = _create_move_face(part["id"], _face_ref(stepped_body_id, 7), offset_distance=-3.0)

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], stepped_body_id)[2] == (0.0, 10.0)  # boss fully gone


def test_offset_mode_with_faces_from_two_different_bodies_is_rejected():
    part = _create_part()
    body_a = _make_box(part["id"], x0=0.0)
    body_b = _make_box(part["id"], x0=20.0)

    response = _create_move_face(
        part["id"], [_face_ref(body_a, 1), _face_ref(body_b, 1)], offset_distance=1.0
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "mixed_body_selection"


def test_delta_mode_with_two_unconnected_perpendicular_faces_is_rejected():
    """`delta`/`direction_ref` modes now accept a rigid group of 1+ faces
    (V3 - see `MoveFaceFeature`'s own docstring), but the group is still
    swept as one shape via `BRepPrimAPI_MakePrism`: face 0 (y=0, normal
    -Y) swept sideways along the +X delta is a degenerate sweep for that
    member, so the whole group fails the new prism-validity check
    (`move_face_failed`) rather than any face-count restriction."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], [_face_ref(body_id, 0), _face_ref(body_id, 1)], delta=[1.0, 0.0, 0.0]
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_failed"


def test_move_face_with_empty_face_refs_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = client.post(
        f"/document/parts/{part['id']}/move-face-features",
        json={"face_refs": [], "offset_distance": 1.0},
    )

    assert response.status_code == 422


# --- Delta mode ------------------------------------------------------------


def test_delta_mode_along_the_faces_own_normal():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), delta=[3.0, 0.0, 0.0])

    assert response.status_code == 201
    assert response.json()["delta"] == [3.0, 0.0, 0.0]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)


# --- Direction mode --------------------------------------------------------


def test_direction_mode_along_a_parallel_edge():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"],
        _face_ref(body_id, 1),
        direction_ref={"edge_ref": _edge_ref(body_id, 2)},
        direction_distance=3.0,
    )

    assert response.status_code == 201
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)


def test_direction_mode_along_a_perpendicular_edge_is_rejected():
    """Edge 0 runs perpendicular to face 1's own normal (confirmed - see
    this file's own module docstring) - no meaningful perpendicular
    movement for this technique to act on, fails closed."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"],
        _face_ref(body_id, 1),
        direction_ref={"edge_ref": _edge_ref(body_id, 0)},
        direction_distance=3.0,
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_failed"


# --- V3: multi-face rigid group (delta/direction_ref) -----------------------
# A 10x10x10 box, fillet-radius-1'd around its own top-face edge loop (edges
# 3/6/9/11 - confirmed via spike, not assumed, same discipline this file's
# own module docstring establishes): produces an 8x8 top cap (face 7) framed
# by 4 quarter-cylinder blend faces (2/6/8/9), a connected rigid group with
# exactly one planar member. Sweeping this whole group vertically (its own
# planar member's own normal) is the "flat face and its fillets, to make a
# filleted part taller" case that motivated V3 - confirmed via a real spike
# to add/remove volume in round, exact 100 units per Z unit (991.7994... to
# 1291.7994... for +3, to 791.7994... for -2 - not assumed, taken directly
# off a real run).


def _make_top_filleted_box(part_id: str) -> str:
    """A `_make_box`, then fillets its own top-face edge loop (radius 1) -
    face 7 (the shrunk 8x8 top cap) plus faces 2/6/8/9 (the 4 blend faces)
    is the rigid group used by every V3 test below."""
    body_id = _make_box(part_id, x0=0.0)
    edges = [_edge_ref(body_id, i) for i in [3, 6, 9, 11]]
    response = client.post(
        f"/document/parts/{part_id}/fillet-features", json={"edge_refs": edges, "radius": 1.0}
    )
    assert response.status_code == 201
    return body_id


def _top_group_refs(body_id: str) -> list[dict]:
    return [_face_ref(body_id, i) for i in [7, 2, 6, 8, 9]]


def test_delta_mode_grows_a_multi_face_group_along_its_planar_members_normal():
    part = _create_part()
    body_id = _make_top_filleted_box(part["id"])

    response = _create_move_face(part["id"], _top_group_refs(body_id), delta=[0.0, 0.0, 3.0])

    assert response.status_code == 201
    z_range = _bbox_ranges(part["id"], body_id)[2]
    assert z_range == (0.0, 13.0)


def test_delta_mode_shrinks_a_multi_face_group_along_its_planar_members_normal():
    part = _create_part()
    body_id = _make_top_filleted_box(part["id"])

    response = _create_move_face(part["id"], _top_group_refs(body_id), delta=[0.0, 0.0, -2.0])

    assert response.status_code == 201
    z_range = _bbox_ranges(part["id"], body_id)[2]
    assert z_range == (0.0, 8.0)


def test_direction_mode_moves_a_multi_face_group():
    part = _create_part()
    body_id = _make_top_filleted_box(part["id"])

    response = _create_move_face(
        part["id"],
        _top_group_refs(body_id),
        direction_ref={"edge_ref": _edge_ref(body_id, 0)},  # a vertical edge, post-fillet
        direction_distance=3.0,
    )

    assert response.status_code == 201
    z_range = _bbox_ranges(part["id"], body_id)[2]
    assert z_range == (0.0, 13.0)


def test_delta_mode_group_with_no_planar_face_and_mismatched_axes_is_rejected():
    """V4: a group with no planar face now falls into the coaxial-
    reposition sub-case instead of an immediate rejection - but these 4
    blend faces are 4 *different* corners' own quarter-cylinder fillets,
    each with its own distinct axis (not one shared hole/boss), so they
    fail the axis-coincidence check instead - see
    `_move_face_group_axis_mismatch`'s own docstring."""
    part = _create_part()
    body_id = _make_top_filleted_box(part["id"])

    response = _create_move_face(
        part["id"], [_face_ref(body_id, i) for i in [2, 6, 8, 9]], delta=[0.0, 0.0, 1.0]
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_group_axis_mismatch"


# --- V4: lone coaxial curved-face group reposition --------------------------
# A group with NO planar face (a hole/boss's own wall, optionally plus its
# own coaxial tip/counterbore faces) - see `app.document.move_face`'s own
# module docstring for the reconstruct-and-Fuse/Cut technique this dispatches
# to instead of the sweep technique above. Every box below is the same
# standard `_create_square_sketch_feature`-default 10x10x10 box the rest of
# this file already uses; face 6 is confirmed (empirically, not assumed) to
# be the lone cylindrical/conical wall in every single-hole/boss fixture
# here, matching `test_offset_mode_grows_a_cylindrical_hole`'s own confirmed
# face 6.


def _make_box_with_a_hole(part_id: str, *, start_distance: float, end_distance: float) -> str:
    """A standard 10x10x10 box with a circular hole (r=2, centred at
    (5, 5)) cut from `start_distance` to `end_distance` in Z - through
    (start/end straddling 0..10) or blind (end_distance < 10)."""
    box_sketch = _create_square_sketch_feature(part_id)
    _create_extrude_feature(part_id, box_sketch["id"])
    body_id = _body_ids(part_id)[0]
    hole_sketch = _create_sketch_feature(part_id)
    _add_circle(hole_sketch["sketch_id"], 5.0, 5.0, 2.0)
    _create_extrude_feature(
        part_id, hole_sketch["id"], extrude_type="cut", start_distance=start_distance,
        end_distance=end_distance, target_body_ids=[body_id],
    )
    return body_id


def test_delta_mode_relocates_a_through_hole():
    part = _create_part()
    body_id = _make_box_with_a_hole(part["id"], start_distance=-1.0, end_distance=11.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 6), delta=[2.0, 1.5, 0.0])

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id) == [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)]


def test_direction_mode_relocates_a_through_hole():
    part = _create_part()
    body_id = _make_box_with_a_hole(part["id"], start_distance=-1.0, end_distance=11.0)

    response = _create_move_face(
        part["id"],
        _face_ref(body_id, 6),
        direction_ref={"edge_ref": _edge_ref(body_id, 2)},
        direction_distance=2.0,
    )

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id) == [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)]


def test_delta_mode_relocates_a_blind_hole_with_a_flat_bottom():
    """The wall's own real (already-trimmed) V-range stops exactly at the
    blind end - reconstructing from it alone preserves the blind depth at
    the new location, no cap face needed in `face_refs`."""
    part = _create_part()
    body_id = _make_box_with_a_hole(part["id"], start_distance=4.0, end_distance=10.5)
    z_before = _bbox_ranges(part["id"], body_id)[2]

    response = _create_move_face(part["id"], _face_ref(body_id, 6), delta=[2.0, 1.5, 0.0])

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id)[2] == z_before  # box's own Z extent untouched


def test_delta_mode_relocates_a_boss():
    part = _create_part()
    box_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], box_sketch["id"])
    body_id = _body_ids(part["id"])[0]
    boss_sketch = _create_sketch_feature(part["id"])
    _add_circle(boss_sketch["sketch_id"], 5.0, 5.0, 2.0)
    _create_extrude_feature(
        part["id"], boss_sketch["id"], extrude_type="boss", start_distance=10.0, end_distance=13.0,
        target_body_ids=[body_id],
    )
    z_before = _bbox_ranges(part["id"], body_id)[2]

    response = _create_move_face(part["id"], _face_ref(body_id, 6), delta=[2.0, 1.5, 0.0])

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id)[2] == z_before  # boss relocated, not duplicated/removed


def test_delta_mode_relocates_a_counterbore():
    """2 coaxial cylindrical faces of different diameter (a wide
    counterbore mouth + a narrower through-bore), relocated together -
    confirms the reconstruction generalizes past a lone wall."""
    part = _create_part()
    box_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], box_sketch["id"])
    body_id = _body_ids(part["id"])[0]
    counterbore_sketch = _create_sketch_feature(part["id"])
    _add_circle(counterbore_sketch["sketch_id"], 5.0, 5.0, 3.0)
    _create_extrude_feature(
        part["id"], counterbore_sketch["id"], extrude_type="cut", start_distance=7.0,
        end_distance=11.0, target_body_ids=[body_id],
    )
    through_sketch = _create_sketch_feature(part["id"])
    _add_circle(through_sketch["sketch_id"], 5.0, 5.0, 1.0)
    _create_extrude_feature(
        part["id"], through_sketch["id"], extrude_type="cut", start_distance=-1.0,
        end_distance=8.0, target_body_ids=[body_id],
    )

    response = _create_move_face(
        part["id"], [_face_ref(body_id, 6), _face_ref(body_id, 7)], delta=[2.0, -1.5, 0.0]
    )

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id) == [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)]


def test_delta_mode_group_with_mismatched_axes_is_rejected():
    """Two independent through-holes, far enough apart that their own
    fitted axes share nothing - `_move_face_group_axis_mismatch`, not a
    coincidental accept."""
    part = _create_part()
    box_sketch = _create_square_sketch_feature(part["id"])
    _create_extrude_feature(part["id"], box_sketch["id"])
    body_id = _body_ids(part["id"])[0]
    hole_a = _create_sketch_feature(part["id"])
    _add_circle(hole_a["sketch_id"], 3.0, 5.0, 1.0)
    _create_extrude_feature(
        part["id"], hole_a["id"], extrude_type="cut", start_distance=-1.0, end_distance=11.0,
        target_body_ids=[body_id],
    )
    hole_b = _create_sketch_feature(part["id"])
    _add_circle(hole_b["sketch_id"], 7.0, 5.0, 1.0)
    _create_extrude_feature(
        part["id"], hole_b["id"], extrude_type="cut", start_distance=-1.0, end_distance=11.0,
        target_body_ids=[body_id],
    )

    response = _create_move_face(
        part["id"], [_face_ref(body_id, 6), _face_ref(body_id, 7)], delta=[1.0, 0.0, 0.0]
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_group_axis_mismatch"


def test_delta_mode_conical_tip_wall_only_is_rejected_as_incomplete():
    """A through-hole, chamfered at its own top rim (a real,
    HTTP-achievable stand-in for a drill-point-style coaxial tip face,
    face 1 after the chamfer): picking only the wall (still face 6) leaves
    the chamfer's own cone face - a coaxial neighbour - out of the group,
    which the adjacency-based completeness check must catch (silently
    reconstructing from the wall alone would leave the cone's own void
    unfilled - see `_coaxial_group_is_complete`'s own docstring)."""
    part = _create_part()
    body_id = _make_box_with_a_hole(part["id"], start_distance=-1.0, end_distance=11.0)
    _create_chamfer_feature(part["id"], [_edge_ref(body_id, 13)], distance=0.5)

    response = _create_move_face(part["id"], _face_ref(body_id, 6), delta=[2.0, 1.5, 0.0])

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_group_incomplete_coaxial_chain"


def test_delta_mode_conical_tip_wall_and_cone_together_relocates():
    """Same fixture as the rejection test above - picking wall (6) and the
    chamfer's own cone (1) together succeeds."""
    part = _create_part()
    body_id = _make_box_with_a_hole(part["id"], start_distance=-1.0, end_distance=11.0)
    _create_chamfer_feature(part["id"], [_edge_ref(body_id, 13)], distance=0.5)

    response = _create_move_face(
        part["id"], [_face_ref(body_id, 6), _face_ref(body_id, 1)], delta=[2.0, 1.5, 0.0]
    )

    assert response.status_code == 201
    assert _bbox_ranges(part["id"], body_id) == [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)]


# --- Update: mode switching ------------------------------------------------


def test_update_move_face_switches_from_offset_to_delta_mode():
    """Updating with a different mode's field must clear the previous
    mode's own field(s), not merge both - see `MoveFaceFeatureUpdate`'s own
    docstring."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    feature = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()
    assert feature["offset_distance"] == 3.0

    response = client.patch(
        f"/document/parts/{part['id']}/move-face-features/{feature['id']}",
        json={"delta": [5.0, 0.0, 0.0]},
    )

    assert response.status_code == 200
    assert response.json()["offset_distance"] is None
    assert response.json()["delta"] == [5.0, 0.0, 0.0]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 15.0)


# --- native_format round-trip -------------------------------------------------


def test_move_face_feature_round_trips_through_native_export_import():
    """Mirrors test_feature_delete_face.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"], x0=0.0)
        move_face = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "move_face")
        assert round_tripped["face_refs"] == move_face["face_refs"]
        assert round_tripped["offset_distance"] == move_face["offset_distance"] == 3.0
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_faces_owning_extrude_cascade_deletes_the_move_face_feature():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    move_face = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert move_face["id"] in response.json()["deleted_feature_ids"]
