"""Assembly support Phase 5 (`docs/assembly-scope.md`): `PATCH
/parts/{part_id}/occurrences/{occurrence_id}` - the first mutation
endpoint an Occurrence has ever had, added specifically so the Move/Rotate
gizmo has somewhere real to persist a drag to. Mirrors
`test_assembly_tree_endpoints.py`'s own setup helpers/composed-payload
convention.

Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read)."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _import_composed(payload: dict) -> None:
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200


def _setup_top_with_one_occurrence(*, fixed: bool = False) -> tuple[str, str]:
    """Returns (top_part_id, occurrence_id) - a Top Part with one real
    Occurrence (`occ-bolt-1`, placing a Bolt Part) already imported,
    mirroring `test_assembly_tree_endpoints.py`'s own composed-payload
    setup."""
    top = _create_part("Top")
    bolt = _create_part("Bolt")
    top_export = _export_part(top["id"])
    bolt_export = _export_part(bolt["id"])
    top_part_dict = top_export["document"]["parts"][0]
    top_part_dict["occurrences"] = [
        {
            "id": "occ-bolt-1",
            "external_ref": "parts/bolt.didsa",
            "resolved_part_id": bolt["id"],
            "name_override": None,
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
            "fixed": fixed,
        }
    ]
    top_part_dict["mates"] = []
    composed_payload = {
        "schema_version": top_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": top["id"],
            "parts": [top_part_dict, bolt_export["document"]["parts"][0]],
        },
        "sketches": [],
    }
    _import_composed(composed_payload)
    return top["id"], "occ-bolt-1"


def test_patching_the_transform_updates_it_and_returns_the_full_occurrence():
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [5.0, 1.0, -2.0],
                "rotation_axis": [0.0, 1.0, 0.0],
                "rotation_angle_degrees": 90.0,
            }
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == occurrence_id
    assert body["transform"]["translation"] == [5.0, 1.0, -2.0]
    assert body["transform"]["rotation_axis"] == [0.0, 1.0, 0.0]
    assert body["transform"]["rotation_angle_degrees"] == 90.0
    # Every other field is untouched by a transform-only PATCH.
    assert body["name_override"] is None
    assert body["suppressed"] is False
    assert body["hidden"] is False


def test_the_updated_transform_is_visible_on_a_subsequent_get_and_export():
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [3.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 45.0,
            }
        },
    )

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    updated = next(o for o in occurrences if o["id"] == occurrence_id)
    assert updated["transform"]["translation"] == [3.0, 0.0, 0.0]
    assert updated["transform"]["rotation_angle_degrees"] == 45.0

    exported = _export_part(top_id)
    exported_occurrence = exported["document"]["parts"][0]["occurrences"][0]
    assert exported_occurrence["transform"]["translation"] == [3.0, 0.0, 0.0]
    assert exported_occurrence["transform"]["rotation_angle_degrees"] == 45.0


def test_patching_an_unknown_part_returns_404():
    response = client.patch(
        "/document/parts/does-not-exist/occurrences/occ-1",
        json={
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 404


def test_patching_an_unknown_occurrence_on_a_real_part_returns_404():
    top = _create_part("Lonely Top")
    response = client.patch(
        f"/document/parts/{top['id']}/occurrences/does-not-exist",
        json={
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 404


def test_patching_hidden_only_leaves_transform_untouched():
    """Phase 8 (`docs/assembly-scope.md` §2k): `OccurrenceTransformUpdate`
    widened to accept `hidden`, both fields now omitted-means-unchanged - a
    `hidden`-only PATCH (no `transform` key at all) must not reset the
    Occurrence's transform to identity or otherwise touch it."""
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [4.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"hidden": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["hidden"] is True
    assert body["transform"]["translation"] == [4.0, 0.0, 0.0]


def test_patching_transform_only_leaves_hidden_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(f"/document/parts/{top_id}/occurrences/{occurrence_id}", json={"hidden": True})

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [1.0, 2.0, 3.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["hidden"] is True
    assert body["transform"]["translation"] == [1.0, 2.0, 3.0]


def test_patching_leaves_every_other_occurrence_summary_field_alone():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    part_response = client.get(f"/document/parts/{top_id}").json()
    assert part_response["occurrence_ids"] == [occurrence_id]

    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [9.0, 9.0, 9.0],
                "rotation_axis": [1.0, 0.0, 0.0],
                "rotation_angle_degrees": 30.0,
            }
        },
    )

    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert len(occurrences) == 1
    assert occurrences[0]["transform"]["translation"] == [9.0, 9.0, 9.0]


def test_patching_a_nonzero_rotation_angle_with_a_zero_length_axis_is_rejected():
    """§6 roadmap Phase 10 (`[4]`): `_validate_occurrence_transform_payload`
    mirrors `_validate_move_body_payload`'s own guard - a rotation angle with
    no real axis to rotate around is rejected outright, rather than silently
    persisted as a no-op rotation."""
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [1.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 0.0],
                "rotation_angle_degrees": 45.0,
            }
        },
    )
    assert response.status_code == 422


def test_patching_a_zero_rotation_angle_with_a_zero_length_axis_is_allowed():
    """The zero-length axis is only rejected when it would actually be asked
    to do something - a zero angle (the common translate-only case) is fine
    regardless of what `rotation_axis` happens to carry."""
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [1.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 0.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 200
    assert response.json()["transform"]["translation"] == [1.0, 0.0, 0.0]


def test_patching_a_nonzero_rotation_angle_with_a_real_axis_is_allowed():
    top_id, occurrence_id = _setup_top_with_one_occurrence()

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [0.0, 0.0, 0.0],
                "rotation_axis": [0.0, 1.0, 0.0],
                "rotation_angle_degrees": 45.0,
            }
        },
    )
    assert response.status_code == 200
    assert response.json()["transform"]["rotation_angle_degrees"] == 45.0


# Bug report (assembly testing): "Long pressing a part in the assembly tree
# should offer the option to fix/float" - `OccurrenceTransformUpdate.fixed`,
# `OccurrenceResponse.fixed`, and the `occurrence_is_fixed` 422 guard both
# `update_occurrence_transform` and `solve_for_occurrence` now enforce.


def test_patching_fixed_only_leaves_transform_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [4.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"fixed": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["fixed"] is True
    assert body["transform"]["translation"] == [4.0, 0.0, 0.0]


def test_patching_transform_on_a_fixed_occurrence_is_rejected():
    top_id, occurrence_id = _setup_top_with_one_occurrence(fixed=True)

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [1.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "occurrence_is_fixed"

    # Rejected before any mutation - the transform stays exactly as seeded.
    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    unchanged = next(o for o in occurrences if o["id"] == occurrence_id)
    assert unchanged["transform"]["translation"] == [0.0, 0.0, 0.0]


def test_patching_transform_together_with_fixed_true_is_rejected():
    top_id, occurrence_id = _setup_top_with_one_occurrence(fixed=False)

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [1.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "fixed": True,
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "occurrence_is_fixed"


def test_patching_transform_together_with_fixed_false_on_an_already_fixed_occurrence_is_allowed():
    """`{transform, fixed: false}` in the same call - unfixing and
    repositioning in one round trip - is the one case a `fixed` Occurrence's
    `transform` may still change, since the request's own *effective*
    `fixed` (what it's about to become, not what it currently is) is what
    the guard checks."""
    top_id, occurrence_id = _setup_top_with_one_occurrence(fixed=True)

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [2.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "fixed": False,
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["fixed"] is False
    assert body["transform"]["translation"] == [2.0, 0.0, 0.0]


def test_solving_a_fixed_occurrence_is_rejected():
    top_id, occurrence_id = _setup_top_with_one_occurrence(fixed=True)

    response = client.post(f"/document/parts/{top_id}/occurrences/{occurrence_id}/solve")
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "occurrence_is_fixed"


# --- Bug report (assembly testing): the colour-disc's own `color` field --


def test_a_fresh_occurrence_reports_no_colour_override():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert occurrences[0]["id"] == occurrence_id
    assert occurrences[0]["color"] is None


def test_patching_color_only_leaves_transform_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [4.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": "#FF8800"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["color"] == "#FF8800"
    assert body["transform"]["translation"] == [4.0, 0.0, 0.0]


def test_omitting_color_leaves_the_current_override_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": "#00FF00"},
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"hidden": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["hidden"] is True
    assert body["color"] == "#00FF00"


def test_an_empty_string_color_explicitly_clears_the_override():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": "#00FF00"},
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": ""},
    )

    assert response.status_code == 200
    assert response.json()["color"] is None


def test_color_survives_a_native_export_import_round_trip():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": "#123456"},
    )

    exported = _export_part(top_id)
    exported_occurrence = exported["document"]["parts"][0]["occurrences"][0]
    assert exported_occurrence["color"] == "#123456"

    _import_composed(exported)
    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert occurrences[0]["color"] == "#123456"


def test_assembly_mesh_instance_reports_the_occurrence_color():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"color": "#ABCDEF"},
    )

    mesh = client.get(f"/document/parts/{top_id}/assembly-mesh").json()
    bolt_instance = next(i for i in mesh["instances"] if i["occurrence_path"] == [occurrence_id])
    assert bolt_instance["color"] == "#ABCDEF"
    # The root Part's own local-content instance (occurrence_path == [])
    # has no Occurrence of its own to carry a colour override.
    root_instance = next(i for i in mesh["instances"] if i["occurrence_path"] == [])
    assert root_instance["color"] is None


# --- Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
# §3.2): the assembly tree's own Rename action, `name_override` ---


def test_patching_name_override_only_leaves_transform_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={
            "transform": {
                "translation": [4.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            }
        },
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"name_override": "Left Bolt"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["name_override"] == "Left Bolt"
    assert body["transform"]["translation"] == [4.0, 0.0, 0.0]


def test_omitting_name_override_leaves_the_current_one_untouched():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"name_override": "Left Bolt"},
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"hidden": True},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["hidden"] is True
    assert body["name_override"] == "Left Bolt"


def test_an_empty_string_name_override_explicitly_clears_it():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"name_override": "Left Bolt"},
    )

    response = client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"name_override": ""},
    )

    assert response.status_code == 200
    assert response.json()["name_override"] is None


def test_name_override_survives_a_native_export_import_round_trip():
    top_id, occurrence_id = _setup_top_with_one_occurrence()
    client.patch(
        f"/document/parts/{top_id}/occurrences/{occurrence_id}",
        json={"name_override": "Left Bolt"},
    )

    exported = _export_part(top_id)
    exported_occurrence = exported["document"]["parts"][0]["occurrences"][0]
    assert exported_occurrence["name_override"] == "Left Bolt"

    _import_composed(exported)
    occurrences = client.get(f"/document/parts/{top_id}/occurrences").json()
    assert occurrences[0]["name_override"] == "Left Bolt"


# --- Save/project overhaul Phase 2: `update_part`'s own new `name` field ---


def test_patching_part_name_updates_it_and_leaves_other_metadata_alone():
    part = _create_part("Bracket")
    client.patch(f"/document/parts/{part['id']}", json={"description": "A bracket"})

    response = client.patch(f"/document/parts/{part['id']}", json={"name": "Bracket v2"})

    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "Bracket v2"
    assert body["description"] == "A bracket"


def test_omitting_name_leaves_the_current_one_untouched():
    part = _create_part("Bracket")

    response = client.patch(f"/document/parts/{part['id']}", json={"description": "A bracket"})

    assert response.status_code == 200
    assert response.json()["name"] == "Bracket"


def test_patching_an_empty_or_whitespace_only_name_is_rejected():
    part = _create_part("Bracket")

    response = client.patch(f"/document/parts/{part['id']}", json={"name": "   "})

    assert response.status_code == 422
    # Rejected before anything else in the payload was applied.
    assert client.get(f"/document/parts/{part['id']}").json()["name"] == "Bracket"


def test_patching_name_strips_surrounding_whitespace():
    part = _create_part("Bracket")

    response = client.patch(f"/document/parts/{part['id']}", json={"name": "  Bracket v2  "})

    assert response.status_code == 200
    assert response.json()["name"] == "Bracket v2"
