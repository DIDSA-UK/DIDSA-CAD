"""Native project file format: a pure, lossless serialization of the whole
Document (every Part's ordered Feature list) plus every Sketch referenced by
any SketchFeature in it - no cached mesh/geometry, matching the locked-in
"pure parametric tree" scope for Save/Load. Re-opening a native file means
re-running `app.document.extrude.compute_part_bodies` from this exact
Feature/Sketch data, the same as any other recompute.

This is deliberately a standalone dict<->dataclass mapping, not a reuse of
`app.document.schemas`'s pydantic response models - the native file's own
on-disk shape is its own contract, free to diverge from the HTTP API's
response shape (which already carries API-only fields like `locked`/
`produces`/resolved plane geometry that have no place in a save file).

Client-owned files (locked-in scope): the backend has no persistent project
storage of its own - `export_native`/`import_native` only convert between
this process's in-memory Document/Sketch store and one JSON-serializable
dict; the client is the one that writes/reads the actual file to/from disk.
"""

import base64
import dataclasses

from app.document.models import (
    BevelGearFeature,
    BevelGearType,
    ChamferFeature,
    CreatePlaneFeature,
    Document,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FilletFeature,
    FixedAxis,
    GearChainFeature,
    GearChainMemberSpec,
    GearChainMemberType,
    GearChainStage,
    GearFeature,
    GearGroup,
    GearType,
    ImportFeature,
    ImportSourceFormat,
    LoftFeature,
    LoftMode,
    LoftSection,
    MergeMode,
    MirrorFeature,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PatternType,
    PlanetaryGearFeature,
    PlaneRef,
    PlaneType,
    PointRef,
    RackFeature,
    RackType,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
    SweepFeature,
    SweepMode,
)
from app.sketch.constraints import (
    AngleConstraint,
    AtMidpointConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    Constraint,
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    SplineTangentConstraint,
    TangentConstraint,
    VerticalConstraint,
)
from app.sketch.models import (
    Arc,
    Circle,
    Ellipse,
    ExternalVertexReference,
    Line,
    Plane,
    Point,
    Polygon,
    Rectangle,
    Sketch,
    SketchEntity,
    SketchEntityRef,
    SketchEntityType,
    SketchFixedAxis,
    SketchMirrorInstance,
    SketchPatternDirection,
    SketchPatternInstance,
    Slot,
    Spline,
    TextEntity,
)

# Bumped whenever the on-disk shape changes in a way that breaks reading an
# older file - `import_native` rejects anything else outright rather than
# guessing at a best-effort partial read.
SCHEMA_VERSION = 1

_CONSTRAINT_CLASSES: dict[str, type[Constraint]] = {
    "distance": DistanceConstraint,
    "vertical": VerticalConstraint,
    "horizontal": HorizontalConstraint,
    "angle": AngleConstraint,
    "coincident": CoincidentConstraint,
    "parallel": ParallelConstraint,
    "perpendicular": PerpendicularConstraint,
    "equal_length": EqualLengthConstraint,
    "collinear": CollinearConstraint,
    "line_distance": LineDistanceConstraint,
    "point_line_distance": PointLineDistanceConstraint,
    "at_midpoint": AtMidpointConstraint,
    "spline_tangent": SplineTangentConstraint,
    "tangent": TangentConstraint,
    "equal_radius": EqualRadiusConstraint,
}


class NativeFormatError(ValueError):
    """Raised for anything wrong with a native file's own shape/content -
    an unsupported schema_version, an unknown Feature/entity/constraint
    type, or a missing required field. Always a client-supplied-file
    problem, never an internal bug - `app.document.router` maps this to a
    422, mirroring every other structured-validation-error convention in
    this codebase."""


def _require(data: dict, key: str) -> object:
    if key not in data:
        raise NativeFormatError(f"Missing required field: {key!r}")
    return data[key]


# --- Sketch-domain leaves ------------------------------------------------


def _point_to_dict(point: Point) -> dict:
    return {"id": point.id, "x": point.x, "y": point.y}


def _point_from_dict(data: dict) -> Point:
    return Point(id=_require(data, "id"), x=_require(data, "x"), y=_require(data, "y"))


def _entity_to_dict(entity: SketchEntity) -> dict:
    if isinstance(entity, Line):
        return {
            "type": "line",
            "id": entity.id,
            "construction": entity.construction,
            "start_point_id": entity.start_point_id,
            "end_point_id": entity.end_point_id,
        }
    if isinstance(entity, Circle):
        return {
            "type": "circle",
            "id": entity.id,
            "construction": entity.construction,
            "center_point_id": entity.center_point_id,
            "radius_point_id": entity.radius_point_id,
            "radius_constraint_id": entity.radius_constraint_id,
            "cardinal_point_ids": entity.cardinal_point_ids,
            "cardinal_constraint_ids": entity.cardinal_constraint_ids,
        }
    if isinstance(entity, Arc):
        return {
            "type": "arc",
            "id": entity.id,
            "construction": entity.construction,
            "center_point_id": entity.center_point_id,
            "start_point_id": entity.start_point_id,
            "end_point_id": entity.end_point_id,
            "radius_constraint_id": entity.radius_constraint_id,
            "end_radius_constraint_id": entity.end_radius_constraint_id,
        }
    if isinstance(entity, Ellipse):
        return {
            "type": "ellipse",
            "id": entity.id,
            "construction": entity.construction,
            "center_point_id": entity.center_point_id,
            "major_point_id": entity.major_point_id,
            "major_point_neg_id": entity.major_point_neg_id,
            "major_constraint_id": entity.major_constraint_id,
            "major_midpoint_constraint_id": entity.major_midpoint_constraint_id,
            "minor_point_id": entity.minor_point_id,
            "minor_point_neg_id": entity.minor_point_neg_id,
            "minor_constraint_id": entity.minor_constraint_id,
            "minor_midpoint_constraint_id": entity.minor_midpoint_constraint_id,
            "major_axis_line_id": entity.major_axis_line_id,
            "minor_axis_line_id": entity.minor_axis_line_id,
            "perpendicular_constraint_id": entity.perpendicular_constraint_id,
        }
    if isinstance(entity, Polygon):
        return {
            "type": "polygon",
            "id": entity.id,
            "construction": entity.construction,
            "center_point_id": entity.center_point_id,
            "vertex_point_ids": entity.vertex_point_ids,
            "line_ids": entity.line_ids,
            "radial_line_ids": entity.radial_line_ids,
            "radius_constraint_id": entity.radius_constraint_id,
            "equal_radius_constraint_ids": entity.equal_radius_constraint_ids,
            "angle_constraint_ids": entity.angle_constraint_ids,
            "sides": entity.sides,
            "circumscribed_circle_id": entity.circumscribed_circle_id,
            "inscribed_circle_id": entity.inscribed_circle_id,
            "inscribed_tangent_constraint_id": entity.inscribed_tangent_constraint_id,
        }
    if isinstance(entity, Slot):
        return {
            "type": "slot",
            "id": entity.id,
            "construction": entity.construction,
            "center1_point_id": entity.center1_point_id,
            "center2_point_id": entity.center2_point_id,
            "centerline_id": entity.centerline_id,
            "arc1_id": entity.arc1_id,
            "arc2_id": entity.arc2_id,
            "line1_id": entity.line1_id,
            "line2_id": entity.line2_id,
            "a_point_id": entity.a_point_id,
            "b_point_id": entity.b_point_id,
            "c_point_id": entity.c_point_id,
            "d_point_id": entity.d_point_id,
            "radius_constraint_id": entity.radius_constraint_id,
            "equal_radius_constraint_ids": entity.equal_radius_constraint_ids,
            "tangent_constraint_ids": entity.tangent_constraint_ids,
            "parallel_constraint_ids": entity.parallel_constraint_ids,
        }
    if isinstance(entity, Rectangle):
        return {
            "type": "rectangle",
            "id": entity.id,
            "construction": entity.construction,
            "corner_point_ids": entity.corner_point_ids,
            "line_ids": entity.line_ids,
            "axis_aligned": entity.axis_aligned,
            "axis_constraint_ids": entity.axis_constraint_ids,
            "center_point_id": entity.center_point_id,
            "diagonal_line_id": entity.diagonal_line_id,
            "diagonal2_line_id": entity.diagonal2_line_id,
            "midpoint_constraint_id": entity.midpoint_constraint_id,
        }
    if isinstance(entity, Spline):
        return {
            "type": "spline",
            "id": entity.id,
            "construction": entity.construction,
            "through_point_ids": entity.through_point_ids,
            "control_point_ids": entity.control_point_ids,
            "tangent_constraint_ids": entity.tangent_constraint_ids,
        }
    if isinstance(entity, TextEntity):
        return {
            "type": "text",
            "id": entity.id,
            "construction": entity.construction,
            "content": entity.content,
            "font": entity.font,
            "size": entity.size,
            "anchor_point_id": entity.anchor_point_id,
            "rotation_degrees": entity.rotation_degrees,
        }
    raise NativeFormatError(f"No native export mapping for sketch entity type: {entity.type!r}")


def _entity_from_dict(data: dict) -> SketchEntity:
    entity_type = _require(data, "type")
    if entity_type == "line":
        return Line(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            start_point_id=_require(data, "start_point_id"),
            end_point_id=_require(data, "end_point_id"),
        )
    if entity_type == "circle":
        return Circle(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            center_point_id=_require(data, "center_point_id"),
            radius_point_id=_require(data, "radius_point_id"),
            radius_constraint_id=_require(data, "radius_constraint_id"),
            cardinal_point_ids=_require(data, "cardinal_point_ids"),
            cardinal_constraint_ids=_require(data, "cardinal_constraint_ids"),
        )
    if entity_type == "arc":
        return Arc(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            center_point_id=_require(data, "center_point_id"),
            start_point_id=_require(data, "start_point_id"),
            end_point_id=_require(data, "end_point_id"),
            radius_constraint_id=_require(data, "radius_constraint_id"),
            end_radius_constraint_id=_require(data, "end_radius_constraint_id"),
        )
    if entity_type == "ellipse":
        return Ellipse(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            center_point_id=_require(data, "center_point_id"),
            major_point_id=_require(data, "major_point_id"),
            major_point_neg_id=_require(data, "major_point_neg_id"),
            major_constraint_id=_require(data, "major_constraint_id"),
            major_midpoint_constraint_id=_require(data, "major_midpoint_constraint_id"),
            minor_point_id=_require(data, "minor_point_id"),
            minor_point_neg_id=_require(data, "minor_point_neg_id"),
            minor_constraint_id=_require(data, "minor_constraint_id"),
            minor_midpoint_constraint_id=_require(data, "minor_midpoint_constraint_id"),
            major_axis_line_id=_require(data, "major_axis_line_id"),
            minor_axis_line_id=_require(data, "minor_axis_line_id"),
            perpendicular_constraint_id=_require(data, "perpendicular_constraint_id"),
        )
    if entity_type == "polygon":
        return Polygon(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            center_point_id=_require(data, "center_point_id"),
            vertex_point_ids=list(_require(data, "vertex_point_ids")),
            line_ids=list(_require(data, "line_ids")),
            # `radial_line_ids` fallback: a native-format file saved before
            # this Polygon redesign (see that class's own docstring) has no
            # such key at all - those construction Lines never existed for
            # it, so an empty list is the correct, honest read (not a
            # missing-data error).
            radial_line_ids=list(data.get("radial_line_ids", [])),
            radius_constraint_id=_require(data, "radius_constraint_id"),
            equal_radius_constraint_ids=list(_require(data, "equal_radius_constraint_ids")),
            angle_constraint_ids=list(_require(data, "angle_constraint_ids")),
            sides=_require(data, "sides"),
            circumscribed_circle_id=data.get("circumscribed_circle_id"),
            inscribed_circle_id=data.get("inscribed_circle_id"),
            inscribed_tangent_constraint_id=data.get("inscribed_tangent_constraint_id"),
        )
    if entity_type == "slot":
        return Slot(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            center1_point_id=_require(data, "center1_point_id"),
            center2_point_id=_require(data, "center2_point_id"),
            centerline_id=_require(data, "centerline_id"),
            arc1_id=_require(data, "arc1_id"),
            arc2_id=_require(data, "arc2_id"),
            line1_id=_require(data, "line1_id"),
            line2_id=_require(data, "line2_id"),
            a_point_id=_require(data, "a_point_id"),
            b_point_id=_require(data, "b_point_id"),
            c_point_id=_require(data, "c_point_id"),
            d_point_id=_require(data, "d_point_id"),
            radius_constraint_id=_require(data, "radius_constraint_id"),
            equal_radius_constraint_ids=list(_require(data, "equal_radius_constraint_ids")),
            tangent_constraint_ids=list(_require(data, "tangent_constraint_ids")),
            parallel_constraint_ids=list(_require(data, "parallel_constraint_ids")),
        )
    if entity_type == "rectangle":
        return Rectangle(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            corner_point_ids=list(_require(data, "corner_point_ids")),
            line_ids=list(_require(data, "line_ids")),
            axis_aligned=_require(data, "axis_aligned"),
            axis_constraint_ids=list(_require(data, "axis_constraint_ids")),
            center_point_id=data.get("center_point_id"),
            diagonal_line_id=data.get("diagonal_line_id"),
            diagonal2_line_id=data.get("diagonal2_line_id"),
            midpoint_constraint_id=data.get("midpoint_constraint_id"),
        )
    if entity_type == "spline":
        return Spline(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            through_point_ids=list(_require(data, "through_point_ids")),
            control_point_ids=list(_require(data, "control_point_ids")),
            tangent_constraint_ids=list(_require(data, "tangent_constraint_ids")),
        )
    if entity_type == "text":
        return TextEntity(
            id=_require(data, "id"),
            construction=data.get("construction", False),
            content=_require(data, "content"),
            font=_require(data, "font"),
            size=_require(data, "size"),
            anchor_point_id=_require(data, "anchor_point_id"),
            rotation_degrees=data.get("rotation_degrees", 0.0),
        )
    raise NativeFormatError(f"Unknown native sketch entity type: {entity_type!r}")


def _constraint_to_dict(constraint: Constraint) -> dict:
    # Every Constraint subclass is a plain dataclass of str/float fields
    # only (no nesting) - dataclasses.asdict round-trips all of them without
    # per-type field lists, unlike Feature/SketchEntity which do nest.
    data = dataclasses.asdict(constraint)
    data["type"] = constraint.type
    return data


def _constraint_from_dict(data: dict) -> Constraint:
    constraint_type = _require(data, "type")
    cls = _CONSTRAINT_CLASSES.get(constraint_type)
    if cls is None:
        raise NativeFormatError(f"Unknown native constraint type: {constraint_type!r}")
    kwargs = {key: value for key, value in data.items() if key != "type"}
    try:
        return cls(**kwargs)
    except TypeError as exc:
        raise NativeFormatError(f"Malformed {constraint_type!r} constraint: {exc}") from exc


def _pattern_direction_to_dict(direction: SketchPatternDirection) -> dict:
    return {
        "line_id": direction.line_id,
        "fixed_axis": direction.fixed_axis.value if direction.fixed_axis is not None else None,
    }


def _pattern_direction_from_dict(data: dict) -> SketchPatternDirection:
    fixed_axis = data.get("fixed_axis")
    return SketchPatternDirection(
        line_id=data.get("line_id"),
        fixed_axis=SketchFixedAxis(fixed_axis) if fixed_axis is not None else None,
    )


def _pattern_instance_to_dict(instance: SketchPatternInstance) -> dict:
    return {
        "id": instance.id,
        "source_entity_ids": instance.source_entity_ids,
        "direction_1": _pattern_direction_to_dict(instance.direction_1),
        "count_1": instance.count_1,
        "spacing_1": instance.spacing_1,
        "reverse_1": instance.reverse_1,
        # On-device feedback ("allow pattern in two directions"): additive,
        # None-safe fields, same "second direction is inert unless count_2
        # > 1" convention `app.document.native_format`'s own `PatternFeature`
        # round-trip already established.
        "direction_2": _pattern_direction_to_dict(instance.direction_2) if instance.direction_2 is not None else None,
        "count_2": instance.count_2,
        "spacing_2": instance.spacing_2,
        "reverse_2": instance.reverse_2,
    }


def _pattern_instance_from_dict(data: dict) -> SketchPatternInstance:
    # `direction_1`/`count_1`/`spacing_1`/`reverse_1` fall back to this
    # phase's own original, pre-two-direction key names ("direction"/
    # "count"/"spacing"/"reverse") for a save made in the brief window
    # between Phase 7's own initial ship and this on-device revision -
    # every other field here is purely additive and needs no such fallback.
    direction_1_data = data.get("direction_1", data.get("direction"))
    if direction_1_data is None:
        raise NativeFormatError("Missing required field: 'direction_1'")
    count_1 = data.get("count_1", data.get("count"))
    if count_1 is None:
        raise NativeFormatError("Missing required field: 'count_1'")
    spacing_1 = data.get("spacing_1", data.get("spacing"))
    if spacing_1 is None:
        raise NativeFormatError("Missing required field: 'spacing_1'")
    direction_2 = data.get("direction_2")
    return SketchPatternInstance(
        id=_require(data, "id"),
        source_entity_ids=list(_require(data, "source_entity_ids")),
        direction_1=_pattern_direction_from_dict(direction_1_data),
        count_1=count_1,
        spacing_1=spacing_1,
        reverse_1=data.get("reverse_1", data.get("reverse", False)),
        direction_2=_pattern_direction_from_dict(direction_2) if direction_2 is not None else None,
        count_2=data.get("count_2", 1),
        spacing_2=data.get("spacing_2", 0.0),
        reverse_2=data.get("reverse_2", False),
    )


def _mirror_instance_to_dict(instance: SketchMirrorInstance) -> dict:
    return {
        "id": instance.id,
        "source_entity_ids": instance.source_entity_ids,
        "mirror_line_id": instance.mirror_line_id,
    }


def _mirror_instance_from_dict(data: dict) -> SketchMirrorInstance:
    return SketchMirrorInstance(
        id=_require(data, "id"),
        source_entity_ids=list(_require(data, "source_entity_ids")),
        mirror_line_id=_require(data, "mirror_line_id"),
    )


def sketch_to_dict(sketch: Sketch) -> dict:
    """A `Sketch`'s full state, serialized to a plain dict - the same shape
    `export_native`'s own `"sketches"` array entries use.

    Public (no leading underscore) since the standalone "2D Drawing" tool's
    own bare-Sketch save/open endpoints (`app.sketch.router`) reuse this
    verbatim rather than re-deriving a second serialization for the exact
    same `Sketch` shape - a bare Sketch has no Part/Document context, so it
    needed a save/open path independent of `export_native`/`import_native`'s
    own Document-level format, but the underlying per-Sketch dict shape is
    identical either way."""
    return {
        "id": sketch.id,
        "plane": sketch.plane.value if sketch.plane is not None else None,
        "origin_point_id": sketch.origin_point_id,
        # Sketcher-roadmap Phase 5.
        "flip": sketch.flip,
        "rotation_quarter_turns": sketch.rotation_quarter_turns,
        "points": [_point_to_dict(p) for p in sketch.points.values()],
        "entities": [_entity_to_dict(e) for e in sketch.entities.values()],
        "constraints": [_constraint_to_dict(c) for c in sketch.constraints.values()],
        # Sketcher-roadmap Phase 4.3 v1.
        "external_references": [
            {"point_id": point_id, "body_id": ref.body_id, "vertex_index": ref.vertex_index}
            for point_id, ref in sketch.external_references.items()
        ],
        # Sketcher-roadmap Phase 7 (2D Pattern/Mirror).
        "pattern_instances": [_pattern_instance_to_dict(i) for i in sketch.pattern_instances.values()],
        "mirror_instances": [_mirror_instance_to_dict(i) for i in sketch.mirror_instances.values()],
    }


def sketch_from_dict(data: dict) -> Sketch:
    """The inverse of [sketch_to_dict] - public for the same reason."""
    plane_value = data.get("plane")
    sketch = Sketch(id=_require(data, "id"), plane=Plane(plane_value) if plane_value is not None else None)
    sketch._origin_point_id = data.get("origin_point_id")
    # Sketcher-roadmap Phase 5 - defaulted (not _require'd), unlike most
    # other fields in this function: a native file saved before this
    # feature existed has no opinion on orientation, and the identity
    # orientation is the correct, harmless default for it.
    sketch.set_orientation(
        flip=data.get("flip", False), rotation_quarter_turns=data.get("rotation_quarter_turns", 0)
    )
    for point_data in data.get("points", []):
        point = _point_from_dict(point_data)
        sketch.points[point.id] = point
    for entity_data in data.get("entities", []):
        entity = _entity_from_dict(entity_data)
        sketch.entities[entity.id] = entity
    for constraint_data in data.get("constraints", []):
        constraint = _constraint_from_dict(constraint_data)
        sketch.constraints[constraint.id] = constraint
    # Sketcher-roadmap Phase 4.3 v1 - defaulted to `[]`, same "a file saved
    # before this feature existed has no opinion on it" reasoning as
    # flip/rotation_quarter_turns above.
    for ref_data in data.get("external_references", []):
        sketch.external_references[ref_data["point_id"]] = ExternalVertexReference(
            body_id=ref_data["body_id"], vertex_index=ref_data["vertex_index"]
        )
    # Sketcher-roadmap Phase 7 (2D Pattern/Mirror) - defaulted to `[]`, same
    # "a file saved before this feature existed has no opinion on it"
    # reasoning as external_references above.
    for instance_data in data.get("pattern_instances", []):
        instance = _pattern_instance_from_dict(instance_data)
        sketch.pattern_instances[instance.id] = instance
    for instance_data in data.get("mirror_instances", []):
        instance = _mirror_instance_from_dict(instance_data)
        sketch.mirror_instances[instance.id] = instance
    return sketch


# --- Document-domain reference value types --------------------------------


def _sketch_entity_ref_to_dict(ref: SketchEntityRef) -> dict:
    return {"sketch_id": ref.sketch_id, "entity_type": ref.entity_type.value, "entity_id": ref.entity_id}


def _sketch_entity_ref_from_dict(data: dict) -> SketchEntityRef:
    return SketchEntityRef(
        sketch_id=_require(data, "sketch_id"),
        entity_type=SketchEntityType(_require(data, "entity_type")),
        entity_id=_require(data, "entity_id"),
    )


def _subshape_ref_to_dict(ref: SubShapeRef) -> dict:
    return {"body_id": ref.body_id, "shape_type": ref.shape_type.value, "index": ref.index}


def _subshape_ref_from_dict(data: dict) -> SubShapeRef:
    return SubShapeRef(
        body_id=_require(data, "body_id"),
        shape_type=SubShapeType(_require(data, "shape_type")),
        index=_require(data, "index"),
    )


def _loft_section_to_dict(section: LoftSection) -> dict:
    return {
        "sketch_feature_id": section.sketch_feature_id,
        "profile_refs": [_sketch_entity_ref_to_dict(r) for r in section.profile_refs],
        "reference_point": _sketch_entity_ref_to_dict(section.reference_point)
        if section.reference_point
        else None,
    }


def _loft_section_from_dict(data: dict) -> LoftSection:
    return LoftSection(
        sketch_feature_id=_require(data, "sketch_feature_id"),
        profile_refs=[_sketch_entity_ref_from_dict(r) for r in data.get("profile_refs", [])],
        reference_point=_sketch_entity_ref_from_dict(data["reference_point"])
        if data.get("reference_point")
        else None,
    )


def _gear_group_to_dict(group: GearGroup) -> dict:
    return {
        "id": group.id,
        "module": group.module,
        "pressure_angle_degrees": group.pressure_angle_degrees,
        "display_color": group.display_color,
    }


def _gear_group_from_dict(data: dict) -> GearGroup:
    return GearGroup(
        id=_require(data, "id"),
        module=_require(data, "module"),
        pressure_angle_degrees=data.get("pressure_angle_degrees", 20.0),
        display_color=data.get("display_color"),
    )


def _gear_chain_member_to_dict(member: GearChainMemberSpec) -> dict:
    return {
        "member_type": member.member_type.value,
        "group_id": member.group_id,
        "tooth_count": member.tooth_count,
        "face_width": member.face_width,
        "outer_diameter": member.outer_diameter,
    }


def _gear_chain_member_from_dict(data: dict) -> GearChainMemberSpec:
    return GearChainMemberSpec(
        member_type=GearChainMemberType(_require(data, "member_type")),
        group_id=_require(data, "group_id"),
        tooth_count=_require(data, "tooth_count"),
        face_width=_require(data, "face_width"),
        outer_diameter=data.get("outer_diameter"),
    )


def _gear_chain_stage_to_dict(stage: GearChainStage) -> dict:
    return {
        "turn_angle_degrees": stage.turn_angle_degrees,
        "member": _gear_chain_member_to_dict(stage.member) if stage.member is not None else None,
        "compound_member_a": _gear_chain_member_to_dict(stage.compound_member_a)
        if stage.compound_member_a is not None
        else None,
        "compound_member_b": _gear_chain_member_to_dict(stage.compound_member_b)
        if stage.compound_member_b is not None
        else None,
        "compound_axial_offset": stage.compound_axial_offset,
        "compound_merge": stage.compound_merge.value,
    }


def _gear_chain_stage_from_dict(data: dict) -> GearChainStage:
    return GearChainStage(
        turn_angle_degrees=data.get("turn_angle_degrees", 0.0),
        member=_gear_chain_member_from_dict(data["member"]) if data.get("member") else None,
        compound_member_a=_gear_chain_member_from_dict(data["compound_member_a"])
        if data.get("compound_member_a")
        else None,
        compound_member_b=_gear_chain_member_from_dict(data["compound_member_b"])
        if data.get("compound_member_b")
        else None,
        compound_axial_offset=data.get("compound_axial_offset", 0.0),
        compound_merge=MergeMode(data.get("compound_merge", MergeMode.FUSE_INTO_ONE.value)),
    )


def _point_ref_to_dict(ref: PointRef) -> dict:
    return {
        "vertex_ref": _subshape_ref_to_dict(ref.vertex_ref) if ref.vertex_ref else None,
        "sketch_point_ref": _sketch_entity_ref_to_dict(ref.sketch_point_ref) if ref.sketch_point_ref else None,
    }


def _point_ref_from_dict(data: dict) -> PointRef:
    return PointRef(
        vertex_ref=_subshape_ref_from_dict(data["vertex_ref"]) if data.get("vertex_ref") else None,
        sketch_point_ref=_sketch_entity_ref_from_dict(data["sketch_point_ref"])
        if data.get("sketch_point_ref")
        else None,
    )


def _plane_ref_to_dict(ref: PlaneRef) -> dict:
    return {
        "face_ref": _subshape_ref_to_dict(ref.face_ref) if ref.face_ref else None,
        "fixed_plane": ref.fixed_plane.value if ref.fixed_plane else None,
        "plane_feature_id": ref.plane_feature_id,
    }


def _plane_ref_from_dict(data: dict) -> PlaneRef:
    return PlaneRef(
        face_ref=_subshape_ref_from_dict(data["face_ref"]) if data.get("face_ref") else None,
        fixed_plane=Plane(data["fixed_plane"]) if data.get("fixed_plane") else None,
        plane_feature_id=data.get("plane_feature_id"),
    )


def _pattern_direction_ref_to_dict(ref: PatternDirectionRef) -> dict:
    return {
        "edge_ref": _subshape_ref_to_dict(ref.edge_ref) if ref.edge_ref else None,
        "sketch_line_ref": _sketch_entity_ref_to_dict(ref.sketch_line_ref) if ref.sketch_line_ref else None,
        "fixed_axis": ref.fixed_axis.value if ref.fixed_axis else None,
    }


def _pattern_direction_ref_from_dict(data: dict) -> PatternDirectionRef:
    return PatternDirectionRef(
        edge_ref=_subshape_ref_from_dict(data["edge_ref"]) if data.get("edge_ref") else None,
        sketch_line_ref=_sketch_entity_ref_from_dict(data["sketch_line_ref"])
        if data.get("sketch_line_ref")
        else None,
        fixed_axis=FixedAxis(data["fixed_axis"]) if data.get("fixed_axis") else None,
    )


def _pattern_axis_ref_to_dict(ref: PatternAxisRef) -> dict:
    return {
        "edge_ref": _subshape_ref_to_dict(ref.edge_ref) if ref.edge_ref else None,
        "face_ref": _subshape_ref_to_dict(ref.face_ref) if ref.face_ref else None,
        "sketch_line_ref": _sketch_entity_ref_to_dict(ref.sketch_line_ref) if ref.sketch_line_ref else None,
    }


def _pattern_axis_ref_from_dict(data: dict) -> PatternAxisRef:
    return PatternAxisRef(
        edge_ref=_subshape_ref_from_dict(data["edge_ref"]) if data.get("edge_ref") else None,
        face_ref=_subshape_ref_from_dict(data["face_ref"]) if data.get("face_ref") else None,
        sketch_line_ref=_sketch_entity_ref_from_dict(data["sketch_line_ref"])
        if data.get("sketch_line_ref")
        else None,
    )


# --- Features --------------------------------------------------------------


def _feature_to_dict(feature: Feature) -> dict:
    if isinstance(feature, SketchFeature):
        return {
            "type": "sketch",
            "id": feature.id,
            "sketch_id": feature.sketch_id,
            "plane_feature_id": feature.plane_feature_id,
        }
    if isinstance(feature, ExtrudeFeature):
        return {
            "type": "extrude",
            "id": feature.id,
            "sketch_feature_id": feature.sketch_feature_id,
            "extrude_type": feature.extrude_type.value,
            "start_distance": feature.start_distance,
            "end_distance": feature.end_distance,
            "target_body_ids": list(feature.target_body_ids),
            "profile_refs": [_sketch_entity_ref_to_dict(r) for r in feature.profile_refs],
        }
    if isinstance(feature, CreatePlaneFeature):
        return {
            "type": "create_plane",
            "id": feature.id,
            "plane_type": feature.plane_type.value,
            "face_refs": [_plane_ref_to_dict(r) for r in feature.face_refs],
            "offset": feature.offset,
            "line_ref": _sketch_entity_ref_to_dict(feature.line_ref) if feature.line_ref else None,
            "point_ref": _sketch_entity_ref_to_dict(feature.point_ref) if feature.point_ref else None,
            "edge_ref": _subshape_ref_to_dict(feature.edge_ref) if feature.edge_ref else None,
            "vertex_ref": _subshape_ref_to_dict(feature.vertex_ref) if feature.vertex_ref else None,
            "point_refs": [_point_ref_to_dict(r) for r in feature.point_refs],
        }
    if isinstance(feature, FilletFeature):
        return {
            "type": "fillet",
            "id": feature.id,
            "edge_refs": [_subshape_ref_to_dict(r) for r in feature.edge_refs],
            "radius": feature.radius,
        }
    if isinstance(feature, ChamferFeature):
        return {
            "type": "chamfer",
            "id": feature.id,
            "edge_refs": [_subshape_ref_to_dict(r) for r in feature.edge_refs],
            "distance": feature.distance,
        }
    if isinstance(feature, RevolveFeature):
        return {
            "type": "revolve",
            "id": feature.id,
            "sketch_feature_id": feature.sketch_feature_id,
            "axis_ref": _sketch_entity_ref_to_dict(feature.axis_ref),
            "angle": feature.angle,
            "mode": feature.mode.value,
            "target_body_ids": list(feature.target_body_ids),
            "profile_refs": [_sketch_entity_ref_to_dict(r) for r in feature.profile_refs],
        }
    if isinstance(feature, SweepFeature):
        return {
            "type": "sweep",
            "id": feature.id,
            "sketch_feature_id": feature.sketch_feature_id,
            "path_refs": [_sketch_entity_ref_to_dict(r) for r in feature.path_refs],
            "mode": feature.mode.value,
            "target_body_ids": list(feature.target_body_ids),
            "profile_refs": [_sketch_entity_ref_to_dict(r) for r in feature.profile_refs],
        }
    if isinstance(feature, ImportFeature):
        return {
            "type": "import",
            "id": feature.id,
            "source_format": feature.source_format.value,
            # The Feature's own true source of truth (see its docstring) -
            # base64 inside JSON, same as the create payload over HTTP.
            "source_data_base64": base64.b64encode(feature.source_data).decode("ascii"),
        }
    if isinstance(feature, MirrorFeature):
        return {
            "type": "mirror",
            "id": feature.id,
            "source_body_ids": list(feature.source_body_ids),
            "mirror_plane": _plane_ref_to_dict(feature.mirror_plane),
            "source_feature_ids": list(feature.source_feature_ids),
            "merge": feature.merge.value,
            # Phase 8 (`docs/pattern-mirror-scope.md` §2.11/§4): the third,
            # mutually-exclusive seed-picking mode - `None` for every
            # Mirror persisted before this field existed, or one using the
            # ordinary source_body_ids/source_feature_ids path.
            "tool_feature_id": feature.tool_feature_id,
        }
    if isinstance(feature, PatternFeature):
        return {
            "type": "pattern",
            "id": feature.id,
            "source_body_ids": list(feature.source_body_ids),
            "source_feature_ids": list(feature.source_feature_ids),
            "pattern_type": feature.pattern_type.value,
            "direction_1": _pattern_direction_ref_to_dict(feature.direction_1)
            if feature.direction_1
            else None,
            "count_1": feature.count_1,
            "spacing_1": feature.spacing_1,
            "reverse_1": feature.reverse_1,
            "direction_2": _pattern_direction_ref_to_dict(feature.direction_2)
            if feature.direction_2
            else None,
            "count_2": feature.count_2,
            "spacing_2": feature.spacing_2,
            "reverse_2": feature.reverse_2,
            "axis": _pattern_axis_ref_to_dict(feature.axis) if feature.axis else None,
            "count_angular": feature.count_angular,
            "angle_total": feature.angle_total,
            "reverse_angular": feature.reverse_angular,
            "skip_indices": list(feature.skip_indices),
            "merge": feature.merge.value,
            # Phase 8: mirrors MirrorFeature's own identical field above.
            "tool_feature_id": feature.tool_feature_id,
        }
    if isinstance(feature, GearFeature):
        return {
            "type": "gear",
            "id": feature.id,
            "plane_ref": _plane_ref_to_dict(feature.plane_ref),
            "gear_type": feature.gear_type.value,
            "is_internal": feature.is_internal,
            "module": feature.module,
            "tooth_count": feature.tooth_count,
            "face_width": feature.face_width,
            "pressure_angle_degrees": feature.pressure_angle_degrees,
            "profile_shift": feature.profile_shift,
            "backlash": feature.backlash,
            "root_fillet_radius": feature.root_fillet_radius,
            "outer_diameter": feature.outer_diameter,
            "target_body_ids": list(feature.target_body_ids),
            # Workstream 4a: default 0.0/False for every gear persisted
            # before these two fields existed.
            "helix_angle_degrees": feature.helix_angle_degrees,
            "herringbone": feature.herringbone,
        }
    if isinstance(feature, RackFeature):
        return {
            "type": "rack",
            "id": feature.id,
            "plane_ref": _plane_ref_to_dict(feature.plane_ref),
            "rack_type": feature.rack_type.value,
            "module": feature.module,
            "tooth_count": feature.tooth_count,
            "face_width": feature.face_width,
            "pressure_angle_degrees": feature.pressure_angle_degrees,
            "backlash": feature.backlash,
            "backing_height": feature.backing_height,
            "target_body_ids": list(feature.target_body_ids),
        }
    if isinstance(feature, BevelGearFeature):
        return {
            "type": "bevel_gear",
            "id": feature.id,
            "plane_ref": _plane_ref_to_dict(feature.plane_ref),
            "bevel_type": feature.bevel_type.value,
            "module": feature.module,
            "tooth_count": feature.tooth_count,
            "face_width": feature.face_width,
            "pitch_cone_angle_degrees": feature.pitch_cone_angle_degrees,
            "pressure_angle_degrees": feature.pressure_angle_degrees,
            "backlash": feature.backlash,
            "profile_shift": feature.profile_shift,
            "target_body_ids": list(feature.target_body_ids),
        }
    if isinstance(feature, LoftFeature):
        return {
            "type": "loft",
            "id": feature.id,
            "sections": [_loft_section_to_dict(section) for section in feature.sections],
            "mode": feature.mode.value,
            "ruled": feature.ruled,
            "target_body_ids": list(feature.target_body_ids),
        }
    if isinstance(feature, GearChainFeature):
        return {
            "type": "gear_chain",
            "id": feature.id,
            "plane_ref": _plane_ref_to_dict(feature.plane_ref),
            "groups": [_gear_group_to_dict(g) for g in feature.groups],
            "stages": [_gear_chain_stage_to_dict(s) for s in feature.stages],
            "start_direction_degrees": feature.start_direction_degrees,
            "print_clearance_margin": feature.print_clearance_margin,
        }
    if isinstance(feature, PlanetaryGearFeature):
        return {
            "type": "planetary_gear",
            "id": feature.id,
            "plane_ref": _plane_ref_to_dict(feature.plane_ref),
            "module": feature.module,
            "sun_tooth_count": feature.sun_tooth_count,
            "ring_tooth_count": feature.ring_tooth_count,
            "planet_count": feature.planet_count,
            "face_width": feature.face_width,
            "ring_outer_diameter": feature.ring_outer_diameter,
            "pressure_angle_degrees": feature.pressure_angle_degrees,
        }
    raise NativeFormatError(f"No native export mapping for feature type: {feature.type!r}")


def _feature_from_dict(data: dict) -> Feature:
    feature_type = _require(data, "type")
    feature_id = _require(data, "id")
    if feature_type == "sketch":
        return SketchFeature(
            id=feature_id,
            sketch_id=_require(data, "sketch_id"),
            plane_feature_id=data.get("plane_feature_id"),
        )
    if feature_type == "extrude":
        return ExtrudeFeature(
            id=feature_id,
            sketch_feature_id=_require(data, "sketch_feature_id"),
            extrude_type=ExtrudeType(_require(data, "extrude_type")),
            start_distance=_require(data, "start_distance"),
            end_distance=_require(data, "end_distance"),
            target_body_ids=list(data.get("target_body_ids", [])),
            profile_refs=[_sketch_entity_ref_from_dict(r) for r in data.get("profile_refs", [])],
        )
    if feature_type == "create_plane":
        return CreatePlaneFeature(
            id=feature_id,
            plane_type=PlaneType(_require(data, "plane_type")),
            face_refs=[_plane_ref_from_dict(r) for r in data.get("face_refs", [])],
            offset=data.get("offset"),
            line_ref=_sketch_entity_ref_from_dict(data["line_ref"]) if data.get("line_ref") else None,
            point_ref=_sketch_entity_ref_from_dict(data["point_ref"]) if data.get("point_ref") else None,
            edge_ref=_subshape_ref_from_dict(data["edge_ref"]) if data.get("edge_ref") else None,
            vertex_ref=_subshape_ref_from_dict(data["vertex_ref"]) if data.get("vertex_ref") else None,
            point_refs=[_point_ref_from_dict(r) for r in data.get("point_refs", [])],
        )
    if feature_type == "fillet":
        return FilletFeature(
            id=feature_id,
            edge_refs=[_subshape_ref_from_dict(r) for r in data.get("edge_refs", [])],
            radius=data.get("radius", 0.0),
        )
    if feature_type == "chamfer":
        return ChamferFeature(
            id=feature_id,
            edge_refs=[_subshape_ref_from_dict(r) for r in data.get("edge_refs", [])],
            distance=data.get("distance", 0.0),
        )
    if feature_type == "revolve":
        return RevolveFeature(
            id=feature_id,
            sketch_feature_id=_require(data, "sketch_feature_id"),
            axis_ref=_sketch_entity_ref_from_dict(_require(data, "axis_ref")),
            angle=_require(data, "angle"),
            mode=RevolveMode(_require(data, "mode")),
            target_body_ids=list(data.get("target_body_ids", [])),
            profile_refs=[_sketch_entity_ref_from_dict(r) for r in data.get("profile_refs", [])],
        )
    if feature_type == "sweep":
        return SweepFeature(
            id=feature_id,
            sketch_feature_id=_require(data, "sketch_feature_id"),
            path_refs=[_sketch_entity_ref_from_dict(r) for r in data.get("path_refs", [])],
            mode=SweepMode(_require(data, "mode")),
            target_body_ids=list(data.get("target_body_ids", [])),
            profile_refs=[_sketch_entity_ref_from_dict(r) for r in data.get("profile_refs", [])],
        )
    if feature_type == "import":
        try:
            source_data = base64.b64decode(_require(data, "source_data_base64"), validate=True)
        except (ValueError, TypeError) as exc:
            raise NativeFormatError(f"Malformed import feature source_data_base64: {exc}") from exc
        return ImportFeature(
            id=feature_id,
            source_format=ImportSourceFormat(_require(data, "source_format")),
            source_data=source_data,
        )
    if feature_type == "mirror":
        return MirrorFeature(
            id=feature_id,
            source_body_ids=list(data.get("source_body_ids", [])),
            mirror_plane=_plane_ref_from_dict(_require(data, "mirror_plane")),
            source_feature_ids=list(data.get("source_feature_ids", [])),
            # `merge` (Phase 5) defaults to KEEP_SEPARATE for any Mirror
            # persisted before this field existed (Phase 1-4).
            merge=MergeMode(data.get("merge", MergeMode.KEEP_SEPARATE.value)),
            # `tool_feature_id` (Phase 8) defaults to None for any Mirror
            # persisted before this field existed.
            tool_feature_id=data.get("tool_feature_id"),
        )
    if feature_type == "pattern":
        return PatternFeature(
            id=feature_id,
            source_body_ids=list(data.get("source_body_ids", [])),
            # `source_feature_ids` (Phase 6) defaults to empty for any
            # Pattern persisted before this field existed (Phase 2-5).
            source_feature_ids=list(data.get("source_feature_ids", [])),
            # `pattern_type` (Phase 4) defaults to RECTANGULAR for any
            # Pattern persisted before this field existed (Phase 2) - see
            # `PatternType`'s own docstring.
            pattern_type=PatternType(data.get("pattern_type", PatternType.RECTANGULAR.value)),
            direction_1=_pattern_direction_ref_from_dict(data["direction_1"])
            if data.get("direction_1")
            else None,
            count_1=data.get("count_1", 1),
            spacing_1=data.get("spacing_1", 0.0),
            reverse_1=data.get("reverse_1", False),
            direction_2=_pattern_direction_ref_from_dict(data["direction_2"])
            if data.get("direction_2")
            else None,
            count_2=data.get("count_2", 1),
            spacing_2=data.get("spacing_2", 0.0),
            reverse_2=data.get("reverse_2", False),
            axis=_pattern_axis_ref_from_dict(data["axis"]) if data.get("axis") else None,
            count_angular=data.get("count_angular", 1),
            angle_total=data.get("angle_total", 360.0),
            reverse_angular=data.get("reverse_angular", False),
            # `skip_indices` (Phase 3) defaults to empty for any Pattern
            # persisted before this field existed (Phase 2/4).
            skip_indices=list(data.get("skip_indices", [])),
            # `merge` (Phase 5) defaults to KEEP_SEPARATE for any Pattern
            # persisted before this field existed (Phase 2-4).
            merge=MergeMode(data.get("merge", MergeMode.KEEP_SEPARATE.value)),
            # `tool_feature_id` (Phase 8) defaults to None for any Pattern
            # persisted before this field existed.
            tool_feature_id=data.get("tool_feature_id"),
        )
    if feature_type == "gear":
        return GearFeature(
            id=feature_id,
            plane_ref=_plane_ref_from_dict(_require(data, "plane_ref")),
            gear_type=GearType(_require(data, "gear_type")),
            is_internal=_require(data, "is_internal"),
            module=_require(data, "module"),
            tooth_count=_require(data, "tooth_count"),
            face_width=_require(data, "face_width"),
            pressure_angle_degrees=data.get("pressure_angle_degrees", 20.0),
            profile_shift=data.get("profile_shift", 0.0),
            backlash=data.get("backlash", 0.0),
            root_fillet_radius=data.get("root_fillet_radius", 0.0),
            outer_diameter=data.get("outer_diameter"),
            target_body_ids=list(data.get("target_body_ids", [])),
            # Workstream 4a: default 0.0/False for any GearFeature persisted
            # before these two fields existed - byte-identical straight-tooth
            # behaviour, per that field's own docstring.
            helix_angle_degrees=data.get("helix_angle_degrees", 0.0),
            herringbone=data.get("herringbone", False),
        )
    if feature_type == "rack":
        return RackFeature(
            id=feature_id,
            plane_ref=_plane_ref_from_dict(_require(data, "plane_ref")),
            rack_type=RackType(_require(data, "rack_type")),
            module=_require(data, "module"),
            tooth_count=_require(data, "tooth_count"),
            face_width=_require(data, "face_width"),
            pressure_angle_degrees=data.get("pressure_angle_degrees", 20.0),
            backlash=data.get("backlash", 0.0),
            backing_height=data.get("backing_height"),
            target_body_ids=list(data.get("target_body_ids", [])),
        )
    if feature_type == "bevel_gear":
        return BevelGearFeature(
            id=feature_id,
            plane_ref=_plane_ref_from_dict(_require(data, "plane_ref")),
            bevel_type=BevelGearType(_require(data, "bevel_type")),
            module=_require(data, "module"),
            tooth_count=_require(data, "tooth_count"),
            face_width=_require(data, "face_width"),
            pitch_cone_angle_degrees=_require(data, "pitch_cone_angle_degrees"),
            pressure_angle_degrees=data.get("pressure_angle_degrees", 20.0),
            backlash=data.get("backlash", 0.0),
            profile_shift=data.get("profile_shift", 0.0),
            target_body_ids=list(data.get("target_body_ids", [])),
        )
    if feature_type == "loft":
        return LoftFeature(
            id=feature_id,
            sections=[_loft_section_from_dict(s) for s in data.get("sections", [])],
            mode=LoftMode(_require(data, "mode")),
            ruled=data.get("ruled", False),
            target_body_ids=list(data.get("target_body_ids", [])),
        )
    if feature_type == "gear_chain":
        return GearChainFeature(
            id=feature_id,
            plane_ref=_plane_ref_from_dict(_require(data, "plane_ref")),
            groups=[_gear_group_from_dict(g) for g in data.get("groups", [])],
            stages=[_gear_chain_stage_from_dict(s) for s in data.get("stages", [])],
            start_direction_degrees=data.get("start_direction_degrees", 0.0),
            print_clearance_margin=data.get("print_clearance_margin", 0.2),
        )
    if feature_type == "planetary_gear":
        return PlanetaryGearFeature(
            id=feature_id,
            plane_ref=_plane_ref_from_dict(_require(data, "plane_ref")),
            module=_require(data, "module"),
            sun_tooth_count=_require(data, "sun_tooth_count"),
            ring_tooth_count=_require(data, "ring_tooth_count"),
            planet_count=_require(data, "planet_count"),
            face_width=_require(data, "face_width"),
            ring_outer_diameter=_require(data, "ring_outer_diameter"),
            pressure_angle_degrees=data.get("pressure_angle_degrees", 20.0),
        )
    raise NativeFormatError(f"Unknown native feature type: {feature_type!r}")


# --- Part / Document ---------------------------------------------------------


def _part_to_dict(part: Part) -> dict:
    return {
        "id": part.id,
        "name": part.name,
        "features": [_feature_to_dict(f) for f in part.features],
    }


def _part_from_dict(data: dict) -> Part:
    part = Part(id=_require(data, "id"), name=_require(data, "name"))
    part.features = [_feature_from_dict(f) for f in data.get("features", [])]
    return part


def export_native(document: Document, sketches: dict[str, Sketch]) -> dict:
    """Serializes `document` (every Part's ordered Feature list) plus every
    Sketch referenced by any SketchFeature across any Part, into a plain
    JSON-serializable dict - no cached mesh/geometry, no API-only fields
    (`locked`/`produces`/resolved plane geometry), matching the locked-in
    "pure parametric tree" scope. `sketches` is the full sketch store (see
    `app.sketch.store.all_sketches`) - only the ids actually referenced are
    included, sorted for a deterministic, diff-friendly output."""
    referenced_sketch_ids: set[str] = {
        feature.sketch_id
        for part in document.parts.values()
        for feature in part.features
        if isinstance(feature, SketchFeature)
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "document": {
            "id": document.id,
            "parts": [_part_to_dict(part) for part in document.parts.values()],
        },
        "sketches": [
            sketch_to_dict(sketches[sketch_id])
            for sketch_id in sorted(referenced_sketch_ids)
            if sketch_id in sketches
        ],
    }


def import_native(data: dict) -> tuple[Document, dict[str, Sketch]]:
    """The inverse of `export_native`: parses a native file's dict back into
    a fresh `Document` and its own standalone `sketches` dict - neither is
    written into this process's live stores here, that's the caller's own
    (`app.document.router`) explicit "full replace" step, mirroring
    `export_native` reading from the live stores rather than writing to
    them. Raises `NativeFormatError` for anything malformed; never partially
    populates its return value on failure."""
    if not isinstance(data, dict):
        raise NativeFormatError("Native file must be a JSON object")
    schema_version = data.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise NativeFormatError(f"Unsupported native file schema_version: {schema_version!r}")

    sketches: dict[str, Sketch] = {}
    for sketch_data in data.get("sketches", []):
        sketch = sketch_from_dict(sketch_data)
        sketches[sketch.id] = sketch

    document_data = _require(data, "document")
    document = Document(id=_require(document_data, "id"))
    for part_data in document_data.get("parts", []):
        part = _part_from_dict(part_data)
        document.parts[part.id] = part

    return document, sketches
