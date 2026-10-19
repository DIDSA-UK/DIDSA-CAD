"""Scenes (`docs/scenes-scope.md`): the reference COMPOSITION - a scene plus the real placement tree give every placed instance
its pose, visibility and appearance while the scene is shown. A scene never changes the model (`Occurrence.transform`, `.hidden`,
the appearance overrides): it is laid on top for display only.

Like `app.document.appearance`, this is the reference the clients copy (DIDSA-VR in GDScript, the flat app in Dart): it imports
nothing from the backend but `appearance` (no OCCT, no pydantic), and `tools/scene_vectors/generate.py` writes the golden vectors
both copies are tested against.

Input (the vectors' shape):

    nodes: [{"path": "frame/barA", "local": T, "hidden": false, "bodies": ["a1", ...]}, ...]
        every placed instance of the assembly being shown, its occurrence path from the scene's Part ("" = the Part's own bodies,
        `#pattern:` copies are their own nodes), its REAL local transform at its own level (`Occurrence.transform`; a pattern copy's
        derived one), its real `hidden`, and the bodies to resolve an appearance for;
    model: the appearance resolution model (`app.document.appearance`);
    scene: {"overrides": [{"path", "body_id"?, "face"?, "transform"?, "hidden"?, "appearance"?}], ...} or None (the default).

A transform T is `{"translation": [x, y, z], "rotation_axis": [x, y, z], "rotation_angle_degrees": a}` (mm, rotate then translate,
the `RigidTransform` convention).

The rule (D2-D5):
  * pose: a node's local transform is the scene's transform override for its path if there is one, else its real one; world poses
    compose down the tree (moving a sub-assembly moves what is inside it; a child can be moved as well);
  * visibility: the nearest scene `hidden` on the node or an ancestor decides (a hidden sub-assembly hides its contents, and a scene
    can show a part the model hides with `hidden: false`); with none, the node's own real `hidden`;
  * appearance: the scene's appearance overrides are the top layer of `appearance.resolve_appearance` (a scene beats everything).
"""

from __future__ import annotations

import math

from app.document.appearance import resolve_appearance, split_path

IDENTITY = {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}


def _matrix(transform: dict) -> list[list[float]]:
    """Rodrigues: the rotation matrix (row-major) of an axis-angle transform."""
    x, y, z = transform.get("rotation_axis", [0.0, 0.0, 1.0])
    length = math.sqrt(x * x + y * y + z * z)
    angle = math.radians(float(transform.get("rotation_angle_degrees", 0.0)))
    if length < 1e-12 or abs(angle) < 1e-12:
        return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    x, y, z = x / length, y / length, z / length
    c, s = math.cos(angle), math.sin(angle)
    t = 1.0 - c
    return [
        [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
        [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
        [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
    ]


def _pose(transform: dict) -> dict:
    return {"basis": _matrix(transform), "origin": [float(v) for v in transform.get("translation", [0.0, 0.0, 0.0])]}


def compose_poses(parent: dict, child: dict) -> dict:
    """`parent` then `child` (child in the parent's frame), poses as {basis (row-major 3x3), origin}."""
    pb, po = parent["basis"], parent["origin"]
    cb, co = child["basis"], child["origin"]
    basis = [[sum(pb[r][k] * cb[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    origin = [po[r] + sum(pb[r][k] * co[k] for k in range(3)) for r in range(3)]
    return {"basis": basis, "origin": origin}


def parent_path(path: str) -> str | None:
    """The path of the node that places `path` ("" for a top-level one), or None for the Part's own content ("")."""
    if path == "":
        return None
    return path.rsplit("/", 1)[0] if "/" in path else ""


def compose_scene(nodes: list[dict], model: dict, root_id: str, scene: dict | None = None) -> dict[str, dict]:
    """Every node's {world, hidden, appearance, bodies} while `scene` is shown (None: the default, the real model).
    `world` is {basis, origin} in the scene's Part's frame (mm); `appearance` is the node as a whole, `bodies` one per listed body."""
    overrides = list((scene or {}).get("overrides") or [])
    transforms = {o["path"]: o["transform"] for o in overrides if o.get("transform") is not None and not o.get("body_id") and not o.get("face")}
    hidden_set = {o["path"]: bool(o["hidden"]) for o in overrides if o.get("hidden") is not None and not o.get("body_id") and not o.get("face")}
    appearance_layer = [
        {k: v for k, v in o.items() if k in ("path", "body_id", "face", "appearance")} for o in overrides if o.get("appearance")
    ]
    by_path = {n["path"]: n for n in nodes}
    world: dict[str, dict] = {}

    def world_of(path: str) -> dict:
        if path in world:
            return world[path]
        node = by_path.get(path)
        local = transforms.get(path, node["local"] if node is not None else IDENTITY)
        parent = parent_path(path)
        pose = _pose(local) if parent is None else compose_poses(world_of(parent), _pose(local))
        world[path] = pose
        return pose

    out: dict[str, dict] = {}
    for node in nodes:
        path = node["path"]
        hidden = bool(node.get("hidden", False))
        probe: str | None = path
        while probe is not None:
            if probe in hidden_set:
                hidden = hidden_set[probe]
                break
            probe = parent_path(probe)
        segments = split_path(path)
        out[path] = {
            "world": world_of(path),
            "hidden": hidden,
            "appearance": resolve_appearance(model, root_id, segments, None, None, appearance_layer),
            "bodies": {b: resolve_appearance(model, root_id, segments, b, None, appearance_layer) for b in node.get("bodies", [])},
        }
    return out
