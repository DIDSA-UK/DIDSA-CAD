"""Pure-Python `GearChainFeature` positioning + interference math - no OCCT
dependency, mirroring `app.document.gear_math`'s own OCCT-free/OCCT-
dependent split (`docs/gear-design/00-conventions.md`). Implements
`docs/gear-design/05-gear-chain-and-planetary.md`'s "Spike 1 findings"
section directly: the turtle-graphics bent-path resolution rule and the
three interference gap functions, both hand-verified there against a real
worked example before this module existed - see that section for the
reference numbers `test_gear_chain_math.py` checks against.

Decoupled from `app.document.models` the same way `gear_math.py` never
imports it either: `ChainMemberSpec`/`ChainStageSpec` below are this
module's own minimal input shape, translated from `app.document.models.
GearChainStage`/`GearGroup` by the OCCT-dependent half
(`app.document.gear_chain`), not passed in directly - keeps this module
testable in a sandbox that has never had `pythonocc-core` installed.

Every domain failure here raises `gear_math.GearGeometryError` (reused
directly, not redefined) - same convention this module's own dependency
already establishes.
"""

import math
from dataclasses import dataclass
from enum import Enum
from typing import Literal

from app.document.gear_math import (
    GearGeometryError,
    RackToothGeometry,
    rack_length,
    rack_tooth_geometry,
    spur_gear_geometry,
)

# ---------------------------------------------------------------------------
# Pure-math input shape (translated from app.document.models by the
# OCCT-dependent half - see module docstring)
# ---------------------------------------------------------------------------


class ChainMemberKind(str, Enum):
    EXTERNAL = "external"
    INTERNAL = "internal"
    RACK = "rack"


@dataclass(frozen=True)
class ChainMemberSpec:
    """One physical gear/rack member's geometry-relevant parameters - a
    single-gear stage's own member, or one of a compound stage's two
    members. `module`/`pressure_angle_degrees` are already resolved from
    the member's own `GearGroup` by the caller (this module has no concept
    of a group id, only the resolved numbers)."""

    kind: ChainMemberKind
    module: float
    pressure_angle_degrees: float
    tooth_count: int
    face_width: float
    outer_diameter: float | None = None  # required when kind == INTERNAL


@dataclass(frozen=True)
class ChainStageSpec:
    """One stage's pure-math-relevant input - either a single-gear/rack
    member (`member` set) or a compound pair (`compound_member_a`/
    `compound_member_b` set), mirroring `app.document.models.
    GearChainStage`'s own "exactly one of N populated" shape (PlaneRef's
    convention, applied here too).

    `compound_member_a` is the *incoming*-facing member (meshes with the
    previous stage), `compound_member_b` the *outgoing*-facing one (meshes
    with the next stage) - `05-gear-chain-and-planetary.md`'s own compound
    section states the two members face opposite directions but doesn't
    name which field is which; this a/b=incoming/outgoing convention is
    this module's own explicit pick (mirrors `LoftSection.reference_point`'s
    own "first section establishes the reference" style of picking one
    concrete convention among several that would have worked)."""

    turn_angle_degrees: float = 0.0
    member: ChainMemberSpec | None = None
    compound_member_a: ChainMemberSpec | None = None
    compound_member_b: ChainMemberSpec | None = None

    @property
    def is_compound(self) -> bool:
        return self.compound_member_a is not None

    def incoming_member(self) -> ChainMemberSpec:
        return self.compound_member_a if self.is_compound else self.member

    def outgoing_member(self) -> ChainMemberSpec:
        return self.compound_member_b if self.is_compound else self.member


# ---------------------------------------------------------------------------
# Bounding shapes (Spike 1, part 2) - one per physical member, used only for
# interference checking, never for the actual OCCT construction.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class BoundingCircle:
    center: tuple[float, float]
    radius: float


@dataclass(frozen=True)
class BoundingRect:
    """`angle` (radians) is the rectangle's own length-axis orientation -
    for a rack, perpendicular to the chain segment direction connecting it
    to its one neighbour (Spike 1's own rack-orientation convention, see
    `_bounding_shape_for_member`)."""

    center: tuple[float, float]
    angle: float
    half_length: float
    half_width: float


BoundingShape = BoundingCircle | BoundingRect


@dataclass(frozen=True)
class ResolvedChainMember:
    """One physical member's resolved position + bounding shape - a
    single-gear/rack stage contributes exactly one (`label="single"`), a
    compound stage exactly two (`label="a"`/`"b"`), both sharing the same
    `center` (coaxial - Spike 2's own confirmed finding 4)."""

    stage_index: int
    label: Literal["single", "a", "b"]
    center: tuple[float, float]
    bounding_shape: BoundingShape


@dataclass(frozen=True)
class ResolvedChainStage:
    """Mirrors `05-gear-chain-and-planetary.md`'s own "Spike 1 findings"
    data-structure sketch, generalized from one member per stage to
    `members` (1, or 2 for a compound stage)."""

    index: int
    center: tuple[float, float]
    incoming_direction: float | None  # radians; None for stage 0
    outgoing_direction: float | None  # radians; None for the last stage
    members: list[ResolvedChainMember]


@dataclass(frozen=True)
class InterferenceFinding:
    stage_index_a: int
    member_label_a: str
    stage_index_b: int
    member_label_b: str
    gap: float  # signed: negative = overlap depth, positive = clear gap
    kind: Literal["overlap", "clearance"]


@dataclass(frozen=True)
class ResolvedGearChain:
    stages: list[ResolvedChainStage]
    interference_findings: list[InterferenceFinding]


# ---------------------------------------------------------------------------
# Part 1: bent-path positioning (Spike 1's own "turtle graphics" resolution)
# ---------------------------------------------------------------------------


def _pitch_radius(member: ChainMemberSpec) -> float:
    """`module * tooth_count / 2` - the same formula regardless of
    external/internal (only the addendum/dedendum sign flips between the
    two, per `gear_math.spur_gear_geometry`'s own docstring; pitch radius
    itself never does), so no `is_internal` branch is needed here."""
    return member.module * member.tooth_count / 2


def _segment_distance(outgoing: ChainMemberSpec, incoming: ChainMemberSpec) -> float:
    """The centre distance (or, for a rack pairing, the rack-reference-
    point-to-gear-centre distance) for one chain segment, connecting one
    stage's `outgoing_member()` to the next stage's `incoming_member()`."""
    if outgoing.kind == ChainMemberKind.RACK and incoming.kind == ChainMemberKind.RACK:
        raise GearGeometryError("two consecutive rack members have no defined centre distance")
    if outgoing.kind == ChainMemberKind.RACK:
        return _pitch_radius(incoming)
    if incoming.kind == ChainMemberKind.RACK:
        return _pitch_radius(outgoing)
    if outgoing.kind == ChainMemberKind.INTERNAL and incoming.kind == ChainMemberKind.INTERNAL:
        raise GearGeometryError("two internal (ring) members cannot mesh directly with each other")
    if abs(outgoing.module - incoming.module) > 1e-9:
        raise GearGeometryError(
            f"adjacent members have different modules ({outgoing.module!r} vs {incoming.module!r}) - "
            "they must share a GearGroup to mesh"
        )
    if outgoing.kind == ChainMemberKind.INTERNAL or incoming.kind == ChainMemberKind.INTERNAL:
        external = incoming if outgoing.kind == ChainMemberKind.INTERNAL else outgoing
        internal = outgoing if outgoing.kind == ChainMemberKind.INTERNAL else incoming
        if internal.tooth_count <= external.tooth_count:
            raise GearGeometryError(
                f"internal member tooth_count ({internal.tooth_count!r}) must exceed the meshing "
                f"external member's ({external.tooth_count!r})"
            )
        return external.module * (internal.tooth_count - external.tooth_count) / 2
    return outgoing.module * (outgoing.tooth_count + incoming.tooth_count) / 2


def _bounding_shape_for_member(
    member: ChainMemberSpec, center: tuple[float, float], orientation: float
) -> BoundingShape:
    """`orientation` (radians) is the one chain-segment direction adjacent
    to this member's own stage - only used for a RACK member (its own
    length axis is perpendicular to it, per Spike 1's own convention);
    meaningless for a round gear, whose bounding circle has no
    orientation."""
    if member.kind == ChainMemberKind.RACK:
        rack_geometry: RackToothGeometry = rack_tooth_geometry(
            module=member.module, pressure_angle_degrees=member.pressure_angle_degrees
        )
        half_length = rack_length(rack_geometry, member.tooth_count) / 2
        half_width = (rack_geometry.addendum_height + rack_geometry.dedendum_height) / 2
        # The rect's own centre is offset from the rack's pitch-line
        # reference point (`center`) by (addendum-dedendum)/2 along the
        # rack's own perpendicular axis - i.e. along `orientation` itself,
        # since the rack's *length* axis is perpendicular to `orientation`
        # (Spike 1's own formula, verbatim).
        offset = (rack_geometry.addendum_height - rack_geometry.dedendum_height) / 2
        rect_center = (
            center[0] + offset * math.cos(orientation),
            center[1] + offset * math.sin(orientation),
        )
        return BoundingRect(
            center=rect_center,
            angle=orientation + math.pi / 2,
            half_length=half_length,
            half_width=half_width,
        )
    if member.kind == ChainMemberKind.INTERNAL:
        if member.outer_diameter is None:
            raise GearGeometryError("an internal member requires outer_diameter for its bounding shape")
        return BoundingCircle(center=center, radius=member.outer_diameter / 2)
    geometry = spur_gear_geometry(
        module=member.module,
        tooth_count=member.tooth_count,
        pressure_angle_degrees=member.pressure_angle_degrees,
        is_internal=False,
    )
    return BoundingCircle(center=center, radius=geometry.addendum_radius)


def resolve_chain_positions(
    stages: list[ChainStageSpec], start_direction_degrees: float = 0.0
) -> list[ResolvedChainStage]:
    """`05-gear-chain-and-planetary.md`'s "Spike 1 findings" resolution
    rule, generalized from one gear per stage to `ChainStageSpec`'s
    single-or-compound member(s): segment 0's direction is
    `start_direction_degrees`, absolute; segment `k` (`k>=1`)'s direction
    is segment `k-1`'s direction plus `stages[k].turn_angle_degrees`
    (turtle-relative, CCW-positive, reusing `gear_math._rotate`'s own
    convention). `stage[k]`'s `turn_angle_degrees` steers the segment
    *leaving* stage `k` - the last stage's own value is geometrically inert
    (no segment leaves it) - see `app.document.gear_chain` for whether the
    API tolerates or rejects a nonzero value there."""
    if len(stages) < 2:
        raise GearGeometryError(f"a chain needs at least 2 stages, got {len(stages)!r}")

    positions: list[tuple[float, float]] = [(0.0, 0.0)]
    directions: list[float] = []
    for k in range(len(stages) - 1):
        direction = (
            math.radians(start_direction_degrees)
            if k == 0
            else directions[k - 1] + math.radians(stages[k].turn_angle_degrees)
        )
        distance = _segment_distance(stages[k].outgoing_member(), stages[k + 1].incoming_member())
        directions.append(direction)
        prev_x, prev_y = positions[k]
        positions.append((prev_x + distance * math.cos(direction), prev_y + distance * math.sin(direction)))

    resolved: list[ResolvedChainStage] = []
    for i, stage in enumerate(stages):
        incoming_direction = directions[i - 1] if i > 0 else None
        outgoing_direction = directions[i] if i < len(stages) - 1 else None
        orientation = incoming_direction if incoming_direction is not None else outgoing_direction
        assert orientation is not None  # every stage has at least one adjacent segment (len(stages) >= 2)

        if stage.is_compound:
            members = [
                ResolvedChainMember(
                    stage_index=i,
                    label="a",
                    center=positions[i],
                    bounding_shape=_bounding_shape_for_member(stage.compound_member_a, positions[i], orientation),
                ),
                ResolvedChainMember(
                    stage_index=i,
                    label="b",
                    center=positions[i],
                    bounding_shape=_bounding_shape_for_member(stage.compound_member_b, positions[i], orientation),
                ),
            ]
        else:
            members = [
                ResolvedChainMember(
                    stage_index=i,
                    label="single",
                    center=positions[i],
                    bounding_shape=_bounding_shape_for_member(stage.member, positions[i], orientation),
                )
            ]
        resolved.append(
            ResolvedChainStage(
                index=i,
                center=positions[i],
                incoming_direction=incoming_direction,
                outgoing_direction=outgoing_direction,
                members=members,
            )
        )
    return resolved


# ---------------------------------------------------------------------------
# Part 2: interference checking (Spike 1's own topology-split gap functions)
# ---------------------------------------------------------------------------


def circle_circle_gap(a: BoundingCircle, b: BoundingCircle) -> float:
    """`center_distance - (radius_a + radius_b)` - exact, no approximation."""
    center_distance = math.hypot(a.center[0] - b.center[0], a.center[1] - b.center[1])
    return center_distance - (a.radius + b.radius)


def circle_rect_gap(circle: BoundingCircle, rect: BoundingRect) -> float:
    """Oriented-box signed-distance function minus the circle's radius -
    exact both inside and outside the box, per Spike 1's own formula."""
    dx = circle.center[0] - rect.center[0]
    dy = circle.center[1] - rect.center[1]
    cos_a, sin_a = math.cos(-rect.angle), math.sin(-rect.angle)
    local_x = dx * cos_a - dy * sin_a
    local_y = dx * sin_a + dy * cos_a
    outside_x = max(abs(local_x) - rect.half_length, 0.0)
    outside_y = max(abs(local_y) - rect.half_width, 0.0)
    outside_distance = math.hypot(outside_x, outside_y)
    inside_distance = min(max(abs(local_x) - rect.half_length, abs(local_y) - rect.half_width), 0.0)
    return outside_distance + inside_distance - circle.radius


def _rect_corners(rect: BoundingRect) -> list[tuple[float, float]]:
    cos_a, sin_a = math.cos(rect.angle), math.sin(rect.angle)
    local_corners = (
        (rect.half_length, rect.half_width),
        (rect.half_length, -rect.half_width),
        (-rect.half_length, rect.half_width),
        (-rect.half_length, -rect.half_width),
    )
    return [
        (rect.center[0] + lx * cos_a - ly * sin_a, rect.center[1] + lx * sin_a + ly * cos_a)
        for lx, ly in local_corners
    ]


def rect_rect_gap(a: BoundingRect, b: BoundingRect) -> float:
    """Separating Axis Theorem over the 4 unique edge-normal axes (2 per
    rectangle) - overlap detection is exact (SAT is an iff for convex
    polygons); the separation magnitude when they don't overlap (`max` of
    the 4 per-axis gaps) is a conservative lower bound on true separation,
    per Spike 1's own finding - never overestimates clearance."""
    corners_a = _rect_corners(a)
    corners_b = _rect_corners(b)
    axes = [(math.cos(angle), math.sin(angle)) for angle in (a.angle, a.angle + math.pi / 2, b.angle, b.angle + math.pi / 2)]
    max_gap = -math.inf
    for ax, ay in axes:
        proj_a = [px * ax + py * ay for px, py in corners_a]
        proj_b = [px * ax + py * ay for px, py in corners_b]
        gap = max(min(proj_b) - max(proj_a), min(proj_a) - max(proj_b))
        max_gap = max(max_gap, gap)
    return max_gap


def _shape_gap(a: BoundingShape, b: BoundingShape) -> float:
    if isinstance(a, BoundingCircle) and isinstance(b, BoundingCircle):
        return circle_circle_gap(a, b)
    if isinstance(a, BoundingRect) and isinstance(b, BoundingRect):
        return rect_rect_gap(a, b)
    circle, rect = (a, b) if isinstance(a, BoundingCircle) else (b, a)
    return circle_rect_gap(circle, rect)  # type: ignore[arg-type]


def check_chain_interference(
    resolved_stages: list[ResolvedChainStage], print_clearance_margin: float = 0.2
) -> list[InterferenceFinding]:
    """Skips every consecutive (adjacent stage-index) pair outright -
    correctness there is guaranteed by the exact centre-distance formula
    `resolve_chain_positions` already used, per `05-gear-chain-and-
    planetary.md`'s own topology-split reasoning (checked at *stage*
    granularity, not per-member - a compound stage's own two members share
    one stage index, so both are exempted from a check against either
    neighbouring stage, matching the doc's literal "no check between
    consecutive stage pairs" rule). Every non-adjacent pair: `gap < 0` ->
    an "overlap" finding (zero tolerance), `0 <= gap < margin` -> a
    "clearance" finding, `gap >= margin` -> no finding. Both finding kinds
    are non-blocking, per `00-conventions.md`'s validation-banner
    convention."""
    all_members = [member for stage in resolved_stages for member in stage.members]
    findings: list[InterferenceFinding] = []
    for i in range(len(all_members)):
        member_i = all_members[i]
        for j in range(i + 1, len(all_members)):
            member_j = all_members[j]
            if member_i.stage_index == member_j.stage_index:
                continue
            if abs(member_i.stage_index - member_j.stage_index) <= 1:
                continue
            gap = _shape_gap(member_i.bounding_shape, member_j.bounding_shape)
            if gap < 0:
                kind: Literal["overlap", "clearance"] = "overlap"
            elif gap < print_clearance_margin:
                kind = "clearance"
            else:
                continue
            findings.append(
                InterferenceFinding(
                    stage_index_a=member_i.stage_index,
                    member_label_a=member_i.label,
                    stage_index_b=member_j.stage_index,
                    member_label_b=member_j.label,
                    gap=gap,
                    kind=kind,
                )
            )
    return findings


def resolve_chain(
    stages: list[ChainStageSpec],
    start_direction_degrees: float = 0.0,
    print_clearance_margin: float = 0.2,
) -> ResolvedGearChain:
    """Combines `resolve_chain_positions` + `check_chain_interference` into
    the one call `app.document.gear_chain`'s OCCT construction actually
    needs (both the positions to build/place solids at, and the findings
    to surface as non-blocking warnings). Named distinctly from `app.
    document.gear_chain.resolve_gear_chain` (that module's own router-
    facing entry point, mirroring `resolve_gear`/`resolve_rack`/
    `resolve_loft`'s established per-module naming) purely to avoid a
    same-name import collision between the two modules - no behavioural
    significance to the name difference itself."""
    resolved_stages = resolve_chain_positions(stages, start_direction_degrees)
    findings = check_chain_interference(resolved_stages, print_clearance_margin)
    return ResolvedGearChain(stages=resolved_stages, interference_findings=findings)


# ---------------------------------------------------------------------------
# Compound-station checks that don't need OCCT (Spike 2 findings)
# ---------------------------------------------------------------------------


def compound_axial_overlap(member_a_face_width: float, axial_offset: float) -> float:
    """`member_b`'s own local z span starts at `axial_offset` from
    `member_a`'s own z=0 origin (`member_a` spans `[0, member_a_face_
    width]`) - returns the overlap depth between the two members' axial
    spans (positive = real overlap, per Spike 2 finding 1's case 3;
    zero/negative = a flush join or a real gap, the latter being Spike 2's
    own case 1, caught instead by the OCCT-side connected-solid-count
    check). Pure arithmetic on the two stage-spec numbers - no OCCT
    needed, unlike the connected-solid-count check itself."""
    return member_a_face_width - axial_offset


@dataclass(frozen=True)
class LinkRatio:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "two cheap
    numbers from the same math": one meshing link's overall-ratio and
    rotation-direction summary. `ratio` follows the standard driven-teeth/
    driving-teeth convention (the earlier stage in chain order is treated
    as "driving," the next as "driven" - chain order = power-flow order,
    an explicit convention pick since neither this doc nor Spike 1 names an
    input/output end) - `None` for a rack link, since a rack's linear
    motion has no single well-defined angular ratio;
    `linear_mm_per_revolution` (rack travel per one full revolution of its
    meshing gear, `pi * module * tooth_count`) is that link's own
    equivalent number instead. `reverses` is `05-gear-chain-and-planetary.
    md`'s own stated rule: True for external-external, False for external-
    internal - a rack link is treated the same as external-external here
    (the standard rack-and-pinion convention: a rack's single tooth face
    behaves like one side of an external gear for this purpose), which is
    this module's own explicit reading of the doc's "rack direction depends
    on orientation" note (the rack's *own* physical direction of travel
    depends on which side of the segment its teeth face - already resolved
    by `_bounding_shape_for_member`'s `orientation` - but the reversal
    parity relative to the neighbouring gear does not have a second case to
    select between, since a rack has only one meshing face)."""

    ratio: float | None
    reverses: bool
    linear_mm_per_revolution: float | None = None


def mesh_link_ratio(driving: ChainMemberSpec, driven: ChainMemberSpec) -> LinkRatio:
    """One ordinary meshing link between two adjacent stages/members -
    `driving` is the earlier stage's own `outgoing_member()`, `driven` the
    next stage's `incoming_member()` (see `LinkRatio`'s own docstring for
    the chain-order-as-power-flow convention)."""
    if driving.kind == ChainMemberKind.RACK or driven.kind == ChainMemberKind.RACK:
        gear = driven if driving.kind == ChainMemberKind.RACK else driving
        return LinkRatio(
            ratio=None, reverses=True, linear_mm_per_revolution=math.pi * gear.module * gear.tooth_count
        )
    reverses = driving.kind != ChainMemberKind.INTERNAL and driven.kind != ChainMemberKind.INTERNAL
    return LinkRatio(ratio=driven.tooth_count / driving.tooth_count, reverses=reverses)


def compound_transition_ratio(member_a: ChainMemberSpec, member_b: ChainMemberSpec) -> LinkRatio:
    """A compound stage's two members are rigidly fused on one shaft - they
    always co-rotate (`reverses=False` unconditionally - `05-gear-chain-
    and-planetary.md`'s own "never reverses" compound-gear rule), but the
    tooth-count *identity* driving the next mesh changes from `member_a` to
    `member_b`. `ratio` here (`member_b`'s teeth / `member_a`'s teeth)
    reports that identity change for display only - it is not a second
    physical mesh and must not be multiplied into `chain_overall_ratio`
    separately: the ordinary `mesh_link_ratio` calls on either side of this
    stage already pick up `member_a`'s/`member_b`'s own tooth counts
    correctly via `ChainStageSpec.incoming_member()`/`outgoing_member()`."""
    return LinkRatio(ratio=member_b.tooth_count / member_a.tooth_count, reverses=False)


def chain_overall_ratio(links: list[LinkRatio]) -> float | None:
    """Telescoped product of every ordinary mesh link's own driven/driving
    ratio (stage 0's driving speed to the last stage's driven speed) -
    `None` if any link is a rack link, per `LinkRatio`'s own docstring,
    rather than silently reporting a partial/misleading product."""
    ratio = 1.0
    for link in links:
        if link.ratio is None:
            return None
        ratio *= link.ratio
    return ratio


def thin_member_warning(face_width: float, member_label: str, minimum: float = 1.0) -> str | None:
    """Spike 2's own separate, simpler minimum-thickness check "on a single
    member's own face_width in isolation" - unrelated to the join-geometry
    check above, kept because a thin member is fragile once printed
    regardless of how well the join itself resolves. `minimum` defaults to
    1.0mm (the spike's own "a 0.3mm-thick member is physically fragile"
    example is comfortably below this default)."""
    if face_width < minimum:
        return (
            f"compound member {member_label}'s face_width ({face_width!r}mm) is below the "
            f"{minimum!r}mm minimum-thickness guideline - likely fragile once printed"
        )
    return None
