"""Scaling scenes for the mates review (`docs/mates-storage-sessions-plan-2026-11-12.md`, phase M0): groups that are RIGID
(or rigid apart from one mechanism freedom) and grow with N, the case M1's rigid sets are meant to collapse. Built through the
real HTTP surface like `motion_scenes.py`, at their true poses (every mate is satisfied as built).

* `chain_scene(n)`: a lap chain of `n` plates, each bolted to the next (two bolt holes per joint: face coincident + two
  concentric, the second concentric redundant). `bolts=True` adds the two bolts of every joint as parts (each keeps its spin).
* `frame_scene(n)`: a ladder frame of `n` bars (two rails + `n - 2` rungs); every rung is mated to BOTH rails (the mates to the
  second rail are redundant), plus one mate between the rails.
* `linkage_scene()`: a planar 4-bar linkage (four revolute joints: concentric + coincident each, two of the coincidents redundant)
  whose coupler carries a rigidly mated payload of 20 blocks.

Each returns a `ScalingScene` in which NOTHING is fixed; `motion_scenes.fix(scene.root, scene.base)` gives the fixed-base variant.
Every scene also holds one loose part (`probe`, no mates) and three hypothetical mates for the preview benchmark:
`probe_mate` (the loose part onto the mover), `redundant_mate` (a consistent mate between two members that are already locked
together) and `conflict_mate` (the same mate with a value the group cannot meet: the preview then runs the branch search).
"""

import math
from dataclasses import dataclass, field

from tests.motion_scenes import fix  # noqa: F401  (re-exported: the fixed-base variant)
from tests.test_assembly_solver import _add_line, _add_point, _create_part, _export_part, client

PROBE = "occ-probe"
_IDENTITY_AXIS = (0.0, 0.0, 1.0)


@dataclass
class ScalingScene:
    name: str
    root: str
    base: str  # the occurrence the fixed-base variant fixes
    mover: str  # the occurrence the benchmark grabs
    occurrence_ids: tuple[str, ...]  # every occurrence, the probe included
    expected_dof_floating: int  # of the mover's group, nothing fixed
    expected_dof_fixed: int  # of the mover's group, `base` fixed
    probe_mate: dict  # preview payloads (`POST .../occurrences/<driven>/preview-mate-solve`), with the occurrence to drive
    redundant_mate: dict
    conflict_mate: dict
    probe_driven: str = PROBE
    inside_driven: str = ""  # the occurrence driven by `redundant_mate` / `conflict_mate`
    notes: dict = field(default_factory=dict)


# ---- parts -------------------------------------------------------------------


def box_part(name: str, sx: float, sy: float, sz: float, holes: tuple[tuple[float, float, float], ...] = ()) -> dict:
    """A `sx` x `sy` x `sz` box, corner at the origin, with through holes `(x, y, radius)` along z. Returns the part dict
    (`id`, `body_id`) with its faces measured once (`faces`: the Measure answer per face index)."""
    part = _create_part(name)
    sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    corners = [_add_point(sketch["sketch_id"], x, y) for x, y in [(0, 0), (sx, 0), (sx, sy), (0, sy)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch["sketch_id"], a["id"], b["id"])
    boss = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": sz, "target_body_ids": []},
    )
    assert boss.status_code == 201, boss.text
    body_id = client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]
    for x, y, radius in holes:
        hole = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
        centre = _add_point(hole["sketch_id"], x, y)
        assert client.post(f"/sketch/sketches/{hole['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}).status_code == 201
        cut = client.post(
            f"/document/parts/{part['id']}/extrude-features",
            json={"sketch_feature_id": hole["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": sz, "target_body_ids": [body_id]},
        )
        assert cut.status_code == 201, cut.text
    return {"id": part["id"], "body_id": body_id, "size": (sx, sy, sz), "faces": _measure_faces(part["id"], body_id)}


def cylinder_part(name: str, radius: float, depth: float) -> dict:
    """A cylinder on the z axis, base at the origin."""
    part = _create_part(name)
    sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    centre = _add_point(sketch["sketch_id"], 0.0, 0.0)
    assert client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}).status_code == 201
    boss = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": depth, "target_body_ids": []},
    )
    assert boss.status_code == 201, boss.text
    body_id = client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]
    return {"id": part["id"], "body_id": body_id, "size": (2 * radius, 2 * radius, depth), "faces": _measure_faces(part["id"], body_id)}


def _measure_faces(part_id: str, body_id: str) -> list[dict]:
    faces = []
    for index in range(64):
        response = client.post(f"/document/parts/{part_id}/measure", json={"refs": [{"body_id": body_id, "shape_type": "face", "index": index}]})
        if response.status_code != 200:
            break
        faces.append(response.json())
    return faces


def face_index(part: dict, normal) -> int:
    """The planar face of `part` with outward `normal` (part-local)."""
    for index, face in enumerate(part["faces"]):
        if face.get("normal") is not None and all(abs(a - b) < 1e-6 for a, b in zip(face["normal"], normal)):
            return index
    raise AssertionError(f"no planar face with normal {normal}")


def face(part: dict, normal) -> dict:
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": face_index(part, normal)}}


def hole(part: dict, at: tuple[float, float] | None = None) -> dict:
    """The cylindrical face of `part` whose axis (along z) passes through `at` (x, y); `None` = the only / first one."""
    for index, measured in enumerate(part["faces"]):
        axis = measured.get("axis")
        if axis is None or measured.get("radius") is None:
            continue
        if at is None or (abs(axis["origin"][0] - at[0]) < 1e-6 and abs(axis["origin"][1] - at[1]) < 1e-6):
            return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": index}}
    raise AssertionError(f"no cylindrical face through {at}")


# ---- assembly ----------------------------------------------------------------


def pose(translation, angle_z_degrees: float = 0.0) -> dict:
    return {"translation": [float(x) for x in translation], "rotation_axis": list(_IDENTITY_AXIS), "rotation_angle_degrees": float(angle_z_degrees)}


def compose(root: dict, occurrences: list[tuple[str, dict, dict]]) -> str:
    """Root part + occurrences `(id, part, transform dict)` (parts may repeat). Like `test_assembly_group._compose`, with a full pose."""
    root_export = _export_part(root["id"])
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = [
        {"id": oid, "external_ref": f"parts/{p['id']}.didsa", "resolved_part_id": p["id"], "name_override": None, "transform": t, "suppressed": False, "hidden": False}
        for oid, p, t in occurrences
    ]
    root_dict["mates"] = []
    exports = [_export_part(pid) for pid in {p["id"]: p for _o, p, _t in occurrences}]
    payload = {
        "schema_version": root_export["schema_version"],
        "document": {"id": "composed-doc", "root_part_id": root["id"], "parts": [root_dict, *[e["document"]["parts"][0] for e in exports]]},
        "sketches": [*root_export["sketches"], *[s for e in exports for s in e["sketches"]]],
    }
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200, response.text
    return root["id"]


def mate(root: str, mate_type: str, a_occ: str, a_ref: dict, b_occ: str, b_ref: dict, **extra) -> dict:
    """`POST /mates` (stores the mate, solves nothing: the scene is built at its true pose). `aligned=True` on a coincident = the
    two faces point the same way (flush)."""
    body = {"type": mate_type, "references": [{"occurrence_id": a_occ, **a_ref}, {"occurrence_id": b_occ, **b_ref}], **extra}
    response = client.post(f"/document/parts/{root}/mates", json=body)
    assert response.status_code == 201, response.text
    return response.json()


def _flush(root: str, a_occ: str, a_ref: dict, b_occ: str, b_ref: dict) -> dict:
    return mate(root, "coincident", a_occ, a_ref, b_occ, b_ref, alignment="aligned")


def _payload(mate_type: str, a_occ: str, a_ref: dict, b_occ: str, b_ref: dict, **extra) -> dict:
    return {"type": mate_type, "references": [{"occurrence_id": a_occ, **a_ref}, {"occurrence_id": b_occ, **b_ref}], **extra}


def _probe_part() -> dict:
    return box_part("Probe", 8.0, 8.0, 4.0)


_CONFLICT_EXTRA_MM = 7.0


def _inside_mates(a_occ: str, a_ref: dict, b_occ: str, b_ref: dict, true_distance: float) -> tuple[dict, dict]:
    """A distance the built group already meets, and the same one 7 mm off (which no placement of the group can meet)."""
    return (
        _payload("distance", a_occ, a_ref, b_occ, b_ref, value=true_distance),
        _payload("distance", a_occ, a_ref, b_occ, b_ref, value=true_distance + _CONFLICT_EXTRA_MM),
    )


# ---- chain of bolted plates --------------------------------------------------

_PLATE = 60.0
_PLATE_T = 10.0
_LAP = 30.0  # each plate overlaps the next by this much
_HOLES = ((15.0, 15.0), (15.0, 45.0), (45.0, 15.0), (45.0, 45.0))


def chain_scene(n: int, bolts: bool = False) -> ScalingScene:
    """`n` plates in a lap chain (a staircase: plate i at x = 30 i, z = 10 i), plate i + 1 bolted on top of plate i through two
    holes. Per joint: bottom face on top face (coincident) and two concentric holes; the second concentric repeats two rows
    of the first (a bolt pattern is always redundant). The chain is one rigid body: floating dof 6, first plate fixed 0.
    `bolts=True` adds two bolt parts per joint (concentric to the lower plate's hole, flush with its underside): each keeps its
    spin, so the dof grows by `2 (n - 1)`."""
    assert n >= 2
    plate = box_part("Plate", _PLATE, _PLATE, _PLATE_T, holes=tuple((x, y, 5.0) for x, y in _HOLES))
    probe = _probe_part()
    plates = [f"occ-plate-{i}" for i in range(n)]
    occurrences = [(oid, plate, pose((_LAP * i, 0.0, _PLATE_T * i))) for i, oid in enumerate(plates)]
    bolt = cylinder_part("Bolt", 4.0, 2 * _PLATE_T) if bolts else None
    bolt_ids: list[tuple[str, int, tuple[float, float]]] = []
    if bolt is not None:
        for i in range(n - 1):
            for j, at in enumerate(((45.0, 15.0), (45.0, 45.0))):
                oid = f"occ-bolt-{i}-{j}"
                bolt_ids.append((oid, i, at))
                occurrences.append((oid, bolt, pose((_LAP * i + at[0], at[1], _PLATE_T * i))))
    last = n - 1
    occurrences.append((PROBE, probe, pose((_LAP * last + 20.0, 20.0, _PLATE_T * (last + 1) + 30.0))))
    root = compose(_create_part(f"Chain{n}"), occurrences)
    top, bottom = face(plate, (0, 0, 1)), face(plate, (0, 0, -1))
    for i in range(n - 1):
        upper, lower = plates[i + 1], plates[i]
        mate(root, "coincident", upper, bottom, lower, top)
        mate(root, "concentric", upper, hole(plate, (15.0, 15.0)), lower, hole(plate, (45.0, 15.0)))
        mate(root, "concentric", upper, hole(plate, (15.0, 45.0)), lower, hole(plate, (45.0, 45.0)))
    for oid, i, at in bolt_ids:
        mate(root, "concentric", oid, hole(bolt), plates[i], hole(plate, at))
        _flush(root, oid, face(bolt, (0, 0, -1)), plates[i], bottom)
    redundant, conflict = _inside_mates(plates[last], top, plates[0], top, _PLATE_T * last)
    return ScalingScene(
        name=f"chain-{n}" + ("-bolts" if bolts else ""),
        root=root,
        base=plates[0],
        mover=plates[last],
        occurrence_ids=tuple(o for o, _p, _t in occurrences),
        expected_dof_floating=6 + len(bolt_ids),
        expected_dof_fixed=len(bolt_ids),
        probe_mate=_payload("distance", PROBE, face(probe, (0, 0, -1)), plates[last], top, value=5.0),
        redundant_mate=redundant,
        conflict_mate=conflict,
        inside_driven=plates[last],
        notes={"plates": n, "bolts": len(bolt_ids)},
    )


# ---- frame of bars with redundant mates ---------------------------------------

_BAR = 20.0  # square section
_FRAME_W = 200.0  # outside width (y)
_RUNG_PITCH = 60.0


def frame_scene(n: int) -> ScalingScene:
    """A ladder frame of `n` bars: two rails along x and `n - 2` rungs between them (n = 4 is a plain rectangle). Every rung has
    FIVE mates: an end face on each rail's inner face, its top flush with each rail's top, and its place along rail A (flush with
    the rail's end for the first rung, a same-facing distance for the others). The mates to rail B repeat what rail A already
    fixes (redundant, consistent). One more mate keeps the rails' ends flush. Rigid: floating dof 6, rail A fixed 0."""
    assert n >= 4
    rungs = n - 2
    length = (rungs - 1) * _RUNG_PITCH + _BAR
    rail = box_part("Rail", length, _BAR, _BAR)
    rung = box_part("Rung", _BAR, _FRAME_W - 2 * _BAR, _BAR)
    probe = _probe_part()
    rung_ids = [f"occ-rung-{k}" for k in range(rungs)]
    occurrences = [("occ-rail-a", rail, pose((0.0, 0.0, 0.0))), ("occ-rail-b", rail, pose((0.0, _FRAME_W - _BAR, 0.0)))]
    occurrences += [(oid, rung, pose((_RUNG_PITCH * k, _BAR, 0.0))) for k, oid in enumerate(rung_ids)]
    occurrences.append((PROBE, probe, pose((length / 2.0, _FRAME_W + 30.0, 40.0))))
    root = compose(_create_part(f"Frame{n}"), occurrences)
    for k, oid in enumerate(rung_ids):
        mate(root, "coincident", oid, face(rung, (0, -1, 0)), "occ-rail-a", face(rail, (0, 1, 0)))
        mate(root, "coincident", oid, face(rung, (0, 1, 0)), "occ-rail-b", face(rail, (0, -1, 0)))
        _flush(root, oid, face(rung, (0, 0, 1)), "occ-rail-a", face(rail, (0, 0, 1)))
        _flush(root, oid, face(rung, (0, 0, 1)), "occ-rail-b", face(rail, (0, 0, 1)))
        if k == 0:
            _flush(root, oid, face(rung, (-1, 0, 0)), "occ-rail-a", face(rail, (-1, 0, 0)))
        else:
            mate(root, "distance", oid, face(rung, (-1, 0, 0)), "occ-rail-a", face(rail, (-1, 0, 0)), value=_RUNG_PITCH * k)
    _flush(root, "occ-rail-b", face(rail, (-1, 0, 0)), "occ-rail-a", face(rail, (-1, 0, 0)))
    redundant, conflict = _inside_mates("occ-rail-b", face(rail, (0, 1, 0)), "occ-rail-a", face(rail, (0, 1, 0)), _FRAME_W - _BAR)
    return ScalingScene(
        name=f"frame-{n}",
        root=root,
        base="occ-rail-a",
        mover="occ-rail-b",
        occurrence_ids=tuple(o for o, _p, _t in occurrences),
        expected_dof_floating=6,
        expected_dof_fixed=0,
        probe_mate=_payload("distance", PROBE, face(probe, (0, -1, 0)), "occ-rail-b", face(rail, (0, 1, 0)), value=5.0),
        redundant_mate=redundant,
        conflict_mate=conflict,
        inside_driven="occ-rail-b",
        notes={"rails": 2, "rungs": rungs},
    )


# ---- 4-bar linkage with a rigid payload ----------------------------------------

_LINK_W = 20.0
_LINK_T = 5.0
_END = 10.0  # hole centre from each end of a link
_GROUND, _CRANK, _COUPLER, _ROCKER = 90.0, 40.0, 100.0, 70.0  # pivot-to-pivot lengths (Grashof crank-rocker: 40 + 100 < 90 + 70)
_CRANK_ANGLE = 70.0  # degrees, as built
_BLOCK = (8.0, 8.0, 4.0)


def _link(name: str, length: float) -> dict:
    return box_part(name, length + 2 * _END, _LINK_W, _LINK_T, holes=((_END, _LINK_W / 2, 4.0), (_END + length, _LINK_W / 2, 4.0)))


def _link_pose(pivot: tuple[float, float], angle_degrees: float, z: float) -> dict:
    """The pose that puts a link's first hole on `pivot` with its length along `angle_degrees` (about z)."""
    a = math.radians(angle_degrees)
    hx, hy = _END, _LINK_W / 2
    return pose((pivot[0] - (hx * math.cos(a) - hy * math.sin(a)), pivot[1] - (hx * math.sin(a) + hy * math.cos(a)), z), angle_degrees)


def _in_link_frame(link_pose: dict, local: tuple[float, float, float]) -> dict:
    """A part axis-aligned in a link's frame at `local`: the world pose (the link only turns about z)."""
    a = math.radians(link_pose["rotation_angle_degrees"])
    t = link_pose["translation"]
    x, y, z = local
    return pose((t[0] + x * math.cos(a) - y * math.sin(a), t[1] + x * math.sin(a) + y * math.cos(a), t[2] + z), link_pose["rotation_angle_degrees"])


def linkage_scene(payload: int = 20) -> ScalingScene:
    """A planar 4-bar linkage (ground, crank, coupler, rocker; holes at the pivots) with `payload` blocks mated rigidly onto the
    coupler in two rows. Joints: concentric + coincident (the links are stacked: ground z 0..5, crank and rocker 5..10, coupler
    10..15); in a closed planar loop two of the four coincidents and part of the last concentric are redundant. Each block: its
    bottom on the coupler's top, a face against the previous block of its row (the first of a row: flush with the coupler's end),
    and a side flush with the previous block's (the first: flush with / a distance from the coupler's side).
    Floating dof 7 (rigid body + the crank angle), ground link fixed 1."""
    ground, crank, coupler, rocker = _link("Ground", _GROUND), _link("Crank", _CRANK), _link("Coupler", _COUPLER), _link("Rocker", _ROCKER)
    block = box_part("Block", *_BLOCK)
    probe = _probe_part()
    o2, o4 = (0.0, 0.0), (_GROUND, 0.0)
    theta = math.radians(_CRANK_ANGLE)
    a_pt = (_CRANK * math.cos(theta), _CRANK * math.sin(theta))
    # B: on the circle about A (radius coupler) and about O4 (radius rocker), the open configuration (B above the ground link)
    dx, dy = o4[0] - a_pt[0], o4[1] - a_pt[1]
    d = math.hypot(dx, dy)
    along = (_COUPLER**2 - _ROCKER**2 + d**2) / (2 * d)
    height = math.sqrt(_COUPLER**2 - along**2)
    b_pt = (a_pt[0] + along * dx / d - height * dy / d, a_pt[1] + along * dy / d + height * dx / d)
    if b_pt[1] < 0:
        b_pt = (a_pt[0] + along * dx / d + height * dy / d, a_pt[1] + along * dy / d - height * dx / d)
    coupler_pose = _link_pose(a_pt, math.degrees(math.atan2(b_pt[1] - a_pt[1], b_pt[0] - a_pt[0])), 2 * _LINK_T)
    occurrences = [
        ("occ-ground", ground, _link_pose(o2, 0.0, 0.0)),
        ("occ-crank", crank, _link_pose(o2, _CRANK_ANGLE, _LINK_T)),
        ("occ-coupler", coupler, coupler_pose),
        ("occ-rocker", rocker, _link_pose(o4, math.degrees(math.atan2(b_pt[1] - o4[1], b_pt[0] - o4[0])), _LINK_T)),
    ]
    per_row = (payload + 1) // 2
    first_x = 20.0  # clear of the coupler's first hole
    blocks: list[tuple[str, int, int]] = []
    for i in range(payload):
        row, col = divmod(i, per_row)
        oid = f"occ-block-{i}"
        blocks.append((oid, row, col))
        occurrences.append((oid, block, _in_link_frame(coupler_pose, (first_x + _BLOCK[0] * col, _BLOCK[1] * row, _LINK_T))))
    occurrences.append((PROBE, probe, pose((40.0, 120.0, 40.0))))
    root = compose(_create_part("Linkage"), occurrences)

    def joint(upper: str, upper_part: dict, upper_hole: int, lower: str, lower_part: dict, lower_hole: int, lengths: tuple[float, float]) -> None:
        at = lambda which, length: (_END + (length if which else 0.0), _LINK_W / 2)  # noqa: E731
        mate(root, "concentric", upper, hole(upper_part, at(upper_hole, lengths[0])), lower, hole(lower_part, at(lower_hole, lengths[1])))
        mate(root, "coincident", upper, face(upper_part, (0, 0, -1)), lower, face(lower_part, (0, 0, 1)))

    joint("occ-crank", crank, 0, "occ-ground", ground, 0, (_CRANK, _GROUND))
    joint("occ-coupler", coupler, 0, "occ-crank", crank, 1, (_COUPLER, _CRANK))
    joint("occ-coupler", coupler, 1, "occ-rocker", rocker, 1, (_COUPLER, _ROCKER))
    joint("occ-rocker", rocker, 0, "occ-ground", ground, 1, (_ROCKER, _GROUND))
    by_cell = {(row, col): oid for oid, row, col in blocks}
    for oid, row, col in blocks:
        mate(root, "coincident", oid, face(block, (0, 0, -1)), "occ-coupler", face(coupler, (0, 0, 1)))
        if col == 0:
            mate(root, "distance", oid, face(block, (-1, 0, 0)), "occ-coupler", face(coupler, (-1, 0, 0)), value=first_x)
            if row == 0:
                _flush(root, oid, face(block, (0, -1, 0)), "occ-coupler", face(coupler, (0, -1, 0)))
            else:
                mate(root, "coincident", oid, face(block, (0, -1, 0)), by_cell[(row - 1, 0)], face(block, (0, 1, 0)))
        else:
            previous = by_cell[(row, col - 1)]
            mate(root, "coincident", oid, face(block, (-1, 0, 0)), previous, face(block, (1, 0, 0)))
            _flush(root, oid, face(block, (0, -1, 0)), previous, face(block, (0, -1, 0)))
    last_block = blocks[-1][0]
    redundant, conflict = _inside_mates(last_block, face(block, (0, 0, 1)), "occ-coupler", face(coupler, (0, 0, 1)), _BLOCK[2])
    return ScalingScene(
        name=f"linkage-payload-{payload}",
        root=root,
        base="occ-ground",
        mover="occ-crank",
        occurrence_ids=tuple(o for o, _p, _t in occurrences),
        expected_dof_floating=7,
        expected_dof_fixed=1,
        probe_mate=_payload("distance", PROBE, face(probe, (0, 0, -1)), "occ-coupler", face(coupler, (0, 0, 1)), value=5.0),
        redundant_mate=redundant,
        conflict_mate=conflict,
        inside_driven=last_block,
        notes={"links": 4, "payload": payload},
    )


def stored_poses(root: str) -> dict[str, dict]:
    return {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}
