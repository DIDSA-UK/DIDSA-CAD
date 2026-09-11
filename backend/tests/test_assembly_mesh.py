"""Assembly support Phase 2: `GET /parts/{part_id}/assembly-mesh` - real-OCCT
tests. Builds a small multi-part scene the way the client's own multi-file
compose step would (assign each resolved file's Part a fresh id, wire each
Occurrence's `external_ref`/`resolved_part_id` pair, send the whole graph
through one `POST /document/import/native` call - see `Occurrence`'s own
docstring in `app.document.models` for why `resolved_part_id` only survives
import when it actually names another Part in that same payload), then
checks the assembly-mesh response: the root Part's own local bodies appear
as one instance, each Occurrence appears as another with its world
transform correctly composed, and geometry is deduplicated per unique Part
id regardless of how many Occurrences place it.

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
    """A Part with one real solid Body - a `size` x `size` x 10 box."""
    part = _create_part(name)
    sketch_response = client.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"})
    assert sketch_response.status_code == 201
    sketch_id = sketch_response.json()["sketch_id"]
    corners = [
        _add_point(sketch_id, x, y) for x, y in [(0, 0), (size, 0), (size, size), (0, size)]
    ]
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
    return client.get(f"/document/parts/{part['id']}").json() | {"id": part["id"]}


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _assembly_mesh(part_id: str) -> dict:
    response = client.get(f"/document/parts/{part_id}/assembly-mesh")
    assert response.status_code == 200
    return response.json()


def test_assembly_mesh_for_a_plain_part_with_no_occurrences_is_just_its_own_bodies():
    part = _make_box_part("Solo Part")

    mesh = _assembly_mesh(part["id"])

    assert len(mesh["geometry"]) == 1
    assert mesh["geometry"][0]["part_id"] == part["id"]
    assert len(mesh["geometry"][0]["bodies"]) == 1
    assert len(mesh["instances"]) == 1
    root_instance = mesh["instances"][0]
    assert root_instance["occurrence_path"] == []
    assert root_instance["part_id"] == part["id"]
    assert root_instance["world_transform"]["translation"] == [0.0, 0.0, 0.0]
    assert root_instance["world_transform"]["rotation_angle_degrees"] == 0.0
    assert root_instance["hidden"] is False


def test_assembly_mesh_includes_the_root_parts_own_bodies_and_occurrences_together():
    """The exact scenario the model correction was about: a root Part with
    BOTH a local Feature (standing in for a modelled/imported mount) AND an
    Occurrence of another Part, coexisting in one assembly-mesh response."""
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)

    mount_export = _export_part(mount["id"])
    bolt_export = _export_part(bolt["id"])
    mount_part_dict = mount_export["document"]["parts"][0]
    mount_part_dict["occurrences"] = [
        {
            "id": "occ-bolt-1",
            "external_ref": "parts/bolt.didsa",
            "resolved_part_id": bolt["id"],
            "name_override": None,
            "transform": {
                "translation": [15.0, 0.0, 10.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
        }
    ]
    mount_part_dict["mates"] = []

    composed_payload = {
        "schema_version": mount_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": mount["id"],
            "parts": [mount_part_dict, bolt_export["document"]["parts"][0]],
        },
        "sketches": [*mount_export["sketches"], *bolt_export["sketches"]],
    }
    import_response = client.post("/document/import/native", json=composed_payload)
    assert import_response.status_code == 200

    mesh = _assembly_mesh(mount["id"])

    # Two unique Parts' worth of geometry - the mount's own, and the bolt's.
    geometry_by_part_id = {entry["part_id"]: entry for entry in mesh["geometry"]}
    assert set(geometry_by_part_id.keys()) == {mount["id"], bolt["id"]}
    assert len(geometry_by_part_id[mount["id"]]["bodies"]) == 1
    assert len(geometry_by_part_id[bolt["id"]]["bodies"]) == 1

    # Two instances: the root's own content, and the placed bolt occurrence.
    assert len(mesh["instances"]) == 2
    root_instance = next(i for i in mesh["instances"] if i["occurrence_path"] == [])
    bolt_instance = next(i for i in mesh["instances"] if i["occurrence_path"] == ["occ-bolt-1"])
    assert root_instance["part_id"] == mount["id"]
    assert bolt_instance["part_id"] == bolt["id"]
    assert bolt_instance["world_transform"]["translation"] == [15.0, 0.0, 10.0]


def test_assembly_mesh_deduplicates_geometry_across_multiple_occurrences_of_one_part():
    """N occurrences of one Part definition ship one geometry payload, not
    N - the whole point of separating `geometry` from `instances`."""
    plate = _make_box_part("Plate", size=30.0)
    washer = _make_box_part("Washer", size=1.0)

    plate_export = _export_part(plate["id"])
    washer_export = _export_part(washer["id"])
    plate_part_dict = plate_export["document"]["parts"][0]
    plate_part_dict["occurrences"] = [
        {
            "id": f"occ-washer-{i}",
            "external_ref": "parts/washer.didsa",
            "resolved_part_id": washer["id"],
            "name_override": None,
            "transform": {
                "translation": [float(i) * 5.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
        }
        for i in range(3)
    ]
    plate_part_dict["mates"] = []

    composed_payload = {
        "schema_version": plate_export["schema_version"],
        "document": {
            "id": "composed-doc-2",
            "root_part_id": plate["id"],
            "parts": [plate_part_dict, washer_export["document"]["parts"][0]],
        },
        "sketches": [*plate_export["sketches"], *washer_export["sketches"]],
    }
    assert client.post("/document/import/native", json=composed_payload).status_code == 200

    mesh = _assembly_mesh(plate["id"])

    # One geometry entry per unique Part, even though the washer is placed
    # three times.
    assert len(mesh["geometry"]) == 2
    washer_geometry_entries = [g for g in mesh["geometry"] if g["part_id"] == washer["id"]]
    assert len(washer_geometry_entries) == 1

    # But three separate instances, each with its own transform.
    washer_instances = [i for i in mesh["instances"] if i["part_id"] == washer["id"]]
    assert len(washer_instances) == 3
    assert sorted(i["world_transform"]["translation"][0] for i in washer_instances) == [0.0, 5.0, 10.0]


def test_assembly_mesh_skips_an_unresolved_occurrence_without_erroring():
    """An Occurrence whose target file hasn't been composed/imported into
    this session yet (resolved_part_id absent, or naming a Part outside
    this payload) is silently skipped - not an error, and every sibling
    that *is* resolved still renders."""
    root = _make_box_part("Root With Unresolved Ref")

    root_export = _export_part(root["id"])
    root_part_dict = root_export["document"]["parts"][0]
    root_part_dict["occurrences"] = [
        {
            "id": "occ-missing-1",
            "external_ref": "parts/not-yet-loaded.didsa",
            "resolved_part_id": None,
            "name_override": None,
            "transform": {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
            "suppressed": False,
            "hidden": False,
        }
    ]
    root_part_dict["mates"] = []

    composed_payload = {
        "schema_version": root_export["schema_version"],
        "document": {"id": "composed-doc-3", "root_part_id": root["id"], "parts": [root_part_dict]},
        "sketches": root_export["sketches"],
    }
    assert client.post("/document/import/native", json=composed_payload).status_code == 200

    mesh = _assembly_mesh(root["id"])

    assert len(mesh["geometry"]) == 1
    assert mesh["geometry"][0]["part_id"] == root["id"]
    assert len(mesh["instances"]) == 1
    assert mesh["instances"][0]["occurrence_path"] == []


def test_assembly_mesh_composes_transforms_down_a_nested_occurrence_chain():
    """A sub-assembly's own Occurrence gets its transform composed with its
    parent's - `app.document.assembly.compose_chain` - not just placed
    relative to its own immediate parent in isolation."""
    top = _make_box_part("Top")
    sub = _make_box_part("Sub")
    leaf = _make_box_part("Leaf", size=1.0)

    top_export = _export_part(top["id"])
    sub_export = _export_part(sub["id"])
    leaf_export = _export_part(leaf["id"])

    sub_part_dict = sub_export["document"]["parts"][0]
    sub_part_dict["occurrences"] = [
        {
            "id": "occ-leaf-1",
            "external_ref": "parts/leaf.didsa",
            "resolved_part_id": leaf["id"],
            "name_override": None,
            "transform": {
                "translation": [1.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
        }
    ]
    sub_part_dict["mates"] = []

    top_part_dict = top_export["document"]["parts"][0]
    top_part_dict["occurrences"] = [
        {
            "id": "occ-sub-1",
            "external_ref": "parts/sub.didsa",
            "resolved_part_id": sub["id"],
            "name_override": None,
            "transform": {
                "translation": [10.0, 0.0, 0.0],
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 90.0,
            },
            "suppressed": False,
            "hidden": False,
        }
    ]
    top_part_dict["mates"] = []

    composed_payload = {
        "schema_version": top_export["schema_version"],
        "document": {
            "id": "composed-doc-4",
            "root_part_id": top["id"],
            "parts": [top_part_dict, sub_part_dict, leaf_export["document"]["parts"][0]],
        },
        "sketches": [*top_export["sketches"], *sub_export["sketches"], *leaf_export["sketches"]],
    }
    assert client.post("/document/import/native", json=composed_payload).status_code == 200

    mesh = _assembly_mesh(top["id"])

    assert len(mesh["instances"]) == 3
    leaf_instance = next(i for i in mesh["instances"] if i["occurrence_path"] == ["occ-sub-1", "occ-leaf-1"])
    # Parent rotated 90deg about Z then translated by (10,0,0); child's own
    # local (1,0,0) offset gets rotated into (0,1,0) by the parent, then the
    # parent's own translation is added on top - see app.document.assembly's
    # own compose() docstring for this exact composition order.
    tx, ty, tz = leaf_instance["world_transform"]["translation"]
    assert math.isclose(tx, 10.0, abs_tol=1e-4)
    assert math.isclose(ty, 1.0, abs_tol=1e-4)
    assert math.isclose(tz, 0.0, abs_tol=1e-4)
