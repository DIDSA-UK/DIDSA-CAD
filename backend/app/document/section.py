"""OCCT geometry for the sectioning tool's stateless `section-preview`
endpoint (`app.document.router.preview_section`) - `docs/roadmap.md`'s
"Analysis tools" sectioning-tool entry. Deliberately NOT a persisted/
undoable modeling Feature: no entry in `app.document.models`'s `Feature`
hierarchy, and this module never touches `Part.features`, `app.document.
graph`, or `app.document.store` - every function here is a pure,
read-only computation against an already-existing `Part`'s current bodies,
recomputed fresh on every request, exactly like the existing `GET /mesh`
endpoint itself (this is that same idea, with one or more clipping planes
applied on top before tessellation).

One or more section (clipping) planes combine by intersecting their
half-spaces (logical AND): the kept region of a Body is whatever remains
inside every active plane's own "kept" half-space simultaneously, so two
perpendicular planes naturally produce a quarter-cutaway with no extra
logic beyond applying each plane in turn - see `_trim_solid_by_planes`.

Reuses `app.document.split`'s own oversized half-space "block" technique
(`plane_block`, promoted to public there for exactly this reuse - see that
module's own updated docstring) verbatim for sizing/orienting the cutting
block for each plane: `target_shape`'s own bounding-box corners are
projected into the plane's local frame, so the block stays robust at any
plane orientation, not just one aligned with the target Body's own
bounding-box axes. A `SectionPlaneSpec` only carries `origin`/`normal`
(plus `flipped`) - unlike a `CreatePlaneFeature`, there is no natural
in-plane (x_axis, y_axis) reference to inherit from a face/sketch/existing
plane the client picked to start from (by the time this module sees it,
the client's own gizmo has already reduced the plane to a bare
origin+normal), so `app.document.plane_geometry.arbitrary_perpendicular_
basis` fills in an arbitrary (but deterministic) in-plane frame purely to
satisfy `plane_block`'s own `ResolvedPlane` parameter shape - the choice
of in-plane axes has no effect on the resulting block's volume, only its
own polygon's two local directions.

**Cut-face tagging - geometric classification, not history/identity
diffing:** the naive "diff `TopExp_Explorer` faces between the original
and trimmed shape via `IsSame`" approach was considered and rejected -
OCCT's own Boolean ops give a genuinely *new* `TopoDS_Face` (never `IsSame`
to the original) to every face that is even partially trimmed by a cut,
not just to the brand new cap face(s); for a plain box cut by one plane,
3 of its 6 original side faces would misleadingly get flagged as "cut
faces" right alongside the 1 real new cap face. Instead, since this module
already knows the exact cutting planes it constructed (unlike a general
Boolean-op consumer with no such knowledge), each face of the *trimmed*
result is classified directly: planar (`BRepAdaptor_Surface(face).
GetType() == GeomAbs_Plane`) *and* coincident with one of the request's
own cutting planes (its own plane's location lies on that cutting plane,
and its own normal is parallel/anti-parallel to it, both within
tolerance - the same style of check `app.document.plane_geometry.
resolve_planar_circle` already uses for circle/plane coplanarity). This
is correct even for the internal-cavity case that motivated using real
OCCT geometry over naive mesh-triangle clipping in the first place: a cap
face with a hole through it is still exactly one OCCT face (with an inner
wire bounding the hole), so it is tagged as one cut face regardless of how
many inner wires it has - a naive per-triangle client-side clip would have
no equivalent way to reconstruct that inner boundary as a genuinely closed
hole rather than a jagged, ungapped edge.

Known, narrow limitation (documented rather than silently accepted, per
this codebase's own habit - see e.g. `get_part_mesh`'s own "Known, narrow
limitation" paragraph): a pre-existing face in the *original* solid that
already happens to be exactly coplanar with one of the request's own
cutting planes would also be classified as a cut face, even though it
isn't a newly-created cap. This is accepted as a narrow edge case (a
section plane deliberately aligned exactly flush with an existing flat
face of the part) rather than solved with a heavier "is this face new"
history-diffing scheme, for the reasons above.
"""

from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.TopAbs import TopAbs_FACE
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies
from app.document.models import Part, ResolvedPlane
from app.document.plane_geometry import arbitrary_perpendicular_basis
from app.document.split import plane_block

Vector3 = tuple[float, float, float]

# Coincidence tolerance for `_is_cut_face`'s plane-match check - same order
# of magnitude as `plane_geometry.resolve_planar_circle`'s own default
# tolerance for an analogous "does this real OCCT geometry actually match
# the plane we expect" check; loose enough to tolerate ordinary
# floating-point noise from the Boolean op itself, tight enough to reject a
# face that only vaguely resembles one of the cutting planes.
_CUT_FACE_TOLERANCE = 1e-4


@dataclass(frozen=True)
class SectionPlaneSpec:
    """One active clipping plane, as given by the client's own gizmo/tool
    state - deliberately just `origin`/`normal` (no in-plane x_axis/y_axis;
    see this module's own top-level docstring for why none is needed).
    `flipped` inverts which side of the plane is kept, without changing
    `normal` itself - kept as a separate flag (rather than asking the
    client to negate `normal` before sending it) so the client's own UI
    state (an offset/orientation plus an independent flip toggle) maps
    onto this shape with no extra sign bookkeeping on either side."""

    origin: Vector3
    normal: Vector3
    flipped: bool = False


@dataclass
class SectionBody:
    """One Body's own trimmed shape plus which of its (dense, `TopExp_
    Explorer`-order) face ids are newly-created cut-cap faces - the raw
    ingredients `app.document.router.preview_section` tessellates and
    tags, mirroring how `compute_part_bodies` itself returns raw shapes
    for the router to tessellate, not pre-tessellated mesh data."""

    body_id: str
    shape: TopoDS_Shape
    cut_face_ids: list[int]


def _normalized(v: Vector3) -> Vector3:
    length = (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5
    return tuple(c / length for c in v)


def _dot(a: Vector3, b: Vector3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _sub(a: Vector3, b: Vector3) -> Vector3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _effective_normal(spec: SectionPlaneSpec) -> Vector3:
    """`spec.normal`, normalized and negated if `spec.flipped` - the
    direction whose "+" side `plane_block` keeps. Negating only `normal`
    (not deriving a whole new in-plane frame) is enough: `_resolved_plane`
    below builds `x_axis`/`y_axis` fresh from this already-effective
    normal, so a flipped spec never needs its own separate basis
    construction path."""
    normal = _normalized(spec.normal)
    return tuple(-c for c in normal) if spec.flipped else normal


def _resolved_plane(spec: SectionPlaneSpec) -> ResolvedPlane:
    """`spec` widened into the full `ResolvedPlane` shape `plane_block`
    needs - `x_axis`/`y_axis` come from `arbitrary_perpendicular_basis`
    purely to satisfy that shape (see this module's own top-level
    docstring for why their specific direction doesn't matter here)."""
    normal = _effective_normal(spec)
    x_axis, y_axis = arbitrary_perpendicular_basis(normal)
    return ResolvedPlane(origin=spec.origin, normal=normal, x_axis=x_axis, y_axis=y_axis)


def _trim_solid_by_planes(shape: TopoDS_Shape, planes: list[SectionPlaneSpec]) -> TopoDS_Shape:
    """Intersects `shape` against every plane in `planes` in sequence via
    `BRepAlgoAPI_Common` - algebraically the AND of all N half-spaces (the
    result lies inside every plane's own kept side simultaneously), so two
    perpendicular planes naturally produce a quarter-cutaway with zero
    extra logic. Every plane's own block is sized off `shape`'s own
    (original, untrimmed) bounding box, not the progressively-shrinking
    intermediate result - `shape`'s bounding box is always a safe superset
    of any of its own trimmed sub-shapes' bounding boxes, so this stays
    correct regardless of plane order, and avoids re-measuring a
    intermediate shape that a prior trim may have reduced to something
    degenerate."""
    trimmed = shape
    for spec in planes:
        block = plane_block(_resolved_plane(spec), shape)
        trimmed = BRepAlgoAPI_Common(trimmed, block).Shape()
    return trimmed


def _is_cut_face(face, planes: list[SectionPlaneSpec]) -> bool:
    """Whether `face` (a `TopoDS_Face`) is a newly-created cut-cap face -
    planar, and coincident with at least one of `planes`' own cutting
    planes (its own OCCT plane's location lies on that plane, and its own
    normal is parallel or anti-parallel to it, both within `_CUT_FACE_
    TOLERANCE`) - see this module's own top-level docstring for why this
    geometric classification is used instead of diffing face identities
    against the pre-trim shape."""
    surface = BRepAdaptor_Surface(face)
    if surface.GetType() != GeomAbs_Plane:
        return False
    plane = surface.Plane()
    location = plane.Position().Location()
    direction = plane.Position().Direction()
    face_origin: Vector3 = (location.X(), location.Y(), location.Z())
    face_normal: Vector3 = (direction.X(), direction.Y(), direction.Z())
    for spec in planes:
        cutting_normal = _effective_normal(spec)
        if abs(abs(_dot(face_normal, cutting_normal)) - 1.0) > _CUT_FACE_TOLERANCE:
            continue
        if abs(_dot(_sub(face_origin, spec.origin), cutting_normal)) > _CUT_FACE_TOLERANCE:
            continue
        return True
    return False


def _cut_face_ids(shape: TopoDS_Shape, planes: list[SectionPlaneSpec]) -> list[int]:
    """The dense (0-based, `TopExp_Explorer(shape, TopAbs_FACE)`-order) ids
    of `shape`'s own cut-cap faces - the exact same id space `app.document.
    mesh.tessellate_shape` assigns its own `face_ids` from (same walk
    order over the same shape object), so the router can hand these
    straight back to the client as indices into that same tessellation's
    `face_ids`/`triangle_indices`, with no id-space translation needed."""
    ids: list[int] = []
    explorer = TopExp_Explorer(shape, TopAbs_FACE)
    face_id = 0
    while explorer.More():
        face = topods.Face(explorer.Current())
        if _is_cut_face(face, planes):
            ids.append(face_id)
        face_id += 1
        explorer.Next()
    return ids


def _no_section_planes() -> HTTPException:
    """Structured 422, same envelope every other Section/Create-Plane
    validation error in this codebase uses, for an empty `planes` list -
    there is no well-defined cutaway with zero cutting planes."""
    return HTTPException(status_code=422, detail={"type": "no_section_planes"})


def _unknown_body_id(body_id: str) -> HTTPException:
    """Structured 422 for a `body_ids` entry that doesn't currently exist -
    same shape as `app.document.extrude._missing_reference`'s own `body_id`
    field, but for a whole Body reference rather than a SubShapeRef, since
    a section preview targets Bodies directly, not a face/edge/vertex on
    one."""
    return HTTPException(status_code=422, detail={"type": "unknown_body_id", "body_id": body_id})


def compute_section_mesh(
    part: Part,
    body_ids: list[str],
    planes: list[SectionPlaneSpec],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> list[SectionBody]:
    """The trimmed shape + cut-face ids for each of `body_ids`, cut by the
    intersection of `planes` (see `_trim_solid_by_planes`) - the single
    entry point `app.document.router.preview_section` calls. Returns raw
    `TopoDS_Shape`s, not tessellated mesh data, mirroring `compute_part_
    bodies`' own shape-only contract - tessellation (and its own `quality`
    parameter) is the router's job, exactly as for `GET /mesh`.

    Fails closed with `no_section_planes` (empty `planes`) or `unknown_
    body_id` (a `body_ids` entry not present in `compute_part_bodies`'
    result) - both structured 422s, matching every other resolver in this
    codebase."""
    if not planes:
        raise _no_section_planes()
    bodies = compute_part_bodies(part, excluded_feature_ids)
    results: list[SectionBody] = []
    for body_id in body_ids:
        if body_id not in bodies:
            raise _unknown_body_id(body_id)
        trimmed = _trim_solid_by_planes(bodies[body_id], planes)
        results.append(SectionBody(body_id=body_id, shape=trimmed, cut_face_ids=_cut_face_ids(trimmed, planes)))
    return results
