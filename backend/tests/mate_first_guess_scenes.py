"""First-time-accuracy scenes for a new mate's default placement ("Closest"), for `tests/bench_mates_m0.py`
(`docs/mates-storage-sessions-plan-2026-11-12.md`, M0; the judge for M4).

The method is the Phase 4 "mate bench" of `docs/mate-solution-choice-plan.md`, REBUILT from that doc's description (the original
script was never committed): ground truth by construction. Each scene is assembled at its TRUE pose, the driven part is moved to
a start pose, the mate is previewed with nothing named, and the shown placement is compared with the truth by a geometric
signature of the mate (which way the two picked directions face each other, and the signed offset), not by the branch fields.

Start classes: `near` (12 mm, 25 deg), `medium` (50 mm, 100 deg), `far` (110 mm, any way up) as in Phase 4, plus
`upside_down` (the part turned 180 deg about an axis lying in the mate's plane, up to 20 deg more tilt, 30 mm away: a part
dropped in the wrong way up). A `seated` scene already has the part resting on the base (a stored coincident mate), so its
starts stay on that mate: a slide in the plane and a spin about its normal (no `upside_down`).

Scenes of group `phase4` are the nine mates the doc lists (stack, parallel, pin in post, axis distance, inset, overhang, gap
above a face, gap under an underside, vertex above a face); the doc gives only some of their sizes, so the others are chosen
here. Group `m4` adds the same-facing distances M4 targets (a small inset, a large overhang, seated inset / overhang).

Every scene records a realistic PICK POINT per picked face (`GuessScene.picks`, local to each occurrence, on the face): where a
user would click. `trial_picks` jitters them per trial. The backend does not read pick points yet; M4 adds `pick_points`.
"""

import math
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point, compose as compose_transforms
from app.document.models import RigidTransform
from tests.motion_scaling_scenes import box_part, compose, cylinder_part, face, face_index, hole, mate, pose
from tests.test_assembly_solver import _create_part, client

DRIVEN = "occ-driven"
FIXED = "occ-fixed"

START_CLASSES = ("near", "medium", "far", "upside_down")
_START_SIZE = {"near": (12.0, 25.0), "medium": (50.0, 100.0), "far": (110.0, None)}
_UPSIDE_DOWN_MM, _UPSIDE_DOWN_TILT = 30.0, 20.0
_SIGNED_TOL = 1e-4  # mm
_PICK_SPREAD = 0.2  # jitter of a pick, as a share of the face's half-extent
_PICK_MARGIN = 0.1  # a pick stays this share of the half-extent inside the face's edge


@dataclass
class Pick:
    """Where on a face the user clicks: `point` (occurrence-local, on the face) and the two in-face half-extents it may vary by."""

    point: tuple[float, float, float]
    u: tuple[float, float, float] = (0.0, 0.0, 0.0)
    v: tuple[float, float, float] = (0.0, 0.0, 0.0)


@dataclass
class GuessScene:
    name: str
    group: str  # "phase4" | "m4"
    kind: str  # "same_facing" (inset / overhang) | "facing_gap" | "other"
    root: str
    payload: dict  # the new mate, NOTHING named (`preview-mate-solve` body), driven reference first
    true_pose: dict  # the driven occurrence's transform at the truth
    centre: tuple[float, float, float]  # the driven part's centre, part-local (starts turn the part about it)
    up: tuple[float, float, float]  # the mate's direction in world (the fixed face's normal / axis)
    signature: Callable[[dict], tuple]  # driven transform -> (facing sign, signed offset) of the mate
    picks: dict[str, Pick]  # {DRIVEN: ..., FIXED: ...}
    seated: bool = False
    notes: dict = field(default_factory=dict)

    def correct(self, transform: dict) -> bool:
        truth, shown = self.signature(self.true_pose), self.signature(transform)
        return truth[0] == shown[0] and all(abs(a - b) < _SIGNED_TOL for a, b in zip(truth[1:], shown[1:]))

    def start_classes(self) -> tuple[str, ...]:
        return ("near", "medium", "far") if self.seated else START_CLASSES


def _rt(t: dict) -> RigidTransform:
    return RigidTransform(tuple(t["translation"]), tuple(t["rotation_axis"]), t["rotation_angle_degrees"])


def _dict(rt: RigidTransform) -> dict:
    return {"translation": [float(x) for x in rt.translation], "rotation_axis": [float(x) for x in rt.rotation_axis], "rotation_angle_degrees": float(rt.rotation_angle_degrees)}


def _unit(rng: np.random.Generator) -> np.ndarray:
    v = rng.normal(size=3)
    return v / np.linalg.norm(v)


def _turned_about_centre(scene: GuessScene, turn: RigidTransform, offset: np.ndarray) -> dict:
    """The true pose turned by `turn` about the part's own centre, then moved by `offset`."""
    base = _rt(scene.true_pose)
    centre = np.array(apply_transform_to_point(base, scene.centre))
    turned = compose_transforms(turn, base)
    moved_centre = np.array(apply_transform_to_point(turned, scene.centre))
    translation = np.array(turned.translation) + (centre - moved_centre) + offset
    return _dict(RigidTransform(tuple(float(x) for x in translation), turned.rotation_axis, turned.rotation_angle_degrees))


def start_pose(scene: GuessScene, kind: str, rng: np.random.Generator) -> dict:
    """One start of class `kind` for `scene` (see the module docstring)."""
    up = np.array(scene.up, float)
    if scene.seated:
        mm, deg = _START_SIZE[kind]
        slide = np.cross(up, _unit(rng))
        slide /= np.linalg.norm(slide)
        angle = float(rng.uniform(0, 360)) if deg is None else float(deg) * (1 if rng.random() < 0.5 else -1)
        return _turned_about_centre(scene, RigidTransform((0.0, 0.0, 0.0), tuple(float(x) for x in up), angle), slide * mm)
    if kind == "upside_down":
        in_plane = np.cross(up, _unit(rng))
        in_plane /= np.linalg.norm(in_plane)
        flip = RigidTransform((0.0, 0.0, 0.0), tuple(float(x) for x in in_plane), 180.0)
        tilt = RigidTransform((0.0, 0.0, 0.0), tuple(float(x) for x in _unit(rng)), float(rng.uniform(0, _UPSIDE_DOWN_TILT)))
        return _turned_about_centre(scene, compose_transforms(tilt, flip), _unit(rng) * _UPSIDE_DOWN_MM)
    mm, deg = _START_SIZE[kind]
    direction, axis = _unit(rng), _unit(rng)
    angle = float(rng.uniform(0, 360)) if deg is None else float(deg)
    return _turned_about_centre(scene, RigidTransform((0.0, 0.0, 0.0), tuple(float(x) for x in axis), angle), direction * mm)


def trial_picks(scene: GuessScene, rng: np.random.Generator) -> dict[str, list[float]]:
    """This trial's pick point per side (occurrence-local): the scene's pick, moved within the face like a hand would vary."""
    out = {}
    for side, pick in scene.picks.items():
        limit = (1.0 - _PICK_MARGIN) / _PICK_SPREAD
        a, b = (float(np.clip(rng.normal(), -limit, limit)) * _PICK_SPREAD for _ in range(2))
        out[side] = [float(p + a * u + b * v) for p, u, v in zip(pick.point, pick.u, pick.v)]
    return out


# ---- geometry of the picked faces ---------------------------------------------


def _box_pick(part: dict, normal, at: tuple[float, float] = (0.5, 0.5), reach: float = 1.0) -> Pick:
    """A pick on the box face with outward `normal`: `at` is where along the face's two in-plane axes (0..1 of the box's size, in
    x, y, z order with the normal's axis left out), `reach` scales the half-extents the pick may vary by."""
    size = part["size"]
    k = max(range(3), key=lambda i: abs(normal[i]))
    others = [i for i in range(3) if i != k]
    point = [0.0, 0.0, 0.0]
    point[k] = size[k] if normal[k] > 0 else 0.0
    half = []
    for share, i in zip(at, others):
        point[i] = size[i] * share
        room = min(share, 1.0 - share) * size[i] * reach
        e = [0.0, 0.0, 0.0]
        e[i] = room
        half.append(tuple(e))
    return Pick(tuple(point), half[0], half[1])


def _hole_pick(part: dict, ref: dict, height: float) -> Pick:
    """A pick on a cylindrical face (axis along z): a point on the wall at `height`, free to move round a quarter turn's chord."""
    measured = part["faces"][ref["subshape_ref"]["index"]]
    ox, oy = measured["axis"]["origin"][0], measured["axis"]["origin"][1]
    r = measured["radius"]
    return Pick((ox + r, oy, height))  # no in-face jitter (the wall is curved: a straight offset would leave it)


def _plane_signature(d_part: dict, d_normal, f_part: dict, f_normal, fixed_pose: dict) -> Callable[[dict], tuple]:
    """(the faces point the same way +1 / opposite -1, the driven face's signed height over the fixed face along ITS normal)."""
    d_face = d_part["faces"][face_index(d_part, d_normal)]
    f_face = f_part["faces"][face_index(f_part, f_normal)]
    fixed = _rt(fixed_pose)
    fn = np.array(apply_transform_to_direction(fixed, tuple(f_face["normal"])))
    fp = np.array(apply_transform_to_point(fixed, tuple(f_face["point_on_face"])))

    def signature(transform: dict) -> tuple:
        rt = _rt(transform)
        dn = np.array(apply_transform_to_direction(rt, tuple(d_face["normal"])))
        dp = np.array(apply_transform_to_point(rt, tuple(d_face["point_on_face"])))
        dot = float(dn @ fn)
        if abs(abs(dot) - 1.0) > 1e-6:
            return (0, math.nan)  # not parallel: never the truth
        return (1 if dot > 0 else -1, float((dp - fp) @ fn))

    return signature


def _direction_only(signature: Callable[[dict], tuple]) -> Callable[[dict], tuple]:
    return lambda transform: signature(transform)[:1]


def _axis_signature(d_part: dict, d_ref: dict, f_part: dict, f_ref: dict, fixed_pose: dict) -> Callable[[dict], tuple]:
    """(the two axes point the same way +1 / opposite -1, the distance between them)."""
    d_axis = d_part["faces"][d_ref["subshape_ref"]["index"]]["axis"]
    f_axis = f_part["faces"][f_ref["subshape_ref"]["index"]]["axis"]
    fixed = _rt(fixed_pose)
    fd = np.array(apply_transform_to_direction(fixed, tuple(f_axis["direction"])))
    fo = np.array(apply_transform_to_point(fixed, tuple(f_axis["origin"])))

    def signature(transform: dict) -> tuple:
        rt = _rt(transform)
        dd = np.array(apply_transform_to_direction(rt, tuple(d_axis["direction"])))
        do = np.array(apply_transform_to_point(rt, tuple(d_axis["origin"])))
        dot = float(dd @ fd)
        if abs(abs(dot) - 1.0) > 1e-6:
            return (0, math.nan)
        gap = (do - fo) - ((do - fo) @ fd) * fd
        return (1 if dot > 0 else -1, float(np.linalg.norm(gap)))

    return signature


def _vertex_signature(d_part: dict, vertex_index: int, f_part: dict, f_normal, fixed_pose: dict) -> Callable[[dict], tuple]:
    """(1, the vertex's signed height over the fixed face along its normal)."""
    point = _vertex(d_part, vertex_index)
    f_face = f_part["faces"][face_index(f_part, f_normal)]
    fixed = _rt(fixed_pose)
    fn = np.array(apply_transform_to_direction(fixed, tuple(f_face["normal"])))
    fp = np.array(apply_transform_to_point(fixed, tuple(f_face["point_on_face"])))
    return lambda transform: (1, float((np.array(apply_transform_to_point(_rt(transform), point)) - fp) @ fn))


def _vertex(part: dict, index: int) -> tuple[float, float, float]:
    measured = client.post(f"/document/parts/{part['id']}/measure", json={"refs": [{"body_id": part["body_id"], "shape_type": "vertex", "index": index}]})
    assert measured.status_code == 200, measured.text
    return tuple(measured.json()["point"])


# ---- scenes ---------------------------------------------------------------------

_BASE = (120.0, 80.0, 20.0)
_PLATE = (60.0, 40.0, 6.0)


def _refs(driven_ref: dict, fixed_ref: dict) -> list[dict]:
    return [{"occurrence_id": DRIVEN, **driven_ref}, {"occurrence_id": FIXED, **fixed_ref}]


def _assemble(name: str, fixed_part: dict, driven_part: dict, true_translation) -> tuple[str, dict, dict]:
    """The fixed part at the origin (fixed) and the driven part at its true place. Returns (root, fixed pose, true pose)."""
    fixed_pose, true_pose = pose((0.0, 0.0, 0.0)), pose(true_translation)
    root = compose(_create_part(name), [(FIXED, fixed_part, fixed_pose), (DRIVEN, driven_part, true_pose)])
    assert client.patch(f"/document/parts/{root}/occurrences/{FIXED}", json={"fixed": True}).status_code == 200
    return root, fixed_pose, true_pose


def _centre(part: dict) -> tuple[float, float, float]:
    return tuple(s / 2.0 for s in part["size"])


def _plate_on_base(name: str, group: str, kind: str, mate_type: str, d_normal, f_normal, true_translation, value: float | None,
                   picks: tuple[Pick, Pick] | None = None, seated: bool = False, direction_only: bool = False, **notes) -> GuessScene:
    base, plate = box_part("Base", *_BASE), box_part("Plate", *_PLATE)
    root, fixed_pose, true_pose = _assemble(name, base, plate, true_translation)
    if seated:
        mate(root, "coincident", DRIVEN, face(plate, (0, 0, -1)), FIXED, face(base, (0, 0, 1)))
    payload = {"type": mate_type, "references": _refs(face(plate, d_normal), face(base, f_normal))}
    if value is not None:
        payload["value"] = value
    signature = _plane_signature(plate, d_normal, base, f_normal, fixed_pose)
    d_pick, f_pick = picks or (_box_pick(plate, d_normal), _box_pick(base, f_normal))
    return GuessScene(name, group, kind, root, payload, true_pose, _centre(plate), tuple(float(x) for x in f_normal),
                      _direction_only(signature) if direction_only else signature, {DRIVEN: d_pick, FIXED: f_pick}, seated, dict(notes))


def _same_facing(name: str, group: str, value: float, inset: bool, seated: bool = False) -> GuessScene:
    """The plate lying on the base, its +x edge face `value` mm behind (inset) or past (overhang) the base's +x face. The picks
    are where a user reaches for them: the middle of the plate's thin edge face, and the base's side face just under the plate."""
    edge_x = _BASE[0] - value if inset else _BASE[0] + value  # world x of the plate's +x face
    y0 = (_BASE[1] - _PLATE[1]) / 2.0
    plate_stub = {"size": _PLATE}
    base_stub = {"size": _BASE}
    picks = (
        _box_pick(plate_stub, (1, 0, 0)),
        # the base's +x face: level with the plate in y, near the top edge in z (the part of the face next to the plate)
        _box_pick(base_stub, (1, 0, 0), at=(0.5, 0.85), reach=0.5),
    )
    return _plate_on_base(name, group, "same_facing", "distance", (1, 0, 0), (1, 0, 0), (edge_x - _PLATE[0], y0, _BASE[2]), value, picks, seated,
                          mm=value, side="inset" if inset else "overhang")


def stack_scene() -> GuessScene:
    return _plate_on_base("stack", "phase4", "other", "coincident", (0, 0, -1), (0, 0, 1), (30.0, 20.0, _BASE[2]), None)


def parallel_scene() -> GuessScene:
    """The plate's top parallel to the base's top, the same way up (it floats 15 mm above: Parallel fixes no offset)."""
    return _plate_on_base("parallel", "phase4", "other", "parallel", (0, 0, 1), (0, 0, 1), (30.0, 20.0, _BASE[2] + 15.0), None, direction_only=True)


def gap_above_scene() -> GuessScene:
    return _plate_on_base("gap-6-above", "phase4", "facing_gap", "distance", (0, 0, -1), (0, 0, 1), (30.0, 20.0, _BASE[2] + 6.0), 6.0)


def gap_under_scene() -> GuessScene:
    return _plate_on_base("gap-6-under", "phase4", "facing_gap", "distance", (0, 0, 1), (0, 0, -1), (30.0, 20.0, -6.0 - _PLATE[2]), 6.0)


def vertex_above_scene() -> GuessScene:
    base, plate = box_part("Base", *_BASE), box_part("Plate", *_PLATE)
    # the plate tipped onto a corner is not needed: the truth is simply its vertex 0 held 6 mm above the base's top
    corner = _vertex(plate, 0)
    root, fixed_pose, true_pose = _assemble("vertex-6-above", base, plate, (30.0, 20.0, _BASE[2] + 6.0 - corner[2]))
    vertex_ref = {"subshape_ref": {"body_id": plate["body_id"], "shape_type": "vertex", "index": 0}}
    payload = {"type": "distance", "value": 6.0, "references": _refs(vertex_ref, face(base, (0, 0, 1)))}
    return GuessScene("vertex-6-above", "phase4", "facing_gap", root, payload, true_pose, _centre(plate), (0.0, 0.0, 1.0),
                      _vertex_signature(plate, 0, base, (0, 0, 1), fixed_pose), {DRIVEN: Pick(corner), FIXED: _box_pick(base, (0, 0, 1))})


def pin_in_post_scene() -> GuessScene:
    """A pin standing in a post's bore, its base end down (concentric: the root is which way the pin points along the axis)."""
    post = box_part("Post", 30.0, 30.0, 40.0, holes=((15.0, 15.0, 5.0),))
    pin = cylinder_part("Pin", 5.0, 30.0)
    root, fixed_pose, true_pose = _assemble("pin-in-post", post, pin, (15.0, 15.0, 20.0))
    d_ref, f_ref = hole(pin), hole(post, (15.0, 15.0))
    payload = {"type": "concentric", "references": _refs(d_ref, f_ref)}
    return GuessScene("pin-in-post", "phase4", "other", root, payload, true_pose, (0.0, 0.0, 15.0), (0.0, 0.0, 1.0),
                      _axis_signature(pin, d_ref, post, f_ref, fixed_pose), {DRIVEN: _hole_pick(pin, d_ref, 25.0), FIXED: _hole_pick(post, f_ref, 38.0)})


def axis_distance_scene() -> GuessScene:
    """Two shafts side by side, axes 25 mm apart, the same way up (distance between two axes)."""
    shaft_a, shaft_b = cylinder_part("ShaftA", 6.0, 40.0), cylinder_part("ShaftB", 6.0, 40.0)
    root, fixed_pose, true_pose = _assemble("axis-distance-25", shaft_a, shaft_b, (25.0, 0.0, 0.0))
    d_ref, f_ref = hole(shaft_b), hole(shaft_a)
    payload = {"type": "distance", "value": 25.0, "references": _refs(d_ref, f_ref)}
    return GuessScene("axis-distance-25", "phase4", "other", root, payload, true_pose, (0.0, 0.0, 20.0), (0.0, 0.0, 1.0),
                      _axis_signature(shaft_b, d_ref, shaft_a, f_ref, fixed_pose), {DRIVEN: _hole_pick(shaft_b, d_ref, 20.0), FIXED: _hole_pick(shaft_a, f_ref, 20.0)})


def headed_pin_part(name: str, shaft_radius: float, shaft_length: float, head_radius: float, head_length: float) -> dict:
    """A pin on the z axis: a shaft (z 0..`shaft_length`) under a wider head (up to `shaft_length + head_length`). The shaft's top
    edge lies on the head's underside (the shoulder a peg-in-hole seats on the plate)."""
    from tests.motion_scaling_scenes import _measure_faces
    from tests.test_assembly_solver import _add_point

    part = _create_part(name)
    body_id = None
    for radius, start, end in ((shaft_radius, 0.0, shaft_length), (head_radius, shaft_length, shaft_length + head_length)):
        sketch = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
        centre = _add_point(sketch["sketch_id"], 0.0, 0.0)
        assert client.post(f"/sketch/sketches/{sketch['sketch_id']}/circles", json={"center_point_id": centre["id"], "radius": radius, "angle": 0.0}).status_code == 201
        boss = client.post(
            f"/document/parts/{part['id']}/extrude-features",
            json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": start, "end_distance": end, "target_body_ids": [body_id] if body_id else []},
        )
        assert boss.status_code == 201, boss.text
        body_id = body_id or client.get(f"/document/parts/{part['id']}/mesh").json()[0]["body_id"]
    size = (2 * head_radius, 2 * head_radius, shaft_length + head_length)
    return {"id": part["id"], "body_id": body_id, "size": size, "faces": _measure_faces(part["id"], body_id)}


def circle_edge(part: dict, radius: float, centre: tuple[float, float, float]) -> dict:
    """The circular edge of `part` with this radius and centre (part-local), as a mate reference."""
    for index in range(64):
        measured = client.post(f"/document/parts/{part['id']}/measure", json={"refs": [{"body_id": part["body_id"], "shape_type": "edge", "index": index}]})
        if measured.status_code != 200:
            break
        m = measured.json()
        if m.get("radius") is not None and abs(m["radius"] - radius) < 1e-6 and all(abs(a - b) < 1e-6 for a, b in zip(m["center"], centre)):
            return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "edge", "index": index}}
    raise AssertionError(f"no circular edge of radius {radius} at {centre}")


def peg_in_hole_scene() -> GuessScene:
    """M4: a headed pin dropped into a plate's bore: the pin's shoulder edge (the shaft's top rim, on the head's underside) and the
    bore's top rim, previewed as one `peg_in_hole` (Concentric on the edges + Coincident on the head's underside and the plate's top).
    Truth: the shaft in the bore, the head resting on the plate. `notes["old_default"]` is the payload a client sent before M4 for the
    same picks (its type control started on Coincident, which on two circular edges is a plain Concentric: the pin is not seated)."""
    plate = box_part("BorePlate", 60.0, 40.0, 10.0, holes=((30.0, 20.0, 5.0),))
    pin = headed_pin_part("HeadedPin", 5.0, 20.0, 9.0, 5.0)
    root, fixed_pose, true_pose = _assemble("peg-in-hole", plate, pin, (30.0, 20.0, -10.0))
    d_ref, f_ref = circle_edge(pin, 5.0, (0.0, 0.0, 20.0)), circle_edge(plate, 5.0, (30.0, 20.0, 10.0))
    payload = {"type": "peg_in_hole", "references": _refs(d_ref, f_ref)}
    axis = _axis_signature(pin, hole(pin), plate, hole(plate, (30.0, 20.0)), fixed_pose)
    seat = _plane_signature(pin, (0, 0, -1), plate, (0, 0, 1), fixed_pose)

    def signature(transform: dict) -> tuple:
        return (*axis(transform), *seat(transform))

    picks = {DRIVEN: Pick((5.0, 0.0, 20.0)), FIXED: Pick((35.0, 20.0, 10.0))}  # on each rim (an edge pick does not wander)
    return GuessScene("peg-in-hole", "m4", "peg", root, payload, true_pose, (0.0, 0.0, 12.5), (0.0, 0.0, 1.0), signature, picks,
                      notes={"old_default": {"type": "coincident", "references": payload["references"]}})


SCENES: dict[str, Callable[[], GuessScene]] = {
    # the nine mates of the Phase 4 bench
    "stack": stack_scene,
    "parallel": parallel_scene,
    "pin-in-post": pin_in_post_scene,
    "axis-distance-25": axis_distance_scene,
    "inset-10": lambda: _same_facing("inset-10", "phase4", 10.0, inset=True),
    "overhang-3": lambda: _same_facing("overhang-3", "phase4", 3.0, inset=False),
    "gap-6-above": gap_above_scene,
    "gap-6-under": gap_under_scene,
    "vertex-6-above": vertex_above_scene,
    # M4's targets: more same-facing distances, and the same ones with the plate already resting on the base
    "inset-2": lambda: _same_facing("inset-2", "m4", 2.0, inset=True),
    "overhang-25": lambda: _same_facing("overhang-25", "m4", 25.0, inset=False),
    "inset-10-seated": lambda: _same_facing("inset-10-seated", "m4", 10.0, inset=True, seated=True),
    "overhang-3-seated": lambda: _same_facing("overhang-3-seated", "m4", 3.0, inset=False, seated=True),
    # M4's type rule: two circular edges are a peg in a hole (Concentric + Coincident as one action)
    "peg-in-hole": peg_in_hole_scene,
}


def set_pose(scene: GuessScene, transform: dict) -> None:
    response = client.patch(f"/document/parts/{scene.root}/occurrences/{DRIVEN}", json={"transform": transform})
    assert response.status_code == 200, response.text


def preview(scene: GuessScene, movement: str = "auto", **named) -> dict:
    response = client.post(f"/document/parts/{scene.root}/occurrences/{DRIVEN}/preview-mate-solve", params={"movement": movement}, json={**scene.payload, **named})
    assert response.status_code == 200, response.text
    return response.json()


def shown_transform(ghost_or_alternative: dict) -> dict | None:
    """The driven part's placement in a preview answer (or one of its `alternatives`)."""
    for member in ghost_or_alternative.get("members") or []:
        if member["occurrence_id"] == DRIVEN:
            return member["transform"]
    return ghost_or_alternative.get("transform")
