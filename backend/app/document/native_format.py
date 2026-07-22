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
    ChamferFeature,
    CreatePlaneFeature,
    Document,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FilletFeature,
    ImportFeature,
    ImportSourceFormat,
    Part,
    PlaneRef,
    PlaneType,
    PointRef,
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
            "radius_constraint_id": entity.radius_constraint_id,
            "equal_radius_constraint_ids": entity.equal_radius_constraint_ids,
            "equal_length_constraint_ids": entity.equal_length_constraint_ids,
            "angle_constraint_ids": entity.angle_constraint_ids,
            "sides": entity.sides,
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
            radius_constraint_id=_require(data, "radius_constraint_id"),
            equal_radius_constraint_ids=list(_require(data, "equal_radius_constraint_ids")),
            equal_length_constraint_ids=list(_require(data, "equal_length_constraint_ids")),
            angle_constraint_ids=list(_require(data, "angle_constraint_ids")),
            sides=_require(data, "sides"),
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
