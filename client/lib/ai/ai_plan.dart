/// AI Modelling workstream 2's Dart mirror of workstream 3's locked
/// structured-plan schema (`backend/app/document/ai_plan_schemas.py`, the
/// real source of truth - see `docs/ai-modelling/03-structured-plan-
/// schema.md` for the summary this file implements). Same relationship
/// `document_api_client.dart`'s DTOs already have to
/// `backend/app/document/schemas.py`: field names and `kind` discriminator
/// strings mirror the Python models exactly (snake_case on the wire,
/// camelCase in Dart), but this file only needs to *parse and display* a
/// plan (workstream 2's Review & Generate summary), not fully validate it -
/// that's workstream 5's job, already built server-side. Deliberately does
/// **not** duplicate the reference-kind-checking rules from
/// `03-structured-plan-schema.md`'s "Reference kind-checking (locked schema
/// rule)" section - those stay server-side only.
///
/// **Maintenance note** (mirrors `02-scoping-conversation.md`'s own note for
/// the system prompt): if a future session adds a field to an existing step
/// `kind` in `ai_plan_schemas.py`, this file needs a matching manual update
/// or parsing/display will silently ignore the new field.
library;

int _asInt(dynamic v) => (v as num).toInt();

double _asDouble(dynamic v) => (v as num).toDouble();

double? _asDoubleOrNull(dynamic v) => v == null ? null : (v as num).toDouble();

List<String> _asStringList(dynamic v) => v == null ? const [] : (v as List).map((e) => e as String).toList();

List<int> _asIntList(dynamic v) => v == null ? const [] : (v as List).map((e) => _asInt(e)).toList();

/// `app.sketch.models.Plane` - the three fixed reference planes, mirrored
/// exactly (`SketchStep.plane`, `MirrorPlaneStep.fixed_plane`).
enum AiFixedPlane {
  xy('XY'),
  xz('XZ'),
  yz('YZ');

  final String wireValue;
  const AiFixedPlane(this.wireValue);

  static AiFixedPlane fromWire(String value) =>
      AiFixedPlane.values.firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown Plane: $value'));
}

/// `app.document.models.ExtrudeType` - `ExtrudeStep.extrude_type`.
enum AiExtrudeType {
  boss('boss'),
  cut('cut');

  final String wireValue;
  const AiExtrudeType(this.wireValue);

  static AiExtrudeType fromWire(String value) => AiExtrudeType.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown ExtrudeType: $value'));
}

/// `app.document.models.RevolveMode` - `RevolveStep.mode`. A separate enum
/// from [AiExtrudeType] even though the wire values are identical
/// (`"boss"`/`"cut"`), mirroring the backend's own "each Feature type owns
/// its own enum" convention (`RevolveMode`'s docstring).
enum AiRevolveMode {
  boss('boss'),
  cut('cut');

  final String wireValue;
  const AiRevolveMode(this.wireValue);

  static AiRevolveMode fromWire(String value) => AiRevolveMode.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown RevolveMode: $value'));
}

/// `app.document.models.SweepMode` - `SweepStep.mode`. Same "own enum"
/// reasoning as [AiRevolveMode].
enum AiSweepMode {
  boss('boss'),
  cut('cut');

  final String wireValue;
  const AiSweepMode(this.wireValue);

  static AiSweepMode fromWire(String value) =>
      AiSweepMode.values.firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown SweepMode: $value'));
}

/// `app.document.models.MergeMode` - `PatternStep.merge`/`MirrorStep.merge`.
enum AiMergeMode {
  keepSeparate('keep_separate'),
  fuseIntoOne('fuse_into_one');

  final String wireValue;
  const AiMergeMode(this.wireValue);

  static AiMergeMode fromWire(String value) =>
      AiMergeMode.values.firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown MergeMode: $value'));
}

/// `app.document.models.FixedAxis` - `PatternDirectionStep.fixed_axis`
/// (`PatternAxisStep` has no `fixed_axis` field - see its own doc comment).
enum AiFixedAxis {
  x('x'),
  y('y'),
  z('z');

  final String wireValue;
  const AiFixedAxis(this.wireValue);

  static AiFixedAxis fromWire(String value) =>
      AiFixedAxis.values.firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown FixedAxis: $value'));
}

/// `app.document.models.PatternType` - `PatternStep.pattern_type`.
enum AiPatternType {
  rectangular('rectangular'),
  circular('circular');

  final String wireValue;
  const AiPatternType(this.wireValue);

  static AiPatternType fromWire(String value) => AiPatternType.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown PatternType: $value'));
}

/// `CreatePlaneStep.plane_type` - only the two `PlaneType` values the locked
/// schema allows in a plan (`Literal[PlaneType.NORMAL_TO_LINE_AT_POINT,
/// PlaneType.THREE_POINTS]`), not the full six-value backend `PlaneType`
/// enum - mirrors the *plan schema's* own restriction, not the backend
/// Feature schema's broader one.
enum AiCreatePlaneType {
  normalToLineAtPoint('normal_to_line_at_point'),
  threePoints('three_points');

  final String wireValue;
  const AiCreatePlaneType(this.wireValue);

  static AiCreatePlaneType fromWire(String value) => AiCreatePlaneType.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown CreatePlaneType: $value'));
}

/// `EdgeSelectorKind` (`ai_plan_schemas.py`) - the four deterministic
/// Fillet/Chamfer edge-selector heuristics, resolved server-side against
/// real Body topology (`app.document.ai_plan_edges`), never client-side.
enum AiEdgeSelectorKind {
  topFaceEdges('top_face_edges'),
  bottomFaceEdges('bottom_face_edges'),
  verticalEdges('vertical_edges'),
  allEdgesOfFaceAtPosition('all_edges_of_face_at_position');

  final String wireValue;
  const AiEdgeSelectorKind(this.wireValue);

  static AiEdgeSelectorKind fromWire(String value) => AiEdgeSelectorKind.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown EdgeSelectorKind: $value'));
}

/// `CardinalDirection` (`ai_plan_schemas.py`) - always a world/global axis,
/// per that enum's own v1-limitation note.
enum AiCardinalDirection {
  plusX('+x'),
  minusX('-x'),
  plusY('+y'),
  minusY('-y'),
  plusZ('+z'),
  minusZ('-z');

  final String wireValue;
  const AiCardinalDirection(this.wireValue);

  static AiCardinalDirection fromWire(String value) => AiCardinalDirection.values
      .firstWhere((e) => e.wireValue == value, orElse: () => throw FormatException('Unknown CardinalDirection: $value'));
}

/// `EdgeSelector` (`ai_plan_schemas.py`) - `FilletStep.edges`/`ChamferStep.edges`.
class AiEdgeSelector {
  final AiEdgeSelectorKind selector;
  final String of;
  final AiCardinalDirection? direction;

  const AiEdgeSelector({required this.selector, required this.of, this.direction});

  factory AiEdgeSelector.fromJson(Map<String, dynamic> json) => AiEdgeSelector(
        selector: AiEdgeSelectorKind.fromWire(json['selector'] as String),
        of: json['of'] as String,
        direction: json['direction'] == null ? null : AiCardinalDirection.fromWire(json['direction'] as String),
      );

  Map<String, dynamic> toJson() => {
        'selector': selector.wireValue,
        'of': of,
        if (direction != null) 'direction': direction!.wireValue,
      };
}

/// `PatternDirectionStep` (`ai_plan_schemas.py`) - `PatternStep.direction_1`/
/// `direction_2`. Exactly one of [fixedAxis]/[sketchLineRef] should be set
/// (a server-side rule, not enforced here - permissive parsing per this
/// file's own doc comment).
class AiPatternDirectionStep {
  final AiFixedAxis? fixedAxis;
  final String? sketchLineRef;

  const AiPatternDirectionStep({this.fixedAxis, this.sketchLineRef});

  factory AiPatternDirectionStep.fromJson(Map<String, dynamic> json) => AiPatternDirectionStep(
        fixedAxis: json['fixed_axis'] == null ? null : AiFixedAxis.fromWire(json['fixed_axis'] as String),
        sketchLineRef: json['sketch_line_ref'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (fixedAxis != null) 'fixed_axis': fixedAxis!.wireValue,
        if (sketchLineRef != null) 'sketch_line_ref': sketchLineRef,
      };
}

/// `PatternAxisStep` (`ai_plan_schemas.py`) - `PatternStep.axis`. Unlike
/// [AiPatternDirectionStep], no `fixedAxis` option - bug found while
/// implementing workstream 4: `PatternAxisRef` (the real backend type this
/// mirrors) resolves to a full world-space axis (an origin point *and* a
/// direction, since a Circular Pattern rotates around a real pivot, not
/// just along a direction) and has no `fixed_axis` field at all, unlike
/// `PatternDirectionRef`'s plain direction. [sketchLineRef] is the only
/// plan-authorable option as a result.
class AiPatternAxisStep {
  final String sketchLineRef;

  const AiPatternAxisStep({required this.sketchLineRef});

  factory AiPatternAxisStep.fromJson(Map<String, dynamic> json) => AiPatternAxisStep(
        sketchLineRef: json['sketch_line_ref'] as String,
      );

  Map<String, dynamic> toJson() => {'sketch_line_ref': sketchLineRef};
}

/// `MirrorPlaneStep` (`ai_plan_schemas.py`) - `MirrorStep.mirror_plane`.
class AiMirrorPlaneStep {
  final AiFixedPlane? fixedPlane;
  final String? planeFeatureId;

  const AiMirrorPlaneStep({this.fixedPlane, this.planeFeatureId});

  factory AiMirrorPlaneStep.fromJson(Map<String, dynamic> json) => AiMirrorPlaneStep(
        fixedPlane: json['fixed_plane'] == null ? null : AiFixedPlane.fromWire(json['fixed_plane'] as String),
        planeFeatureId: json['plane_feature_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (fixedPlane != null) 'fixed_plane': fixedPlane!.wireValue,
        if (planeFeatureId != null) 'plane_feature_id': planeFeatureId,
      };
}

/// One step of an [AiGenerationPlan] - every concrete subtype below mirrors
/// one Pydantic model in `ai_plan_schemas.py` field-for-field. [localId] is
/// plan-local only (never a real backend id - see that file's own module
/// docstring); [kind] is the discriminator string.
sealed class AiPlanStep {
  final String localId;
  final String kind;

  const AiPlanStep({required this.localId, required this.kind});

  Map<String, dynamic> toJson();

  static AiPlanStep fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String?;
    switch (kind) {
      case 'sketch':
        return AiSketchStep.fromJson(json);
      case 'sketch_point':
        return AiSketchPointStep.fromJson(json);
      case 'sketch_line':
        return AiSketchLineStep.fromJson(json);
      case 'sketch_circle':
        return AiSketchCircleStep.fromJson(json);
      case 'sketch_arc':
        return AiSketchArcStep.fromJson(json);
      case 'sketch_ellipse':
        return AiSketchEllipseStep.fromJson(json);
      case 'sketch_polygon':
        return AiSketchPolygonStep.fromJson(json);
      case 'sketch_slot':
        return AiSketchSlotStep.fromJson(json);
      case 'sketch_rectangle':
        return AiSketchRectangleStep.fromJson(json);
      case 'extrude':
        return AiExtrudeStep.fromJson(json);
      case 'revolve':
        return AiRevolveStep.fromJson(json);
      case 'sweep':
        return AiSweepStep.fromJson(json);
      case 'fillet':
        return AiFilletStep.fromJson(json);
      case 'chamfer':
        return AiChamferStep.fromJson(json);
      case 'pattern':
        return AiPatternStep.fromJson(json);
      case 'mirror':
        return AiMirrorStep.fromJson(json);
      case 'create_plane':
        return AiCreatePlaneStep.fromJson(json);
      case 'gear_request':
        return AiGearRequestStep.fromJson(json);
      default:
        throw FormatException('Unknown plan step kind: $kind');
    }
  }
}

/// `SketchStep` - creates the SketchFeature + Sketch a following
/// `sketch_point`/etc. step attaches to via [AiSketchStep.localId].
class AiSketchStep extends AiPlanStep {
  final AiFixedPlane? plane;
  final String? planeFeatureId;

  const AiSketchStep({required super.localId, this.plane, this.planeFeatureId}) : super(kind: 'sketch');

  factory AiSketchStep.fromJson(Map<String, dynamic> json) => AiSketchStep(
        localId: json['local_id'] as String,
        plane: json['plane'] == null ? null : AiFixedPlane.fromWire(json['plane'] as String),
        planeFeatureId: json['plane_feature_id'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        if (plane != null) 'plane': plane!.wireValue,
        if (planeFeatureId != null) 'plane_feature_id': planeFeatureId,
      };
}

class AiSketchPointStep extends AiPlanStep {
  final String sketchFeatureId;
  final double x;
  final double y;

  const AiSketchPointStep({required super.localId, required this.sketchFeatureId, required this.x, required this.y})
      : super(kind: 'sketch_point');

  factory AiSketchPointStep.fromJson(Map<String, dynamic> json) => AiSketchPointStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        x: _asDouble(json['x']),
        y: _asDouble(json['y']),
      );

  @override
  Map<String, dynamic> toJson() => {'local_id': localId, 'kind': kind, 'sketch_feature_id': sketchFeatureId, 'x': x, 'y': y};
}

class AiSketchLineStep extends AiPlanStep {
  final String sketchFeatureId;
  final String startPointId;
  final String? endPointId;
  final double? length;
  final double? angle;
  final bool construction;

  const AiSketchLineStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.startPointId,
    this.endPointId,
    this.length,
    this.angle,
    this.construction = false,
  }) : super(kind: 'sketch_line');

  factory AiSketchLineStep.fromJson(Map<String, dynamic> json) => AiSketchLineStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        startPointId: json['start_point_id'] as String,
        endPointId: json['end_point_id'] as String?,
        length: _asDoubleOrNull(json['length']),
        angle: _asDoubleOrNull(json['angle']),
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'start_point_id': startPointId,
        if (endPointId != null) 'end_point_id': endPointId,
        if (length != null) 'length': length,
        if (angle != null) 'angle': angle,
        'construction': construction,
      };
}

class AiSketchCircleStep extends AiPlanStep {
  final String sketchFeatureId;
  final String centerPointId;
  final String? radiusPointId;
  final double? radius;
  final double? angle;
  final bool construction;

  const AiSketchCircleStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.centerPointId,
    this.radiusPointId,
    this.radius,
    this.angle,
    this.construction = false,
  }) : super(kind: 'sketch_circle');

  factory AiSketchCircleStep.fromJson(Map<String, dynamic> json) => AiSketchCircleStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        centerPointId: json['center_point_id'] as String,
        radiusPointId: json['radius_point_id'] as String?,
        radius: _asDoubleOrNull(json['radius']),
        angle: _asDoubleOrNull(json['angle']),
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'center_point_id': centerPointId,
        if (radiusPointId != null) 'radius_point_id': radiusPointId,
        if (radius != null) 'radius': radius,
        if (angle != null) 'angle': angle,
        'construction': construction,
      };
}

class AiSketchArcStep extends AiPlanStep {
  final String sketchFeatureId;
  final String centerPointId;
  final String startPointId;
  final String? endPointId;
  final double? endAngle;
  final bool construction;

  const AiSketchArcStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.centerPointId,
    required this.startPointId,
    this.endPointId,
    this.endAngle,
    this.construction = false,
  }) : super(kind: 'sketch_arc');

  factory AiSketchArcStep.fromJson(Map<String, dynamic> json) => AiSketchArcStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        centerPointId: json['center_point_id'] as String,
        startPointId: json['start_point_id'] as String,
        endPointId: json['end_point_id'] as String?,
        endAngle: _asDoubleOrNull(json['end_angle']),
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'center_point_id': centerPointId,
        'start_point_id': startPointId,
        if (endPointId != null) 'end_point_id': endPointId,
        if (endAngle != null) 'end_angle': endAngle,
        'construction': construction,
      };
}

class AiSketchEllipseStep extends AiPlanStep {
  final String sketchFeatureId;
  final String centerPointId;
  final String? majorPointId;
  final double? majorRadius;
  final double? angle;
  final double minorRadius;
  final bool construction;

  const AiSketchEllipseStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.centerPointId,
    this.majorPointId,
    this.majorRadius,
    this.angle,
    required this.minorRadius,
    this.construction = false,
  }) : super(kind: 'sketch_ellipse');

  factory AiSketchEllipseStep.fromJson(Map<String, dynamic> json) => AiSketchEllipseStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        centerPointId: json['center_point_id'] as String,
        majorPointId: json['major_point_id'] as String?,
        majorRadius: _asDoubleOrNull(json['major_radius']),
        angle: _asDoubleOrNull(json['angle']),
        minorRadius: _asDouble(json['minor_radius']),
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'center_point_id': centerPointId,
        if (majorPointId != null) 'major_point_id': majorPointId,
        if (majorRadius != null) 'major_radius': majorRadius,
        if (angle != null) 'angle': angle,
        'minor_radius': minorRadius,
        'construction': construction,
      };
}

class AiSketchPolygonStep extends AiPlanStep {
  final String sketchFeatureId;
  final String centerPointId;
  final String firstVertexPointId;
  final int sides;
  final bool construction;
  final bool referenceCircles;

  const AiSketchPolygonStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.centerPointId,
    required this.firstVertexPointId,
    required this.sides,
    this.construction = false,
    this.referenceCircles = false,
  }) : super(kind: 'sketch_polygon');

  factory AiSketchPolygonStep.fromJson(Map<String, dynamic> json) => AiSketchPolygonStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        centerPointId: json['center_point_id'] as String,
        firstVertexPointId: json['first_vertex_point_id'] as String,
        sides: _asInt(json['sides']),
        construction: json['construction'] as bool? ?? false,
        referenceCircles: json['reference_circles'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'center_point_id': centerPointId,
        'first_vertex_point_id': firstVertexPointId,
        'sides': sides,
        'construction': construction,
        'reference_circles': referenceCircles,
      };
}

class AiSketchSlotStep extends AiPlanStep {
  final String sketchFeatureId;
  final String center1PointId;
  final String center2PointId;
  final double radius;
  final bool construction;

  const AiSketchSlotStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.center1PointId,
    required this.center2PointId,
    required this.radius,
    this.construction = false,
  }) : super(kind: 'sketch_slot');

  factory AiSketchSlotStep.fromJson(Map<String, dynamic> json) => AiSketchSlotStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        center1PointId: json['center1_point_id'] as String,
        center2PointId: json['center2_point_id'] as String,
        radius: _asDouble(json['radius']),
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'center1_point_id': center1PointId,
        'center2_point_id': center2PointId,
        'radius': radius,
        'construction': construction,
      };
}

/// `SketchRectangleStep` - always 4 `sketch_point` [cornerPointIds], never a
/// `corner`/`width`/`height` shorthand (the original draft schema's mistake,
/// corrected during locking - see `ai_plan_schemas.py`'s own comment on this
/// field).
class AiSketchRectangleStep extends AiPlanStep {
  final String sketchFeatureId;
  final List<String> cornerPointIds;
  final bool axisAligned;
  final bool construction;

  const AiSketchRectangleStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.cornerPointIds,
    this.axisAligned = true,
    this.construction = false,
  }) : super(kind: 'sketch_rectangle');

  factory AiSketchRectangleStep.fromJson(Map<String, dynamic> json) => AiSketchRectangleStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        cornerPointIds: _asStringList(json['corner_point_ids']),
        axisAligned: json['axis_aligned'] as bool? ?? true,
        construction: json['construction'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'corner_point_ids': cornerPointIds,
        'axis_aligned': axisAligned,
        'construction': construction,
      };
}

class AiExtrudeStep extends AiPlanStep {
  final String sketchFeatureId;
  final AiExtrudeType extrudeType;
  final double startDistance;
  final double endDistance;
  final List<String> targetBodyIds;
  final List<String> profileRefs;

  const AiExtrudeStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.extrudeType,
    required this.startDistance,
    required this.endDistance,
    this.targetBodyIds = const [],
    this.profileRefs = const [],
  }) : super(kind: 'extrude');

  factory AiExtrudeStep.fromJson(Map<String, dynamic> json) => AiExtrudeStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        extrudeType: AiExtrudeType.fromWire(json['extrude_type'] as String),
        startDistance: _asDouble(json['start_distance']),
        endDistance: _asDouble(json['end_distance']),
        targetBodyIds: _asStringList(json['target_body_ids']),
        profileRefs: _asStringList(json['profile_refs']),
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'extrude_type': extrudeType.wireValue,
        'start_distance': startDistance,
        'end_distance': endDistance,
        'target_body_ids': targetBodyIds,
        'profile_refs': profileRefs,
      };
}

class AiRevolveStep extends AiPlanStep {
  final String sketchFeatureId;
  final String axisRef;
  final double angle;
  final AiRevolveMode mode;
  final List<String> targetBodyIds;
  final List<String> profileRefs;

  const AiRevolveStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.axisRef,
    required this.angle,
    required this.mode,
    this.targetBodyIds = const [],
    this.profileRefs = const [],
  }) : super(kind: 'revolve');

  factory AiRevolveStep.fromJson(Map<String, dynamic> json) => AiRevolveStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        axisRef: json['axis_ref'] as String,
        angle: _asDouble(json['angle']),
        mode: AiRevolveMode.fromWire(json['mode'] as String),
        targetBodyIds: _asStringList(json['target_body_ids']),
        profileRefs: _asStringList(json['profile_refs']),
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'axis_ref': axisRef,
        'angle': angle,
        'mode': mode.wireValue,
        'target_body_ids': targetBodyIds,
        'profile_refs': profileRefs,
      };
}

class AiSweepStep extends AiPlanStep {
  final String sketchFeatureId;
  final List<String> pathRefs;
  final AiSweepMode mode;
  final List<String> targetBodyIds;
  final List<String> profileRefs;

  const AiSweepStep({
    required super.localId,
    required this.sketchFeatureId,
    required this.pathRefs,
    required this.mode,
    this.targetBodyIds = const [],
    this.profileRefs = const [],
  }) : super(kind: 'sweep');

  factory AiSweepStep.fromJson(Map<String, dynamic> json) => AiSweepStep(
        localId: json['local_id'] as String,
        sketchFeatureId: json['sketch_feature_id'] as String,
        pathRefs: _asStringList(json['path_refs']),
        mode: AiSweepMode.fromWire(json['mode'] as String),
        targetBodyIds: _asStringList(json['target_body_ids']),
        profileRefs: _asStringList(json['profile_refs']),
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'sketch_feature_id': sketchFeatureId,
        'path_refs': pathRefs,
        'mode': mode.wireValue,
        'target_body_ids': targetBodyIds,
        'profile_refs': profileRefs,
      };
}

class AiFilletStep extends AiPlanStep {
  final AiEdgeSelector edges;
  final double radius;

  const AiFilletStep({required super.localId, required this.edges, required this.radius}) : super(kind: 'fillet');

  factory AiFilletStep.fromJson(Map<String, dynamic> json) => AiFilletStep(
        localId: json['local_id'] as String,
        edges: AiEdgeSelector.fromJson(json['edges'] as Map<String, dynamic>),
        radius: _asDouble(json['radius']),
      );

  @override
  Map<String, dynamic> toJson() => {'local_id': localId, 'kind': kind, 'edges': edges.toJson(), 'radius': radius};
}

class AiChamferStep extends AiPlanStep {
  final AiEdgeSelector edges;
  final double distance;

  const AiChamferStep({required super.localId, required this.edges, required this.distance}) : super(kind: 'chamfer');

  factory AiChamferStep.fromJson(Map<String, dynamic> json) => AiChamferStep(
        localId: json['local_id'] as String,
        edges: AiEdgeSelector.fromJson(json['edges'] as Map<String, dynamic>),
        distance: _asDouble(json['distance']),
      );

  @override
  Map<String, dynamic> toJson() => {'local_id': localId, 'kind': kind, 'edges': edges.toJson(), 'distance': distance};
}

class AiPatternStep extends AiPlanStep {
  final List<String> sourceBodyIds;
  final AiPatternType patternType;
  final AiPatternDirectionStep? direction1;
  final int count1;
  final double spacing1;
  final bool reverse1;
  final AiPatternDirectionStep? direction2;
  final int count2;
  final double spacing2;
  final bool reverse2;
  final AiPatternAxisStep? axis;
  final int countAngular;
  final double angleTotal;
  final bool reverseAngular;
  final List<int> skipIndices;
  final AiMergeMode merge;
  final String? toolFeatureId;

  const AiPatternStep({
    required super.localId,
    required this.sourceBodyIds,
    this.patternType = AiPatternType.rectangular,
    this.direction1,
    this.count1 = 1,
    this.spacing1 = 0.0,
    this.reverse1 = false,
    this.direction2,
    this.count2 = 1,
    this.spacing2 = 0.0,
    this.reverse2 = false,
    this.axis,
    this.countAngular = 1,
    this.angleTotal = 360.0,
    this.reverseAngular = false,
    this.skipIndices = const [],
    this.merge = AiMergeMode.keepSeparate,
    this.toolFeatureId,
  }) : super(kind: 'pattern');

  factory AiPatternStep.fromJson(Map<String, dynamic> json) => AiPatternStep(
        localId: json['local_id'] as String,
        sourceBodyIds: _asStringList(json['source_body_ids']),
        patternType: json['pattern_type'] == null ? AiPatternType.rectangular : AiPatternType.fromWire(json['pattern_type'] as String),
        direction1: json['direction_1'] == null ? null : AiPatternDirectionStep.fromJson(json['direction_1'] as Map<String, dynamic>),
        count1: json['count_1'] == null ? 1 : _asInt(json['count_1']),
        spacing1: json['spacing_1'] == null ? 0.0 : _asDouble(json['spacing_1']),
        reverse1: json['reverse_1'] as bool? ?? false,
        direction2: json['direction_2'] == null ? null : AiPatternDirectionStep.fromJson(json['direction_2'] as Map<String, dynamic>),
        count2: json['count_2'] == null ? 1 : _asInt(json['count_2']),
        spacing2: json['spacing_2'] == null ? 0.0 : _asDouble(json['spacing_2']),
        reverse2: json['reverse_2'] as bool? ?? false,
        axis: json['axis'] == null ? null : AiPatternAxisStep.fromJson(json['axis'] as Map<String, dynamic>),
        countAngular: json['count_angular'] == null ? 1 : _asInt(json['count_angular']),
        angleTotal: json['angle_total'] == null ? 360.0 : _asDouble(json['angle_total']),
        reverseAngular: json['reverse_angular'] as bool? ?? false,
        skipIndices: _asIntList(json['skip_indices']),
        merge: json['merge'] == null ? AiMergeMode.keepSeparate : AiMergeMode.fromWire(json['merge'] as String),
        toolFeatureId: json['tool_feature_id'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'source_body_ids': sourceBodyIds,
        'pattern_type': patternType.wireValue,
        if (direction1 != null) 'direction_1': direction1!.toJson(),
        'count_1': count1,
        'spacing_1': spacing1,
        'reverse_1': reverse1,
        if (direction2 != null) 'direction_2': direction2!.toJson(),
        'count_2': count2,
        'spacing_2': spacing2,
        'reverse_2': reverse2,
        if (axis != null) 'axis': axis!.toJson(),
        'count_angular': countAngular,
        'angle_total': angleTotal,
        'reverse_angular': reverseAngular,
        'skip_indices': skipIndices,
        'merge': merge.wireValue,
        if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
      };
}

class AiMirrorStep extends AiPlanStep {
  final List<String> sourceBodyIds;
  final AiMirrorPlaneStep mirrorPlane;
  final AiMergeMode merge;
  final String? toolFeatureId;

  const AiMirrorStep({
    required super.localId,
    required this.sourceBodyIds,
    required this.mirrorPlane,
    this.merge = AiMergeMode.keepSeparate,
    this.toolFeatureId,
  }) : super(kind: 'mirror');

  factory AiMirrorStep.fromJson(Map<String, dynamic> json) => AiMirrorStep(
        localId: json['local_id'] as String,
        sourceBodyIds: _asStringList(json['source_body_ids']),
        mirrorPlane: AiMirrorPlaneStep.fromJson(json['mirror_plane'] as Map<String, dynamic>),
        merge: json['merge'] == null ? AiMergeMode.keepSeparate : AiMergeMode.fromWire(json['merge'] as String),
        toolFeatureId: json['tool_feature_id'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'source_body_ids': sourceBodyIds,
        'mirror_plane': mirrorPlane.toJson(),
        'merge': merge.wireValue,
        if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
      };
}

class AiCreatePlaneStep extends AiPlanStep {
  final AiCreatePlaneType planeType;
  final String? lineRef;
  final String? pointRef;
  final List<String> pointRefs;

  const AiCreatePlaneStep({
    required super.localId,
    required this.planeType,
    this.lineRef,
    this.pointRef,
    this.pointRefs = const [],
  }) : super(kind: 'create_plane');

  factory AiCreatePlaneStep.fromJson(Map<String, dynamic> json) => AiCreatePlaneStep(
        localId: json['local_id'] as String,
        planeType: AiCreatePlaneType.fromWire(json['plane_type'] as String),
        lineRef: json['line_ref'] as String?,
        pointRef: json['point_ref'] as String?,
        pointRefs: _asStringList(json['point_refs']),
      );

  @override
  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'kind': kind,
        'plane_type': planeType.wireValue,
        if (lineRef != null) 'line_ref': lineRef,
        if (pointRef != null) 'point_ref': pointRef,
        'point_refs': pointRefs,
      };
}

/// `GearRequestStep` - routing only (`00-conventions.md`'s "Gear-request
/// routing"). Carries gear parameters opaquely (module, tooth count, etc.)
/// since neither this file nor workstream 5's validator ever inspects them
/// - `ConfigDict(extra="allow")` on the Python side becomes [parameters]
/// here, holding every JSON key except `local_id`/`kind`.
class AiGearRequestStep extends AiPlanStep {
  final Map<String, dynamic> parameters;

  const AiGearRequestStep({required super.localId, this.parameters = const {}}) : super(kind: 'gear_request');

  factory AiGearRequestStep.fromJson(Map<String, dynamic> json) {
    final parameters = Map<String, dynamic>.from(json)
      ..remove('local_id')
      ..remove('kind');
    return AiGearRequestStep(localId: json['local_id'] as String, parameters: parameters);
  }

  @override
  Map<String, dynamic> toJson() => {'local_id': localId, 'kind': kind, ...parameters};
}

/// `PlanValidateRequest`/the wire shape's top-level `{"version": 1, "steps":
/// [...]}` object (`ai_plan_schemas.py`) - the finished structured plan
/// `AiTurnResult.plan` holds once the scoping conversation is complete.
class AiGenerationPlan {
  final int version;
  final List<AiPlanStep> steps;

  const AiGenerationPlan({this.version = 1, required this.steps});

  factory AiGenerationPlan.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      throw const FormatException('Plan has no steps');
    }
    return AiGenerationPlan(
      version: json['version'] == null ? 1 : _asInt(json['version']),
      steps: rawSteps.map((s) => AiPlanStep.fromJson(s as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {'version': version, 'steps': steps.map((s) => s.toJson()).toList()};

  AiPlanStep? stepById(String localId) {
    for (final step in steps) {
      if (step.localId == localId) return step;
    }
    return null;
  }
}
