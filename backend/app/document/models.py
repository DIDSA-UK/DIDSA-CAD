import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field


class Feature(ABC):
    """Base type for anything that can live in a Part's ordered Feature
    list.

    SketchFeature is the only concrete type today; ExtrudeFeature/
    RevolveFeature subclass this later without requiring changes to Part
    or the locking rule below - mirrors the SketchEntity/Constraint ABC
    pattern in app.sketch.
    """

    id: str

    @property
    @abstractmethod
    def type(self) -> str:
        ...

    @property
    def produces_solid_geometry(self) -> bool:
        """Whether this Feature contributes real solid geometry to its
        Part's actual modeled shape - false by default. A future
        ExtrudeFeature/RevolveFeature overrides this to True, which is the
        only change needed for `get_part_mesh` (see document/router.py) to
        stop returning its placeholder box once a Part has one."""
        return False


@dataclass
class SketchFeature(Feature):
    """Wraps an existing Sketch (by id) as a step in a Part's Feature
    history. Does not own or duplicate the Sketch's geometry - app.sketch
    remains the sole owner of Sketch data, this is just a reference plus
    its position in the Feature list. A Sketch alone never produces solid
    geometry - it's only ever an input to a future Extrude/Revolve."""

    id: str
    sketch_id: str

    @property
    def type(self) -> str:
        return "sketch"


@dataclass
class Part:
    """An independent solid-modeling history: an ordered list of Features.

    Parts never reference each other or share Features/Sketches/Points -
    each Part is a fully separate Feature list. Stage 7's locking rule:
    a Feature can only be edited/deleted while it is the LAST Feature in
    this list; earlier Features are permanently locked for this stage once
    something is added after them.
    """

    id: str
    name: str
    features: list[Feature] = field(default_factory=list)

    def add_feature(self, feature: Feature) -> None:
        self.features.append(feature)

    @property
    def produces_solid_geometry(self) -> bool:
        """True once any Feature in this Part's history produces real solid
        geometry (see `Feature.produces_solid_geometry`) - drives whether
        `get_part_mesh` should keep returning its placeholder box."""
        return any(f.produces_solid_geometry for f in self.features)

    def is_locked(self, feature_id: str) -> bool:
        """True if `feature_id` is not the last Feature in the list (so it
        cannot be edited/deleted), or doesn't exist at all. Selection/read
        access is never restricted by this - only mutation."""
        if not self.features or self.features[-1].id != feature_id:
            return True
        return False

    def get_feature(self, feature_id: str) -> Feature | None:
        for feature in self.features:
            if feature.id == feature_id:
                return feature
        return None

    def delete_feature(self, feature_id: str) -> None:
        """Remove the last Feature. Callers must check `is_locked` first -
        this raises ValueError if asked to remove anything else, as a
        defensive double-check rather than the primary enforcement point."""
        if self.is_locked(feature_id):
            raise ValueError("Only the last Feature in a Part can be deleted")
        self.features.pop()

    def delete_feature_cascade(self, feature_id: str) -> list[Feature]:
        """Deletes `feature_id` and every Feature after it in order - the
        only way to remove a locked Feature, since doing so always also
        removes every later Feature that depends on it being in the
        history. Returns the deleted Features (in their original order) so
        callers can clean up anything each one owns - e.g. each
        SketchFeature's underlying Sketch."""
        index = next((i for i, f in enumerate(self.features) if f.id == feature_id), None)
        if index is None:
            raise ValueError(f"Feature not found: {feature_id}")
        deleted = self.features[index:]
        self.features = self.features[:index]
        return deleted


@dataclass
class Document:
    """The single Document instance this stage assumes - no multi-document
    management. Owns one or more independent Parts."""

    id: str
    parts: dict[str, Part] = field(default_factory=dict)

    def add_part(self, name: str) -> Part:
        part = Part(id=str(uuid.uuid4()), name=name)
        self.parts[part.id] = part
        return part
