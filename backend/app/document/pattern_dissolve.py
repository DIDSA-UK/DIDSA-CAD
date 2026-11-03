"""Dissolve a component pattern (`docs/pattern-followers-and-dissolve-plan.md`, F2): every live copy becomes a real
`Occurrence` at exactly the copy's pose, everything stored against a copy (mates, appearance overrides, scene overrides, in
EVERY Part of the document) is re-pointed at the new occurrence, the pattern's `scope: "pattern"` appearance overrides become
plain per-occurrence overrides, and the pattern goes. Nothing visibly moves.

Pure model code (no HTTP): `dissolve_component_pattern` raises `PatternDissolveError` and leaves the document untouched when
the pattern cannot be dissolved or a rewritten reference no longer resolves."""

from __future__ import annotations

import uuid
from dataclasses import replace
from typing import Callable

from app.document.appearance import PATTERN_SEGMENT, SCOPE_PATTERN, Appearance
from app.document.assembly import expand_component_pattern_instances
from app.document.models import (
    AppearanceOverride,
    ComponentPattern,
    Document,
    Mate,
    MateEntityRef,
    MidplaneRef,
    Occurrence,
    Part,
)
from app.document.occurrence_paths import last_segment_owner, rewrite_segments


class PatternDissolveError(Exception):
    """The pattern cannot be dissolved (suppressed, or a rewritten reference would not resolve)."""


def copy_segment(source_id: str, pattern_id: str, index: int) -> str:
    return f"{source_id}{PATTERN_SEGMENT}{pattern_id}:{index}"


def _new_name(source: Occurrence, index: int) -> str | None:
    """B4 naming: no source override -> None (the tree shows `<file>:<n>`); an override -> `"<override> (n)"`, n = index + 1."""
    return f"{source.name_override} ({index + 1})" if source.name_override else None


def _fill(primary: Appearance, fallback: Appearance) -> Appearance:
    """`primary`'s fields, the ones it leaves unset taken from `fallback` (a named path beats `scope: "pattern"` field by field)."""
    merged = {name: (value if value is not None else getattr(fallback, name)) for name, value in primary.__dict__.items()}
    return Appearance(**merged)


def _target_key(o: AppearanceOverride) -> tuple:
    return (o.path, o.scope, o.pattern_id, o.part_id, o.body_id, o.face.index if o.face is not None else None)


_ATTRS = ("occurrences", "component_patterns", "mates", "appearance_overrides", "scenes")


def dissolve_component_pattern(
    document: Document,
    part: Part,
    pattern: ComponentPattern,
    check_mate_path: Callable[[Part, str], None],
) -> tuple[list[Occurrence], dict[str, str]]:
    """Dissolves `pattern` of `part` in place. Returns `(the new occurrences in tree order, {old copy segment: new id})`.
    `check_mate_path(owner_part, path)` must raise (anything) when a mate path no longer resolves: the whole dissolve is then
    undone and `PatternDissolveError` raised."""
    if pattern.suppressed:
        raise PatternDissolveError("A suppressed pattern has no live copies to dissolve")
    snapshot = {p.id: {attr: list(getattr(p, attr)) for attr in _ATTRS} for p in document.parts.values()}
    try:
        created, renames = _dissolve(document, part, pattern, check_mate_path)
    except Exception as error:
        for p in document.parts.values():
            for attr, value in snapshot.get(p.id, {}).items():
                setattr(p, attr, value)
        if isinstance(error, PatternDissolveError):
            raise
        raise PatternDissolveError(str(error)) from error
    return created, renames


def _dissolve(
    document: Document, part: Part, pattern: ComponentPattern, check_mate_path: Callable[[Part, str], None]
) -> tuple[list[Occurrence], dict[str, str]]:
    by_id = {o.id: o for o in part.occurrences}
    created_by_source: dict[str, list[tuple[int, Occurrence]]] = {}
    renames: dict[str, str] = {}
    for source_id in pattern.source_occurrence_ids:
        source = by_id.get(source_id)
        if source is None or source.suppressed:
            continue  # its copies were never live
        for index, pose in sorted(expand_component_pattern_instances(pattern, source.transform).items()):
            occurrence = Occurrence(
                id=str(uuid.uuid4()),
                part_id=source.part_id,
                external_ref=source.external_ref,
                name_override=_new_name(source, index),
                transform=pose,
                suppressed=False,
                hidden=source.hidden,
                fixed=False,  # never inherited: a dissolved copy floats
                color=source.color,  # the instance colour a copy already carries (`get_assembly_mesh`)
                ref_part_id=source.ref_part_id,
            )
            created_by_source.setdefault(source_id, []).append((index, occurrence))
            renames[copy_segment(source_id, pattern.id, index)] = occurrence.id

    # Appearance overrides first, while every old copy segment still resolves through its source (walk_segments).
    # pattern-scope overrides of this pattern are read BEFORE any path is rewritten, then split.
    for owner in document.parts.values():
        _rewrite_appearance(document, owner, part, pattern, created_by_source, renames)
        _rewrite_scenes(document, owner, part, renames)
        _rewrite_mates(document, owner, part, renames)

    new_list: list[Occurrence] = []
    for occurrence in part.occurrences:
        new_list.append(occurrence)
        new_list.extend(new for _index, new in created_by_source.get(occurrence.id, []))
    part.occurrences = new_list
    part.component_patterns = [p for p in part.component_patterns if p.id != pattern.id]

    for owner in document.parts.values():
        for mate in owner.mates:
            for ref in mate.references:
                paths = [ref.occurrence_id]
                if ref.midplane is not None and ref.midplane.b_occurrence_id is not None:
                    paths.append(ref.midplane.b_occurrence_id)
                for path in paths:
                    check_mate_path(owner, path)
    return [new for source in part.occurrences for _i, new in created_by_source.get(source.id, [])], renames


def _rewrite_mates(document: Document, owner: Part, part: Part, renames: dict[str, str]) -> None:
    def rewrite(path: str) -> str:
        return rewrite_segments(document, owner, path, part.id, renames)

    mates: list[Mate] = []
    for mate in owner.mates:
        refs: list[MateEntityRef] = []
        for ref in mate.references:
            midplane = ref.midplane
            if midplane is not None and midplane.b_occurrence_id is not None:
                midplane = MidplaneRef(a=midplane.a, b=midplane.b, b_occurrence_id=rewrite(midplane.b_occurrence_id))
            refs.append(replace(ref, occurrence_id=rewrite(ref.occurrence_id), midplane=midplane))
        mates.append(replace(mate, references=refs))
    owner.mates = mates


def _rewrite_scenes(document: Document, owner: Part, part: Part, renames: dict[str, str]) -> None:
    owner.scenes = [
        replace(scene, overrides=[replace(o, path=rewrite_segments(document, owner, o.path, part.id, renames)) for o in scene.overrides])
        for scene in owner.scenes
    ]


def _rewrite_appearance(
    document: Document,
    owner: Part,
    part: Part,
    pattern: ComponentPattern,
    created_by_source: dict[str, list[tuple[int, Occurrence]]],
    renames: dict[str, str],
) -> None:
    kept: list[AppearanceOverride] = []
    pending: list[AppearanceOverride] = []  # the plain overrides a split pattern-scope override turns into
    for o in owner.appearance_overrides:
        if o.scope == SCOPE_PATTERN and o.pattern_id == pattern.id:
            pattern_owner = last_segment_owner(document, owner, o.path)
            if pattern_owner is not None and pattern_owner.id == part.id:
                prefix, _, source_segment = o.path.rpartition("/")
                targets = [source_segment, *(renames[copy_segment(source_segment, pattern.id, i)] for i, _n in created_by_source.get(source_segment, []))]
                for target in targets:
                    pending.append(replace(o, path=f"{prefix}/{target}" if prefix else target, scope=None, pattern_id=None))
                continue
        kept.append(replace(o, path=rewrite_segments(document, owner, o.path, part.id, renames)))
    # merge: a node that already has its own override at the same target keeps its fields and takes the rest from the split one
    index_by_key = {_target_key(o): i for i, o in enumerate(kept)}
    for split in pending:
        key = _target_key(split)
        if key in index_by_key:
            existing = kept[index_by_key[key]]
            kept[index_by_key[key]] = replace(existing, appearance=_fill(existing.appearance, split.appearance))
        else:
            index_by_key[key] = len(kept)
            kept.append(split)
    owner.appearance_overrides = kept
