import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum

from app.sketch.models import Plane, SketchEntityRef


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
    geometry - it's only ever an input to a future Extrude/Revolve.

    C3: `plane_feature_id` anchors this Sketch to a `CreatePlaneFeature`
    instead of one of the three fixed reference planes - mutually exclusive
    with the wrapped Sketch's own `plane` (exactly one is set; enforced by
    `app.document.router._validate_sketch_feature_payload`, same "payload
    shape validated by the API layer" split every other mutually-exclusive
    Feature field already uses). None (the common case) means this Sketch
    lives on its own fixed `plane`, unchanged from before C3."""

    id: str
    sketch_id: str
    plane_feature_id: str | None = None

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

    # Prompt G: which outer profile(s) of the backing Sketch to extrude -
    # each entry anchors one desired profile via any Line/Circle entity
    # known to belong to it (see app.document.extrude.select_profiles).
    # Empty (the default) means "every outer profile currently detected",
    # exactly the pre-Prompt-G behaviour (a MultiProfile Sketch extrudes
    # all of its disjoint outer loops) - this field only ever narrows that
    # set, never widens it beyond what app.sketch.profile.detect_profile
    # itself reports as usable.
    profile_refs: list[SketchEntityRef] = field(default_factory=list)

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
    `face_ref`) embeds one in its own payload schema.

    C4: `VERTEX` added for `NORMAL_TO_EDGE_THROUGH_VERTEX`/
    `PARALLEL_TO_FACE_THROUGH_VERTEX`/`THREE_POINTS`'s Body-vertex
    references - resolves the same way EDGE/FACE already do (see
    `app.document.extrude._TOPABS_FOR_SUBSHAPE_TYPE`), against the same
    0-based `topexp.MapShapes(body, TopAbs_VERTEX, ...)` index scheme the
    client's `topology_vertex_ids` (see `app.document.mesh.
    _extract_topology_vertices`) already assigns."""

    EDGE = "edge"
    FACE = "face"
    VERTEX = "vertex"


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


class PlaneType(str, Enum):
    """Which plane-construction method a `CreatePlaneFeature` uses - mirrors
    `ExtrudeType`/`SubShapeType`'s str-Enum pattern.

    C3 added `MIDPLANE` (equidistant between two parallel plane-like
    references) to C2's original `OFFSET_FACE`/`NORMAL_TO_LINE_AT_POINT`
    pair. C4 adds three more, all using Body edges/vertices (or, for
    `THREE_POINTS`, optionally Sketch Points too) rather than Sketch
    entities:
    - `NORMAL_TO_EDGE_THROUGH_VERTEX`: a plane normal to a straight Body
      edge's direction, through a given Body vertex.
    - `PARALLEL_TO_FACE_THROUGH_VERTEX`: a plane parallel to a plane-like
      reference, through a given Body vertex (an offset-through-a-point
      instead of `OFFSET_FACE`'s offset-by-a-distance).
    - `THREE_POINTS`: the plane through three points, each independently
      either a Body vertex or a Sketch Point (see `PointRef`).
    All six share the same `CreatePlaneFeature` shape (see its own
    docstring). C5: `OFFSET_FACE`/`MIDPLANE`/`PARALLEL_TO_FACE_THROUGH_VERTEX`'s
    "plane-like reference" is a `PlaneRef` - a Body face, a fixed reference
    plane, or an existing Plane, not just a Body face as before.

    On-device feedback ("allow 'point and curve' as a valid combination to
    create a plane, on point and normal to arc"): `NORMAL_TO_CURVE_AT_POINT`
    adds a seventh method, `NORMAL_TO_LINE_AT_POINT`'s Arc-shaped sibling - a
    Sketch Arc's tangent direction at one of its own endpoints, through that
    same Point. Reuses `line_ref`/`point_ref` verbatim (an Arc reference
    fits the same "one Sketch entity + one of its own Points" shape a Line
    reference already does) rather than adding a parallel pair of fields."""

    OFFSET_FACE = "offset_face"
    NORMAL_TO_LINE_AT_POINT = "normal_to_line_at_point"
    MIDPLANE = "midplane"
    NORMAL_TO_EDGE_THROUGH_VERTEX = "normal_to_edge_through_vertex"
    PARALLEL_TO_FACE_THROUGH_VERTEX = "parallel_to_face_through_vertex"
    THREE_POINTS = "three_points"
    NORMAL_TO_CURVE_AT_POINT = "normal_to_curve_at_point"


@dataclass(frozen=True)
class ResolvedPlane:
    """C2/C3: the world-space geometry a `CreatePlaneFeature` (or a fixed
    reference plane, via `app.document.plane_geometry.sketch_basis_for_
    plane`) resolves to - an origin point, a unit normal, and a full
    right-handed in-plane basis (`x_axis`/`y_axis`), everything a client
    needs to render the plane (a bounded quad centered at `origin`, oriented
    by `normal`) and everything a Sketch anchored to it (C3) needs to embed
    its own local (x, y) coordinates into world space (`origin + x * x_axis
    + y * y_axis`). Not persisted - recomputed on every read/use the same
    way `/mesh` recomputes Bodies, so it always reflects the Part's
    *current* state rather than whatever it was at creation time (consistent
    with `resolve_subshape`'s own "re-derive, don't cache" philosophy).

    C3: `x_axis`/`y_axis` are new (C2 shipped with only `origin`/`normal`,
    since nothing yet consumed a plane's in-plane orientation) - added
    rather than left to be derived ad hoc by each consumer, since a Sketch's
    embedding must use the *exact same* basis its Extrude later re-derives
    (see `app.document.extrude._solid_for_extrude_feature`), and because a
    generic `normal`-only cross-product derivation does not reproduce this
    project's existing fixed-plane conventions (see `app.document.plane_
    geometry`'s explicit per-plane lookup table, kept instead of such a
    formula for exactly this reason)."""

    origin: tuple[float, float, float]
    normal: tuple[float, float, float]
    x_axis: tuple[float, float, float]
    y_axis: tuple[float, float, float]


@dataclass(frozen=True)
class PointRef:
    """C4: a reference to one point usable in a `THREE_POINTS`
    `CreatePlaneFeature` - either a Body vertex (`vertex_ref`) or a Sketch
    Point (`sketch_point_ref`), never both at once. Mirrors
    `CreatePlaneFeature`'s own "exactly one of two optional fields, payload
    shape validated by the router" convention, just at the single-point
    granularity rather than the whole Feature's - lets `THREE_POINTS` accept
    any mix of Body vertices and Sketch Points (e.g. two Sketch Points and
    one Body vertex) without needing a separate `CreatePlaneFeature` field
    per source kind."""

    vertex_ref: SubShapeRef | None = None
    sketch_point_ref: SketchEntityRef | None = None


@dataclass(frozen=True)
class PlaneRef:
    """C5: a face-like reference usable in `OFFSET_FACE`/`MIDPLANE`/
    `PARALLEL_TO_FACE_THROUGH_VERTEX`'s `face_refs` - exactly one of the
    three fields is ever set (payload shape validated by the router, same
    convention `PointRef` (C4) already established for its own two-way
    version of this same idea):
    - `face_ref`: a Body face (the only option before C5).
    - `fixed_plane`: one of the three fixed reference planes (XY/XZ/YZ) -
      e.g. an `OFFSET_FACE` offset from the XY plane instead of a Body face.
    - `plane_feature_id`: an existing `CreatePlaneFeature` in this Part -
      e.g. a `MIDPLANE` between an already-created Plane and a Body face.

    Named `face_refs`' element type (not renamed to e.g. `PlaneOrFaceRef`)
    because the field itself keeps its pre-C5 name - `CreatePlaneFeature`'s
    own docstring already explains why `face_refs` is the shared name for
    every plane-construction method that needs "a face-like thing", and C5
    only widens what "face-like" can mean, not which Feature fields use it."""

    face_ref: SubShapeRef | None = None
    fixed_plane: Plane | None = None
    plane_feature_id: str | None = None


@dataclass
class CreatePlaneFeature(Feature):
    """C2/C3/C4/C5: a reference-only Plane, fully determined by one of six
    construction methods, never more than one at once:
    - `OFFSET_FACE`: an offset from an existing planar Body face, a fixed
      reference plane, or an existing Plane (`face_refs` has exactly one
      `PlaneRef` entry, `offset` is set).
    - `MIDPLANE` (C3): equidistant between two parallel plane-like
      references - any mix of Body faces, fixed reference planes, and
      existing Planes (`face_refs` has exactly two `PlaneRef` entries,
      `offset` is unset).
    - `NORMAL_TO_LINE_AT_POINT`: a Sketch Line's direction through one of
      its own endpoints (`line_ref`/`point_ref` set, `face_refs` empty).
    - `NORMAL_TO_CURVE_AT_POINT`: a Sketch Arc's tangent direction at one of
      its own endpoints, through that same Point (`line_ref`/`point_ref`
      set, same shape as `NORMAL_TO_LINE_AT_POINT` - `line_ref` names the
      Arc despite the field's name, see `PlaneType`'s own doc comment).
    - `NORMAL_TO_EDGE_THROUGH_VERTEX` (C4): a straight Body edge's direction
      through a given Body vertex (`edge_ref`/`vertex_ref` set).
    - `PARALLEL_TO_FACE_THROUGH_VERTEX` (C4): parallel to a plane-like
      reference, through a given Body vertex instead of a numeric offset
      (`face_refs` has exactly one `PlaneRef` entry, `vertex_ref` set,
      `offset` unset).
    - `THREE_POINTS` (C4): the plane through three points, each a Body
      vertex or a Sketch Point (`point_refs` has exactly three entries -
      see `PointRef`).
    Produces no mesh/solid of its own, but (C3) can anchor a Sketch via
    `SketchFeature.plane_feature_id` - this is a pure reference object other
    Features (a Sketch, so far) can target.

    Which combination of fields is populated, matching `plane_type`, is
    enforced by the router at construction time
    (`app.document.router._validate_create_plane_payload`), not by this
    dataclass itself, the same "payload shape validated by the API layer,
    not encoded in the domain type" split `ExtrudeFeature`'s Boss-vs-Cut
    `target_body_ids` rules already use. All fields are optional here
    (rather than six mutually-exclusive dataclasses) so one concrete type
    can flow through `Part.features`/`Feature.get_feature` uniformly, same
    reason `ExtrudeFeature` doesn't split into `BossFeature`/`CutFeature`.

    `face_ref` (C2, singular) became `face_refs` (C3, a list) so `MIDPLANE`
    can reuse the same field as `OFFSET_FACE` instead of adding a second,
    near-identical pair of fields - `OFFSET_FACE` and
    `PARALLEL_TO_FACE_THROUGH_VERTEX` (C4) always have exactly one entry,
    `MIDPLANE` always exactly two. C5 widened each entry from a plain
    `SubShapeRef` (a Body face only) to a `PlaneRef` (a Body face, a fixed
    reference plane, or an existing Plane), on user feedback that a Plane
    ought to be a valid reference too - e.g. "offset from XY plane",
    "midplane between an existing Plane and a Face" - without needing a
    parallel set of fields per reference kind. `vertex_ref` (C4) is likewise
    shared between `NORMAL_TO_EDGE_THROUGH_VERTEX` and
    `PARALLEL_TO_FACE_THROUGH_VERTEX`.

    The actual OCCT/plane-geometry resolution lives in
    `app.document.create_plane` (every type except `NORMAL_TO_LINE_AT_POINT`
    needs OCCT - planarity/parallelism/line-type checks have no OCCT-free
    equivalent) and `app.document.plane_geometry` (`NORMAL_TO_LINE_AT_POINT`'s
    own dispatch, plus `THREE_POINTS`'s pure cross-product math once each
    `PointRef` is already resolved to a world position - no OCCT needed at
    all as long as every Sketch involved sits on a fixed plane; C3's
    custom-plane case still needs OCCT to resolve a Sketch's own anchor
    plane first, see `app.document.create_plane.resolve_sketch_basis`),
    mirroring the existing app.document.extrude / app.sketch.store split by
    OCCT dependency."""

    id: str
    plane_type: PlaneType
    face_refs: list[PlaneRef] = field(default_factory=list)
    offset: float | None = None
    line_ref: SketchEntityRef | None = None
    point_ref: SketchEntityRef | None = None
    edge_ref: SubShapeRef | None = None
    vertex_ref: SubShapeRef | None = None
    point_refs: list[PointRef] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "create_plane"

    @property
    def produces(self) -> Produces:
        return Produces.PLANE


@dataclass
class FilletFeature(Feature):
    """Prompt D: rounds every edge named in `edge_refs` (all of which must
    belong to the same Body - see `app.document.fillet._mixed_body_
    selection`) with one shared `radius`, via OCCT `BRepFilletAPI_
    MakeFillet`. No per-edge radii, no variable/setback fillets - v1 scope,
    matching this project's established conservative-scoping convention
    (mirrors `CreatePlaneFeature`'s own "narrowest correct slice first"
    precedent).

    Unlike Boss/Cut, a Fillet *modifies* a Body's shape rather than
    creating a new one - it therefore keeps the target Body's existing
    `body_id` (an in-place shape replacement in `app.document.extrude.
    compute_part_bodies`'s `bodies` accumulator), rather than minting a new
    one the way a fresh Boss with no `target_body_ids` does. This preserves
    A1's body-identity guarantee: any later Boss/Cut `target_body_ids`
    entry, or `SubShapeRef`/Fillet `edge_refs` entry, that already named
    this Body keeps resolving to it after a Fillet is applied, instead of
    silently dangling."""

    id: str
    edge_refs: list[SubShapeRef] = field(default_factory=list)
    radius: float = 0.0

    @property
    def type(self) -> str:
        return "fillet"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class ChamferFeature(Feature):
    """Prompt E: bevels every edge named in `edge_refs` (all of which must
    belong to the same Body - see `app.document.chamfer._mixed_body_
    selection`) with one shared `distance`, via OCCT `BRepFilletAPI_
    MakeChamfer`. Same narrow v1 scope as `FilletFeature`: no per-edge
    distances, no two-distance/angle chamfer variants - this prompt follows
    Prompt D's design decisions exactly rather than re-deriving them (see
    that Feature's own docstring for the reasoning in full).

    Same body-identity decision as `FilletFeature`, for the same reason:
    keeps the target Body's existing `body_id` (an in-place shape
    replacement in `app.document.extrude.compute_part_bodies`'s `bodies`
    accumulator) rather than minting a new one - matters doubly here since
    a Fillet and a Chamfer can both apply to the same Body, in either
    order, in a real feature tree, and both need to preserve A1's
    body-identity guarantee identically for that to work."""

    id: str
    edge_refs: list[SubShapeRef] = field(default_factory=list)
    distance: float = 0.0

    @property
    def type(self) -> str:
        return "chamfer"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class RevolveMode(str, Enum):
    """Boss/Cut parity with `ExtrudeType` (Prompt F) - a `RevolveFeature`
    combines its revolved solid with `target_body_ids` exactly the same way
    an `ExtrudeFeature` does (see that type's own docstring), just built by
    revolving a Profile around an axis instead of prismatically extruding
    it. A separate enum (not a reuse of `ExtrudeType`) since a Revolve's
    "mode" is conceptually its own field, even though the two enums share
    identical values - matches this codebase's established "each Feature
    type owns its own enum" convention (`ExtrudeType`/`SubShapeType`/
    `PlaneType` are none of them reused across Feature types either)."""

    BOSS = "boss"
    CUT = "cut"


@dataclass
class RevolveFeature(Feature):
    """Prompt F: revolves the closed Profile of the SketchFeature referenced
    by `sketch_feature_id` around `axis_ref` (a Sketch Line reference - see
    `app.sketch.models.SketchEntityRef`, restricted to `SketchEntityType.LINE`
    here; a Point/Circle `axis_ref` is invalid and rejected as
    `invalid_axis_ref`, see `app.document.revolve`) by `angle` degrees, an
    arbitrary value in `(0, 360]` (360 itself is valid - a full revolve),
    then combines the resulting solid with `target_body_ids` exactly like
    `ExtrudeFeature` does: Boss fuses into each named Body (or starts a new
    one if empty), Cut subtracts from each named Body (non-empty required -
    see `app.document.router._validate_target_body_ids`, generalized to
    accept a Body originating from either an ExtrudeFeature or a
    RevolveFeature).

    `axis_ref`'s Sketch is *not* required to be the same Sketch as the
    Profile being revolved (confirmed explicitly, not the prompt's own
    "same-Sketch" default recommendation) - the axis Line can live in any
    Sketch in the Part, resolved independently via its own owning
    SketchFeature's basis (`app.document.create_plane.resolve_sketch_basis`)
    the same way the Profile's own Sketch is. The axis Line is also allowed
    to be one of the Profile's own entities (confirmed explicitly) - no
    special-case rejection for a self-referencing axis.

    The actual OCCT geometry construction (`BRepPrimAPI_MakeRevol`) lives in
    `app.document.revolve`, not here - same separation `ExtrudeFeature`
    keeps from `app.document.extrude`."""

    id: str
    sketch_feature_id: str
    axis_ref: SketchEntityRef
    angle: float
    mode: RevolveMode
    target_body_ids: list[str] = field(default_factory=list)

    # Prompt G: mirrors ExtrudeFeature.profile_refs exactly - which outer
    # profile(s) of the backing Sketch to revolve, empty meaning every one
    # currently detected.
    profile_refs: list[SketchEntityRef] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "revolve"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class SweepMode(str, Enum):
    """Boss/Cut parity with `ExtrudeType`/`RevolveMode` (the Sweep module) -
    a `SweepFeature` combines its swept solid with `target_body_ids` exactly
    the same way an `ExtrudeFeature`/`RevolveFeature` does. Its own separate
    enum, matching this codebase's established "each Feature type owns its
    own enum" convention."""

    BOSS = "boss"
    CUT = "cut"


@dataclass
class SweepFeature(Feature):
    """Sweeps the closed Profile of the SketchFeature referenced by
    `sketch_feature_id` along `path_refs` - an *ordered* list of Sketch Line
    references (see `app.sketch.models.SketchEntityRef`, each restricted to
    `SketchEntityType.LINE`; a Point/Circle entry is invalid and rejected as
    `invalid_path_ref`, see `app.document.sweep`) forming one connected
    chain, then combines the resulting solid with `target_body_ids` exactly
    like `ExtrudeFeature`/`RevolveFeature` do: Boss fuses into each named
    Body (or starts a new one if empty), Cut subtracts from each named Body
    (non-empty required - see `app.document.router._validate_target_body_
    ids`, generalized to accept a Body originating from any of Extrude/
    Revolve/Sweep).

    `path_refs` entries are explicit, user-ordered picks (confirmed
    explicitly, not "the whole open chain of one Sketch") and may each name
    a Line in a *different* Sketch (confirmed explicitly, not restricted to
    one Sketch) - resolved independently via each entry's own owning
    SketchFeature's basis (`app.document.create_plane.resolve_sketch_basis`),
    then chained by matching 3D world-space endpoint position (not a shared
    Point id, which cross-Sketch entries never have) within a small
    tolerance - see `app.document.sweep.resolve_path_wire`. Consecutive
    entries in list order must share a coincident endpoint (`disconnected_
    path` otherwise); the first and last entries' endpoints may also
    coincide, producing a closed (looping) path - both open and closed paths
    are valid, confirmed explicitly, distinguished structurally rather than
    by a separate flag.

    The actual OCCT geometry construction (`BRepOffsetAPI_MakePipe`) lives
    in `app.document.sweep`, not here - same separation `ExtrudeFeature`/
    `RevolveFeature` keep from their own modules."""

    id: str
    sketch_feature_id: str
    path_refs: list[SketchEntityRef]
    mode: SweepMode
    target_body_ids: list[str] = field(default_factory=list)

    # Mirrors ExtrudeFeature.profile_refs/RevolveFeature.profile_refs
    # exactly - which outer profile(s) of the backing Sketch to sweep,
    # empty meaning every one currently detected.
    profile_refs: list[SketchEntityRef] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "sweep"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class MergeMode(str, Enum):
    """Pattern/Mirror scoping's Phase 5 (`docs/pattern-mirror-scope.md`
    §2.10/§4): whether a `MirrorFeature`/`PatternFeature`'s realized
    instances register as independent Bodies or get fused together into
    one, on both Feature types. Mirrors `ExtrudeType`/`SweepMode`'s
    str-Enum pattern. `KEEP_SEPARATE` (the default, matching every
    mainstream CAD tool's own default) is every Phase 1-4 Feature's
    existing behaviour, unchanged - each realized instance registers as
    its own Body via the established `#N`-suffix convention. `FUSE_INTO_
    ONE` fuses every realized instance plus the original source Body/
    Bodies together via repeated `BRepAlgoAPI_Fuse` (see `app.document.
    extrude._fuse_realized_instances`, sharing `_apply_boss_or_cut`'s own
    multi-target fuse/survivor-tie-break/`_register_solids` convention),
    registered as a single Body under whichever source's own Feature
    index sorts lowest - not a brand-new id, the same "the fused result
    inherits an existing target's identity" convention `_apply_boss_or_
    cut`'s own Boss-into-target case already uses."""

    KEEP_SEPARATE = "keep_separate"
    FUSE_INTO_ONE = "fuse_into_one"


@dataclass
class MirrorFeature(Feature):
    """Pattern/Mirror scoping's Phase 1 (see `docs/pattern-mirror-scope.md`
    §2.1/§4): reflects every Body named in `source_body_ids` across
    `mirror_plane`, producing one brand-new, independent Body per source via
    OCCT `gp_Trsf.SetMirror` (a `gp_Ax2` plane-mirror, not the `gp_Ax1`
    line-mirror overload) - see `app.document.mirror.resolve_mirror_from_
    bodies`.

    `mirror_plane: PlaneRef` is reused verbatim from Create Plane/`OFFSET_
    FACE` (see `PlaneRef`'s own docstring) rather than inventing a new
    reference type - this is what lets `MirrorFeature` support "mirror
    about a fixed plane", "mirror about a Body face", and "mirror about an
    existing Plane feature" as the exact same field, matching every
    mainstream CAD tool's own unified "pick a plane-like thing" mirror UX.

    `source_body_ids` accepts one or more entries - on-device feedback on
    the guided "New > Mirror" flow ("select body/bodies (multiple bodies
    should be supported)") pulled multi-body seeding forward from its
    original Phase 6 scoping into Phase 1 directly (see `docs/pattern-
    mirror-scope.md`'s updated Phase 1/6 entries). Defaults to `KEEP_
    SEPARATE` (see `MergeMode`) - a single source mints a brand-new Body
    identified by its own Feature id directly; 2+ sources each get their
    own `#N`-suffixed id (see `app.document.extrude.compute_part_bodies`'s
    own `MirrorFeature` branch), like a Boss with no `target_body_ids`.
    `merge=FUSE_INTO_ONE` (Phase 5) instead fuses every mirrored copy plus
    every source Body together into a single Body (see `app.document.
    extrude._fuse_realized_instances`). `source_feature_ids` (Phase 6,
    §2.8) names Feature-tree entries as additional sources, resolved to
    their current output Body/Bodies via the one-line `base_feature_id`
    lookup (`{bid for bid in bodies if base_feature_id(bid) == fid}`),
    combined with `source_body_ids` and deduplicated - see `app.document.
    mirror.resolve_mirror_from_bodies`.

    `tool_feature_id` (Pattern/Mirror Phase 8, `docs/pattern-mirror-scope.md`
    §2.11) is a third, mutually-exclusive seed-picking mode - names an
    upstream Extrude/Revolve/Sweep Feature in Cut mode, or Boss mode with a
    non-empty `target_body_ids` (a targetless Boss has no shared-target
    problem - the ordinary `source_body_ids`/`source_feature_ids` path
    above already copies it correctly as an independent Body). Its presence
    *is* the mode switch, mirroring `PlaneRef`'s own "which optional field
    is set selects the behaviour" convention - no separate mode enum. In
    this mode, `source_body_ids`/`source_feature_ids` must both be empty
    (validated by `app.document.router._validate_tool_feature_id`) and
    `merge` is meaningless (there is exactly one target by construction -
    `KEEP_SEPARATE` has no referent, so the router rejects it outright).
    Rather than producing a brand-new Body, this mode mirrors the
    referenced Feature's own pre-boolean tool shape once and applies a
    single `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse` (matching that Feature's own
    Cut/Boss mode) against its own single target Body - see
    `app.document.mirror.resolve_mirror_tool_feature_from_bodies`, the
    actual fix for "mirror an asymmetric hole pattern into the same part"
    (§2.11's own "why FUSE_INTO_ONE doesn't cover this" reasoning)."""

    id: str
    source_body_ids: list[str]
    mirror_plane: PlaneRef
    # Phase 6 (§2.8/§4): Feature-tree entries as additional sources - see
    # this class's own docstring.
    source_feature_ids: list[str] = field(default_factory=list)
    # Phase 5 (§2.10): KEEP_SEPARATE (default) vs. FUSE_INTO_ONE.
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    # Phase 8 (§2.11): a third, mutually-exclusive seed-picking mode - see
    # this class's own docstring.
    tool_feature_id: str | None = None

    @property
    def type(self) -> str:
        return "mirror"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class MergeFeature(Feature):
    """The first of the Boolean family (Subtract/Common/Split follow in
    later work): fuses every Body named in `body_ids` (2+ required - see
    `app.document.router._validate_merge_body_ids`) into a single Body via
    repeated `BRepAlgoAPI_Fuse` - symmetric, no target/tool distinction, no
    options. Every input Body is always consumed into the result, unlike
    `MirrorFeature`/`PatternFeature`'s optional `MergeMode.FUSE_INTO_ONE` -
    Merge only ever fuses, so it needs none of that enum.

    Reuses `app.document.extrude._fuse_realized_instances` verbatim (an
    empty `realized_shapes` list, `body_ids` as `base_ids`) rather than
    reimplementing the fuse/survivor-tie-break/`_register_solids` logic a
    second time - see that function's own docstring. The surviving Body id
    is whichever `body_ids` entry's owning Feature sorts lowest in
    `feature_index` (`base_feature_id`-resolved, so a `#N`-suffixed id still
    resolves to its real owning Feature), matching `_apply_boss_or_cut`'s/
    `_fuse_realized_instances`'s own tie-break exactly."""

    id: str
    body_ids: list[str]

    @property
    def type(self) -> str:
        return "merge"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class BooleanOperation(str, Enum):
    """Boolean family, second/third entries: SUBTRACT removes every Body
    named by `tool_body_ids` from every Body named by `target_body_ids`
    (`BRepAlgoAPI_Cut`); COMMON keeps only their shared volume
    (`BRepAlgoAPI_Common`) - both are the same `BooleanFeature` shape (see
    below), differing only in this field, mirroring `ExtrudeType`'s own
    Boss/Cut str-Enum pattern."""

    SUBTRACT = "subtract"
    COMMON = "common"


@dataclass
class BooleanFeature(Feature):
    """The second/third entries of the Boolean family (Merge above was the
    first; Split follows in later work): unlike `MergeFeature`'s symmetric
    fuse-everything-together, this has a real target/tool distinction -
    `target_body_ids` (1+ required) are the Bodies operated *on*,
    `tool_body_ids` (1+ required, disjoint from `target_body_ids` - see
    `app.document.router._validate_boolean_body_ids`) are the Bodies
    operated *with*. For each target Body, every tool Body's current shape
    is folded in via repeated `BRepAlgoAPI_Cut` (SUBTRACT) or
    `BRepAlgoAPI_Common` (COMMON) - see `app.document.boolean`.

    Both sides are already-existing, already-registered Bodies - unlike
    `ExtrudeFeature`/`RevolveFeature`/etc.'s own Boss/Cut, which combines a
    freshly-computed transient solid into/from `target_body_ids`, this
    combines two sets of Bodies that both already have their own identity
    and history. That's what makes `consume_tool_bodies` a real, novel
    choice here (default `True`, matching `GearFeature.is_internal`'s
    plain-bool convention rather than a new enum): today's Cut always
    implicitly discards its transient solid (it was never a registered Body
    to begin with), but a Subtract/Common's tool Bodies are real Bodies a
    user might still want to keep around afterward - `False` leaves every
    `tool_body_ids` entry registered and untouched."""

    id: str
    operation: BooleanOperation
    target_body_ids: list[str]
    tool_body_ids: list[str]
    consume_tool_bodies: bool = True

    @property
    def type(self) -> str:
        return "boolean"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass(frozen=True)
class SplitToolRef:
    """Boolean family, fourth/last entry (`SplitFeature`): the cutting tool
    a Split divides its `target_body_id` against - exactly one of the three
    fields is ever set (payload shape validated by the router, same
    "exactly one of N fields" convention `PointRef`/`PlaneRef` already
    establish - see either's own docstring):
    - `plane_ref`: any `PlaneRef` (a Body face, a fixed reference plane, or
      an existing Plane feature) - reused verbatim rather than inventing a
      narrower "just the fixed/existing-Plane cases" type, since a Body
      face is just as valid a cutting plane for a Split as it is for a
      Mirror.
    - `surface_feature_id`: an existing, already-created `SurfaceFeature` in
      this Part (built ahead of time via New > Feature > Surfacing > Extrude
      Surface, with a real closed profile) - the reason `SurfaceFeature`
      exists as a real, reusable Feature rather than a throwaway internal
      helper (see its own docstring's explicit "A Split feature ... is the
      reason this exists"). Lets a Split cut along a Sketch-derived,
      potentially non-planar cutting tool, not just a flat plane.
    - `sketch_line_ref`: a single connectable-curve Sketch entity (Line,
      Arc, EllipseArc, or Spline - see `app.document.split.
      CONNECTABLE_CURVE_ENTITY_TYPES`), used directly with no backing
      SurfaceFeature ever created - an "infinite" cutting surface extruded
      normal to the entity's own host Sketch plane, assumed automatically
      (no direction override: there is no persisted Feature for one to
      attach to). This is the guided flow's own replacement for what used
      to be an inline "New Surface" mini-step that silently persisted a
      real SurfaceFeature as a side effect of picking a Sketch as a Split
      tool - picking a raw sketch curve now resolves immediately instead.

    Resolved to an oversized half-space solid "block" by `app.document.
    split._split_tool_block` - see that module's own top-level docstring
    for why a manually-built block (rather than `BRepAlgoAPI_Splitter`/
    `BOPAlgo`) is what actually performs the split."""

    plane_ref: PlaneRef | None = None
    surface_feature_id: str | None = None
    sketch_line_ref: SketchEntityRef | None = None


@dataclass
class SplitFeature(Feature):
    """Boolean family, fourth/last entry (Merge/Subtract/Common came
    first): divides `target_body_id`'s current shape into two independent,
    surviving Bodies along `tool` (a Plane or an existing Surface - see
    `SplitToolRef`'s own docstring), via `app.document.split.resolve_split_
    pieces`. Unlike Merge/Boolean (which combine 2+ already-existing
    Bodies), Split takes exactly one target and produces exactly two
    outputs from it - both pieces are registered back under `target_body_
    id` itself via `_register_solids` (see `app.document.extrude.compute_
    part_bodies`'s own `SplitFeature` branch), yielding `target_body_id#0`/
    `target_body_id#1` the same way any other multi-solid-producing
    operation in this codebase does (Boss over a multi-profile Sketch, a
    Cut that severs a Body in two, ...) - there is no third "consume vs
    keep" choice the way `BooleanFeature.consume_tool_bodies` has, since
    both halves of a Split always survive.

    Deliberately does not build on `BRepAlgoAPI_Splitter`/`BOPAlgo` (not
    confirmed available in this project's pinned pythonocc-core build) -
    see `app.document.split`'s own top-level docstring for the oversized-
    half-space-block technique this uses instead, built from `target_body_
    id`'s own `Bnd_Box` so it stays robust for a cutting Plane/Surface at
    any orientation relative to the target Body, not just one aligned with
    its bounding-box axes."""

    id: str
    target_body_id: str
    tool: SplitToolRef

    @property
    def type(self) -> str:
        return "split"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class FixedAxis(str, Enum):
    """Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md`
    §2.2/§2.5): a world-space X/Y/Z direction, for `PatternDirectionRef`'s
    third option alongside a Body edge or a Sketch Line - the cheap, obvious
    v1 addition the scope doc itself calls out. Mirrors `ExtrudeType`/
    `SubShapeType`'s str-Enum pattern."""

    X = "x"
    Y = "y"
    Z = "z"


@dataclass(frozen=True)
class PatternDirectionRef:
    """Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md`
    §2.2/§2.5): exactly one of three - a straight Body edge, a straight
    Sketch Line, or a fixed world axis - mirrors `PlaneRef`'s own "exactly
    one of N fields, payload shape validated by the router" convention
    (see `app.document.router._validate_pattern_direction_ref`). None of
    the three existing reference types alone covers "an edge OR a sketch
    line OR a fixed world axis", so this is genuinely new rather than a
    reuse.

    Resolved to a plain world-space direction (`app.document.pattern.
    direction_vector`), not a full axis with an origin point - a
    Rectangular Pattern only ever translates along a direction, it never
    needs a pivot the way `PatternAxisRef` (Phase 4, Circular Pattern's own
    axis reference) does."""

    edge_ref: SubShapeRef | None = None
    sketch_line_ref: SketchEntityRef | None = None
    fixed_axis: FixedAxis | None = None


@dataclass
class SurfaceFeature(Feature):
    """Extrudes the Sketch wire referenced by `sketch_feature_id` - open or
    closed - into a non-solid `TopoDS_Shell` via OCCT `BRepPrimAPI_
    MakePrism` applied directly to the wire rather than to a face (see
    `app.document.surface.resolve_surface_from_bodies`) - "Extrude but a
    shell instead of a solid": no Boss/Cut, no `target_body_ids`, this
    Feature only ever mints a brand-new, standalone Surface of its own. A
    Split feature (separate, upcoming work) is the reason this exists as a
    real, reusable Feature rather than a throwaway internal helper.

    `start_distance`/`end_distance` share `ExtrudeFeature`'s own signed-
    distance-from-the-sketch-plane convention exactly (see that class's own
    docstring) - the surface spans from `start_distance` to `end_distance`
    along `direction_ref`.

    `direction_ref` reuses `PatternDirectionRef` verbatim (an edge, a
    Sketch Line, or a fixed world axis - see that type's own docstring)
    rather than inventing a new reference type; `None` (the default)
    extrudes normal to the backing Sketch's own host plane, matching
    `ExtrudeFeature`'s implicit direction.

    `profile_refs` mirrors `ExtrudeFeature.profile_refs` exactly - narrows
    a MultiProfile Sketch down to specific outer profile(s) via
    `app.document.extrude.select_profiles`; empty (the default) uses every
    detected outer profile. Only meaningful when the backing Sketch's
    detected geometry is a closed profile (or MultiProfile) - a single open
    chain has no profile-selection concept of its own (mirrors
    `app.document.loft`'s identical, more conservative open-chain scoping),
    so this field is simply inert whenever the Sketch resolves to an open
    wire instead."""

    id: str
    sketch_feature_id: str
    start_distance: float
    end_distance: float
    direction_ref: PatternDirectionRef | None = None
    profile_refs: list[SketchEntityRef] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "surface"

    @property
    def produces_solid_geometry(self) -> bool:
        return False

    @property
    def produces(self) -> Produces:
        return Produces.SURFACE


class PatternType(str, Enum):
    """Pattern/Mirror scoping's Phase 4 (`docs/pattern-mirror-scope.md`
    §2.3/§4): which construction method a `PatternFeature` uses - mirrors
    `PlaneType`'s "one dataclass, many construction methods" precedent
    rather than splitting Rectangular/Circular into two Feature types (see
    `docs/didsa-longterm-vision-and-model.md` §6's explicit decision
    against giving patterns their own family of semantic sub-types).
    Defaults to `RECTANGULAR` so every Phase-2-created `PatternFeature`
    (persisted before this field existed) round-trips unchanged - see
    `app.document.native_format`'s own `.get("pattern_type", ...)`
    fallback."""

    RECTANGULAR = "rectangular"
    CIRCULAR = "circular"


@dataclass(frozen=True)
class PatternAxisRef:
    """Pattern/Mirror scoping's Phase 4 (`docs/pattern-mirror-scope.md`
    §2.3/§2.7): exactly one of three - a circular Body edge, a cylindrical
    Body face, or a Sketch Line - mirrors `PatternDirectionRef`'s own
    "exactly one of N fields, payload shape validated by the router"
    convention (see `app.document.router._validate_pattern_axis_ref`).

    Unlike `PatternDirectionRef`, this resolves to a full world-space axis
    (an origin point *and* a direction, not just a direction -
    `app.document.pattern._axis_from_ref`) - a Circular Pattern rotates
    around a real pivot, not just along a direction. `edge_ref`/`face_ref`
    each already carry an implicit origin (the circle's centre, or a point
    on the cylinder's own axis) via their own OCCT geometry; `sketch_line_ref`
    supplies one explicitly (mirroring `RevolveFeature.axis_ref`'s identical
    Sketch-Line-as-axis precedent, restricted to `SketchEntityType.LINE`
    the same way)."""

    edge_ref: SubShapeRef | None = None
    face_ref: SubShapeRef | None = None
    sketch_line_ref: SketchEntityRef | None = None


@dataclass
class PatternFeature(Feature):
    """Pattern/Mirror scoping's Phase 2/4 (`docs/pattern-mirror-scope.md`
    §2.2/§2.3/§4): one `PatternFeature` type covers both Rectangular and
    Circular patterns via `pattern_type` (mirrors `CreatePlaneFeature`'s own
    "one dataclass, many construction methods" precedent) - repeats the
    Body named in `source_body_ids` either:
    - **Rectangular** (`pattern_type=RECTANGULAR`, the default - Phase 2):
      along `direction_1` (`count_1` instances, `spacing_1` apart) and, if
      `direction_2` is set, crossed with `direction_2` (`count_2` instances,
      `spacing_2` apart) for a 2D grid, via OCCT `gp_Trsf.SetTranslation`
      per instance. `reverse_1`/`reverse_2` flip their respective direction
      before use. The flattened linear index for instance `(i, j)` is
      `i * count_2 + j` (row-major).
    - **Circular** (`pattern_type=CIRCULAR` - Phase 4): `count_angular`
      instances spaced evenly across `angle_total` degrees (default 360 -
      a full revolution) around `axis` (a `PatternAxisRef`), via OCCT
      `gp_Trsf.SetRotation(gp_Ax1, angle)` per instance - the per-instance
      angular step is `angle_total / count_angular` (so a full-360 pattern
      distributes evenly around the circle with no overlapping duplicate at
      both 0° and 360°). `reverse_angular` flips the rotation direction.
      The linear index is simply `count_angular`'s own iteration index `i`
      (no second dimension - `count_2`/`direction_2` are meaningless here).

    Both construction methods share the identical "index 0 is the untouched
    seed Body itself" convention (see `app.document.pattern.
    resolve_pattern_from_bodies`/`resolve_pattern_circular_from_bodies`):
    already registered under its own id by whichever earlier Feature
    produced it, this Feature registers only the *other* instances as
    brand-new Bodies (see `app.document.extrude.compute_part_bodies`'s own
    `PatternFeature` branch), matching every mainstream CAD tool's own
    "count includes the original" convention rather than adding a redundant
    zero-offset copy on top of the seed.

    `source_body_ids` accepts one or more entries (Phase 6 - widened from
    Phase 2/4's original exactly-one, mirroring `MirrorFeature.source_
    body_ids`'s own Phase 1 revision exactly - see `app.document.router.
    _validate_pattern_source_body_ids`). Every source shares the identical
    instance-transform grid (the same `direction_1`/`direction_2`/`axis`,
    `count_1`/`count_2`/`count_angular`, `spacing_1`/`spacing_2`,
    `reverse_1`/`reverse_2`/`reverse_angular`) - each source's own index 0
    is that source's own already-existing Body, untouched, exactly like
    the single-source case (see `app.document.pattern.resolve_pattern_
    from_bodies`, now keyed per-source). `source_feature_ids` (also Phase
    6) names Feature-tree entries as additional sources - resolved to
    their current output Body/Bodies via the same one-line `base_feature_
    id` lookup `MirrorFeature.source_feature_ids` uses (see `docs/pattern-
    mirror-scope.md` §2.8), combined with `source_body_ids` and
    deduplicated (a Body named both directly and via its own owning
    Feature is only ever patterned once).

    `tool_feature_id` (Pattern/Mirror Phase 8, `docs/pattern-mirror-scope.md`
    §2.11) is a third, mutually-exclusive seed-picking mode, mirroring
    `MirrorFeature.tool_feature_id`'s own identical shape exactly - names
    an upstream Extrude/Revolve/Sweep Feature in Cut mode, or Boss mode
    with a non-empty `target_body_ids`, mutually exclusive with `source_
    body_ids`/`source_feature_ids` and with `merge` forced away from
    `KEEP_SEPARATE` (meaningless once there's exactly one target). Index 0
    is already baked into the target (the seed Cut/Boss already ran once,
    earlier in feature order) - this mode only computes the *other*
    `count-1` transformed tool copies (same instance loop, `skip_indices`
    applies unchanged), unions them into one combined tool, and applies a
    single `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse` against the target - not
    `count-1` separate booleans. v1 scope: exactly one target (`target_
    body_ids[0]` of the referenced Feature) - see `app.document.pattern.
    resolve_pattern_tool_feature_from_bodies`.

    Every Rectangular-only and Circular-only field is optional/defaulted
    (not just the ones Phase 2 already had before Circular existed) -
    which fields are actually required for a given `pattern_type` is
    enforced by the router at construction time
    (`app.document.router._validate_pattern_payload`), not by this
    dataclass itself, the same "payload shape validated by the API layer,
    not encoded in the domain type" split `CreatePlaneFeature`/
    `ExtrudeFeature` already use.

    Defaults to `KEEP_SEPARATE` (see `MergeMode`) - every realized
    instance registers as its own Body. `merge=FUSE_INTO_ONE` (Phase 5)
    instead fuses every realized (non-skipped) instance plus the untouched
    seed Body together into a single Body (see `app.document.extrude.
    _fuse_realized_instances`), registered under the seed Body's own
    existing id rather than a brand-new one (mirrors `_apply_boss_or_cut`'s
    own "the fused result inherits an existing target's identity"
    convention). `skip_indices` (Phase 3) suppresses individual instances by
    their own linear index (the same `i * count_2 + j` row-major index for
    Rectangular, or the plain angular-step index for Circular, that
    `count_1`/`count_2`/`count_angular` themselves use) - a skipped index
    is filtered out before `app.document.pattern._rectangular_instances`/
    `_circular_instances` ever build a `BRepBuilderAPI_Transform` for it,
    so a skipped instance never even briefly exists as a shape (and is
    therefore never part of a `FUSE_INTO_ONE` merge either). Index `0`
    (the untouched seed Body) can never usefully appear in `skip_indices` -
    it was never going to be (re)created in the first place - so the
    router rejects it explicitly (`app.document.router.
    _validate_pattern_skip_indices`) rather than silently no-op-ing it."""

    id: str
    source_body_ids: list[str]
    # Phase 6 (§2.8/§4): Feature-tree entries as additional sources,
    # resolved to their current output Body/Bodies - see this class's own
    # docstring.
    source_feature_ids: list[str] = field(default_factory=list)
    pattern_type: PatternType = PatternType.RECTANGULAR
    # Rectangular:
    direction_1: PatternDirectionRef | None = None
    count_1: int = 1
    spacing_1: float = 0.0
    reverse_1: bool = False
    direction_2: PatternDirectionRef | None = None
    count_2: int = 1
    spacing_2: float = 0.0
    reverse_2: bool = False
    # Circular:
    axis: PatternAxisRef | None = None
    count_angular: int = 1
    angle_total: float = 360.0
    reverse_angular: bool = False
    # Phase 3 (both construction methods):
    skip_indices: list[int] = field(default_factory=list)
    # Phase 5 (§2.10): KEEP_SEPARATE (default) vs. FUSE_INTO_ONE.
    merge: MergeMode = MergeMode.KEEP_SEPARATE
    # Phase 8 (§2.11): a third, mutually-exclusive seed-picking mode - see
    # this class's own docstring.
    tool_feature_id: str | None = None

    @property
    def type(self) -> str:
        return "pattern"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class ImportSourceFormat(str, Enum):
    """Which interchange format an `ImportFeature`'s own `source_data` bytes
    are - mirrors `ExtrudeType`/`SweepMode`'s str-Enum pattern. `STEP` reads
    real B-rep geometry (`STEPControl_Reader`); `STL`/`OBJ`/`GLTF` are all
    triangle-soup mesh formats, decoded by `app.document.mesh_import` into
    the same `MeshData` shape `app.document.mesh_export`'s encoders produce
    on the way out, then rebuilt into a single surface-less, triangulation-
    only `TopoDS_Face` (the same convention OCCT's own STL import uses) -
    see `app.document.import_geometry` for both paths."""

    STEP = "step"
    STL = "stl"
    OBJ = "obj"
    GLTF = "gltf"


@dataclass
class ImportFeature(Feature):
    """Brings an external file's geometry into the Part as a fixed,
    non-parametric Body (locked-in scope, AskUserQuestion round: "import as
    a dumb body, future features will be able to edit existing bodies
    (scale, move face, delete face, move body)" - this Feature itself has
    no editable parameters of its own beyond which file it wraps).

    `source_data` is the actual uploaded file's raw bytes - the true source
    of truth (there is no simpler parametric representation to derive from,
    unlike every other Feature type here), re-parsed via `app.document.
    import_geometry.resolve_import` on every recompute, matching this
    codebase's "re-derive, don't cache" philosophy. Persisted as-is (base64
    inside JSON) by both the native file format and this Feature's own
    create payload.

    Unlike Extrude/Revolve/Sweep, there is no Boss/Cut `mode` and no
    `target_body_ids` here - importing a file always starts a brand-new
    Body (mirroring a fresh Boss with an empty `target_body_ids`), never
    fuses/cuts into an existing one on its own. The imported Body can still
    be *targeted* by a later Extrude/Revolve/Sweep's own `target_body_ids`
    exactly like any other Body (see `app.document.router._validate_target_
    body_ids`, widened to accept `ImportFeature`-originated ids too) - e.g.
    "Cut my extruded solid using the imported STEP body" is a normal,
    supported combination, just expressed via the *other* Feature's own
    Cut, not this one.

    A STEP import is a real B-rep solid (whatever `STEPControl_Reader`
    transferred), usable everywhere a Body already is (Boss/Cut target,
    Fillet/Chamfer edge source, Create Plane face reference) exactly like
    an Extrude/Revolve/Sweep result - no compromise there. A mesh import
    (STL/OBJ/glTF) is a surface-less, triangulation-only shape instead (the
    same shape OCCT itself builds for a bare STL file) - sufficient for the
    requested "view, measure, model around" use case (it renders, and its
    own vertices/edges are real topology other Features can already
    reference the same way any Body's are), but not guaranteed to survive a
    Boolean operation the way a genuine B-rep solid does; no attempt is made
    here to sew/heal it into a watertight solid - that remains a real,
    separate limitation flagged for whoever needs true CSG on an ingested
    mesh next.

    Always registers as exactly one Body, keyed by this Feature's own id -
    unlike Extrude/Revolve/Sweep's Boss path, `compute_part_bodies` never
    splits an ImportFeature's result by its `TopAbs_SOLID` count (see
    `app.document.extrude`'s own ImportFeature branch): the multi-solid
    split exists for a multi-profile Sketch boss, a scenario that doesn't
    apply here, and a mesh import's own shape has no `TopoDS_Solid` at all
    to split by in the first place - splitting is skipped unconditionally
    for both source kinds instead of only when it would find nothing."""

    id: str
    source_format: ImportSourceFormat
    source_data: bytes

    @property
    def type(self) -> str:
        return "import"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class GearType(str, Enum):
    """Boss/Cut parity with `ExtrudeType` (`docs/gear-design/00-conventions.md`
    - every Feature type owns its own enum, not a shared one, matching this
    codebase's established convention even though the values are
    identical). A gear is normally Bossed as a fresh Body, but Cut is
    supported for symmetry with every other primitive-producing Feature
    (Extrude/Revolve/Sweep) - e.g. cutting a gear-shaped pocket."""

    BOSS = "boss"
    CUT = "cut"


@dataclass
class GearFeature(Feature):
    """`docs/gear-design/02-gear-feature.md`: an external or internal
    involute spur gear, built straight from parameters - no backing
    SketchFeature at all (`docs/gear-design/00-conventions.md`'s "gear
    teeth are not Sketch entities" decision), so unlike `ExtrudeFeature`
    this owns its own `plane_ref: PlaneRef` directly rather than getting a
    plane for free via an upstream Sketch. Defaults to the fixed XY plane
    at the router layer, per that same conventions doc.

    `app.document.gear_math.spur_gear_geometry` resolves `module`/
    `tooth_count`/`pressure_angle_degrees`/`profile_shift`/`backlash` into
    real dimensions; `app.document.gear` (the OCCT-dependent half) turns
    those into a solid, each tooth flank a real `Geom_BSplineCurve` (see
    conventions - the only choice that keeps STEP export genuinely
    smooth), extruded `face_width` deep along the plane's normal.

    `is_internal=True` builds an annulus (outer `outer_diameter` rim +
    inward-facing tooth boundary) as one Boss, not a separate Cut step -
    `outer_diameter` is required when `is_internal` is True, meaningless
    (and ignored) otherwise.

    Boss/Cut + `target_body_ids` follow `ExtrudeFeature`'s exact
    convention: Boss fuses into each named Body (or starts a new Body if
    empty), Cut subtracts from each named Body (non-empty required - see
    `app.document.router._validate_target_body_ids`, widened to accept a
    `GearFeature`-originated Body).

    `docs/gear-design/04-helical-herringbone-loft.md` (Workstream 4a):
    `helix_angle_degrees` (default `0.0`) adds helical teeth - the tooth
    profile twists by `app.document.gear_math.helical_twist_angle`'s own
    angle between the bottom face and the top face, built as a
    `BRepOffsetAPI_ThruSections` loft between two rotated copies of the
    ordinary straight-tooth outline (`app.document.gear._gear_outline_
    wire`, reused completely unchanged - see `app.document.gear.
    _twisted_basis`) rather than a new tooth-generation path, per that
    doc's own 2026-08-04 spike findings (loft-between-rotated-copies is
    the *primary* technique, not sweep-along-helix, which distorts the
    cross-section and was dropped). `0.0` (the default) is a plain
    straight-tooth gear, built by the exact original `BRepPrimAPI_
    MakePrism` path unchanged - `helix_angle_degrees == 0.0` is
    byte-identical to this field not existing at all, so every GearFeature
    persisted before this field existed keeps producing the exact same
    geometry.

    `herringbone` (default `False`, meaningless unless `helix_angle_
    degrees != 0.0`) replaces the single loft above with two - a helical
    half from the bottom face to the gear's own mid-plane, and a *mirrored*
    (opposite-handed) helical half from the mid-plane to the top face -
    fused into one solid, per the doc's own "mirrored, not simply twice as
    tall" definition: each half spans `face_width / 2` and only half of
    the full-face-width twist angle, meeting at zero relative twist at
    both the very top and very bottom.

    Root fillet (`root_fillet_radius`) is supported for a helical/
    herringbone tooth too (`app.document.gear._apply_root_fillet_to_loft`)
    - `BRepOffsetAPI_ThruSections`, like `BRepPrimAPI_MakePrism`, is a real
    shape-history producer, so the same "map an original wire vertex to
    its generated lateral edge, fillet that edge" idiom
    `_apply_root_fillet` already uses for a straight tooth applies here too
    (via `ThruSections.Generated()` instead of `MakePrism.Generated()`),
    just on a genuinely curved/twisted lateral edge rather than a straight
    vertical one. Same best-effort convention either way: a non-converging
    fillet at a given radius falls back to an unfilleted gear with a
    warning rather than failing the whole Feature.

    `profile_shift` is `float | None` - `None` (the default) means "auto",
    same sentinel convention `RackFeature.backing_height`/`BevelPairMember
    Spec.profile_shift` already use; an explicit value always wins.
    `gear_math.minimum_tooth_count_without_undercut`'s own predictive check
    decides whether this gear's `tooth_count` would be undercut at `0.0`
    shift; if so, `app.document.gear.resolve_gear_profile_shift` applies
    `gear_math.minimum_profile_shift_to_avoid_undercut`'s closed-form value
    instead (verified against a real `spur_gear_geometry` call first,
    falling back to `0.0` if that shift would itself yield invalid
    geometry) - so a low-tooth-count external gear no longer silently
    undercuts by default the way it did before this field could auto-
    resolve. Internal gears are exempt (their tooth points inward, not
    outward - the cutter-undercut formula doesn't apply), same as the
    `is_internal` exemption `/gear/preview`'s own undercut warning already
    carries; auto always resolves to `0.0` for one. Same "can't null a real
    value back out via Update" limitation every other Optional field here
    already has (`RackFeatureUpdate.backing_height`) - `GearFeatureUpdate`
    is a flat field, not a nested replaceable object the way `BevelPair
    MemberSpecSchema.profile_shift` is, so there is no way to distinguish
    an omitted Update field from an explicit `null` one."""

    id: str
    plane_ref: PlaneRef
    gear_type: GearType
    is_internal: bool
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float = 20.0
    profile_shift: float | None = None
    backlash: float = 0.0
    root_fillet_radius: float = 0.0
    outer_diameter: float | None = None
    target_body_ids: list[str] = field(default_factory=list)
    helix_angle_degrees: float = 0.0
    herringbone: bool = False

    # On-device feedback (herringbone/complex-gear timeout investigation):
    # how many points `app.document.gear` samples per tooth flank when
    # fitting each one's `Geom_BSplineCurve` - previously a fixed module
    # constant there, matching `01-gear-math-core.md`'s "~10-20 sampled
    # points per flank" target - lower trades tooth-flank smoothness for a
    # cheaper OCCT build, which matters most for a helical/herringbone gear
    # (two twisted `ThruSections` lofts, each
    # wire carrying `4 * tooth_count` edges, then fused) on modest
    # hardware. `12` (the default) reproduces every GearFeature persisted
    # before this field existed byte-identically.
    points_per_flank: int = 12

    @property
    def type(self) -> str:
        return "gear"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class RackType(str, Enum):
    """Boss/Cut parity with `GearType`/`ExtrudeType` - kept as its own enum
    despite identical values, matching this codebase's established
    "each Feature type owns its own enum" convention rather than reusing
    another Feature type's mode enum (`docs/gear-design/00-conventions.md`)."""

    BOSS = "boss"
    CUT = "cut"


@dataclass
class RackFeature(Feature):
    """`docs/gear-design/03-rack.md`: a standalone rack - a straight-sided
    trapezoidal-tooth profile (genuinely different math from an involute
    spur gear's curved flank, not a variant of it - see
    `app.document.gear_math`'s own OCCT-free split between
    `spur_gear_geometry`/`rack_tooth_geometry`) over a derived length,
    extruded `face_width` deep along `plane_ref`'s normal, same
    positioning convention every other gear-producing Feature here uses.

    Kept as its own Feature type rather than a `GearFeature` variant flag -
    a rack has no pitch/base/addendum/dedendum radii, no `is_internal`
    concept, and needs its own `backing_height` field a round gear has no
    use for; folding it into `GearFeature` would mean either type carrying
    fields meaningless to the other, the exact shape this project's
    "each Feature type owns its own fields" convention exists to avoid.

    `tooth_count` is the free input; overall rack length is *derived*
    (`app.document.gear_math.rack_length`), not entered - the same
    "derived, not entered" treatment `GearChainFeature`'s centre distance
    and `PlanetaryGearFeature`'s planet tooth count already get.
    `backing_height` is the solid material thickness below the tooth
    root/dedendum line, closing the toothed profile into a real closed 2D
    region before extrusion - a rack has no natural "far side" the way a
    round gear's own axis provides one, so this needs its own explicit
    field. `None` (the default) resolves to `2 * module`
    (`app.document.gear_math.default_rack_backing_height`) at build time -
    a *positive* default is required here, unlike `plane_ref`'s XY
    default: a literal `0.0` backing height would close the profile into
    a zero-area rectangle (a degenerate, invalid solid), not a valid "no
    backing" rack, so `None`-as-sentinel is used rather than a plain
    `0.0` default, which would look like a normal float but silently
    produce unbuildable geometry. Boss/Cut + `target_body_ids` follow
    `GearFeature`'s exact convention."""

    id: str
    plane_ref: PlaneRef
    rack_type: RackType
    module: float
    tooth_count: int
    face_width: float
    pressure_angle_degrees: float = 20.0
    backlash: float = 0.0
    backing_height: float | None = None
    target_body_ids: list[str] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "rack"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class LoftMode(str, Enum):
    """Boss/Cut parity with `ExtrudeType`/`SweepMode` - kept as its own enum
    despite identical values, matching this codebase's established "each
    Feature type owns its own enum" convention (`00-conventions.md`)."""

    BOSS = "boss"
    CUT = "cut"


@dataclass(frozen=True)
class LoftSection:
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): one cross-
    section of a `LoftFeature` - an existing SketchFeature's closed Profile
    (`sketch_feature_id`/`profile_refs`, exactly the same reference shape
    `SweepFeature` already uses for its own Profile, narrowed here to
    select exactly one profile per section - a Loft section is a single
    2D cross-section, not a MultiProfile). Each section may live in a
    *different* Sketch (confirmed pattern, mirrors `SweepFeature.path_refs`
    each possibly naming a different Sketch) - a Loft between two Sketches
    at different heights/planes is exactly what makes a tapered or twisted
    3D transition possible at all.

    `reference_point` (optional, a `SketchEntityRef` restricted to
    `SketchEntityType.POINT` in this section's *own* Sketch) resolves the
    still-open question the 04 doc's own 2026-08-04 spike flagged and left
    unanswered: how a user aligns/twists one section relative to another
    when `BRepOffsetAPI_ThruSections`'s own vertex correspondence
    (confirmed by that spike to ignore wire order entirely) can't be
    steered by reordering. This is resolved here as an *explicit pre-
    alignment transform*, one of the two candidates the spike itself named
    as worth investigating instead of `AddVertex`/`ParType`: if the first
    section and this section both have a `reference_point` set, this
    section's whole profile is rotated (about its own Sketch's local
    origin, in its own local (x, y) plane, before being embedded into
    world space) so its own reference point's local angle-from-origin
    matches the first section's - see `app.document.loft._resolve_section`/
    `_rotate_wire`. A section with no `reference_point` (the default) is
    never rotated - this only ever changes behaviour for a section that
    opts in, so a plain two-section Loft with no alignment picked at all
    behaves exactly as `ThruSections`' own default correspondence would
    produce unmodified.

    `alignment_point` (optional, same `SketchEntityRef`-restricted-to-
    `POINT`-in-this-section's-own-Sketch shape as `reference_point`, but a
    genuinely separate field - never conflated with it) is a second,
    independent alignment mechanism, added later alongside `LoftFeature.
    guide_curve_refs`: a *translation*, not a rotation, applied after
    `reference_point`'s rotation (if any) - see `app.document.loft`'s own
    `_apply_alignment_point_translation` for the exact rule (follow a
    guide curve if `LoftFeature.guide_curve_refs` is set, otherwise track
    the first section's own `alignment_point`). Deliberately its own field
    rather than reusing `reference_point` for this too: `reference_point`'s
    rotation-only behaviour is load-bearing for helical/herringbone gear
    teeth (`app.document.gear`'s loft-between-two-rotated-copies technique
    - a *translation* there would slide a tooth off its own gear axis,
    silently wrong), so it must never change meaning under it - the two
    fields compose (both may be set on the same section) rather than one
    superseding the other."""

    sketch_feature_id: str
    profile_refs: list[SketchEntityRef] = field(default_factory=list)
    reference_point: SketchEntityRef | None = None
    alignment_point: SketchEntityRef | None = None


@dataclass
class LoftFeature(Feature):
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): a genuinely
    standalone Feature (useful on its own, not gear-specific - same
    "useful on its own" status `SweepFeature` already has), lofting a
    solid through 2+ ordered `sections` via `BRepOffsetAPI_ThruSections`
    (`isSolid=True`) - the OCCT-dependent construction lives in
    `app.document.loft`, not here, same module split every other Feature
    type here already keeps.

    `ruled` selects `ThruSections`' own ruled-vs-smooth surface mode
    (straight-line-interpolated between consecutive sections vs. a smooth
    spline blend) - per the 04 doc's own spike, this makes no measurable
    difference for exactly 2 sections (a spline fit through 2 points
    degenerates to the same result as a straight line), only relevant once
    3+ sections are involved.

    Boss/Cut + `target_body_ids` follow `SweepFeature`'s exact convention:
    Boss fuses into each named Body (or starts a new Body if empty), Cut
    subtracts from each named Body (non-empty required - see
    `app.document.router._validate_target_body_ids`, widened to accept a
    `LoftFeature`-originated Body).

    v1 scope, matching this project's established conservative-scoping
    convention (`FilletFeature`/`ChamferFeature`'s own docstrings): each
    section's profile must have no inner loops (holes) - lofting a
    profile-with-holes needs its own per-hole correspondence between
    sections (the exact same open "reference point per profile" problem,
    once per hole), rejected outright (`invalid_loft_section`) rather than
    silently only lofting the outer boundary and dropping the holes.

    `thickness`, when set, switches every `sections` entry from a closed
    Profile to a single open chain (`app.sketch.profile.detect_open_chain`)
    - a thin/sheet Loft, lofted as an open shell then thickened by this
    signed value (`app.document.loft.resolve_loft_from_bodies`) rather than
    lofted directly into a solid. `None` (the default) is the original
    closed-profile behaviour, completely unchanged. A `LoftFeature` never
    mixes open and closed sections - `thickness` applies to every section
    at once, not per-section.

    `guide_curve_refs` (optional, empty by default - completely unchanged
    behaviour when omitted): an ordered, possibly cross-Sketch chain of
    Line/Arc/Ellipse/Spline references - the exact same shape and the same
    resolution machinery (`app.document.sweep.resolve_path_wire`) as
    `SweepFeature.path_refs`, just used as a *rail* here rather than an
    extrusion direction. When set, every `sections` entry must carry a
    `LoftSection.alignment_point` (`app.document.router._validate_loft_
    guide_curve_refs`) - `app.document.loft._apply_alignment_point_
    translation` then slides each section (a rigid in-plane translation,
    never a reshape) so its own `alignment_point` lands exactly on this
    curve's own intersection with that section's plane, letting the loft
    follow a curved backbone (e.g. a bent handle/pipe transition) rather
    than a straight line between each section's own local origin. Not a
    reshape of the rest of each section's own boundary to hug the curve
    (a materially harder, still-unsolved multi-guide-curve surface-fitting
    problem real CAD tools handle with their own dedicated algorithms) -
    an honest, narrower v1: one designated point per section rides the
    rail exactly, the rest of that section's own shape is carried along
    rigidly with it."""

    id: str
    sections: list[LoftSection]
    mode: LoftMode
    ruled: bool = False
    target_body_ids: list[str] = field(default_factory=list)
    thickness: float | None = None
    guide_curve_refs: list[SketchEntityRef] = field(default_factory=list)

    @property
    def type(self) -> str:
        return "loft"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass(frozen=True)
class GearGroup:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: a small named
    record - `module`/`pressure_angle_degrees`/`display_color` - referenced
    by id from every `GearChainMemberSpec.group_id` rather than inlined per-
    stage. Two members can only mesh if they share a group, which is what
    makes a mismatched-module meshing pair structurally impossible to
    construct. Not a Feature (no Feature-tree entry of its own, no separate
    CRUD endpoint) - owned directly by the one `GearChainFeature` it
    belongs to (`GearChainFeature.groups`), the same "embedded record, not
    a standalone Feature" treatment `LoftSection` already gets from
    `LoftFeature`. v1 UI creates exactly one implicit group per chain
    (`00-conventions.md`), but the schema already supports 2+ groups
    without a later breaking migration - a chain with a compound join
    genuinely needs (at least) 2."""

    id: str
    module: float
    pressure_angle_degrees: float = 20.0
    display_color: str | None = None


class GearChainMemberType(str, Enum):
    """Boss/Cut-enum parity with `GearType`/`RackType` in spirit (its own
    enum, not shared - `00-conventions.md`), but this one selects a
    member's *kind* rather than Boss-vs-Cut - a `GearChainFeature` has no
    Boss/Cut concept at all (see that Feature's own docstring)."""

    EXTERNAL = "external"
    INTERNAL = "internal"
    RACK = "rack"


@dataclass(frozen=True)
class GearChainMemberSpec:
    """One physical gear/rack member - a single-gear/rack stage's own
    `GearChainStage.member`, or one of a compound stage's `compound_
    member_a`/`compound_member_b`. `group_id` resolves to one entry of the
    owning `GearChainFeature.groups` for `module`/`pressure_angle_degrees`
    - see `GearGroup`'s own docstring for why this indirection exists.
    `outer_diameter` is required when `member_type == INTERNAL`,
    meaningless (and rejected) otherwise - mirrors `GearFeature.
    outer_diameter`'s identical convention. A compound member's own
    `member_type` is restricted to `EXTERNAL`/`INTERNAL` (never `RACK` -
    a rack has no coaxial-stacking concept at all) by the router, not by
    this dataclass itself, same "payload shape validated by the API layer"
    split every other mutually-exclusive Feature field already uses."""

    member_type: GearChainMemberType
    group_id: str
    tooth_count: int
    face_width: float
    outer_diameter: float | None = None


@dataclass
class GearChainStage:
    """One stage of `GearChainFeature.stages` - a single-gear/rack stage
    (`member` set, every `compound_*` field unset) or a compound stage
    (`compound_member_a`/`compound_member_b` set, `member` unset),
    discriminated by which fields are populated - mirrors `PlaneRef`'s own
    "exactly one of N, payload shape validated by the router" convention
    rather than a redundant separate `is_compound` flag.

    `turn_angle_degrees` steers the chain segment *leaving* this stage
    (turtle-graphics style, CCW-positive, relative to the previous
    segment's own direction - see `app.document.gear_chain_math.
    resolve_chain_positions`) - geometrically inert on the chain's last
    stage (no segment leaves it); `app.document.gear_chain` rejects a
    nonzero value there rather than silently accepting a no-op, per Spike
    1's own flagged loose end (`05-gear-chain-and-planetary.md`).

    `compound_member_a` is the incoming-facing member (meshes with the
    previous stage), `compound_member_b` the outgoing-facing one (meshes
    with the next) - see `app.document.gear_chain_math.ChainStageSpec`'s
    own docstring for why this a/b assignment was picked (the doc itself
    only says the two members face opposite directions, not which field is
    which). `compound_axial_offset` is member_b's own z-start (its local
    frame's origin) measured from member_a's z=0 origin, along the shared
    shaft axis (member_a spans `[0, compound_member_a.face_width]`).
    `compound_merge` reuses `MergeMode`'s existing two values verbatim -
    Spike 2's own confirmed-sufficient finding, no new field needed -
    defaulting to `FUSE_INTO_ONE` (matches what a compound gear physically
    usually is when printed/machined, per this doc's own compound
    section), overridable to `KEEP_SEPARATE`."""

    turn_angle_degrees: float = 0.0
    member: GearChainMemberSpec | None = None
    compound_member_a: GearChainMemberSpec | None = None
    compound_member_b: GearChainMemberSpec | None = None
    compound_axial_offset: float = 0.0
    compound_merge: MergeMode = MergeMode.FUSE_INTO_ONE

    @property
    def is_compound(self) -> bool:
        return self.compound_member_a is not None


@dataclass
class GearChainFeature(Feature):
    """`docs/gear-design/05-gear-chain-and-planetary.md`: an ordered list
    of N>=2 meshing `stages` (external/internal/rack/compound), resolved in
    one pass into N (or more, for a compound stage kept separate via
    `GearChainStage.compound_merge=KEEP_SEPARATE`) positioned Bodies - the
    same `#N`-suffix convention Pattern/Mirror/Extrude already use (see
    `app.document.gear_chain.resolve_gear_chain_from_bodies`, which reuses
    `app.document.extrude._register_solids` directly rather than inventing
    a new suffix scheme), so a later Feature can still target one specific
    stage's Body individually (`00-conventions.md`).

    No backing SketchFeature (`00-conventions.md`'s "gear teeth are not
    Sketch entities" decision) - owns its own `plane_ref: PlaneRef`
    directly, same convention `GearFeature`/`RackFeature` already use; the
    turn-angle chain lives within that plane. An `internal` stage/member is
    rejected anywhere but the final stage - `05-gear-chain-and-planetary.
    md`'s own deliberate restriction (nothing meaningfully continues past a
    ring without turning into a branching, `PlanetaryGearFeature` topology)
    - enforced at the router (`app.document.router._validate_gear_chain_
    stages`), not by this dataclass.

    `groups` are this Feature's own embedded `GearGroup` records (not a
    standalone Feature type - see `GearGroup`'s own docstring); every
    stage/member's `group_id` must resolve to one of them.

    Always mints brand-new Bodies - no Boss/Cut `target_body_ids` concept
    at all (a chain is a fresh multi-body assembly, not a modification of
    an existing Body), unlike `GearFeature`/`RackFeature`/`LoftFeature`.

    `print_clearance_margin` (default 0.2mm) feeds `app.document.
    gear_chain_math.check_chain_interference`'s own non-blocking overlap/
    clearance findings (`00-conventions.md`'s validation-banner convention
    - never blocks creation)."""

    id: str
    plane_ref: PlaneRef
    groups: list[GearGroup]
    stages: list[GearChainStage]
    start_direction_degrees: float = 0.0
    print_clearance_margin: float = 0.2

    @property
    def type(self) -> str:
        return "gear_chain"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class PlanetaryGearFeature(Feature):
    """`docs/gear-design/05-gear-chain-and-planetary.md`: a branching (not
    sequential) gear topology - sun meshes every planet, every planet
    meshes the ring - kept as its own Feature type rather than folded into
    `GearChainFeature` (see that doc's own "genuinely different topology"
    reasoning). Sun/ring tooth counts are the free inputs; planet tooth
    count is *derived* (`app.document.gear_math.planetary_planet_tooth_
    count`, `N_planet = (N_ring - N_sun) / 2`), not entered - an odd or
    non-positive result means there is no valid planet gear to draw at all,
    which BLOCKS creation outright (`00-conventions.md`'s validation-banner
    exception), not a soft warning. `planet_count` is validated against
    `gear_math.validate_planetary_assembly`'s own assembly condition
    (`(sun_tooth_count + ring_tooth_count) mod planet_count == 0`) and
    interference check, both at creation/update time.

    One shared `module`/`pressure_angle_degrees`/`face_width` across
    sun/ring/planets - real planetary sets mesh across one common axial
    band and structurally require one shared module (no place for a module
    change to happen the way a chain has a compound join), so unlike
    `GearChainFeature` there is no `GearGroup` concept here at all.
    `ring_outer_diameter` is the ring's own rim diameter - required the
    same way `GearFeature.outer_diameter` is for any internal gear.

    No turn-angle/path concept - planets auto-space evenly around the sun
    at the correct radius (see `app.document.planetary_gear`). Resolves
    into N+2 positioned Bodies (sun, ring, N planets) in one pass, static/
    positioned only - no kinematics/rotation. Same "no Boss/Cut, always
    mints brand-new Bodies" shape as `GearChainFeature`."""

    id: str
    plane_ref: PlaneRef
    module: float
    sun_tooth_count: int
    ring_tooth_count: int
    planet_count: int
    face_width: float
    ring_outer_diameter: float
    pressure_angle_degrees: float = 20.0

    @property
    def type(self) -> str:
        return "planetary_gear"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


class BevelGearType(str, Enum):
    """Boss/Cut parity with `GearType`/`RackType`/`LoftMode` - kept as its
    own enum despite identical values, matching this codebase's
    established "each Feature type owns its own enum" convention
    (`00-conventions.md`)."""

    BOSS = "boss"
    CUT = "cut"


class SpiralBevelHand(str, Enum):
    """`docs/gear-design/12-spiral-bevel-gear.md`: `BevelGearFeature.
    spiral_hand`'s own type - which way a spiral bevel tooth's trace leans
    as radius decreases from the outer (back) cone toward the inner cone.
    Same two values as `app.document.bevel_math.SpiralHand` (the math
    module's own formula-level enum, `spiral_curve_offset_angle`'s `hand`
    parameter) but kept as its own separate definition here rather than an
    import - matching `BevelGearType`'s own identical-values-but-separate-
    definition precedent just above ("each Feature type owns its own enum",
    `00-conventions.md`) and keeping `models.py` free of any dependency on
    another `app.document` module, same as every other Feature dataclass
    here. `app.document.bevel` (which already imports both modules for
    other reasons) converts between the two explicitly at its own
    boundary. Meaningless unless `spiral_angle_degrees != 0.0`, mirroring
    `GearFeature.herringbone`'s own "meaningless unless helix_angle_degrees
    != 0.0" convention."""

    LEFT = "left"
    RIGHT = "right"


@dataclass
class BevelGearFeature(Feature):
    """`docs/gear-design/10-bevel-gear.md`: a standalone straight bevel
    gear - the highest-risk workstream in this project (genuinely new BRep
    shell/solid construction, no shell-from-curved-surfaces precedent
    anywhere else in this codebase - see `app.document.bevel`'s own module
    docstring). No backing SketchFeature, same "gear teeth are not Sketch
    entities" decision every other gear-family Feature type already makes
    (`00-conventions.md`) - `app.document.bevel_math.bevel_gear_geometry`
    resolves the pitch cone's own dimensions, `app.document.bevel` (the
    OCCT-dependent half) assembles the real solid.

    `pitch_cone_angle_degrees` is a **direct field**, not derived from a
    mate's tooth count - unlike `bevel_math.bevel_gear_geometry`'s own
    `mate_tooth_count`/`shaft_angle_degrees`-derived spike convenience
    (that function's own docstring), a standalone `BevelGearFeature` has
    no meshing partner to derive its own cone angle from; `11-bevel-
    pair.md`'s own future pairing system computes and sets this
    automatically when generating a mating pair together, out of scope
    here. `module`/`face_width` are both measured at the outer (large,
    back-cone) end, matching how bevel gear module is conventionally
    specified (`bevel_math.BevelGearGeometry`'s own docstring).

    Anchored via `plane_ref: PlaneRef` - the plane's origin is the cone
    apex, its normal is the gear's own primary shaft axis (`00-
    conventions.md`'s positioning convention), defaulting to the fixed XY
    plane at the router layer like every other gear-family Feature.

    Boss/Cut + `target_body_ids` follow `GearFeature`/`RackFeature`'s
    exact convention, for symmetry with every other primitive-producing
    Feature type in this codebase (`GearType`'s own docstring) - a bevel
    gear is normally Bossed as a fresh Body, but Cut (e.g. a bevel-shaped
    pocket) is supported too.

    There is no `root_fillet_radius` field at all - a bevel tooth's root
    fillet is not supported (no `BRepPrimAPI_MakePrism.Generated()`-
    equivalent vertex-tracking exists for a `ThruSections`/`Sewing`-built
    solid, the same reason `GearFeature`'s own helical/herringbone teeth
    don't support one either - see that dataclass's own docstring).

    `docs/gear-design/12-spiral-bevel-gear.md`: `spiral_angle_degrees`
    (default `0.0`, mirroring `GearFeature.helix_angle_degrees`'s own
    default) turns on the layered-constant-spiral-angle construction
    (`app.document.bevel_math.bevel_tooth_flank_sections`) once non-zero -
    `0.0` is a **literal no-op**, producing the exact same straight-bevel
    Tredgold construction this Feature always has (`app.document.bevel.
    _assemble_gear_solid`'s own `spiral_angle_degrees == 0.0` branch, byte-
    for-byte the pre-spiral code path). `spiral_hand` (default `RIGHT`,
    meaningless unless `spiral_angle_degrees != 0.0` - same "meaningless
    unless" convention as `herringbone`) picks which way the tooth trace
    leans - see `SpiralBevelHand`'s own docstring. Zerol bevel (curved
    trace, zero *net* spiral) falls out of this same family for free at
    `spiral_angle_degrees != 0.0` evaluated only at the mean radius -
    no separate field or scope line, per that doc's own "Proposed v1
    scope". Spiral bevel *pairing* is out of scope for this Feature type
    entirely (Workstream 13, `BevelPairFeature`'s own separate, later
    concern) - a standalone `BevelGearFeature` never runs the meshing-phase
    search that workstream will need."""

    id: str
    plane_ref: PlaneRef
    bevel_type: BevelGearType
    module: float
    tooth_count: int
    face_width: float
    pitch_cone_angle_degrees: float
    pressure_angle_degrees: float = 20.0
    backlash: float = 0.0
    profile_shift: float = 0.0
    target_body_ids: list[str] = field(default_factory=list)
    # Mirrors `GearFeature.points_per_flank` - a bevel tooth's spherical-
    # involute flank is at least as expensive to build as a helical one
    # (`app.document.bevel._assemble_gear_solid`'s own `4*tooth_count + 2`
    # face sew/solid/flatten pipeline), so the same accuracy/build-cost
    # tradeoff control applies here.
    points_per_flank: int = 12
    spiral_angle_degrees: float = 0.0
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT

    @property
    def type(self) -> str:
        return "bevel_gear"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass(frozen=True)
class BevelPairMemberSpec:
    """One physical member of a `BevelPairFeature` - the *legitimately-
    differing* per-member fields only (`docs/gear-design/11-bevel-pair.md`):
    `tooth_count` and `profile_shift` (used to balance strength between a
    small pinion and a large gear). Every other dimension (module, pressure
    angle, shaft angle, backlash, face width) is shared pair-level, flat on
    `BevelPairFeature` itself, not here - both gears physically share one
    axial band/mesh, so those can't legitimately differ between the two
    members (see that dataclass's own docstring).

    `profile_shift` is `float | None`, `None` (the default) meaning "auto" -
    same sentinel convention `RackFeature.backing_height` already
    established (`app.document.rack.rack_outline_points`'s own `backing_
    height if backing_height is not None else default_rack_backing_height
    (module)`), extended here to a genuinely pair-level auto-value instead
    of a per-feature one: `app.document.bevel_pair.resolve_bevel_pair_
    from_bodies` resolves `None` to whichever value (0.0, or a computed
    negative shift) keeps this member's own tooth tip clear of the *other*
    member's material - see `app.document.bevel_math.bevel_pair_mesh_
    interference_warning`'s own docstring for the on-device-verified
    finding this is built on (a real bevel pair's default settings can
    have genuine, measurable tooth interference that raising `pressure_
    angle_degrees` isn't the only fix for - a negative `profile_shift` on
    whichever member's tooth tip is the intruder works too, without
    touching pressure angle at all). An explicit (non-`None`) value always
    wins over the auto computation, same override-sticks convention
    `backing_height` already uses."""

    tooth_count: int
    profile_shift: float | None = None
    # `docs/gear-design/13-spiral-bevel-pair.md`: per-member, unlike `Bevel
    # PairFeature.spiral_angle_degrees` (shared - both members physically
    # mesh at one spiral angle magnitude, the same "arguably must share it"
    # reasoning `module`/`pressure_angle_degrees` already get). Hand is kept
    # per-member specifically so a real hand-of-spiral *mismatch* is
    # representable at all - the design call that doc's own "Proposed
    # auto-resolution field(s)" section left open: if hand were instead
    # derived/auto-opposite, there would be nothing left to mismatch, and
    # `bevel_math.spiral_hand_mismatch_warning`'s own compatibility check
    # would have no real input to compare. Defaults to `RIGHT` on this
    # dataclass (mirroring `BevelGearFeature.spiral_hand`'s own default) -
    # the router/client default member_1 to `RIGHT` and member_2 to `LEFT`
    # so a freshly-created pair meshes correctly out of the box, but
    # nothing stops a user from setting both the same to see (and be
    # warned about) a mismatch. Meaningless unless `BevelPairFeature.
    # spiral_angle_degrees != 0.0`, same "meaningless unless" convention
    # `SpiralBevelHand`'s own docstring already uses.
    spiral_hand: SpiralBevelHand = SpiralBevelHand.RIGHT


@dataclass
class BevelPairFeature(Feature):
    """`docs/gear-design/11-bevel-pair.md`: automated live bevel pairing -
    exactly 2 members (`member_1`/`member_2`), deliberately narrower than
    `GearChainFeature`'s own N-stage generality (a bevel train longer than
    two gears is a rarer, geometrically unrelated case per that doc's own
    scoping reasoning) - not a generalized N-stage bevel chain.

    **Shared pair-level fields, flat on this Feature** (not a `GearGroup`
    reference - a pair always has exactly 2 members that always mesh, no
    third station for a module change to happen, unlike `GearChainFeature`):
    `module`, `pressure_angle_degrees`, `shaft_angle_degrees` (default
    90.0, pre-filled and editable, arbitrary - not restricted to 90),
    `backlash`, `face_width`.

    **Cone angles are auto-derived, not entered** - the whole point of
    automated live bevel pairing vs. `BevelGearFeature`'s own standalone
    `pitch_cone_angle_degrees` direct field (which exists specifically
    because a standalone gear has no partner to derive from). `app.
    document.bevel_pair.resolve_bevel_pair_from_bodies` calls `bevel_math.
    pitch_cone_half_angles(shaft_angle_degrees, member_1.tooth_count,
    member_2.tooth_count)` directly, then feeds each member's own resolved
    gamma into `bevel_math.bevel_gear_geometry` via its `pitch_cone_angle_
    degrees` direct-field path (not the `mate_tooth_count`-derived path -
    that one exists for `bevel_gear_geometry`'s own original spike-era
    convenience, not what a live pair needs, since this Feature already
    resolved both gammas itself in one call).

    **Positioning - apex-aligned**: both members' cone apexes coincide at
    `plane_ref`'s own origin. Member 1's axis is `plane_ref`'s own normal
    directly (identical basis to a standalone `BevelGearFeature`). Member
    2's axis is member 1's axis rotated by `shaft_angle_degrees` about
    `plane_ref`'s own `x_axis` (CCW-positive, matching `RevolveFeature.
    angle`'s own right-hand-rule convention - `00-conventions.md`) - see
    `app.document.bevel_pair._tilted_basis`.

    **No interference checking at all** - explicit simplification per the
    doc: with exactly two members that are always the intended meshing
    pair, there's no "non-adjacent stage" case for `GearChainFeature`'s own
    interference machinery to apply to.

    No backing SketchFeature (`00-conventions.md`'s "gear teeth are not
    Sketch entities" decision) - owns its own `plane_ref: PlaneRef`
    directly, defaulting to the fixed XY plane at the router layer like
    every other gear-family Feature. Always mints two brand-new Bodies (the
    same `#N`-suffix convention `GearChainFeature`/`PlanetaryGearFeature`
    already use via `_register_solids`) - no Boss/Cut `target_body_ids`
    concept at all, same shape as `GearChainFeature`/`PlanetaryGearFeature`.

    Kept fully separate from `GearChainFeature` - no bevel stage kind was
    added to the planar chain's own stage union, and `app.document.gear_
    chain`/`app.document.gear_chain_math` are untouched by this Feature.

    DXF flat-pattern export (a bevel gear's cone "unrolled" flat) is
    explicitly out of scope here - `11-bevel-pair.md` flags it as new
    geometry work belonging to `06-dxf-export.md`, not this Feature.

    `docs/gear-design/13-spiral-bevel-pair.md`: `spiral_angle_degrees`
    (default `0.0`, a literal no-op producing the exact same straight-bevel
    pair this Feature always has - `app.document.bevel_pair.resolve_bevel_
    pair_from_bodies` passes it straight through to `app.document.bevel.
    _assemble_gear_solid`'s own already-verified no-op branch, unchanged)
    is **pair-level shared**, not per-member - the design call that doc's
    own "Proposed fields" section left open, made explicitly here: both
    members physically mesh along one shared spiral trace, so this is the
    same "arguably must share it" reasoning already applied to `module`/
    `pressure_angle_degrees`/`shaft_angle_degrees`/`backlash`/`face_width`
    above, not a new precedent. Hand of spiral, by contrast, is per-member
    (`BevelPairMemberSpec.spiral_hand` - see that dataclass's own docstring
    for why) - a real hand-of-spiral *mismatch* has to be representable for
    `bevel_math.spiral_hand_mismatch_warning` to have anything to compare.
    A non-zero `spiral_angle_degrees` also turns on a real per-build
    meshing-phase search (`app.document.bevel_pair._search_meshing_phase`,
    `docs/gear-design/12-spiral-bevel-gear.md`'s own Spike C) in place of
    the fixed `+-pi/2`/`-pi/2 + pi/tooth_count_2` phase convention - see
    that module's own top-level docstring for the full algorithm and cost
    reasoning."""

    id: str
    plane_ref: PlaneRef
    module: float
    member_1: BevelPairMemberSpec
    member_2: BevelPairMemberSpec
    face_width: float
    pressure_angle_degrees: float = 20.0
    shaft_angle_degrees: float = 90.0
    backlash: float = 0.0
    # Mirrors `BevelGearFeature.points_per_flank` - applies to both
    # members' own tooth flanks (`app.document.bevel_pair.resolve_bevel_
    # pair_from_bodies` builds two full bevel solids per recompute, so this
    # matters even more here than for a standalone bevel gear).
    points_per_flank: int = 12
    spiral_angle_degrees: float = 0.0

    @property
    def type(self) -> str:
        return "bevel_pair"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class DeleteBodyFeature(Feature):
    """Direct Editing family (first entry - see `docs/direct-editing-scope.md`):
    removes every Body named in `body_ids` (1+ required - see
    `app.document.router._validate_delete_body_ids`) from the Part's Bodies
    entirely. Unlike Merge/Boolean, which combine Bodies into a new or
    existing one, this simply discards them - closest existing ancestor is
    `BooleanFeature.consume_tool_bodies`'s plain `bodies.pop(...)` removal
    (`app.document.boolean.apply_boolean_to_bodies`), generalized here to be
    the Feature's *entire* effect rather than a side option of a fold. No
    OCCT geometry of its own to construct or fail (see `app.document.
    delete_body.apply_delete_body_to_bodies`), so `produces` is NONE and
    `produces_solid_geometry` is False - a DeleteBodyFeature never
    contributes shape to the Part, only removes it. There is deliberately no
    "keep" mode: selecting the Bodies to delete IS the interaction (a
    client-side "select inverse" convenience is a UI affordance, not a
    second Feature type - see the scope doc's own reasoning)."""

    id: str
    body_ids: list[str]

    @property
    def type(self) -> str:
        return "delete_body"

    @property
    def produces_solid_geometry(self) -> bool:
        return False

    @property
    def produces(self) -> Produces:
        return Produces.NONE


@dataclass
class ScaleBodyFeature(Feature):
    """Direct Editing family, second entry (see `docs/direct-editing-
    scope.md`): uniformly scales `body_id` by `factor` about its own
    current bounding-box centre (see `app.document.scale_body._bbox_
    center` - recomputed fresh at every resolve, not a stored reference;
    v1 has no user-pickable origin - see this feature's own scope doc).
    `factor` must be > 0 (see `app.document.router._validate_scale_body_
    factor`) - zero collapses to a point, a negative factor isn't a scale.
    Modifies `body_id` in place (Fillet/Chamfer's "keep the same id"
    pattern - see `FilletFeature`'s own docstring), unlike Mirror, which
    always mints a brand-new Body. Non-uniform (independent X/Y/Z factors)
    is deferred - see `app.document.scale_body`'s own module docstring for
    why."""

    id: str
    body_id: str
    factor: float = 1.0

    @property
    def type(self) -> str:
        return "scale_body"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class MoveBodyFeature(Feature):
    """Direct Editing family, third entry (see `docs/direct-editing-
    scope.md`) - "Move/Copy Body", SolidWorks/Fusion 360's own naming for
    this single command (not two separate ones - see this package's own
    scope doc §1.3/1.4 for why translate+rotate+copy are one Feature, not
    three): translates `body_id` by `delta` (world-space XYZ) and/or
    rotates it `rotation_angle_degrees` around `rotation_axis` (a
    `PatternAxisRef`, reused verbatim from the Pattern/Mirror family - see
    that type's own docstring), composed rotate-then-translate (see
    `app.document.move_body`'s own module docstring for why: the axis
    reference is resolved once, against the Body's position *before* any
    translation moves it, matching SolidWorks' own composition order).
    `rotation_axis=None` (or `rotation_angle_degrees=0`) means no rotation
    at all - translate-only is the common case.

    `make_copy=False` (default) modifies `body_id` in place (Fillet/
    Chamfer's "keep the same id" pattern - see `FilletFeature`'s own
    docstring); `make_copy=True` instead mints a brand-new Body under this
    Feature's own `id` (mirrors a Mirror with a single source -
    `_register_solids`'s own un-suffixed-if-single-result convention),
    leaving `body_id` itself untouched. Named `make_copy`, not `copy` -
    `copy` collides with `pydantic.BaseModel.copy()` on this dataclass's
    own wire-schema counterpart (`MoveBodyFeatureCreate`/`Update`/
    `Response` in `app.document.schemas`), so every layer (this dataclass,
    the schemas, the wire JSON key, the client) uses `make_copy`
    consistently rather than diverging names across layers."""

    id: str
    body_id: str
    delta: tuple[float, float, float] = (0.0, 0.0, 0.0)
    rotation_axis: PatternAxisRef | None = None
    rotation_angle_degrees: float = 0.0
    make_copy: bool = False

    @property
    def type(self) -> str:
        return "move_body"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class DeleteFaceFeature(Feature):
    """Direct Editing family, fourth entry (see `docs/direct-editing-
    scope.md`): removes every face named in `face_refs` (1+ entries, all
    sharing one Body - see `app.document.delete_face._delete_face_mixed_
    body_selection`, mirrors `FilletFeature.edge_refs`' own constraint)
    from its Body in one pass, healing the resulting opening(s) closed,
    via OCCT `BRepAlgoAPI_Defeaturing` (see `app.document.delete_face`'s
    own module docstring for why this specific tool, and its own fail-
    closed contract). Modifies the shared `body_id` in place (Fillet/
    Chamfer's "keep the same id" pattern).

    V2 (see `docs/direct-editing-scope.md`'s own "Delete Face V2 spike
    findings" section): accepts planar, cylindrical, and conical faces
    (anything else - spherical, toroidal, free-form/B-spline - is
    rejected), and 2+ faces removed together in one `Build()` call -
    confirmed via a real pythonocc-core spike that `AddFaceToRemove`
    genuinely supports both, not just the single-planar-face case v1
    originally spiked. A face selection with no well-defined single healed
    result (most commonly: a face of a primitive box/cylinder with no
    adjacent fillet/chamfer/pocket geometry to naturally close the gap, or
    two faces whose *combined* removal has nothing to heal into even
    though either alone might) fails closed with a structured 422 rather
    than silently returning an unmodified or invalid Body."""

    id: str
    face_refs: list[SubShapeRef] = field(default_factory=list)  # every entry's shape_type must be FACE

    @property
    def type(self) -> str:
        return "delete_face"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


@dataclass
class MoveFaceFeature(Feature):
    """Direct Editing family, fifth (last) entry (see `docs/direct-
    editing-scope.md`) - moves every face named in `face_refs` (all of
    which must belong to the same Body - see `app.document.move_face.
    _move_face_mixed_body_selection`, mirrors `FilletFeature.edge_refs`'
    own single-Body constraint) by exactly one of three mutually-exclusive
    modes (payload shape validated by `app.document.router._validate_
    move_face_payload`, same "exactly one of N fields" convention
    `SplitToolRef`/`PatternAxisRef` already establish):
    - `offset_distance`: along each face's own outward normal (positive =
      outward/adds material, negative = inward/removes material), applied
      identically to every face in `face_refs` (one shared value, mirrors
      `FilletFeature.radius`'s own "list of refs, one shared param"
      convention). V2 (see `docs/direct-editing-scope.md`'s own "Move Face
      V2" section): supports non-planar (cylindrical/conical) faces and
      2+ faces at once, via OCCT's own `BRepOffset_MakeOffset` (a genuine
      per-face variable-offset engine - see `app.document.move_face`'s own
      module docstring for why this mode specifically moved off v1's
      original prism-sweep technique and the other two modes below did
      not).
    - `delta`: an explicit world-space XYZ translation - permissive by
      design (not restricted to a face's own normal direction); only its
      component along the group's own reference face's outward normal
      actually determines whether material is added or removed, any
      tangential component shears the swept region between the group's
      old and new position. **V3** (see `docs/direct-editing-scope.md`'s
      own "Move Face V3" section): `face_refs` now accepts 1+ *connected*
      faces, swept together as one rigid group - e.g. a flat cap plus its
      own blend fillets, so a filleted feature can be translated as a
      whole (imported/non-sketch geometry's own motivating case - it has
      no Sketch to fall back to editing). Every face must be planar,
      cylindrical, or conical, and the group must contain at least one
      planar face (it anchors the Fuse-vs-Cut sign decision - a curved
      face's own "outward" is only ever locally defined, confirmed via
      spike that per-face voting across a group's curved members is
      unreliable). Still does **not** support repositioning a lone curved
      face by an arbitrary vector (e.g. relocating a hole's own X/Y
      position) - confirmed via spike that sweeping a curved face with
      *any* tangential (sideways) component relative to its own local
      generatrix is geometrically degenerate, not merely unimplemented;
      see `app.document.move_face`'s own module docstring for the full
      reasoning.
    - `direction_ref` + `direction_distance`: along a picked edge's
      direction (`PatternDirectionRef`, reused verbatim from the Pattern/
      Mirror family), with the sign of `direction_distance` acting as the
      client's own "Flip direction" control (mirrors Extrude's own
      flip-via-sign convention, not a separate boolean field). **V3** -
      same multi-face-group support/restrictions as `delta` above, same
      reasoning.

    Modifies the shared `body_id` in place (Fillet/Chamfer's "keep the
    same id" pattern). No guaranteed healing across an offset large enough
    to consume a neighbouring face for `delta`/`direction_ref` modes -
    fails closed with a structured 422 (`move_face_failed`) rather than
    producing invalid/wrong geometry; `offset_distance` mode *does*
    guarantee this (confirmed via spike, see the module docstring)."""

    id: str
    face_refs: list[SubShapeRef] = field(default_factory=list)  # every entry's shape_type must be FACE
    offset_distance: float | None = None
    delta: tuple[float, float, float] | None = None
    direction_ref: PatternDirectionRef | None = None
    direction_distance: float | None = None

    @property
    def type(self) -> str:
        return "move_face"

    @property
    def produces_solid_geometry(self) -> bool:
        return True

    @property
    def produces(self) -> Produces:
        return Produces.BODY


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
        geometry (see `Feature.produces_solid_geometry`). Kept meaning
        literally "solid" - see `produces_displayable_geometry` below for
        the broader "anything tessellatable at all" check `get_part_mesh`
        actually gates on."""
        return any(f.produces_solid_geometry for f in self.features)

    @property
    def produces_displayable_geometry(self) -> bool:
        """True once any Feature in this Part's history yields a real,
        tessellatable shape via `compute_part_bodies` - a solid Body or a
        non-solid Surface alike (`Produces.BODY`/`Produces.SURFACE`; a
        `PLANE`/`SKETCH`/`NONE` Feature never does). Distinct from
        `produces_solid_geometry` above: this is what `get_part_mesh`
        should gate its placeholder box on, so a Surface-only Part (no
        Extrude/Revolve/etc.) still gets its real geometry rendered instead
        of staying stuck on the placeholder."""
        return any(f.produces in (Produces.BODY, Produces.SURFACE) for f in self.features)

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
