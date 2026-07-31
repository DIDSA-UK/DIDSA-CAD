"""Bug fix: on-device report - "created the plate, then cut a hole, then
tried to pattern the hole" showed the hole's own host Sketch and its
face-anchored Plane sitting on completely different faces than where the
user actually placed them - confirmed by the user to already be wrong
*before* any Pattern operation, so not a Phase 8 (pattern-mirror-scope.md)
regression at all.

Root cause: `_create_plane_feature_response` (a CreatePlaneFeature's own
`origin`/`normal`, recomputed live on every `GET .../features`) and
`_sketch_has_lost_reference` (a SketchFeature's `external_references`,
re-resolved and *persisted* onto `sketch.points[...].x/y` on every
`GET .../features`) both resolved an already-persisted Feature's own
stored `SubShapeRef`/`ExternalVertexReference` against
`compute_part_bodies(part)` with no exclusions - i.e. the Part's *final*,
fully-built state. A raw OCCT face/edge/vertex index
(`topexp.MapShapes`'s own enumeration order over one specific
`TopoDS_Shape` - see `SubShapeRef`'s own docstring) is only stable when
resolved against the same shape snapshot it was captured against; it is
not a persistent label attached to "the same" face forever. A *later*
Boolean (a Cut/Boss into the same Body a Plane is anchored to, or that a
Sketch's own external reference points at) can restructure that Body's
B-rep enough that the identical index now lands on a genuinely different
face/edge/vertex once the *whole* Part is computed - even though neither
stored reference itself ever changed.

Fix: both call sites now resolve against
`app.document.router._excluded_feature_ids_after(part, feature.id)` -
every Feature id that comes after `feature.id` in `part.features`' own
append-only, creation-order list (see `Part`'s own docstring: a Feature
can only be edited/deleted while it is the last one, so this is always a
safe, causally-consistent snapshot of "the Part as it stood right after
this Feature was added"). A first fix attempt used
`transitive_dependents(build_feature_graph(part), feature.id)` (B2's own
cascade-delete graph query) instead - proven wrong by direct reproduction
of the scenario below before ever being trusted: it only excludes
Features that *explicitly reference* `feature.id` by id, missing the
actual reported case entirely - a later Cut that modifies the same Body a
Plane is anchored to, with no dependency edge between the Cut and the
Plane at all (the Cut's own `target_body_ids` references the Body
directly, never the Plane).

Runs for real against pythonocc-core in this sandbox (unlike most other
OCCT-touching bugfix tests in this project - see the recurring caveat in
docs/status.md - this one was verified end-to-end via a real HTTP
TestClient run before being written down)."""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, **payload) -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json=payload or {"plane": "XY"})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _build_the_reported_scenario() -> dict:
    """A 40x40x10 plate (Body), a Plane independently anchored to its top
    face (face index 5 - proven stable pre-cut, matches the on-device
    report's own "New Sketch on Face" host Plane), a *separate* Sketch
    holding an external vertex reference onto one of the plate's own
    corners (matches the report's own hole-sketch symptom - a real Sketch
    entity drifting off its intended anchor), and a *third*, unrelated
    plain-XY Sketch + Cut into the same plate (the report's own "cut a
    hole" step) - the Cut shares no dependency-graph edge with either the
    Plane or the external-reference Sketch, only the same underlying
    Body, which is exactly the case the first (graph-based) fix attempt
    failed to cover."""
    part = _create_part()
    base_sketch = _create_sketch_feature(part["id"], plane="XY")
    _add_square(base_sketch["sketch_id"], -20.0, -20.0, 40.0)
    plate = _create_extrude_feature(part["id"], base_sketch["id"])

    plane = client.post(
        f"/document/parts/{part['id']}/create-plane-features",
        json={
            "plane_type": "offset_face",
            "face_refs": [
                {"face_ref": {"body_id": plate["id"], "shape_type": "face", "index": 5}},
            ],
            "offset": 0.0,
        },
    ).json()
    assert plane["origin"] == [0.0, 0.0, 10.0]
    assert plane["normal"] == [0.0, 0.0, 1.0]

    # Vertex index 4 - proven (via direct pre/post-cut comparison) to
    # resolve to a genuinely different corner once the cut below runs,
    # unlike index 0 which happens to stay stable for this particular
    # square/cut layout - this index is the one that actually exercises
    # the bug rather than passing by coincidence either way.
    ext_sketch = _create_sketch_feature(part["id"], plane="XY")
    ext_point = client.post(
        f"/document/parts/{part['id']}/features/sketch/{ext_sketch['id']}/external-references",
        json={"body_id": plate["id"], "vertex_index": 4},
    ).json()
    assert (ext_point["x"], ext_point["y"]) == (20.0, 20.0)

    cut_sketch = _create_sketch_feature(part["id"], plane="XY")
    _add_square(cut_sketch["sketch_id"], 1.0, 1.0, 2.0)
    cut = _create_extrude_feature(
        part["id"],
        cut_sketch["id"],
        extrude_type="cut",
        target_body_ids=[plate["id"]],
    )

    return {
        "part": part,
        "plate": plate,
        "plane": plane,
        "ext_sketch": ext_sketch,
        "ext_point": ext_point,
        "cut": cut,
    }


def test_face_anchored_plane_does_not_drift_after_a_later_unrelated_cut_into_its_body():
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]

    features = client.get(f"/document/parts/{part_id}/features").json()
    plane_after = next(f for f in features if f["id"] == scenario["plane"]["id"])

    assert plane_after["origin"] == [0.0, 0.0, 10.0]
    assert plane_after["normal"] == [0.0, 0.0, 1.0]


def test_sketch_external_reference_does_not_drift_or_report_lost_after_a_later_unrelated_cut():
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]
    ext_sketch = scenario["ext_sketch"]

    features = client.get(f"/document/parts/{part_id}/features").json()
    sketch_after = next(f for f in features if f["id"] == ext_sketch["id"])
    point_after = client.get(
        f"/sketch/sketches/{ext_sketch['sketch_id']}/points/{scenario['ext_point']['id']}"
    ).json()

    assert sketch_after["has_lost_reference"] is False
    assert (point_after["x"], point_after["y"]) == (20.0, 20.0)


def test_repeated_get_features_calls_do_not_progressively_corrupt_the_external_reference_point():
    """`refresh_external_references` *writes* the newly-resolved position
    straight onto the Sketch's own persisted Point data on every
    `GET .../features` call - the more serious half of the bug, since a
    wrong resolution wouldn't just display wrong once, it would
    permanently overwrite the real geometry the moment anyone opened the
    feature list. Calling `GET .../features` several times in a row must
    be a no-op on the point's stored position."""
    scenario = _build_the_reported_scenario()
    part_id = scenario["part"]["id"]
    ext_sketch = scenario["ext_sketch"]

    for _ in range(3):
        client.get(f"/document/parts/{part_id}/features")

    point_after = client.get(
        f"/sketch/sketches/{ext_sketch['sketch_id']}/points/{scenario['ext_point']['id']}"
    ).json()
    assert (point_after["x"], point_after["y"]) == (20.0, 20.0)
