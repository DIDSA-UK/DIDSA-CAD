"""Occurrence paths from an assembly Part down to one placed instance (`outer/inner/leaf`, the mate convention), with
pattern copies named by their instance segment `<source>#pattern:<pattern id>:<index>` (the id `assembly-mesh.glb`
builds). Shared by the Appearance tool's overrides (`docs/appearance-tool-scope.md` D2) and scenes
(`docs/scenes-scope.md` D3, D8): resolving a stored path, and finding the paths a delete takes away.

Pure model code: no OCCT, no HTTP."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator

from app.document.appearance import PATTERN_SEGMENT, base_segment, split_path
from app.document.assembly import expand_component_pattern_instances
from app.document.models import Document, Part


def parse_pattern_segment(segment: str) -> tuple[str, str, int] | None:
    """`(source occurrence id, pattern id, index)` of a pattern-copy segment, or None for a plain occurrence id."""
    if PATTERN_SEGMENT not in segment:
        return None
    source, rest = segment.split(PATTERN_SEGMENT, 1)
    pattern_id, _, index = rest.rpartition(":")
    if not pattern_id or not index.lstrip("-").isdigit():
        return None
    return source, pattern_id, int(index)


@dataclass(frozen=True)
class PathResolution:
    """`part`: the Part the path ends on (None when the last occurrence is not resolved to a loaded Part, which is
    allowed for a whole-node target, as for mates). `error`: why the path does not resolve at all, else None."""

    part: Part | None = None
    error: str | None = None
    # The Part owning the last segment's occurrence (the one a `scope: "pattern"` override reads its pattern from).
    owner: Part | None = None


def resolve_path(document: Document, part: Part, path: str) -> PathResolution:
    """Walk `path` from `part`. Every segment's occurrence must exist (not suppressed) in the Part the previous one
    placed; a pattern-copy segment must name a live copy (its pattern exists and is not suppressed, the occurrence is
    one of its sources, the index is one the pattern currently derives). Only the last occurrence may be unresolved."""
    current: Part | None = part
    owner: Part | None = None
    segments = split_path(path)
    for position, segment in enumerate(segments):
        if current is None:
            return PathResolution(error="part_not_resolved")
        occurrence = next((o for o in current.occurrences if o.id == base_segment(segment)), None)
        if occurrence is None or occurrence.suppressed:
            return PathResolution(error="occurrence_not_found")
        copy = parse_pattern_segment(segment)
        if PATTERN_SEGMENT in segment:
            if copy is None:
                return PathResolution(error="pattern_copy_not_found")
            _, pattern_id, index = copy
            pattern = next((p for p in current.component_patterns if p.id == pattern_id), None)
            if (
                pattern is None
                or pattern.suppressed
                or occurrence.id not in pattern.source_occurrence_ids
                or index not in expand_component_pattern_instances(pattern, occurrence.transform)
            ):
                return PathResolution(error="pattern_copy_not_found")
        owner = current
        current = document.parts.get(occurrence.part_id) if occurrence.part_id else None
        if current is None and position < len(segments) - 1:
            return PathResolution(error="part_not_resolved")
    return PathResolution(part=current, owner=owner)


def walk_segments(document: Document, part: Part, path: str) -> Iterator[tuple[Part, str]]:
    """`(the Part a segment is read in, the segment)` along `path`, as far as it resolves (no validation)."""
    current: Part | None = part
    for segment in split_path(path):
        if current is None:
            return
        yield current, segment
        occurrence = next((o for o in current.occurrences if o.id == base_segment(segment)), None)
        current = document.parts.get(occurrence.part_id) if occurrence and occurrence.part_id else None


def path_goes_through(document: Document, part: Part, path: str, owner_id: str, occurrence_id: str) -> bool:
    """Whether `path` (from `part`) passes through the occurrence `occurrence_id` of the Part `owner_id` (itself or
    any pattern copy of it): the paths a delete of that occurrence takes away (the Mate cascade, scenes D8)."""
    return any(
        level.id == owner_id and base_segment(segment) == occurrence_id for level, segment in walk_segments(document, part, path)
    )


def path_uses_pattern(document: Document, part: Part, path: str, owner_id: str, pattern_id: str) -> bool:
    """Whether `path` (from `part`) passes through a copy of the pattern `pattern_id` of the Part `owner_id`."""
    for level, segment in walk_segments(document, part, path):
        copy = parse_pattern_segment(segment)
        if level.id == owner_id and copy is not None and copy[1] == pattern_id:
            return True
    return False


def last_segment_owner(document: Document, part: Part, path: str) -> Part | None:
    """The Part that owns the last segment of `path` (where a `scope: "pattern"` override's pattern lives)."""
    owner = None
    for level, _segment in walk_segments(document, part, path):
        owner = level
    return owner


def placements_of(document: Document, part: Part, target_part_id: str, ancestors: frozenset[str] = frozenset()) -> int:
    """How many times `target_part_id` is placed inside `part` at any depth (pattern copies counted), the size of an
    "Every <part> (N)" row."""
    count = 0
    child_ancestors = ancestors | {part.id}
    copies_by_source: dict[str, int] = {}
    for pattern in part.component_patterns:
        if pattern.suppressed:
            continue
        for source_id in pattern.source_occurrence_ids:
            source = next((o for o in part.occurrences if o.id == source_id), None)
            if source is not None:
                copies_by_source[source_id] = copies_by_source.get(source_id, 0) + len(
                    expand_component_pattern_instances(pattern, source.transform)
                )
    for occurrence in part.occurrences:
        if occurrence.suppressed or occurrence.part_id is None:
            continue
        child = document.parts.get(occurrence.part_id)
        if child is None or child.id in child_ancestors:
            continue
        copies = 1 + copies_by_source.get(occurrence.id, 0)
        if child.id == target_part_id:
            count += copies
        count += copies * placements_of(document, child, target_part_id, child_ancestors)
    return count
