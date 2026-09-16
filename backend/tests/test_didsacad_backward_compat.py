"""Assembly support Phase 9 (`docs/assembly-scope.md` §2l): the full
`.didsacad` backward-compat test matrix §3's original item 9 asked for -
consolidating and completing coverage of every additive field the assembly
effort (Phases 0-8) has ever added to the native file format, since
`SCHEMA_VERSION` has never bumped (`native_format.py`'s own comment on why:
every one of these fields is purely additive, read back via
`.get(key, default)`, so an older file simply lacks the key and imports
with a sensible default rather than needing a version branch).

`test_assembly_model.py`'s own `test_a_pre_assembly_file_with_no_
occurrences_or_mates_keys_imports_with_empty_lists` already covers the
single most basic case (a file predating assembly support entirely) - not
duplicated here. This file covers every other historical shape a real
`.didsa`/`.didsacad` file could have been saved with, phase by phase:

- Phase 0-1 vintage: `occurrences`/`mates` keys exist, but an individual
  Occurrence dict predates Phase 2's `resolved_part_id` wire field, and/or
  omits every other optional field (`external_ref`/`name_override`/
  `transform`/`suppressed`/`hidden`).
- Phase 0-6 vintage (predates Phase 7): real Occurrences/Mates, but no
  `component_patterns` key on the Part dict at all.
- Phase 6 vintage: a Mate dict with only its required fields, predating
  nothing schema-wise (Mate's shape hasn't changed since it shipped) but
  worth confirming its own optional fields default correctly regardless.
- Phase 7 vintage: a `ComponentPattern` dict missing every optional field,
  and a Circular one missing `axis` entirely (a real, still-safe-to-expand
  shape - `assembly.expand_component_pattern_instances` already defaults a
  `None` axis to the world Z axis through the origin).
- A composed multi-file payload predating Phase 0's own `root_part_id`
  field on `Document`.
- `_resolve_occurrence_part_ids`'s own real-world safety net: a
  `resolved_part_id` naming a Part not actually present in this import
  payload (the ordinary shape a single-file save/reload round trip
  produces, per `Occurrence.part_id`'s own docstring) is cleared to `None`,
  never trusted blindly.

Pure-Python, zero OCCT dependency, mirroring `test_assembly_model.py`'s own
"runs for real in this sandbox" note - constructs native-format dicts by
hand (the exact shape an old file on disk would have) and imports them
directly via `import_native`, rather than building today's dataclasses and
exporting them (which could never produce a dict missing a field this
codebase's own current dataclasses always populate)."""

from app.document.assembly import expand_component_pattern_instances
from app.document.models import ComponentPatternType, RigidTransform
from app.document.native_format import SCHEMA_VERSION, import_native


def _payload(parts: list[dict], *, root_part_id: str | None = "missing-key") -> dict:
    """Builds a minimal native-file payload around the given raw Part
    dicts. `root_part_id="missing-key"` (the default, a value no real Part
    id would ever equal) omits the key entirely rather than setting it to
    `None` - the actual pre-Phase-0 shape (the key never existed at all),
    distinct from setting it explicitly to `null`."""
    document: dict = {"id": "legacy-doc", "parts": parts}
    if root_part_id != "missing-key":
        document["root_part_id"] = root_part_id
    return {"schema_version": SCHEMA_VERSION, "document": document, "sketches": []}


# --- Phase 0-1 vintage: Occurrence predates Phase 2's resolved_part_id ------


def test_occurrence_missing_resolved_part_id_key_imports_with_part_id_none():
    """Phase 2 (`docs/assembly-scope.md` §2c) added `resolved_part_id` -
    a file saved before that fix simply has no such key on its Occurrence
    dicts. Must import with `part_id=None`, the same "unresolved" state a
    freshly-imported Occurrence always starts in, per that field's own
    docstring - never a `NativeFormatError` for a missing optional key."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1", "external_ref": "parts/bolt.didsa"}],
        "mates": [],
    }
    document, _ = import_native(_payload([part_dict]))
    occurrence = document.parts["top"].occurrences[0]

    assert occurrence.part_id is None
    assert occurrence.external_ref == "parts/bolt.didsa"


def test_occurrence_with_only_id_defaults_every_other_field():
    """The bare minimum an Occurrence dict could ever have (just its own
    required `id`) - every optional field must fall back to its documented
    default, matching a freshly-placed, never-yet-touched Occurrence."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-bare"}],
        "mates": [],
    }
    document, _ = import_native(_payload([part_dict]))
    occurrence = document.parts["top"].occurrences[0]

    assert occurrence.id == "occ-bare"
    assert occurrence.external_ref is None
    assert occurrence.name_override is None
    assert occurrence.part_id is None
    assert occurrence.suppressed is False
    assert occurrence.hidden is False
    assert occurrence.transform == RigidTransform.identity()


# --- Phase 0-6 vintage: predates Phase 7's component_patterns --------------


def test_a_part_with_real_occurrences_and_mates_but_no_component_patterns_key_imports_as_empty_list():
    """Phase 7 (`docs/assembly-scope.md` §2j) added `component_patterns` -
    a file saved by any build between Phase 0 and Phase 6 already has real
    `occurrences`/`mates` content, but its Part dicts have no
    `component_patterns` key at all yet."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1", "external_ref": "parts/bolt.didsa"}],
        "mates": [
            {
                "id": "mate-1",
                "type": "coincident",
                "references": [
                    {"occurrence_id": "occ-1", "subshape_ref": {"body_id": "b1", "shape_type": "face", "index": 0}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": "b2", "shape_type": "face", "index": 0}},
                ],
            }
        ],
    }
    document, _ = import_native(_payload([part_dict]))
    part = document.parts["top"]

    assert len(part.occurrences) == 1
    assert len(part.mates) == 1
    assert part.component_patterns == []


def test_mate_with_only_required_fields_defaults_value_flipped_suppressed():
    """A Mate dict carrying only its own required fields (`id`/`type`/
    `references`) - `value`/`flipped`/`suppressed` must all fall back to
    their documented defaults (unused/False/False)."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [],
        "mates": [
            {
                "id": "mate-bare",
                "type": "parallel",
                "references": [
                    {"occurrence_id": "", "subshape_ref": {"body_id": "b1", "shape_type": "face", "index": 0}},
                    {"occurrence_id": "", "subshape_ref": {"body_id": "b2", "shape_type": "face", "index": 0}},
                ],
            }
        ],
    }
    document, _ = import_native(_payload([part_dict]))
    mate = document.parts["top"].mates[0]

    assert mate.value is None
    assert mate.flipped is False
    assert mate.suppressed is False


# --- Phase 7 vintage: ComponentPattern's own optional fields ----------------


def test_component_pattern_with_only_required_fields_defaults_to_a_linear_identity_pattern():
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1"}],
        "mates": [],
        "component_patterns": [{"id": "pat-bare", "source_occurrence_ids": ["occ-1"]}],
    }
    document, _ = import_native(_payload([part_dict]))
    pattern = document.parts["top"].component_patterns[0]

    assert pattern.pattern_type == ComponentPatternType.LINEAR
    assert pattern.direction == (1.0, 0.0, 0.0)
    assert pattern.count == 1
    assert pattern.spacing == 0.0
    assert pattern.reverse is False
    assert pattern.axis is None
    assert pattern.count_angular == 1
    assert pattern.angle_total == 360.0
    assert pattern.reverse_angular is False
    assert pattern.suppressed is False


def test_circular_component_pattern_with_no_axis_key_imports_and_still_expands_safely():
    """A Circular `ComponentPattern` genuinely needs an axis to mean
    anything, but nothing in the wire format *requires* one - confirms this
    doesn't just import without crashing, but also still expands (via the
    real `assembly.expand_component_pattern_instances`, the same function
    `GET /assembly-mesh` calls) by falling back to the world Z axis through
    the origin, per that function's own documented default."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1"}],
        "mates": [],
        "component_patterns": [
            {
                "id": "pat-circular",
                "source_occurrence_ids": ["occ-1"],
                "pattern_type": "circular",
                "count_angular": 4,
                "angle_total": 360.0,
            }
        ],
    }
    document, _ = import_native(_payload([part_dict]))
    pattern = document.parts["top"].component_patterns[0]
    assert pattern.axis is None

    derived = expand_component_pattern_instances(pattern, RigidTransform.identity())

    assert len(derived) == 3  # count_angular=4 minus the untouched seed at index 0
    # A pure rotation about the world Z axis through the origin never moves
    # a source already sitting at the origin.
    for transform in derived:
        assert transform.translation == (0.0, 0.0, 0.0)


def test_component_pattern_axis_missing_direction_key_defaults_to_world_z():
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1"}],
        "mates": [],
        "component_patterns": [
            {
                "id": "pat-axis",
                "source_occurrence_ids": ["occ-1"],
                "pattern_type": "circular",
                "count_angular": 2,
                "axis": {"origin": [5.0, 0.0, 0.0]},
            }
        ],
    }
    document, _ = import_native(_payload([part_dict]))
    axis = document.parts["top"].component_patterns[0].axis

    assert axis is not None
    assert axis.origin == (5.0, 0.0, 0.0)
    assert axis.direction == (0.0, 0.0, 1.0)


# --- Document-level: root_part_id predates Phase 0's own optional field ----


def test_a_composed_payload_missing_root_part_id_key_imports_with_root_part_id_none():
    part_dict = {"id": "top", "name": "Top", "features": [], "occurrences": [], "mates": []}
    document, _ = import_native(_payload([part_dict], root_part_id="missing-key"))

    assert document.root_part_id is None


# --- resolved_part_id's own real safety net ---------------------------------


def test_resolved_part_id_naming_a_part_not_in_this_payload_is_cleared_to_none():
    """`Occurrence.part_id`'s own docstring: a single-file save's Occurrence
    targets necessarily live in other files, not in that solo payload - so
    a `resolved_part_id` surviving from a prior composed-graph save must be
    cleared back to `None` on a standalone reimport, never trusted blindly
    (the two-pass `_resolve_occurrence_part_ids` validation this whole
    mechanism depends on)."""
    part_dict = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [
            {"id": "occ-1", "external_ref": "parts/bolt.didsa", "resolved_part_id": "bolt-part-not-in-this-file"}
        ],
        "mates": [],
    }
    document, _ = import_native(_payload([part_dict]))

    assert document.parts["top"].occurrences[0].part_id is None


def test_resolved_part_id_naming_a_part_actually_present_in_the_same_payload_is_trusted():
    top = {
        "id": "top",
        "name": "Top",
        "features": [],
        "occurrences": [{"id": "occ-1", "external_ref": "parts/bolt.didsa", "resolved_part_id": "bolt"}],
        "mates": [],
    }
    bolt = {"id": "bolt", "name": "Bolt", "features": []}
    document, _ = import_native(_payload([top, bolt], root_part_id="top"))

    assert document.parts["top"].occurrences[0].part_id == "bolt"


# --- Mixed-vintage payload: old and current Parts imported together --------


def test_a_single_import_mixing_every_vintage_of_part_dict_imports_all_of_them_correctly():
    """The realistic worst case: one multi-file assembly graph composed from
    files saved at very different points in this feature's own history -
    confirms importing them together in one call doesn't let one Part's
    older/missing keys bleed into another's."""
    pre_assembly_part = {"id": "pre-assembly", "name": "Pre-assembly Part", "features": []}
    pre_pattern_part = {
        "id": "pre-pattern",
        "name": "Pre-pattern Part",
        "features": [],
        "occurrences": [{"id": "occ-1"}],
        "mates": [],
    }
    current_part = {
        "id": "current",
        "name": "Current Part",
        "features": [],
        "occurrences": [{"id": "occ-2"}],
        "mates": [],
        "component_patterns": [{"id": "pat-1", "source_occurrence_ids": ["occ-2"], "count": 3}],
    }

    document, _ = import_native(_payload([pre_assembly_part, pre_pattern_part, current_part], root_part_id="current"))

    assert document.parts["pre-assembly"].occurrences == []
    assert document.parts["pre-assembly"].mates == []
    assert document.parts["pre-assembly"].component_patterns == []

    assert len(document.parts["pre-pattern"].occurrences) == 1
    assert document.parts["pre-pattern"].component_patterns == []

    assert len(document.parts["current"].component_patterns) == 1
    assert document.parts["current"].component_patterns[0].count == 3
