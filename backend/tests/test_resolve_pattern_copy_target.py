"""B2 step 1: `resolve_occurrence_target` understands `<src>#pattern:<pid>:<i>` segments."""

import pytest

from app.document.assembly import resolve_occurrence_target
from app.document.models import ComponentPattern, ComponentPatternType, Document, Occurrence, Part, RigidTransform


def _scene(suppressed=False):
    leaf = Part(id="leaf", name="Leaf")
    top = Part(id="top", name="Top")
    top.occurrences = [
        Occurrence(id="src", external_ref="leaf.didsa", part_id="leaf",
                   transform=RigidTransform(translation=(5.0, 0.0, 0.0)))
    ]
    top.component_patterns = [
        ComponentPattern(id="pat", source_occurrence_ids=["src"], pattern_type=ComponentPatternType.LINEAR,
                         direction=(0.0, 0.0, 1.0), count=3, spacing=100.0, suppressed=suppressed)
    ]
    return Document(id="d", parts={"leaf": leaf, "top": top}, root_part_id="top"), top


def test_copy_resolves_to_derived_transform():
    doc, top = _scene()
    part, transform = resolve_occurrence_target(doc, top, "src#pattern:pat:2")
    assert part.id == "leaf"
    assert transform.translation == pytest.approx((5.0, 0.0, 200.0))


@pytest.mark.parametrize("path", ["src#pattern:pat:0", "src#pattern:pat:9", "src#pattern:nope:1", "other#pattern:pat:1",
                                  "src#pattern:pat:x"])
def test_dead_copies_raise_key_error(path):
    doc, top = _scene()
    with pytest.raises(KeyError):
        resolve_occurrence_target(doc, top, path)


def test_suppressed_pattern_raises():
    doc, top = _scene(suppressed=True)
    with pytest.raises(KeyError):
        resolve_occurrence_target(doc, top, "src#pattern:pat:1")
