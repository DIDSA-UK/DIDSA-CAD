"""Assembly-audit gap `[29]` (`docs/assembly-scope.md`): `GET /parts/
{part_id}/export/assembly-step` and its STL/OBJ/glb siblings - the plain
`export/step` endpoint (and its own siblings) only ever exports `part_id`'s
own *local* Bodies, with zero awareness of placed Occurrences (at any
transform, including `ComponentPattern`-derived ones) - for an assembly
whose real content lives entirely in placed components, that ships an
essentially empty file. These new endpoints walk the full occurrence tree
(mirroring `get_assembly_mesh`'s own `_walk`) and export every placed
instance's own real, world-transformed geometry instead.

Mirrors `test_assembly_mesh.py`'s own `_make_box_part` fixture and
`test_stage_export_formats.py`'s own binary-format assertions (STL vertex/
triangle parsing, OBJ vertex-line presence, glb magic bytes) - real OCCT
needed, see either file's own caveat about this sandbox."""

import struct

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
    """A Part with one real solid Body - a `size` x `size` x 10 box, its own
    local-frame corner at the origin."""
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


def _import_composed(payload: dict) -> None:
    response = client.post("/document/import/native", json=payload)
    assert response.status_code == 200


def _place_occurrence(root: dict, child: dict, *, occurrence_id: str, translation: list[float]) -> None:
    """Composes `root_export`'s own payload with one Occurrence of `child`
    at `translation`, and imports it, mirroring `test_assembly_mesh.py`'s
    own composed-payload convention."""
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
                "rotation_axis": [0.0, 0.0, 1.0],
                "rotation_angle_degrees": 0.0,
            },
            "suppressed": False,
            "hidden": False,
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
    _import_composed(composed_payload)


def _stl_triangle_count(content: bytes) -> int:
    (count,) = struct.unpack_from("<I", content, 80)
    return count


def _stl_vertices(content: bytes) -> list[tuple[float, float, float]]:
    (count,) = struct.unpack_from("<I", content, 80)
    vertices = []
    offset = 84
    for _ in range(count):
        for v in range(3):
            xyz = struct.unpack_from("<fff", content, offset + 12 + v * 12)
            vertices.append(xyz)
        offset += 50
    return vertices


def _bounds(vertices: list[tuple[float, float, float]]) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    xs, ys, zs = zip(*vertices)
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def test_assembly_step_export_of_root_with_no_local_bodies_but_one_occurrence_succeeds():
    root = _create_part("Root")
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(root, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0])

    response = client.get(f"/document/parts/{root['id']}/export/assembly-step")

    assert response.status_code == 200
    assert response.content.startswith(b"ISO-10303-21")
    assert b"AP242" in response.content


def test_assembly_stl_export_places_the_occurrences_geometry_at_its_real_world_position():
    """The real, previously-missing behavior: a root Part with zero local
    geometry, exporting an Occurrence's own Body at its real composed world
    transform - not the empty file the plain (non-assembly) export endpoint
    would produce for this same root."""
    root = _create_part("Root")
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(root, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0])

    response = client.get(f"/document/parts/{root['id']}/export/assembly-stl")
    assert response.status_code == 200

    vertices = _stl_vertices(response.content)
    assert len(vertices) > 0
    lower, upper = _bounds(vertices)
    # The bolt's own local-frame box spans (0,0,0)-(2,2,10) - translated by
    # (15, 0, 10), it must span (15,0,10)-(17,2,20), not the untranslated
    # local bounds.
    assert lower == (15.0, 0.0, 10.0)
    assert upper == (17.0, 2.0, 20.0)


def test_the_plain_non_assembly_export_endpoint_is_unaffected_and_still_400s_for_this_same_root():
    """Confirms this is genuinely a new, additive endpoint - the pre-existing
    `export/step` stays scoped to the root's own (here, nonexistent) local
    Bodies, unchanged."""
    root = _create_part("Root")
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(root, bolt, occurrence_id="occ-bolt-1", translation=[15.0, 0.0, 10.0])

    response = client.get(f"/document/parts/{root['id']}/export/step")

    assert response.status_code == 400


def test_assembly_export_with_nothing_reachable_at_all_returns_400():
    root = _create_part("Empty Root")

    response = client.get(f"/document/parts/{root['id']}/export/assembly-step")

    assert response.status_code == 400


def test_assembly_export_on_an_unknown_part_returns_404():
    response = client.get("/document/parts/does-not-exist/export/assembly-step")
    assert response.status_code == 404


def test_assembly_stl_export_includes_a_component_patterns_own_derived_instances():
    """`ComponentPattern`-derived instances are never persisted as real
    Occurrences (`ComponentPattern`'s own "re-derive, don't cache" design) -
    confirms `_walk_assembly_export_bodies` reuses the same recursive
    `_walk` shape `get_assembly_mesh` does for this, not just plain
    Occurrences."""
    root = _create_part("Root")
    peg = _make_box_part("Peg", size=1.0)
    _place_occurrence(root, peg, occurrence_id="occ-peg-1", translation=[0.0, 0.0, 0.0])

    pattern_response = client.post(
        f"/document/parts/{root['id']}/component-patterns",
        json={
            "source_occurrence_ids": ["occ-peg-1"],
            "pattern_type": "linear",
            "direction": [1.0, 0.0, 0.0],
            "count": 3,
            "spacing": 10.0,
        },
    )
    assert pattern_response.status_code == 201

    response = client.get(f"/document/parts/{root['id']}/export/assembly-stl")
    assert response.status_code == 200

    # One box is 12 triangles (2 per face * 6 faces) - 3 real instances
    # (the seed occurrence plus 2 pattern-derived ones) means 36 total.
    assert _stl_triangle_count(response.content) == 36
    vertices = _stl_vertices(response.content)
    lower, upper = _bounds(vertices)
    assert lower == (0.0, 0.0, 0.0)
    # Spaced every 10 units along +X, 3 instances: seed at x=[0,1], last
    # derived instance at x=[20,21] - `_make_box_part`'s own `size` only
    # controls the X/Y sketch footprint, its Z extrusion is always 10.
    assert upper == (21.0, 1.0, 10.0)


def test_assembly_obj_export_has_vertex_and_face_lines():
    root = _create_part("Root")
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(root, bolt, occurrence_id="occ-bolt-1", translation=[0.0, 0.0, 0.0])

    response = client.get(f"/document/parts/{root['id']}/export/assembly-obj")

    assert response.status_code == 200
    text = response.text
    assert "\nv " in text
    assert "\nf " in text


def test_assembly_glb_export_is_a_valid_glb_container():
    root = _create_part("Root")
    bolt = _make_box_part("Bolt", size=2.0)
    _place_occurrence(root, bolt, occurrence_id="occ-bolt-1", translation=[0.0, 0.0, 0.0])

    response = client.get(f"/document/parts/{root['id']}/export/assembly-glb")

    assert response.status_code == 200
    magic, version, total_length = struct.unpack_from("<4sII", response.content, 0)
    assert magic == b"glTF"
    assert version == 2
    assert total_length == len(response.content)
