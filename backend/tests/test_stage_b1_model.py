"""B1: pure-Python tests for the `Produces` tag and the `SubShapeRef` value
type - both live in app.document.models, which has zero OCCT/pythonocc-core
imports, so (unlike almost everything else this prompt touches) these can
run for real in this sandbox without a pythonocc-core environment. See
test_stage_b1_subshape.py for the OCCT-touching resolve_subshape/produces-
over-the-API tests, which need the real thing.
"""

from app.document.models import (
    ExtrudeFeature,
    ExtrudeType,
    Produces,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)


def test_sketch_feature_produces_sketch():
    feature = SketchFeature(id="f1", sketch_id="s1")
    assert feature.produces == Produces.SKETCH


def test_extrude_feature_produces_body_for_boss_and_cut():
    boss = ExtrudeFeature(
        id="f1",
        sketch_feature_id="s1",
        extrude_type=ExtrudeType.BOSS,
        start_distance=0.0,
        end_distance=10.0,
    )
    cut = ExtrudeFeature(
        id="f2",
        sketch_feature_id="s1",
        extrude_type=ExtrudeType.CUT,
        start_distance=0.0,
        end_distance=10.0,
        target_body_ids=["f1"],
    )

    assert boss.produces == Produces.BODY
    assert cut.produces == Produces.BODY


def test_produces_enum_has_exactly_the_five_documented_values():
    assert {p.value for p in Produces} == {"body", "plane", "surface", "sketch", "none"}


def test_subshape_type_enum_has_exactly_edge_face_and_vertex():
    # C4: VERTEX added for NORMAL_TO_EDGE_THROUGH_VERTEX/PARALLEL_TO_FACE_
    # THROUGH_VERTEX/THREE_POINTS' own vertex-referencing PlaneType variants.
    assert {t.value for t in SubShapeType} == {"edge", "face", "vertex"}


def test_subshape_ref_is_a_value_type_with_structural_equality():
    a = SubShapeRef(body_id="body-1", shape_type=SubShapeType.FACE, index=2)
    b = SubShapeRef(body_id="body-1", shape_type=SubShapeType.FACE, index=2)
    c = SubShapeRef(body_id="body-1", shape_type=SubShapeType.FACE, index=3)

    assert a == b
    assert a != c
    assert hash(a) == hash(b)


def test_subshape_ref_fields_round_trip():
    ref = SubShapeRef(body_id="boss-1#0", shape_type=SubShapeType.EDGE, index=5)

    assert ref.body_id == "boss-1#0"
    assert ref.shape_type == SubShapeType.EDGE
    assert ref.index == 5
