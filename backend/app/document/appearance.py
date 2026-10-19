"""The Appearance tool's record and its resolution rule (`docs/appearance-tool-scope.md` sections 2, D2, D3).

This module is the **reference implementation** the two clients copy (DIDSA-VR in GDScript, the flat app in Dart): it
imports nothing from the rest of the backend (no OCCT, no pydantic) so `tools/appearance_vectors/generate.py` can load it
on its own and write the golden vectors both copies are tested against (the `tools/motion_vectors` pattern). The backend
uses the same functions for the materials of `assembly-mesh.glb` (D7), so the server, the vectors and the clients agree.

It works on a plain-dict **resolution model** (the JSON the vectors carry), not on `models.Part`:

    {"parts": {part_id: {
        "appearance": {...},                                    # the Part's own, whole part
        "body_appearances": {body_id: {...}},                   # the Part's own, one body
        "face_appearances": [{"face": {"body_id", "index"}, "appearance": {...}}],
        "appearance_overrides": [{"path", "scope"?, "pattern_id"?, "part_id"?, "body_id"?, "face"?, "appearance"}],
        "occurrences": {occurrence_id: {"part_id": ..., "color": "#RRGGBB" | None}},
    }}}

Every key is optional. A face is named by its current index (the backend re-finds a signed face first, `decide_subshape`).

**Which appearance wins** (D3), field by field (an override that sets only `opacity` keeps the colour from below):

1. the scene being shown (its overrides, paths from the root);
2. the overrides of the assembly being viewed (the root);
3. the overrides stored in each sub-assembly file on the way down, highest first, ending with the leaf Part's own list
   (whose empty-path entries cover its own bodies);
4. the leaf Part's own `face_appearances`, then `body_appearances`, then `appearance`;
5. the app's default look (not here: each renderer has its own, `DEFAULT_LOOK` is the backend's).

Within one override list the most specific target wins (`_specificity`): a face beats a body beats a whole node; then
the target nearest the face wins (a part inside a painted sub-assembly keeps its own colour); on the same node a named
path beats `scope: "pattern"` beats `scope: "same_part"`, and the empty path (Whole assembly) is under everything. For the
owner's list this reads face > body > part > pattern > every placement of the part > sub-assembly > whole assembly. Two
entries that tie (a source occurrence in two patterns, both painted) resolve to the later one in the list.

`Occurrence.color` is a legacy alias (D2): read as the override `{path: <occurrence id>, appearance: {colour}}` in the
Part that places it; an explicit override with the same target keeps its own fields and takes the colour from it only
when it sets none.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, fields

FIELDS = ("colour", "opacity", "metallic", "roughness", "emission", "emission_strength")
_HEX_FIELDS = ("colour", "emission")
_UNIT_FIELDS = ("opacity", "metallic", "roughness")
EMISSION_STRENGTH_MAX = 10.0
_HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")

SCOPE_PATTERN = "pattern"
SCOPE_SAME_PART = "same_part"
SCOPES = (SCOPE_PATTERN, SCOPE_SAME_PART)

PATTERN_SEGMENT = "#pattern:"

# The backend's own default look, for the fields nothing sets (step 5): light grey, non-metallic, fairly matte - the flat
# app's own default material (`mesh_data.dart`). A client that wants its own default reads the material's
# `extras.appearance` (only the fields that were set) instead.
DEFAULT_LOOK = {"colour": "#C8C8C8", "opacity": 1.0, "metallic": 0.0, "roughness": 0.8}


@dataclass(frozen=True)
class Appearance:
    """One appearance record (section 2). Every field optional; an empty one is never stored."""

    colour: str | None = None
    opacity: float | None = None
    metallic: float | None = None
    roughness: float | None = None
    emission: str | None = None
    emission_strength: float | None = None

    def to_dict(self) -> dict:
        return {f.name: getattr(self, f.name) for f in fields(self) if getattr(self, f.name) is not None}

    @staticmethod
    def from_dict(data: dict) -> "Appearance":
        return Appearance(**{name: data[name] for name in FIELDS if data.get(name) is not None})

    def is_empty(self) -> bool:
        return not self.to_dict()


def appearance_errors(data: object) -> list[str]:
    """Why `data` is not a valid appearance record ([] when it is): known fields only, at least one set, `#RRGGBB`
    colours, 0-1 for opacity / metallic / roughness, 0-10 for emission_strength."""
    if not isinstance(data, dict):
        return ["appearance must be an object"]
    errors = [f"unknown appearance field {key!r}" for key in data if key not in FIELDS]
    set_fields = [key for key in FIELDS if data.get(key) is not None]
    if not set_fields:
        errors.append("an appearance must set at least one field")
    for key in _HEX_FIELDS:
        value = data.get(key)
        if value is not None and not (isinstance(value, str) and _HEX_RE.match(value)):
            errors.append(f"{key} must be '#RRGGBB'")
    for key in (*_UNIT_FIELDS, "emission_strength"):
        value = data.get(key)
        if value is None:
            continue
        upper = EMISSION_STRENGTH_MAX if key == "emission_strength" else 1.0
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0.0 <= value <= upper:
            errors.append(f"{key} must be a number from 0 to {upper:g}")
    return errors


def base_segment(segment: str) -> str:
    """The occurrence id of a path segment: a pattern copy `<source>#pattern:<pattern id>:<index>` names `<source>`."""
    return segment.split(PATTERN_SEGMENT, 1)[0]


def split_path(path: str) -> list[str]:
    return path.split("/") if path else []


def override_key(record: dict) -> tuple:
    """What one override targets; an assembly holds at most one override per key (PUT replaces it)."""
    face = record.get("face")
    return (
        record.get("path") or "",
        record.get("scope"),
        record.get("pattern_id"),
        record.get("part_id"),
        record.get("body_id"),
        face.get("index") if face else None,
    )


def effective_overrides(part: dict) -> list[dict]:
    """A Part's own override list with the legacy `Occurrence.color` aliases folded in (see the module docstring)."""
    explicit = list(part.get("appearance_overrides") or [])
    by_key = {override_key(record): index for index, record in enumerate(explicit)}
    legacy: list[dict] = []
    for occurrence_id, occurrence in (part.get("occurrences") or {}).items():
        colour = occurrence.get("color")
        if not colour:
            continue
        key = (occurrence_id, None, None, None, None, None)
        if key in by_key:
            record = explicit[by_key[key]]
            if record["appearance"].get("colour") is None:
                explicit[by_key[key]] = {**record, "appearance": {**record["appearance"], "colour": colour}}
        else:
            legacy.append({"path": occurrence_id, "appearance": {"colour": colour}})
    return legacy + explicit


def _specificity(
    record: dict, suffix: list[str], suffix_parts: list[str | None], body_id: str | None, face_index: int | None
) -> tuple[int, int, int] | None:
    """`(subshape, depth, kind)` when `record` applies to the face `(body_id, face_index)` of the instance `suffix`
    below the record's own Part (`suffix_parts[j]` is the Part placed by `suffix[j]`), else None. Larger wins.
    subshape: 2 face, 1 body, 0 a whole node. depth: how far below the record's Part the node it names sits.
    kind: 3 a named path, 2 every copy of a pattern, 1 every placement of a Part, 0 the whole assembly."""
    face = record.get("face")
    record_body = record.get("body_id") or (face.get("body_id") if face else None)
    subshape = 2 if face else (1 if record_body else 0)
    if subshape:
        if record_body != body_id:
            return None
        if face and face.get("index") != face_index:
            return None
    scope = record.get("scope")
    if scope == SCOPE_SAME_PART:
        anchors = [j for j, part_id in enumerate(suffix_parts) if part_id == record.get("part_id")]
        if not anchors:
            return None
        depth = anchors[-1] + 1
        if subshape and depth != len(suffix):
            return None
        return (subshape, depth, 1)
    segments = split_path(record.get("path") or "")
    if scope == SCOPE_PATTERN:
        n = len(segments)
        if n == 0 or len(suffix) < n or suffix[: n - 1] != segments[:-1]:
            return None
        source, segment = segments[-1], suffix[n - 1]
        if segment != source and not segment.startswith(f"{source}{PATTERN_SEGMENT}{record.get('pattern_id')}:"):
            return None
        if subshape and len(suffix) != n:
            return None
        return (subshape, n, 2)
    n = len(segments)
    if suffix[:n] != segments:
        return None
    if n == 0 and not subshape:
        return (0, 0, 0)
    if subshape and len(suffix) != n:
        return None
    return (subshape, n, 3)


def _ordered_matches(
    records: list[dict], suffix: list[str], suffix_parts: list[str | None], body_id: str | None, face_index: int | None
) -> list[dict]:
    matched = []
    for index, record in enumerate(records):
        spec = _specificity(record, suffix, suffix_parts, body_id, face_index)
        if spec is not None:
            matched.append((spec, index, record["appearance"]))
    matched.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [appearance for _spec, _index, appearance in matched]


def instance_chain(model: dict, root_id: str, path: list[str]) -> list[str] | None:
    """The Part ids from the root down to the instance `path` names (`len(path) + 1` of them), or None when a segment
    does not resolve (an occurrence that is not there, or not resolved to a Part in this model)."""
    parts = model.get("parts", {})
    chain = [root_id]
    for segment in path:
        part = parts.get(chain[-1])
        occurrence = (part.get("occurrences") or {}).get(base_segment(segment)) if part else None
        if occurrence is None or occurrence.get("part_id") not in parts:
            return None
        chain.append(occurrence["part_id"])
    return chain


def resolve_layers(
    model: dict,
    root_id: str,
    path: list[str],
    body_id: str | None = None,
    face_index: int | None = None,
    scene_overrides: list[dict] | None = None,
) -> list[dict]:
    """Every appearance record that applies to one face (or, with `body_id` None, to the instance as a whole: only
    node-level targets), highest priority first. `resolve_appearance` merges them; a client can show where a field
    comes from by walking the same list."""
    chain = instance_chain(model, root_id, path)
    if chain is None:
        return []
    parts = model["parts"]
    layers: list[dict] = []
    if scene_overrides:
        layers += _ordered_matches(scene_overrides, path, chain[1:], body_id, face_index)
    for k, part_id in enumerate(chain):
        layers += _ordered_matches(effective_overrides(parts[part_id]), path[k:], chain[k + 1 :], body_id, face_index)
    leaf = parts[chain[-1]]
    if body_id is not None:
        for entry in leaf.get("face_appearances") or []:
            face = entry["face"]
            if face.get("body_id") == body_id and face.get("index") == face_index:
                layers.append(entry["appearance"])
        body_appearance = (leaf.get("body_appearances") or {}).get(body_id)
        if body_appearance:
            layers.append(body_appearance)
    if leaf.get("appearance"):
        layers.append(leaf["appearance"])
    return layers


def merge_layers(layers: list[dict]) -> dict:
    """Field by field, the first layer that sets a field wins. Only fields something sets are in the result."""
    out: dict = {}
    for layer in layers:
        for name in FIELDS:
            if name not in out and layer.get(name) is not None:
                out[name] = layer[name]
    return out


def resolve_appearance(
    model: dict,
    root_id: str,
    path: list[str],
    body_id: str | None = None,
    face_index: int | None = None,
    scene_overrides: list[dict] | None = None,
) -> dict:
    """The resolved appearance of one face (`body_id`, `face_index`) of the instance at `path` (occurrence path from
    `root_id`, `#pattern:` segments allowed; `[]` is the root's own bodies), as seen in `root_id`'s assembly with
    `scene_overrides` shown. Only the fields something sets; the renderer fills the rest from its default look."""
    return merge_layers(resolve_layers(model, root_id, path, body_id, face_index, scene_overrides))


def resolve_faces(
    model: dict,
    root_id: str,
    path: list[str],
    faces: list[tuple[str, int]],
    scene_overrides: list[dict] | None = None,
) -> dict[tuple[str, int], dict]:
    """`resolve_appearance` for many faces of one instance at once (what a renderer paints a whole mesh from): the
    node-level matches are found once, only the body / face entries are matched per face. Same answers, face by face
    (`backend/tests/test_appearance_resolution.py` checks it against `resolve_appearance`)."""
    chain = instance_chain(model, root_id, path)
    if chain is None:
        return {face: {} for face in faces}
    parts = model["parts"]
    lists: list[tuple[list[dict], list[str], list[str]]] = []
    if scene_overrides:
        lists.append((scene_overrides, path, chain[1:]))
    for k, part_id in enumerate(chain):
        lists.append((effective_overrides(parts[part_id]), path[k:], chain[k + 1 :]))
    node_matches = [_ordered_matches(records, suffix, suffix_parts, None, None) for records, suffix, suffix_parts in lists]
    subshape_records = [[r for r in records if r.get("face") or r.get("body_id")] for records, _s, _p in lists]
    leaf = parts[chain[-1]]
    leaf_faces = leaf.get("face_appearances") or []
    leaf_bodies = leaf.get("body_appearances") or {}
    out: dict[tuple[str, int], dict] = {}
    for body_id, face_index in faces:
        layers: list[dict] = []
        for position, (_records, suffix, suffix_parts) in enumerate(lists):
            if subshape_records[position]:
                layers += _ordered_matches(subshape_records[position], suffix, suffix_parts, body_id, face_index)
            layers += node_matches[position]
        for entry in leaf_faces:
            if entry["face"].get("body_id") == body_id and entry["face"].get("index") == face_index:
                layers.append(entry["appearance"])
        if leaf_bodies.get(body_id):
            layers.append(leaf_bodies[body_id])
        if leaf.get("appearance"):
            layers.append(leaf["appearance"])
        out[(body_id, face_index)] = merge_layers(layers)
    return out
