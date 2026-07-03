import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum


class Produces(str, Enum):
    """B1: what a Feature contributes to the Part, for the client's feature-
    tree categorization (B3) - independent of `produces_solid_geometry`
    below, which only drives whether `get_part_mesh` returns real geometry
    or its placeholder box. A Feature that doesn't fit any group (nothing
    exists yet that would) reports NONE rather than a client having to infer
    grouping from `type` strings."""

    BODY = "body"
    PLANE = "plane"
    SURFACE = "surface"
    SKETCH = "sketch"
    NONE = "none"


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

    @property
    def produces(self) -> Produces:
        """B1: the client-tree-categorization tag (see `Produces` above) -
        defaults to NONE, overridden by SketchFeature (SKETCH) and
        ExtrudeFeature (BODY). Create Plane/Fillet/Chamfer will set their
        own PLANE/BODY/SURFACE value once they exist (C/D/E) rather than
        this prompt inventing a placeholder for them."""
        return Produces.NONE


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

    @property
    def produces(self) -> Produces:
        """A SketchFeature is already a node in `build_feature_graph` (A1) -
        it just has no dependencies of its own - so it is a real
        Feature-graph node in its own right, not merely an upstream
        reference from Extrude. Reports SKETCH accordingly (see B1's status
        doc for the reasoning B3 needs to match this)."""
        return Produces.SKETCH


class ExtrudeType(str, Enum):
    """Boss adds material to a Part's accumulated solid; Cut removes it -
    both are the same ExtrudeFeature shape (see below), differing only in
    this field. Mirrors app.sketch.models.Plane's str-Enum pattern, so it
    round-trips through pydantic/FastAPI the same way."""

    BOSS = "boss"
    CUT = "cut"


@dataclass
class ExtrudeFeature(Feature):
    """Extrudes the closed Profile of the SketchFeature referenced by
    `sketch_feature_id` into a real OCCT solid, then combines it with an
    explicit set of target Bodies - Boss fuses the new solid into each Body
    named by `target_body_ids` (or starts a brand-new Body if that list is
    empty), Cut subtracts it from each named Body (`target_body_ids` must be
    non-empty for a Cut - see app.document.router._validate_target_body_ids).
    `start_distance`/`end_distance` are both signed distances from the
    sketch plane along its normal (positive = in front of the plane, in the
    normal direction; negative = behind it) - the extrude spans from
    `start_distance` to `end_distance`, so the sketch plane can sit anywhere
    within (or outside) the extruded depth. Only `end_distance >
    start_distance` is enforced (see
    app.document.router._validate_extrude_distances) - there would
    otherwise be no volume. The actual OCCT geometry construction lives in
    app.document.extrude, not here - this is just the Feature-tree record of
    the operation, same separation SketchFeature keeps from app.sketch.

    A Body's id (A1) is derived from the id of the ExtrudeFeature that
    first created it (a Boss with empty `target_body_ids`) - deterministic
    and stable across recomputes, since Feature ids never change once
    assigned. When a later Boss fuses two or more existing Bodies together
    via `target_body_ids`, the merge keeps whichever of those ids belongs
    to the Feature that appears earliest in `Part.features` (see
    app.document.graph.base_feature_id) - a single, deterministic,
    documented tie-break rather than an ad-hoc one.

    Amendment: a Body is always exactly one maximally-connected solid, not
    "whatever one ExtrudeFeature produced" - a Boss over a multi-profile
    Sketch with disjoint outer loops, or a Cut that severs a Body into
    disconnected pieces, produces multiple Bodies from that one operation.
    The extra Bodies get a `#N` split-index suffix appended to the base id
    above (see app.document.extrude._register_solids) - a plain,
    unsuffixed id is used whenever an operation produces exactly one
    connected solid, which is the common case and keeps every
    single-solid Body's id unchanged from before this amendment."""

    id: str
    sketch_feature_id: str
    extrude_type: ExtrudeType
    start_distance: float
    end_distance: float
    target_body_ids: list[str] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "extrude"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class SubShapeType(str, Enum):
    """Which kind of sub-shape a `SubShapeRef` (below) points at. Mirrors
    `ExtrudeType`'s str-Enum pattern so it round-trips through pydantic the
    same way once a future Feature (Fillet's `edge_refs`, Create Plane's
    `face_ref`) embeds one in its own payload schema."""

    EDGE = "edge"
    FACE = "face"


@dataclass(frozen=True)
class SubShapeRef:
    """B1: a body-scoped reference to one specific edge or face, so a future
    Feature can persist "this specific edge/face" across recomputes the same
    way Boss/Cut already persists "this specific body" (`target_body_ids`,
    A1). Not a Feature itself - a value type meant to be embedded inside a
    future Feature's own parameter payload (Fillet's `edge_refs: list[
    SubShapeRef]`, Create Plane's `face_ref: SubShapeRef`); no such consumer
    exists yet (that's C/D/E), so this prompt builds and tests the type and
    its resolver (`app.document.extrude.resolve_subshape`) in isolation.

    `body_id` is required (unlike a bare shape reference) because bodies are
    plural since A1/A3 - a sub-shape reference without a body would be
    ambiguous as to which Body's tessellation `index` counts into. `index`
    is an enumeration index captured at creation time via OCCT
    `topexp.MapShapes` over that body's current (single-solid, see the
    Body-splitting amendment) shape - deterministic given identical upstream
    topology, but not guaranteed stable if the body's own face/edge topology
    changes shape (fewer/more sub-shapes, or the same count in a different
    order) - see `resolve_subshape`'s fail-closed behaviour for that case.
    Frozen/hashable like `app.document.graph.GraphNode`, since this is a
    plain value type, not a Feature with its own identity."""

    body_id: str
    shape_type: SubShapeType
    index: int


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

    def delete_features(self, feature_ids: set[str]) -> list[Feature]:
        """B2: deletes exactly the Features named in `feature_ids` (in their
        original relative order), leaving every other Feature untouched in
        its original relative order too - the only way to remove a locked
        Feature, since removing it always also requires removing every
        Feature that actually depends on it being in the history.

        `feature_ids` is expected to already be a real dependency-graph
        transitive-dependents closure (see
        `app.document.graph.transitive_dependents`, called by
        `app.document.router.delete_feature_cascade` before this) - this
        method itself has no graph knowledge and does no closure
        computation of its own, it just partitions `self.features` by
        membership in the given id set. Replaces the pre-B2
        `delete_feature_cascade`, which deleted `feature_id` and everything
        *after it in the list* - correct only by coincidence for every
        pre-A1 scenario where list order and dependency order happened to
        coincide, and wrong as soon as a Feature could depend on something
        other than its immediate predecessor (A1's `target_body_ids`).

        Returns the deleted Features (in their original order) so callers
        can clean up anything each one owns - e.g. each SketchFeature's
        underlying Sketch."""
        deleted = [f for f in self.features if f.id in feature_ids]
        self.features = [f for f in self.features if f.id not in feature_ids]
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
