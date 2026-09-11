"""Assembly support's core data-model invariant (`docs/assembly-scope.md`):
a `Part` can hold local Features and assembly structure (Occurrences/Mates)
*at the same time* - the NX-style "one file, features and assembly
structure side by side" model, not two mutually-exclusive node kinds. A
user models/imports local reference geometry (a fixture, a mounting boss)
via `features` in the very same file where they place and mate other Parts
as components via `occurrences`/`mates`.

Pure-Python, zero OCCT dependency (mirrors `test_stage_native_format.py`'s
own "runs for real in this sandbox" note) - constructs a Document/Part/
Feature/Occurrence/Mate tree directly, round-trips it through
`export_native`/`import_native` and a real `json.dumps`/`json.loads` cycle,
and asserts the result is equivalent to the original.
"""

import json

from app.document.models import (
    Document,
    ImportFeature,
    ImportSourceFormat,
    Mate,
    MateEntityRef,
    MateType,
    Occurrence,
    Part,
    RigidTransform,
    SubShapeRef,
    SubShapeType,
)
from app.document.native_format import SCHEMA_VERSION, export_native, import_native


def _mixed_part() -> Part:
    """A single Part with a local Feature (standing in for an imported
    mount/fixture, modelled in place - not an assembly component) plus two
    Occurrences of other files and a Mate between them - the exact scenario
    the assembly UI needs to support switching between a feature-tool lens
    and an assembly-tool lens on one open file."""
    part = Part(id="top-assembly", name="Top Assembly")
    part.features = [
        ImportFeature(id="feat-mount", source_format=ImportSourceFormat.STEP, source_data=b"mount-geometry"),
    ]
    part.occurrences = [
        Occurrence(
            id="occ-bolt-1",
            external_ref="parts/bolt.didsa",
            transform=RigidTransform(translation=(10.0, 0.0, 0.0), rotation_angle_degrees=45.0),
        ),
        Occurrence(id="occ-bracket-1", external_ref="parts/bracket.didsa"),
    ]
    part.mates = [
        Mate(
            id="mate-1",
            type=MateType.CONCENTRIC,
            references=[
                MateEntityRef(
                    occurrence_id="occ-bolt-1",
                    subshape_ref=SubShapeRef(body_id="body-1", shape_type=SubShapeType.FACE, index=0),
                ),
                MateEntityRef(
                    occurrence_id="occ-bracket-1",
                    subshape_ref=SubShapeRef(body_id="body-2", shape_type=SubShapeType.FACE, index=3),
                ),
            ],
        )
    ]
    return part


def test_a_part_holds_local_features_and_assembly_structure_simultaneously():
    part = _mixed_part()

    assert len(part.features) == 1
    assert part.features[0].type == "import"
    assert len(part.occurrences) == 2
    assert len(part.mates) == 1
    # Nothing about adding occurrences/mates disturbed the Feature list, and
    # vice versa - they're independent, coexisting fields on one Part.
    assert part.features[0].id == "feat-mount"


def test_mixed_part_round_trips_through_native_export_import_and_real_json():
    document = Document(id="doc-1")
    part = _mixed_part()
    document.parts[part.id] = part
    document.root_part_id = part.id

    exported = json.loads(json.dumps(export_native(document, {})))
    assert exported["schema_version"] == SCHEMA_VERSION
    assert exported["document"]["root_part_id"] == part.id

    part_dict = exported["document"]["parts"][0]
    assert len(part_dict["features"]) == 1
    assert len(part_dict["occurrences"]) == 2
    assert len(part_dict["mates"]) == 1
    # Occurrence.part_id is session-local only - never persisted on disk.
    assert "part_id" not in part_dict["occurrences"][0]
    assert part_dict["occurrences"][0]["external_ref"] == "parts/bolt.didsa"

    imported_document, _ = import_native(exported)
    imported_part = imported_document.parts[part.id]

    assert len(imported_part.features) == 1
    assert imported_part.features[0].type == "import"
    assert len(imported_part.occurrences) == 2
    assert imported_part.occurrences[0].external_ref == "parts/bolt.didsa"
    assert imported_part.occurrences[0].part_id is None
    assert imported_part.occurrences[0].transform.translation == (10.0, 0.0, 0.0)
    assert imported_part.occurrences[0].transform.rotation_angle_degrees == 45.0
    assert len(imported_part.mates) == 1
    assert imported_part.mates[0].type == MateType.CONCENTRIC
    assert imported_part.mates[0].references[1].subshape_ref.index == 3


def test_a_pre_assembly_file_with_no_occurrences_or_mates_keys_imports_with_empty_lists():
    """Backward compatibility: a file saved before assembly support existed
    has no `"occurrences"`/`"mates"` keys on its Part dicts at all - must
    import as empty lists, not raise. No SCHEMA_VERSION bump was needed for
    this (see that constant's own comment) since it's purely additive,
    exactly like every other evolutionary field this file already has."""
    payload = {
        "schema_version": SCHEMA_VERSION,
        "document": {
            "id": "legacy-doc",
            "parts": [{"id": "legacy-part", "name": "Legacy Part", "features": []}],
        },
        "sketches": [],
    }
    document, _ = import_native(payload)
    part = document.parts["legacy-part"]

    assert part.occurrences == []
    assert part.mates == []


def test_per_part_export_includes_both_features_and_assembly_structure_never_a_resolved_subtree():
    """`export_native(document, sketches, part_id=...)` - what saving one
    file in a multi-file assembly actually does - must include the target
    Part's own features AND its own occurrences/mates, but never resolve
    what an Occurrence's `external_ref` points at (that lives in its own
    separate file)."""
    document = Document(id="doc-2")
    part = _mixed_part()
    document.parts[part.id] = part
    referenced_part = Part(id="referenced", name="Bolt")
    document.parts[referenced_part.id] = referenced_part

    exported = export_native(document, {}, part_id=part.id)

    assert len(exported["document"]["parts"]) == 1
    exported_part = exported["document"]["parts"][0]
    assert exported_part["id"] == part.id
    assert len(exported_part["features"]) == 1
    assert len(exported_part["occurrences"]) == 2
    # The referenced Part (bolt.didsa's own content) must never be embedded
    # here - only its external_ref string appears, inside the occurrence.
    assert all(node["id"] != referenced_part.id for node in exported["document"]["parts"])


def test_root_part_id_is_none_for_a_document_with_no_explicit_root():
    document = Document(id="doc-3")
    part = Part(id="p1", name="P1")
    document.parts[part.id] = part

    exported = export_native(document, {})

    assert exported["document"]["root_part_id"] is None
    imported_document, _ = import_native(exported)
    assert imported_document.root_part_id is None
