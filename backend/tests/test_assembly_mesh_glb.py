"""VR/XR recon follow-up (`docs/vr-recon-2026-09-24.md` SS2 point 2, sized in
`docs/vr-recon-2-2026-09-24.md` SS3 point 3): `GET /parts/{part_id}/
assembly-mesh.glb` - the node-instanced binary glTF sibling to `GET /parts/
{part_id}/assembly-mesh`, for a non-Flutter Quest client. Mirrors
`test_assembly_mesh.py`'s own fixtures/composed-payload convention; parses
the raw glb chunks directly (same technique `test_mesh_export.py`'s own
`_parse_glb` uses) since the response isn't JSON.

Needs a real pythonocc-core/py_slvs environment, same caveat as
`test_assembly_mesh.py`."""

import json
import math
import struct

from fastapi.testclient import TestClient

from app.document.assembly_solver import _axis_angle_from_quaternion
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
    return part


def _export_part(part_id: str) -> dict:
    response = client.get("/document/export/native", params={"part_id": part_id})
    assert response.status_code == 200
    return response.json()


def _place_occurrence(
    root: dict,
    child: dict,
    *,
    occurrence_id: str,
    translation: list[float],
    rotation_axis: list[float] | None = None,
    rotation_angle_degrees: float = 0.0,
    hidden: bool = False,
    color: str | None = None,
) -> None:
    root_export = _export_part(root["id"])
    child_export = _export_part(child["id"])
    root_part_dict = root_export["document"]["parts"][0]
    root_part_dict["occurrences"] = [
        {
            "id": occurrence_id,
            "external_ref": f"parts/{child['id']}.didsa",
            "resolved_part_id": child["id"],
            "name_override": None,
            "transform": {
                "translation": translation,
                "rotation_axis": rotation_axis or [0.0, 0.0, 1.0],
                "rotation_angle_degrees": rotation_angle_degrees,
            },
            "suppressed": False,
            "hidden": hidden,
            "color": color,
        }
    ]
    root_part_dict["mates"] = []
    composed_payload = {
        "schema_version": root_export["schema_version"],
        "document": {
            "id": "composed-doc",
            "root_part_id": root["id"],
            "parts": [root_part_dict, child_export["document"]["parts"][0]],
        },
        "sketches": [*root_export["sketches"], *child_export["sketches"]],
    }
    response = client.post("/document/import/native", json=composed_payload)
    assert response.status_code == 200


def _fetch_assembly_glb(part_id: str, **params) -> bytes:
    response = client.get(f"/document/parts/{part_id}/assembly-mesh.glb", params=params)
    assert response.status_code == 200
    assert response.headers["content-type"] == "model/gltf-binary"
    return response.content


def _parse_glb(data: bytes) -> tuple[dict, bytes]:
    magic, version, total_length = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF"
    assert version == 2
    assert total_length == len(data)

    json_len, json_type = struct.unpack_from("<II", data, 12)
    json_bytes = data[20 : 20 + json_len]
    assert json_type == 0x4E4F534A

    bin_offset = 20 + json_len
    bin_len, bin_type = struct.unpack_from("<II", data, bin_offset)
    bin_bytes = data[bin_offset + 8 : bin_offset + 8 + bin_len]
    assert bin_type == 0x004E4942

    return json.loads(json_bytes), bin_bytes


def test_assembly_mesh_glb_for_a_plain_part_is_one_node_one_mesh():
    part = _make_box_part("Solo Part")

    data = _fetch_assembly_glb(part["id"])
    gltf, _bin_bytes = _parse_glb(data)

    assert len(gltf["nodes"]) == 1
    assert len(gltf["meshes"]) == 1
    assert gltf["nodes"][0]["translation"] == [0.0, 0.0, 0.0]


def test_assembly_mesh_glb_node_count_equals_instance_count_and_mesh_count_equals_unique_parts():
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(mount, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0])

    data = _fetch_assembly_glb(mount["id"])
    gltf, _bin_bytes = _parse_glb(data)

    # Root's own content + the one placed bolt occurrence.
    assert len(gltf["nodes"]) == 2
    # Two unique Parts' worth of geometry.
    assert len(gltf["meshes"]) == 2


def test_assembly_mesh_glb_deduplicates_mesh_data_across_multiple_occurrences_of_one_part():
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

    data = _fetch_assembly_glb(plate["id"])
    gltf, _bin_bytes = _parse_glb(data)

    # Root's own content + three washer occurrences = 4 nodes.
    assert len(gltf["nodes"]) == 4
    # Two unique Parts (plate, washer) -> two mesh entries, even though the
    # washer is placed three times - the whole point of node instancing.
    assert len(gltf["meshes"]) == 2
    washer_mesh_indices = {node["mesh"] for node in gltf["nodes"][1:]}
    assert len(washer_mesh_indices) == 1


def test_assembly_mesh_glb_transforms_round_trip_through_the_node_quaternion():
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(
        mount,
        bolt,
        occurrence_id="occ-bolt-1",
        translation=[15.0, 3.0, 10.0],
        rotation_axis=[0.0, 0.0, 1.0],
        rotation_angle_degrees=90.0,
    )

    data = _fetch_assembly_glb(mount["id"])
    gltf, _bin_bytes = _parse_glb(data)

    bolt_node = next(n for n in gltf["nodes"] if n["translation"] == [15.0, 3.0, 10.0])
    qx, qy, qz, qw = bolt_node["rotation"]
    axis, angle_degrees = _axis_angle_from_quaternion((qw, qx, qy, qz))

    assert math.isclose(angle_degrees, 90.0, abs_tol=1e-4)
    assert math.isclose(axis[0], 0.0, abs_tol=1e-4)
    assert math.isclose(axis[1], 0.0, abs_tol=1e-4)
    assert math.isclose(axis[2], 1.0, abs_tol=1e-4)


def test_assembly_mesh_glb_omits_hidden_instances_by_default():
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(mount, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0], hidden=True)

    default_data = _fetch_assembly_glb(mount["id"])
    default_gltf, _ = _parse_glb(default_data)
    assert len(default_gltf["nodes"]) == 1

    included_data = _fetch_assembly_glb(mount["id"], include_hidden="true")
    included_gltf, _ = _parse_glb(included_data)
    assert len(included_gltf["nodes"]) == 2


def test_assembly_mesh_glb_uses_one_material_per_distinct_instance_colour():
    mount = _make_box_part("Mount", size=20.0)
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(mount, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0], color="#ff0000")

    data = _fetch_assembly_glb(mount["id"])
    gltf, _bin_bytes = _parse_glb(data)

    assert len(gltf["materials"]) == 1
    assert gltf["materials"][0]["pbrMetallicRoughness"]["baseColorFactor"] == [1.0, 0.0, 0.0, 1.0]


def test_assembly_mesh_glb_respects_the_coarse_tier():
    part = _make_box_part("Solo Part")

    full_gltf, full_bin = _parse_glb(_fetch_assembly_glb(part["id"], tier="full"))
    coarse_gltf, coarse_bin = _parse_glb(_fetch_assembly_glb(part["id"], tier="coarse"))

    assert len(full_gltf["nodes"]) == 1
    assert len(coarse_gltf["nodes"]) == 1


def test_assembly_mesh_glb_respects_the_quality_param():
    part = _make_box_part("Solo Part")

    fine_gltf, fine_bin = _parse_glb(_fetch_assembly_glb(part["id"], quality=1.0))
    coarse_gltf, coarse_bin = _parse_glb(_fetch_assembly_glb(part["id"], quality=0.0))

    fine_position_accessor = fine_gltf["accessors"][0]
    coarse_position_accessor = coarse_gltf["accessors"][0]
    assert fine_position_accessor["count"] >= coarse_position_accessor["count"]
