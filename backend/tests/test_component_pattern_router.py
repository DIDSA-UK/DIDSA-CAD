"""Phase 7 (`docs/assembly-scope.md` §3 item 7): real-OCCT tests for
`ComponentPattern` CRUD (`POST`/`PATCH`/`DELETE`/`GET .../component-patterns`)
and its expansion into `GET /parts/{part_id}/assembly-mesh`'s own `instances`
list - mirrors `test_assembly_mesh.py`'s "build real geometry via the API,
compose a multi-part scene via `export` + edit + `import`" convention for
setting up Occurrences (there is still no `POST` to create an Occurrence
directly - only a composed `import/native` call establishes one).

Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read)."""

import math

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> None:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201


def _make_box_part(name: str, *, size: float = 10.0) -> dict:
    part = _create_part(name)
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    corners = [_add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])
    extrude_response = client.post(
        f"/document/parts/{part['id']}/extrude-features",
        json={
            "sketch_feature_id": sketch_response.json()["id"],
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 10.0,
            "target_body_ids": [],
        },
    )
    assert extrude_response.status_code == 201
    return {"id": part["id"]}


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _occurrence_dict(occurrence_id: str, resolved_part_id: str, translation=(0.0, 0.0, 0.0), *, hidden=False, suppressed=False) -> dict:
    return {
        "id": occurrence_id,
        "external_ref": f"parts/{resolved_part_id}.didsa",
        "resolved_part_id": resolved_part_id,
        "name_override": None,
        "transform": {
            "translation": list(translation),
            "rotation_axis": [0.0, 0.0, 1.0],
            "rotation_angle_degrees": 0.0,
        },
        "suppressed": suppressed,
        "hidden": hidden,
    }


def _compose(root_id: str, root_occurrences: list[dict], *other_part_ids: str, component_patterns: list[dict] | None = None) -> None:
    """Composes `root_id` (with `root_occurrences`/`component_patterns` set
    directly on its own exported dict, the same hand-built-composed-payload
    technique `test_assembly_mesh.py` already uses) plus every other Part in
    `other_part_ids`, and imports the result as one session - after this,
    `root_id`'s own occurrences/component-patterns are real, queryable via
    the normal endpoints."""
    root_export = _export_part(root_id)
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = root_occurrences
    root_dict["mates"] = []
    root_dict["component_patterns"] = component_patterns or []
    sketches = list(root_export["sketches"])
    parts = [root_dict]
    for other_id in other_part_ids:
        other_export = _export_part(other_id)
        parts.append(other_export["document"]["parts"][0])
        sketches.extend(other_export["sketches"])
    payload = {
        "schema_version": root_export["schema_version"],
        "document": {"id": "composed-doc", "root_part_id": root_id, "parts": parts},
        "sketches": sketches,
    }
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200


def _assembly_mesh(part_id: str) -> dict:
    response = client.get(f"/document/parts/{part_id}/assembly-mesh")
    assert response.status_code == 200
    return response.json()


# --- CRUD --------------------------------------------------------------


def test_create_list_update_delete_component_pattern_round_trip():
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)
    _compose(mount["id"], [_occurrence_dict("occ-bolt-1", bolt["id"])], bolt["id"])

    create_response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-bolt-1"],
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 3,
            "spacing": 10.0,
        },
    )
    assert create_response.status_code == 201
    pattern = create_response.json()
    assert pattern["source_occurrence_ids"] == ["occ-bolt-1"]
    assert pattern["pattern_type"] == "linear"
    assert pattern["count"] == 3

    list_response = client.get(f"/document/parts/{mount['id']}/component-patterns")
    assert list_response.status_code == 200
    assert [p["id"] for p in list_response.json()] == [pattern["id"]]

    part_response = client.get(f"/document/parts/{mount['id']}").json()
    assert part_response["component_pattern_ids"] == [pattern["id"]]

    update_response = client.patch(
        f"/document/parts/{mount['id']}/component-patterns/{pattern['id']}",
        json={"count": 5, "spacing": 20.0},
    )
    assert update_response.status_code == 200
    updated = update_response.json()
    assert updated["count"] == 5
    assert updated["spacing"] == 20.0
    assert updated["pattern_type"] == "linear"

    delete_response = client.delete(f"/document/parts/{mount['id']}/component-patterns/{pattern['id']}")
    assert delete_response.status_code == 204
    assert client.get(f"/document/parts/{mount['id']}/component-patterns").json() == []


def test_update_unknown_component_pattern_404s():
    mount = _make_box_part("Mount Solo")
    response = client.patch(f"/document/parts/{mount['id']}/component-patterns/does-not-exist", json={"count": 3})
    assert response.status_code == 404


def test_delete_unknown_component_pattern_404s():
    mount = _make_box_part("Mount Solo 2")
    response = client.delete(f"/document/parts/{mount['id']}/component-patterns/does-not-exist")
    assert response.status_code == 404


# --- Validation ----------------------------------------------------------


def test_create_component_pattern_rejects_unknown_source_occurrence():
    mount = _make_box_part("Mount Validation 1")
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": ["does-not-exist"], "pattern_type": "linear", "count": 3, "spacing": 5.0},
    )
    assert response.status_code == 422


def test_create_component_pattern_rejects_empty_source_occurrence_ids():
    mount = _make_box_part("Mount Validation 2")
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": [], "pattern_type": "linear", "count": 3, "spacing": 5.0},
    )
    assert response.status_code == 422


def test_create_linear_component_pattern_rejects_zero_direction():
    mount = _make_box_part("Mount Validation 3")
    bolt = _make_box_part("Bolt Validation 3")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "direction": [0.0, 0.0, 0.0],
            "count": 3,
            "spacing": 5.0,
        },
    )
    assert response.status_code == 422


def test_create_linear_component_pattern_rejects_count_below_two():
    mount = _make_box_part("Mount Validation 4")
    bolt = _make_box_part("Bolt Validation 4")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": ["occ-1"], "pattern_type": "linear", "count": 1, "spacing": 5.0},
    )
    assert response.status_code == 422


# --- Bug report (assembly testing): the optional second direction ------


def test_create_linear_component_pattern_accepts_count_one_when_count_2_supplies_the_second_instance():
    """`count`/`count_2` need only their *product* to be >= 2, mirroring
    `PatternFeature`'s own `count_1 * count_2` rule - a 1xN grid (this
    pattern's own `count == 1`) is valid as long as `count_2 > 1`."""
    mount = _make_box_part("Mount 2D Validation 1")
    bolt = _make_box_part("Bolt 2D Validation 1")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "count": 1,
            "direction_2": [0.0, 1.0, 0.0],
            "count_2": 2,
            "spacing_2": 5.0,
        },
    )
    assert response.status_code == 201


def test_create_linear_component_pattern_rejects_zero_direction_2_when_count_2_above_one():
    mount = _make_box_part("Mount 2D Validation 2")
    bolt = _make_box_part("Bolt 2D Validation 2")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 3,
            "spacing": 10.0,
            "direction_2": [0.0, 0.0, 0.0],
            "count_2": 2,
            "spacing_2": 5.0,
        },
    )
    assert response.status_code == 422


def test_component_pattern_direction_2_round_trips_through_create_and_update():
    mount = _make_box_part("Mount 2D Validation 3")
    bolt = _make_box_part("Bolt 2D Validation 3")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    create_response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 3,
            "spacing": 10.0,
            "direction_2": [0.0, 1.0, 0.0],
            "count_2": 2,
            "spacing_2": 5.0,
            "reverse_2": True,
        },
    )
    assert create_response.status_code == 201
    pattern = create_response.json()
    assert pattern["direction_2"] == [0.0, 1.0, 0.0]
    assert pattern["count_2"] == 2
    assert pattern["spacing_2"] == 5.0
    assert pattern["reverse_2"] is True

    update_response = client.patch(
        f"/document/parts/{mount['id']}/component-patterns/{pattern['id']}",
        json={"count_2": 4, "spacing_2": 8.0},
    )
    assert update_response.status_code == 200
    updated = update_response.json()
    assert updated["count_2"] == 4
    assert updated["spacing_2"] == 8.0
    # Fields not named in the PATCH stay untouched.
    assert updated["direction_2"] == [0.0, 1.0, 0.0]
    assert updated["reverse_2"] is True


def test_create_circular_component_pattern_rejects_count_angular_below_two():
    mount = _make_box_part("Mount Validation 5")
    bolt = _make_box_part("Bolt Validation 5")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": ["occ-1"], "pattern_type": "circular", "count_angular": 1, "angle_total": 360.0},
    )
    assert response.status_code == 422


def test_create_circular_component_pattern_rejects_angle_total_out_of_range():
    mount = _make_box_part("Mount Validation 6")
    bolt = _make_box_part("Bolt Validation 6")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": ["occ-1"], "pattern_type": "circular", "count_angular": 4, "angle_total": 400.0},
    )
    assert response.status_code == 422


def test_create_component_pattern_rejects_skip_index_zero():
    mount = _make_box_part("Mount Validation Skip 1")
    bolt = _make_box_part("Bolt Validation Skip 1")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "count": 3,
            "spacing": 5.0,
            "skip_indices": [0],
        },
    )
    assert response.status_code == 422


def test_create_component_pattern_rejects_skip_index_at_or_above_count():
    mount = _make_box_part("Mount Validation Skip 2")
    bolt = _make_box_part("Bolt Validation Skip 2")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "count": 3,
            "spacing": 5.0,
            "skip_indices": [3],
        },
    )
    assert response.status_code == 422


def test_create_circular_component_pattern_rejects_skip_index_at_or_above_count_angular():
    mount = _make_box_part("Mount Validation Skip 3")
    bolt = _make_box_part("Bolt Validation Skip 3")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    response = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "circular",
            "count_angular": 4,
            "angle_total": 360.0,
            "skip_indices": [4],
        },
    )
    assert response.status_code == 422


def test_update_component_pattern_omitted_skip_indices_leaves_current_set_untouched():
    mount = _make_box_part("Mount Validation Skip 4")
    bolt = _make_box_part("Bolt Validation Skip 4")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    created = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-1"],
            "pattern_type": "linear",
            "count": 4,
            "spacing": 5.0,
            "skip_indices": [2],
        },
    ).json()
    assert created["skip_indices"] == [2]

    updated = client.patch(
        f"/document/parts/{mount['id']}/component-patterns/{created['id']}",
        json={"spacing": 8.0},
    ).json()
    assert updated["skip_indices"] == [2]

    cleared = client.patch(
        f"/document/parts/{mount['id']}/component-patterns/{created['id']}",
        json={"skip_indices": []},
    ).json()
    assert cleared["skip_indices"] == []


def test_update_component_pattern_revalidates_the_merged_result():
    mount = _make_box_part("Mount Validation 7")
    bolt = _make_box_part("Bolt Validation 7")
    _compose(mount["id"], [_occurrence_dict("occ-1", bolt["id"])], bolt["id"])
    created = client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={"source_occurrence_ids": ["occ-1"], "pattern_type": "linear", "count": 3, "spacing": 5.0},
    ).json()
    response = client.patch(
        f"/document/parts/{mount['id']}/component-patterns/{created['id']}",
        json={"count": 1},
    )
    assert response.status_code == 422


# --- Assembly-mesh expansion ----------------------------------------------


def test_linear_component_pattern_expands_into_assembly_mesh_instances():
    mount = _make_box_part("Mount Expand 1", size=30.0)
    bolt = _make_box_part("Bolt Expand 1", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], translation=(5.0, 0.0, 0.0))],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 3,
                "spacing": 10.0,
                "reverse": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])

    # Root content + the real occurrence + 2 derived instances = 4 total.
    assert len(mesh["instances"]) == 4
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    assert len(bolt_instances) == 3
    translations_x = sorted(i["world_transform"]["translation"][0] for i in bolt_instances)
    assert translations_x == [5.0, 15.0, 25.0]

    # Geometry is still deduplicated - one entry for the bolt Part, even
    # though it's now placed 3 times.
    bolt_geometry_entries = [g for g in mesh["geometry"] if g["part_id"] == bolt["id"]]
    assert len(bolt_geometry_entries) == 1

    # Derived instances get their own synthetic occurrence_path, distinct
    # from the real occurrence's own path.
    paths = {tuple(i["occurrence_path"]) for i in bolt_instances}
    assert ("occ-bolt-1",) in paths
    assert len(paths) == 3


def test_linear_component_pattern_with_second_direction_expands_into_a_2d_grid():
    """Bug report (assembly testing): a 2x2 grid (`count=2`, `count_2=2`) -
    mirrors `test_linear_component_pattern_expands_into_assembly_mesh_
    instances`'s own shape, crossing `direction`/`direction_2` the same
    row-major `i * count_2 + j` way `PatternFeature`'s own Rectangular mode
    already does one level down."""
    mount = _make_box_part("Mount Expand Grid 1", size=30.0)
    bolt = _make_box_part("Bolt Expand Grid 1", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], translation=(5.0, 0.0, 0.0))],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 2,
                "spacing": 10.0,
                "reverse": False,
                "direction_2": [0.0, 1.0, 0.0],
                "count_2": 2,
                "spacing_2": 5.0,
                "reverse_2": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    # 2x2 grid = 4 total placements (including the untouched seed).
    assert len(bolt_instances) == 4
    translations = sorted(
        (round(t[0], 6), round(t[1], 6)) for t in (i["world_transform"]["translation"] for i in bolt_instances)
    )
    assert translations == sorted([(5.0, 0.0), (5.0, 5.0), (15.0, 0.0), (15.0, 5.0)])


def test_circular_component_pattern_expands_into_assembly_mesh_instances():
    mount = _make_box_part("Mount Expand 2", size=30.0)
    bolt = _make_box_part("Bolt Expand 2", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], translation=(10.0, 0.0, 0.0))],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "circular",
                "direction": [1.0, 0.0, 0.0],
                "count": 1,
                "spacing": 0.0,
                "reverse": False,
                "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]},
                "count_angular": 4,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    assert len(bolt_instances) == 4
    translations = sorted(
        (round(t[0], 6), round(t[1], 6)) for t in (i["world_transform"]["translation"] for i in bolt_instances)
    )
    assert translations == sorted([(10.0, 0.0), (0.0, 10.0), (-10.0, 0.0), (0.0, -10.0)])


def test_linear_component_pattern_skip_indices_omits_an_instance_without_renumbering_the_rest():
    mount = _make_box_part("Mount Expand Skip 1", size=40.0)
    bolt = _make_box_part("Bolt Expand Skip 1", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], translation=(5.0, 0.0, 0.0))],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 4,
                "spacing": 10.0,
                "reverse": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "skip_indices": [2],
                "orient_with_rotation": True,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    # Real occurrence + indices 1 and 3 (index 2 skipped) = 3.
    assert len(bolt_instances) == 3
    translations_x = sorted(i["world_transform"]["translation"][0] for i in bolt_instances)
    assert translations_x == [5.0, 15.0, 35.0]
    # The skipped index's synthetic path never appears, and the surviving
    # indices keep their own stable per-index suffix.
    paths = {tuple(i["occurrence_path"]) for i in bolt_instances}
    assert ("occ-bolt-1#pattern:pat-1:1",) in paths
    assert ("occ-bolt-1#pattern:pat-1:3",) in paths
    assert ("occ-bolt-1#pattern:pat-1:2",) not in paths


def test_circular_component_pattern_orient_with_rotation_false_keeps_the_source_orientation():
    mount = _make_box_part("Mount Expand Orient 1", size=40.0)
    bolt = _make_box_part("Bolt Expand Orient 1", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], translation=(10.0, 0.0, 0.0))],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "circular",
                "direction": [1.0, 0.0, 0.0],
                "count": 1,
                "spacing": 0.0,
                "reverse": False,
                "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]},
                "count_angular": 4,
                "angle_total": 360.0,
                "reverse_angular": False,
                "orient_with_rotation": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    assert len(bolt_instances) == 4
    # Positions still land on the circle (unaffected by orient_with_rotation)...
    translations = sorted(
        (round(t[0], 6), round(t[1], 6)) for t in (i["world_transform"]["translation"] for i in bolt_instances)
    )
    assert translations == sorted([(10.0, 0.0), (0.0, 10.0), (-10.0, 0.0), (0.0, -10.0)])
    # ...but every derived instance keeps the (identity) source rotation
    # rather than picking up its own step's rotation around the axis.
    for instance in bolt_instances:
        assert math.isclose(instance["world_transform"]["rotation_angle_degrees"], 0.0, abs_tol=1e-9)


def test_suppressed_component_pattern_produces_no_derived_instances():
    mount = _make_box_part("Mount Expand 3", size=30.0)
    bolt = _make_box_part("Bolt Expand 3", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"])],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 3,
                "spacing": 10.0,
                "reverse": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": True,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    assert len(bolt_instances) == 1  # only the real occurrence, no derived ones


def test_component_pattern_referencing_a_suppressed_source_occurrence_is_skipped():
    mount = _make_box_part("Mount Expand 4", size=30.0)
    bolt = _make_box_part("Bolt Expand 4", size=2.0)
    _compose(
        mount["id"],
        [_occurrence_dict("occ-bolt-1", bolt["id"], suppressed=True)],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 3,
                "spacing": 10.0,
                "reverse": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    assert bolt_instances == []


def test_component_pattern_with_multiple_source_occurrences_patterns_each_independently():
    mount = _make_box_part("Mount Expand 5", size=40.0)
    bolt = _make_box_part("Bolt Expand 5", size=2.0)
    _compose(
        mount["id"],
        [
            _occurrence_dict("occ-bolt-1", bolt["id"], translation=(0.0, 0.0, 0.0)),
            _occurrence_dict("occ-bolt-2", bolt["id"], translation=(0.0, 20.0, 0.0)),
        ],
        bolt["id"],
        component_patterns=[
            {
                "id": "pat-1",
                "source_occurrence_ids": ["occ-bolt-1", "occ-bolt-2"],
                "pattern_type": "linear",
                "direction": [1.0, 0.0, 0.0],
                "count": 2,
                "spacing": 10.0,
                "reverse": False,
                "axis": None,
                "count_angular": 1,
                "angle_total": 360.0,
                "reverse_angular": False,
                "suppressed": False,
            }
        ],
    )

    mesh = _assembly_mesh(mount["id"])
    bolt_instances = [i for i in mesh["instances"] if i["part_id"] == bolt["id"]]
    # 2 real occurrences + 1 derived instance each = 4.
    assert len(bolt_instances) == 4
    translations = sorted(tuple(i["world_transform"]["translation"][:2]) for i in bolt_instances)
    assert translations == sorted([(0.0, 0.0), (10.0, 0.0), (0.0, 20.0), (10.0, 20.0)])


def test_component_pattern_of_a_nested_subassembly_repeats_its_own_children_too():
    """A ComponentPattern on `occ-sub-1` (itself a sub-assembly with its own
    nested Occurrence) must repeat the *entire* nested content at each
    derived placement, not just the sub-assembly's own top-level bodies -
    exercises the pattern-expansion recursion reusing `_walk` itself."""
    mount = _make_box_part("Mount Nested", size=40.0)
    sub = _make_box_part("Sub Nested", size=10.0)
    leaf = _make_box_part("Leaf Nested", size=1.0)

    sub_export = _export_part(sub["id"])
    sub_dict = sub_export["document"]["parts"][0]
    sub_dict["occurrences"] = [_occurrence_dict("occ-leaf-1", leaf["id"], translation=(1.0, 0.0, 0.0))]
    sub_dict["mates"] = []
    sub_dict["component_patterns"] = []

    mount_export = _export_part(mount["id"])
    mount_dict = mount_export["document"]["parts"][0]
    mount_dict["occurrences"] = [_occurrence_dict("occ-sub-1", sub["id"], translation=(0.0, 0.0, 0.0))]
    mount_dict["mates"] = []
    mount_dict["component_patterns"] = [
        {
            "id": "pat-1",
            "source_occurrence_ids": ["occ-sub-1"],
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 2,
            "spacing": 20.0,
            "reverse": False,
            "axis": None,
            "count_angular": 1,
            "angle_total": 360.0,
            "reverse_angular": False,
            "suppressed": False,
        }
    ]

    leaf_export = _export_part(leaf["id"])
    payload = {
        "schema_version": mount_export["schema_version"],
        "document": {"id": "composed-doc-nested", "root_part_id": mount["id"], "parts": [mount_dict, sub_dict, leaf_export["document"]["parts"][0]]},
        "sketches": [*mount_export["sketches"], *sub_export["sketches"], *leaf_export["sketches"]],
    }
    assert client.post("/document/import/native", json=payload).status_code == 200

    mesh = _assembly_mesh(mount["id"])
    sub_instances = [i for i in mesh["instances"] if i["part_id"] == sub["id"]]
    leaf_instances = [i for i in mesh["instances"] if i["part_id"] == leaf["id"]]
    # The real sub-assembly occurrence + 1 derived one.
    assert len(sub_instances) == 2
    # The leaf, nested inside the sub-assembly, must appear once per
    # sub-assembly placement too (real + derived) = 2, each offset by its
    # own parent's world transform.
    assert len(leaf_instances) == 2
    leaf_x = sorted(i["world_transform"]["translation"][0] for i in leaf_instances)
    assert leaf_x == [1.0, 21.0]


# --- Native round-trip -----------------------------------------------------


def test_component_pattern_survives_a_native_export_import_round_trip():
    mount = _make_box_part("Mount RoundTrip", size=30.0)
    bolt = _make_box_part("Bolt RoundTrip", size=2.0)
    _compose(mount["id"], [_occurrence_dict("occ-bolt-1", bolt["id"])], bolt["id"])
    client.post(
        f"/document/parts/{mount['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-bolt-1"],
            "pattern_type": "circular",
            "axis": {"origin": [1.0, 2.0, 3.0], "direction": [0.0, 1.0, 0.0]},
            "count_angular": 6,
            "angle_total": 180.0,
            "reverse_angular": True,
            "skip_indices": [2, 4],
            "orient_with_rotation": False,
        },
    ).json()

    exported = _export_part(mount["id"])
    reimport = client.post("/document/import/native", json=exported)
    assert reimport.status_code == 200

    patterns = client.get(f"/document/parts/{mount['id']}/component-patterns").json()
    assert len(patterns) == 1
    pattern = patterns[0]
    assert pattern["pattern_type"] == "circular"
    assert pattern["count_angular"] == 6
    assert pattern["angle_total"] == 180.0
    assert pattern["reverse_angular"] is True
    assert pattern["axis"] == {"origin": [1.0, 2.0, 3.0], "direction": [0.0, 1.0, 0.0]}
    assert pattern["skip_indices"] == [2, 4]
    assert pattern["orient_with_rotation"] is False
