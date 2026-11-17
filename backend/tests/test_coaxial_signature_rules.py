"""N1a (docs/mates-storage-sessions-plan-2026-11-12.md, "N1 plan", decision N-4 (a)): the coaxial tie-break in the pure signature rules.

A cylinder / cone face is measured by its distance from the stored axis, so every face on one axis used to be "the same face" to the rules: a bore's index
renumbered onto the boss around it read `ok` there (silently wrong), and a gear's bore beside its rim was `ambiguous` (lost). `FaceSignature.radius` /
`major_radius` / `half_angle` now break that tie. Golden vectors: `tests/data/coaxial_signature_vectors.json` (expectations set by hand). No OCCT needed for
the rules; the native-format round trip at the bottom imports the backend's format module only."""

import json
from pathlib import Path

import pytest

from app.sketch.reference_signature import (
    HALF_ANGLE_TOLERANCE_DEGREES,
    RADIUS_TOLERANCE_REL,
    SIZE_UNAMBIGUOUS_RATIO,
    FaceSignature,
    ReferenceStatus,
    decide_reference,
    size_error,
    size_unchanged,
)

_VECTORS = json.loads((Path(__file__).parent / "data" / "coaxial_signature_vectors.json").read_text())["cases"]


def _face(data: dict) -> FaceSignature:
    from app.document.native_format import _shape_signature_from_dict

    signature = _shape_signature_from_dict(data)
    assert isinstance(signature, FaceSignature)
    return signature


@pytest.mark.parametrize("case", _VECTORS, ids=[c["name"] for c in _VECTORS])
def test_golden_vector(case):
    decision = decide_reference(_face(case["stored"]), case["index"], [_face(c) for c in case["candidates"]])
    expect = case["expect"]
    assert (decision.status.value, decision.index) == (expect["status"], expect["index"]), decision
    if expect["reason"]:
        assert decision.reason == expect["reason"], decision


def test_the_vectors_cover_what_the_plan_asks_for():
    names = " / ".join(c["name"] for c in _VECTORS)
    for needed in ("tube", "stepped shaft", "radius edit: bore 4 -> 5", "equal radii", "cone pair", "old signature"):
        assert needed in names


def test_a_signature_without_size_decides_exactly_as_before_on_every_vector():
    """Strip the size from the stored signature (a file saved before N1a) and from every candidate: the decision must equal the one with the stored size
    stripped only, i.e. candidates' new sizes change nothing while the stored signature has none."""
    import dataclasses

    for case in _VECTORS:
        stored = dataclasses.replace(_face(case["stored"]), radius=None, major_radius=None, half_angle=None)
        sized = [_face(c) for c in case["candidates"]]
        unsized = [dataclasses.replace(c, radius=None, major_radius=None, half_angle=None) for c in sized]
        assert decide_reference(stored, case["index"], sized) == decide_reference(stored, case["index"], unsized), case["name"]


def test_size_error_and_its_tolerances():
    bore = FaceSignature((0, 0, 5), "cylinder", (0, 0, 1), radius=4.0, body_diagonal=30.0)
    assert size_error(bore, FaceSignature((0, 0, 5), "cylinder", (0, 0, 1), radius=10.0)) == (6.0, RADIUS_TOLERANCE_REL * 4.0)
    assert size_error(bore, FaceSignature((0, 0, 5), "cylinder", (0, 0, 1))) is None
    assert size_unchanged(bore, FaceSignature((0, 0, 5), "cylinder", (0, 0, 1), radius=4.0 * (1 + RADIUS_TOLERANCE_REL / 2)))
    assert not size_unchanged(bore, FaceSignature((0, 0, 5), "cylinder", (0, 0, 1), radius=5.0))
    cone = FaceSignature((0, 0, 5), "cone", (0, 0, 1), half_angle=20.0)
    assert size_error(cone, FaceSignature((0, 0, 5), "cone", (0, 0, 1), half_angle=21.0)) == (1.0, HALF_ANGLE_TOLERANCE_DEGREES)
    ring = FaceSignature((0, 0, 5), "torus", (0, 0, 1), radius=1.0, major_radius=9.0)
    error, tolerance = size_error(ring, FaceSignature((0, 0, 5), "torus", (0, 0, 1), radius=1.5, major_radius=4.0))
    assert error == pytest.approx(5.5) and tolerance == pytest.approx(RADIUS_TOLERANCE_REL * 9.0)
    assert SIZE_UNAMBIGUOUS_RATIO == 3.0
    plane = FaceSignature((0, 0, 0), "plane", (0, 0, 1))
    assert size_error(plane, plane) is None and size_unchanged(plane, plane)


def test_native_format_writes_the_size_only_when_present_and_reads_it_optionally():
    from app.document.native_format import _shape_signature_from_dict, _shape_signature_to_dict

    sized = FaceSignature((0.0, 0.0, 5.0), "torus", (0.0, 0.0, 1.0), area=12.0, body_diagonal=30.0, radius=1.0, major_radius=9.0)
    data = _shape_signature_to_dict(sized)
    assert (data["radius"], data["major_radius"]) == (1.0, 9.0) and "half_angle" not in data
    assert _shape_signature_from_dict(json.loads(json.dumps(data))) == sized

    cone = FaceSignature((0.0, 0.0, 5.0), "cone", (0.0, 0.0, 1.0), half_angle=22.5)
    assert _shape_signature_from_dict(_shape_signature_to_dict(cone)) == cone

    old = FaceSignature((0.0, 0.0, 5.0), "plane", (0.0, 0.0, 1.0), area=12.0, body_diagonal=30.0)
    old_data = _shape_signature_to_dict(old)
    assert set(old_data) == {"kind", "position", "surface_kind", "direction", "area", "body_diagonal"}  # the keys every file had before N1a
    # A cylinder signature as files saved before N1a hold it: no radius key, reads with no size.
    legacy = {"kind": "face", "position": [0, 0, 5], "surface_kind": "cylinder", "direction": [0, 0, 1], "area": 100.0, "body_diagonal": 30.0}
    read = _shape_signature_from_dict(legacy)
    assert (read.radius, read.major_radius, read.half_angle) == (None, None, None)
