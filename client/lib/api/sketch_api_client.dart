import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Raised for any backend call that fails - unreachable host, timeout, or a
/// non-2xx response - so callers can show one consistent error message
/// rather than handling each failure mode separately.
class ApiException implements Exception {
  final String message;

  ApiException(this.message);

  @override
  String toString() => message;
}

class SketchDto {
  final String id;

  /// C3: null for a Sketch anchored to a custom CreatePlaneFeature via the
  /// Document layer (see the backend's `app.sketch.models.Sketch` docstring)
  /// - always populated for a Sketch created through this standalone
  /// `/sketch` API directly. [SketchController._plane]/[PlaneIndicator]
  /// already tolerate a null plane (no indicator shown), so this needs no
  /// further client-side handling beyond the type becoming nullable here.
  final String? plane;
  final String originPointId;

  SketchDto({required this.id, required this.plane, required this.originPointId});

  factory SketchDto.fromJson(Map<String, dynamic> json) => SketchDto(
        id: json['id'] as String,
        plane: json['plane'] as String?,
        originPointId: json['origin_point_id'] as String,
      );
}

class PointDto {
  final String id;
  final double x;
  final double y;

  PointDto({required this.id, required this.x, required this.y});

  factory PointDto.fromJson(Map<String, dynamic> json) => PointDto(
        id: json['id'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
      );
}

class LineDto {
  final String id;
  final String startPointId;
  final String endPointId;
  final double length;
  final bool construction;

  LineDto({
    required this.id,
    required this.startPointId,
    required this.endPointId,
    required this.length,
    this.construction = false,
  });

  factory LineDto.fromJson(Map<String, dynamic> json) => LineDto(
        id: json['id'] as String,
        startPointId: json['start_point_id'] as String,
        endPointId: json['end_point_id'] as String,
        length: (json['length'] as num).toDouble(),
        construction: json['construction'] as bool? ?? false,
      );
}

class CircleDto {
  final String id;
  final String centerPointId;
  final String radiusPointId;
  final double radius;
  final bool construction;

  CircleDto({
    required this.id,
    required this.centerPointId,
    required this.radiusPointId,
    required this.radius,
    this.construction = false,
  });

  factory CircleDto.fromJson(Map<String, dynamic> json) => CircleDto(
        id: json['id'] as String,
        centerPointId: json['center_point_id'] as String,
        radiusPointId: json['radius_point_id'] as String,
        radius: (json['radius'] as num).toDouble(),
        construction: json['construction'] as bool? ?? false,
      );
}

class ArcDto {
  final String id;
  final String centerPointId;
  final String startPointId;
  final String endPointId;
  final double radius;
  final bool construction;

  ArcDto({
    required this.id,
    required this.centerPointId,
    required this.startPointId,
    required this.endPointId,
    required this.radius,
    this.construction = false,
  });

  factory ArcDto.fromJson(Map<String, dynamic> json) => ArcDto(
        id: json['id'] as String,
        centerPointId: json['center_point_id'] as String,
        startPointId: json['start_point_id'] as String,
        endPointId: json['end_point_id'] as String,
        radius: (json['radius'] as num).toDouble(),
        construction: json['construction'] as bool? ?? false,
      );
}

class EllipseDto {
  final String id;
  final String centerPointId;
  final String majorPointId;
  final String majorPointNegId;
  final String minorPointId;
  final String minorPointNegId;
  final String majorAxisLineId;
  final String minorAxisLineId;
  final double majorRadius;
  final double minorRadius;
  final double rotation;
  final bool construction;

  EllipseDto({
    required this.id,
    required this.centerPointId,
    required this.majorPointId,
    required this.majorPointNegId,
    required this.minorPointId,
    required this.minorPointNegId,
    required this.majorAxisLineId,
    required this.minorAxisLineId,
    required this.majorRadius,
    required this.minorRadius,
    required this.rotation,
    this.construction = false,
  });

  factory EllipseDto.fromJson(Map<String, dynamic> json) => EllipseDto(
        id: json['id'] as String,
        centerPointId: json['center_point_id'] as String,
        majorPointId: json['major_point_id'] as String,
        majorPointNegId: json['major_point_neg_id'] as String,
        minorPointId: json['minor_point_id'] as String,
        minorPointNegId: json['minor_point_neg_id'] as String,
        majorAxisLineId: json['major_axis_line_id'] as String,
        minorAxisLineId: json['minor_axis_line_id'] as String,
        majorRadius: (json['major_radius'] as num).toDouble(),
        minorRadius: (json['minor_radius'] as num).toDouble(),
        rotation: (json['rotation'] as num).toDouble(),
        construction: json['construction'] as bool? ?? false,
      );
}

class SplineDto {
  final String id;
  final List<String> throughPointIds;
  final List<String> controlPointIds;
  final bool construction;

  SplineDto({
    required this.id,
    required this.throughPointIds,
    required this.controlPointIds,
    this.construction = false,
  });

  factory SplineDto.fromJson(Map<String, dynamic> json) => SplineDto(
        id: json['id'] as String,
        throughPointIds: (json['through_point_ids'] as List).cast<String>(),
        controlPointIds: (json['control_point_ids'] as List).cast<String>(),
        construction: json['construction'] as bool? ?? false,
      );
}

class TextDto {
  final String id;
  final String content;
  final String font;
  final double size;
  final String anchorPointId;
  final double rotationDegrees;
  final bool construction;

  TextDto({
    required this.id,
    required this.content,
    required this.font,
    required this.size,
    required this.anchorPointId,
    this.rotationDegrees = 0,
    this.construction = false,
  });

  factory TextDto.fromJson(Map<String, dynamic> json) => TextDto(
        id: json['id'] as String,
        content: json['content'] as String,
        font: json['font'] as String,
        size: (json['size'] as num).toDouble(),
        anchorPointId: json['anchor_point_id'] as String,
        rotationDegrees: (json['rotation_degrees'] as num?)?.toDouble() ?? 0,
        construction: json['construction'] as bool? ?? false,
      );
}

/// One glyph contour from `GET .../texts/{id}/preview` - `outer`/each of
/// `holes` a closed `(x, y)` polyline, already positioned/rotated by the
/// server per the owning Text's own anchor Point/`rotationDegrees` (see
/// the backend's `TextContourResponse` docstring - no extra client-side
/// transform is needed to draw these directly).
class TextContourDto {
  final List<(double, double)> outer;
  final List<List<(double, double)>> holes;

  const TextContourDto({required this.outer, this.holes = const []});

  static (double, double) _point(dynamic json) {
    final list = json as List;
    return ((list[0] as num).toDouble(), (list[1] as num).toDouble());
  }

  factory TextContourDto.fromJson(Map<String, dynamic> json) => TextContourDto(
        outer: (json['outer'] as List).map(_point).toList(),
        holes: (json['holes'] as List)
            .map((hole) => (hole as List).map(_point).toList())
            .toList(),
      );
}

/// Base type for the backend's discriminated Constraint union (Stage 12) -
/// see app/sketch/schemas.py's `ConstraintResponse`. Used by the client both
/// to *render* existing constraints (Stage 12 item 10's dimension overlays)
/// and, since Stage 13, to recognize an already-existing `DistanceConstraint`
/// so a dimension-ghost confirm can PATCH it instead of creating a duplicate
/// (see SketchApiClient.createDistanceConstraint/updateConstraintValue).
abstract class ConstraintDto {
  final String id;
  const ConstraintDto({required this.id});

  /// Dispatches on the backend's `type` discriminator, defaulting to
  /// [DistanceConstraintDto] when absent - mirrors the backend's own
  /// smart-union fallback (see DistanceConstraintCreate's `type` default).
  static ConstraintDto fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String?) {
      case 'vertical':
        return VerticalConstraintDto.fromJson(json);
      case 'horizontal':
        return HorizontalConstraintDto.fromJson(json);
      case 'angle':
        return AngleConstraintDto.fromJson(json);
      case 'coincident':
        return CoincidentConstraintDto.fromJson(json);
      case 'parallel':
        return ParallelConstraintDto.fromJson(json);
      case 'perpendicular':
        return PerpendicularConstraintDto.fromJson(json);
      case 'equal_length':
        return EqualLengthConstraintDto.fromJson(json);
      case 'collinear':
        return CollinearConstraintDto.fromJson(json);
      case 'line_distance':
        return LineDistanceConstraintDto.fromJson(json);
      case 'point_line_distance':
        return PointLineDistanceConstraintDto.fromJson(json);
      case 'at_midpoint':
        return AtMidpointConstraintDto.fromJson(json);
      case 'spline_tangent':
        return SplineTangentConstraintDto.fromJson(json);
      case 'tangent':
        return TangentConstraintDto.fromJson(json);
      case 'equal_radius':
        return EqualRadiusConstraintDto.fromJson(json);
      default:
        return DistanceConstraintDto.fromJson(json);
    }
  }
}

class DistanceConstraintDto extends ConstraintDto {
  final String pointAId;
  final String pointBId;
  final double distance;

  /// "linear" (default), "horizontal", or "vertical" - see
  /// [SketchApiClient.createDistanceConstraint]'s doc comment (Prompt B
  /// item B3).
  final String orientation;

  const DistanceConstraintDto({
    required super.id,
    required this.pointAId,
    required this.pointBId,
    required this.distance,
    this.orientation = 'linear',
  });

  factory DistanceConstraintDto.fromJson(Map<String, dynamic> json) => DistanceConstraintDto(
        id: json['id'] as String,
        pointAId: json['point_a_id'] as String,
        pointBId: json['point_b_id'] as String,
        distance: (json['distance'] as num).toDouble(),
        orientation: json['orientation'] as String? ?? 'linear',
      );
}

class VerticalConstraintDto extends ConstraintDto {
  final String lineId;
  final String pointAId;
  final String pointBId;

  const VerticalConstraintDto({
    required super.id,
    required this.lineId,
    required this.pointAId,
    required this.pointBId,
  });

  factory VerticalConstraintDto.fromJson(Map<String, dynamic> json) => VerticalConstraintDto(
        id: json['id'] as String,
        lineId: json['line_id'] as String,
        pointAId: json['point_a_id'] as String,
        pointBId: json['point_b_id'] as String,
      );
}

class HorizontalConstraintDto extends ConstraintDto {
  final String lineId;
  final String pointAId;
  final String pointBId;

  const HorizontalConstraintDto({
    required super.id,
    required this.lineId,
    required this.pointAId,
    required this.pointBId,
  });

  factory HorizontalConstraintDto.fromJson(Map<String, dynamic> json) => HorizontalConstraintDto(
        id: json['id'] as String,
        lineId: json['line_id'] as String,
        pointAId: json['point_a_id'] as String,
        pointBId: json['point_b_id'] as String,
      );
}

class AngleConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;
  final double angleDegrees;

  const AngleConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
    required this.angleDegrees,
  });

  factory AngleConstraintDto.fromJson(Map<String, dynamic> json) => AngleConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
        angleDegrees: (json['angle_degrees'] as num).toDouble(),
      );
}

class CoincidentConstraintDto extends ConstraintDto {
  final String pointAId;
  final String pointBId;

  const CoincidentConstraintDto({
    required super.id,
    required this.pointAId,
    required this.pointBId,
  });

  factory CoincidentConstraintDto.fromJson(Map<String, dynamic> json) => CoincidentConstraintDto(
        id: json['id'] as String,
        pointAId: json['point_a_id'] as String,
        pointBId: json['point_b_id'] as String,
      );
}

class ParallelConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;

  const ParallelConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
  });

  factory ParallelConstraintDto.fromJson(Map<String, dynamic> json) => ParallelConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
      );
}

class PerpendicularConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;

  const PerpendicularConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
  });

  factory PerpendicularConstraintDto.fromJson(Map<String, dynamic> json) => PerpendicularConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
      );
}

class EqualLengthConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;

  const EqualLengthConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
  });

  factory EqualLengthConstraintDto.fromJson(Map<String, dynamic> json) => EqualLengthConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
      );
}

class CollinearConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;

  const CollinearConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
  });

  factory CollinearConstraintDto.fromJson(Map<String, dynamic> json) => CollinearConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
      );
}

/// Stage 16 item 9's fix: a line-to-line distance dimension now PATCHes/
/// creates this directly against the two Lines (see
/// SketchApiClient.createLineDistanceConstraint), instead of the old
/// approach of materializing a midpoint Point on each Line and constraining
/// a plain [DistanceConstraintDto] between those two new Points.
class LineDistanceConstraintDto extends ConstraintDto {
  final String line1Id;
  final String line2Id;
  final double distance;

  const LineDistanceConstraintDto({
    required super.id,
    required this.line1Id,
    required this.line2Id,
    required this.distance,
  });

  factory LineDistanceConstraintDto.fromJson(Map<String, dynamic> json) => LineDistanceConstraintDto(
        id: json['id'] as String,
        line1Id: json['line1_id'] as String,
        line2Id: json['line2_id'] as String,
        distance: (json['distance'] as num).toDouble(),
      );
}

/// Stage 21 item 3's midpoint fix: pins the perpendicular distance from an
/// arbitrary Point to a Line - generalizes [LineDistanceConstraintDto]
/// (anchored at a second Line's own start Point) to any Point id, so
/// SketchController.materializeMidpoint can pin a new Point onto a Line's
/// infinite extension (distance 0) without it being one of that Line's own
/// endpoints.
class PointLineDistanceConstraintDto extends ConstraintDto {
  final String pointId;
  final String lineId;
  final double distance;

  const PointLineDistanceConstraintDto({
    required super.id,
    required this.pointId,
    required this.lineId,
    required this.distance,
  });

  factory PointLineDistanceConstraintDto.fromJson(Map<String, dynamic> json) =>
      PointLineDistanceConstraintDto(
        id: json['id'] as String,
        pointId: json['point_id'] as String,
        lineId: json['line_id'] as String,
        distance: (json['distance'] as num).toDouble(),
      );
}

/// Stage 22 item 1's fix: pins a Point to a Line's geometric midpoint via
/// py-slvs's native SLVS_C_AT_MIDPOINT primitive, replacing the Stage 21
/// [PointLineDistanceConstraintDto](distance 0) + [DistanceConstraintDto]
/// (half-length) pair SketchController.materializeMidpoint used to create -
/// no numeric value field, since the solver tracks the midpoint directly as
/// the Line's endpoints move.
class AtMidpointConstraintDto extends ConstraintDto {
  final String pointId;
  final String lineId;

  const AtMidpointConstraintDto({
    required super.id,
    required this.pointId,
    required this.lineId,
  });

  factory AtMidpointConstraintDto.fromJson(Map<String, dynamic> json) => AtMidpointConstraintDto(
        id: json['id'] as String,
        pointId: json['point_id'] as String,
        lineId: json['line_id'] as String,
      );
}

/// `Sketch.add_spline`'s own internal, non-user-editable constraint (see
/// the backend `SplineTangentConstraint`'s docstring) - the client never
/// creates one of these directly, only ever receives it back from
/// [SketchApiClient.listConstraints] as part of a Spline's auto-created
/// state, so there's no matching `createXConstraint` call for it (unlike
/// every other [ConstraintDto] subtype here).
class SplineTangentConstraintDto extends ConstraintDto {
  final String splineId;
  final String segmentAP0;
  final String segmentAP1;
  final String segmentAP2;
  final String segmentAP3;
  final String segmentBP0;
  final String segmentBP1;
  final String segmentBP2;
  final String segmentBP3;

  const SplineTangentConstraintDto({
    required super.id,
    required this.splineId,
    required this.segmentAP0,
    required this.segmentAP1,
    required this.segmentAP2,
    required this.segmentAP3,
    required this.segmentBP0,
    required this.segmentBP1,
    required this.segmentBP2,
    required this.segmentBP3,
  });

  factory SplineTangentConstraintDto.fromJson(Map<String, dynamic> json) => SplineTangentConstraintDto(
        id: json['id'] as String,
        splineId: json['spline_id'] as String,
        segmentAP0: json['segment_a_p0'] as String,
        segmentAP1: json['segment_a_p1'] as String,
        segmentAP2: json['segment_a_p2'] as String,
        segmentAP3: json['segment_a_p3'] as String,
        segmentBP0: json['segment_b_p0'] as String,
        segmentBP1: json['segment_b_p1'] as String,
        segmentBP2: json['segment_b_p2'] as String,
        segmentBP3: json['segment_b_p3'] as String,
      );
}

/// A Slot's/`SketchController.createTangentConstraint`'s own Circle-or-Arc
/// to Line tangency constraint - see backend `TangentConstraint`'s doc
/// comment for why it's expressed as a centre-to-rim distance rather than
/// py-slvs's native arc-of-circle entity.
class TangentConstraintDto extends ConstraintDto {
  final String centerPointId;
  final String radiusPointId;
  final String lineId;

  const TangentConstraintDto({
    required super.id,
    required this.centerPointId,
    required this.radiusPointId,
    required this.lineId,
  });

  factory TangentConstraintDto.fromJson(Map<String, dynamic> json) => TangentConstraintDto(
        id: json['id'] as String,
        centerPointId: json['center_point_id'] as String,
        radiusPointId: json['radius_point_id'] as String,
        lineId: json['line_id'] as String,
      );
}

/// Ties two Circles'/Arcs' radii together (e.g. a Slot's two end-cap Arcs)
/// without a second independently-editable radius dimension - see backend
/// `EqualRadiusConstraint`'s doc comment.
class EqualRadiusConstraintDto extends ConstraintDto {
  final String center1PointId;
  final String radius1PointId;
  final String center2PointId;
  final String radius2PointId;

  const EqualRadiusConstraintDto({
    required super.id,
    required this.center1PointId,
    required this.radius1PointId,
    required this.center2PointId,
    required this.radius2PointId,
  });

  factory EqualRadiusConstraintDto.fromJson(Map<String, dynamic> json) => EqualRadiusConstraintDto(
        id: json['id'] as String,
        center1PointId: json['center1_point_id'] as String,
        radius1PointId: json['radius1_point_id'] as String,
        center2PointId: json['center2_point_id'] as String,
        radius2PointId: json['radius2_point_id'] as String,
      );
}

class SolveResultDto {
  final bool converged;
  final int dof;
  final String detail;

  /// Phase 3 bug-fix round: py-slvs's own `Failed` constraint-handle list
  /// (see backend solver.py's `SolveResult.solver_reported_failed_
  /// constraint_ids` doc comment) - "tends to list every constraint in an
  /// inconsistent system rather than a single culprit", which is exactly
  /// why it's useful here: when [converged] is false, this is the closest
  /// thing to "which entities are actually responsible" the backend can
  /// offer, used to colour those entities red even though the client's own
  /// purely-structural dof_analysis.dart has no way to know a solve
  /// numerically failed (see [SketchController.rigidity]'s own doc
  /// comment on why it can't - a *topology*-only check can never catch a
  /// numeric conflict like "these dimensions are geometrically
  /// impossible").
  final List<String> solverReportedFailedConstraintIds;

  SolveResultDto({
    required this.converged,
    required this.dof,
    required this.detail,
    this.solverReportedFailedConstraintIds = const [],
  });

  factory SolveResultDto.fromJson(Map<String, dynamic> json) => SolveResultDto(
        converged: json['converged'] as bool,
        dof: json['dof'] as int,
        detail: json['detail'] as String,
        solverReportedFailedConstraintIds:
            (json['solver_reported_failed_constraint_ids'] as List<dynamic>? ?? []).cast<String>(),
      );
}

/// One outer profile loop's ordered Point ids, plus the Point ids of every
/// hole (C1's `inner_loops`) nested inside it - recursive to match the
/// backend's `ProfileResponse` shape, though in practice only one level
/// deep is ever populated (a hole never itself carries holes - see
/// `ProfileStatus.INVALID_NESTING`). The sketch canvas's profile-area fill
/// unit: one filled polygon per [ProfileLoopDto], each hole punched out via
/// an even-odd sub-path (see `SketchCanvas._paintClosedProfileFill`).
class ProfileLoopDto {
  final List<String> pointIds;

  /// Prompt G: this loop's own Line/Circle entity ids (a Circle-only loop
  /// has exactly one, its own id - see the backend's `_circle_profile`) -
  /// needed to resolve "which loop does this tapped Sketch Line/Circle
  /// belong to" for the profile-picking flow's anchor-ref/whole-loop-
  /// highlight mechanism (see `PartScreen`'s new profile-picking state).
  /// Previously unparsed since nothing needed it before this prompt.
  final List<String> lineIds;
  final List<ProfileLoopDto> innerLoops;

  ProfileLoopDto({required this.pointIds, this.lineIds = const [], this.innerLoops = const []});

  factory ProfileLoopDto.fromJson(Map<String, dynamic> json) => ProfileLoopDto(
        pointIds: (json['point_ids'] as List<dynamic>).cast<String>(),
        lineIds: (json['line_ids'] as List<dynamic>? ?? []).cast<String>(),
        innerLoops: (json['inner_loops'] as List<dynamic>? ?? [])
            .map((loop) => ProfileLoopDto.fromJson(loop as Map<String, dynamic>))
            .toList(),
      );
}

/// Result of a Sketch's closed-Profile check. [status]/[detail] drive the
/// Extrude context-menu gate; [fillableLoops] drives the sketch canvas's
/// profile-area fill. The backend's `branch_point_ids` (multi-loop detail)
/// isn't needed by either consumer, so it's left unparsed.
class ProfileDetectionDto {
  static const String closedLoop = 'closed_loop';
  static const String multipleLoops = 'multiple_loops';

  final String status;
  final String detail;

  /// Every outer profile loop this Sketch's closed-profile detection found,
  /// each already carrying its own holes (`ProfileLoopDto.innerLoops`) -
  /// one entry for `closed_loop` (C1's single nested profile), 2+ for
  /// `multiple_loops` (C2's MultiProfile), empty for every other status.
  final List<ProfileLoopDto> fillableLoops;

  ProfileDetectionDto({required this.status, required this.detail, this.fillableLoops = const []});

  bool get isClosedLoop => status == closedLoop;

  /// Prompt C (C2): whether the backend would accept an Extrude created
  /// from this Sketch - `closed_loop` (a single nested profile, C1) or
  /// `multiple_loops` (a MultiProfile of disjoint outer profiles, C2) -
  /// matching `app.document.router._require_closed_sketch_feature`'s own
  /// gate exactly.
  bool get isExtrudable => status == closedLoop || status == multipleLoops;

  factory ProfileDetectionDto.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    final loops = json['loops'] as List<dynamic>?;
    return ProfileDetectionDto(
      status: json['status'] as String,
      detail: json['detail'] as String,
      fillableLoops: profile != null
          ? [ProfileLoopDto.fromJson(profile)]
          : (loops ?? []).map((loop) => ProfileLoopDto.fromJson(loop as Map<String, dynamic>)).toList(),
    );
  }
}

/// Thin wrapper over the backend's `/sketch` REST API. Knows nothing about
/// UI/cursor state - it only translates Dart calls into the HTTP contract
/// defined by backend/app/sketch/router.py and schemas.py.
class SketchApiClient {
  final http.Client _httpClient;

  SketchApiClient({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': ApiConfig.apiKey,
      };

  Uri _uri(String path) => Uri.parse('${ApiConfig.baseUrl}$path');

  Future<T> _send<T>(
    Future<http.Response> Function() request,
    T Function(dynamic decodedBody) onSuccess,
  ) async {
    http.Response response;
    try {
      response = await request().timeout(ApiConfig.requestTimeout);
    } on Exception catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Server returned ${response.statusCode}: ${_detailOf(response)}');
    }
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    return onSuccess(decoded);
  }

  /// FastAPI's HTTPException responses are `{"detail": "..."}` - extracting
  /// that gives a much more useful [ApiException] message (e.g. the actual
  /// reason a Point delete was rejected) than the raw response body.
  String _detailOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Not JSON (or no `detail` field) - fall through to the raw body.
    }
    return response.body;
  }

  Future<SketchDto> createSketch({String plane = 'XY'}) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches'),
              headers: _headers,
              body: jsonEncode({'plane': plane}),
            ),
        (body) => SketchDto.fromJson(body as Map<String, dynamic>),
      );

  Future<SketchDto> getSketch(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId'), headers: _headers),
        (body) => SketchDto.fromJson(body as Map<String, dynamic>),
      );

  Future<PointDto> createPoint(String sketchId, double x, double y) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/points'),
              headers: _headers,
              body: jsonEncode({'x': x, 'y': y}),
            ),
        (body) => PointDto.fromJson(body as Map<String, dynamic>),
      );

  Future<PointDto> getPoint(String sketchId, String pointId) => _send(
        () => _httpClient.get(
              _uri('/sketch/sketches/$sketchId/points/$pointId'),
              headers: _headers,
            ),
        (body) => PointDto.fromJson(body as Map<String, dynamic>),
      );

  Future<List<PointDto>> listPoints(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/points'), headers: _headers),
        (body) => (body as List)
            .map((e) => PointDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<LineDto>> listLines(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/lines'), headers: _headers),
        (body) => (body as List)
            .map((e) => LineDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<CircleDto>> listCircles(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/circles'), headers: _headers),
        (body) => (body as List)
            .map((e) => CircleDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<ArcDto>> listArcs(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/arcs'), headers: _headers),
        (body) => (body as List)
            .map((e) => ArcDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<EllipseDto>> listEllipses(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/ellipses'), headers: _headers),
        (body) => (body as List)
            .map((e) => EllipseDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<SplineDto>> listSplines(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/splines'), headers: _headers),
        (body) => (body as List)
            .map((e) => SplineDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<TextDto>> listTexts(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/texts'), headers: _headers),
        (body) => (body as List).map((e) => TextDto.fromJson(e as Map<String, dynamic>)).toList(),
      );

  /// Every one of a Text entity's own glyph contours, already positioned/
  /// rotated per its anchor Point/`rotationDegrees` (see [TextContourDto]'s
  /// own doc comment) - fetched once per content/font/size/rotation change
  /// and cached client-side (see `SketchTextView`), never polled.
  Future<List<TextContourDto>> getTextPreview(String sketchId, String textId) => _send(
        () => _httpClient.get(
              _uri('/sketch/sketches/$sketchId/texts/$textId/preview'),
              headers: _headers,
            ),
        (body) => ((body as Map<String, dynamic>)['contours'] as List)
            .map((e) => TextContourDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<LineDto> createLine(
    String sketchId,
    String startPointId,
    String endPointId, {
    bool construction = false,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/lines'),
              headers: _headers,
              body: jsonEncode({
                'start_point_id': startPointId,
                'end_point_id': endPointId,
                'construction': construction,
              }),
            ),
        (body) => LineDto.fromJson(body as Map<String, dynamic>),
      );

  Future<CircleDto> createCircle(
    String sketchId,
    String centerPointId,
    String radiusPointId, {
    bool construction = false,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/circles'),
              headers: _headers,
              body: jsonEncode({
                'center_point_id': centerPointId,
                'radius_point_id': radiusPointId,
                'construction': construction,
              }),
            ),
        (body) => CircleDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ArcDto> createArc(
    String sketchId,
    String centerPointId,
    String startPointId,
    String endPointId, {
    bool construction = false,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/arcs'),
              headers: _headers,
              body: jsonEncode({
                'center_point_id': centerPointId,
                'start_point_id': startPointId,
                'end_point_id': endPointId,
                'construction': construction,
              }),
            ),
        (body) => ArcDto.fromJson(body as Map<String, dynamic>),
      );

  /// Always creates from an existing major-axis Point (mirrors how the
  /// client creates Circle/Arc: the major-axis Point is placed as a real
  /// Point first, never via the backend's alternate major_radius+angle
  /// creation path).
  Future<EllipseDto> createEllipse(
    String sketchId,
    String centerPointId,
    String majorPointId,
    double minorRadius, {
    bool construction = false,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/ellipses'),
              headers: _headers,
              body: jsonEncode({
                'center_point_id': centerPointId,
                'major_point_id': majorPointId,
                'minor_radius': minorRadius,
                'construction': construction,
              }),
            ),
        (body) => EllipseDto.fromJson(body as Map<String, dynamic>),
      );

  /// Always creates from through-points that already exist (mirrors how
  /// the client creates Circle/Arc/Ellipse) - server-side, `Sketch.
  /// add_spline` creates the control-handle Points and tangent
  /// constraints, returning them all in the response.
  Future<SplineDto> createSpline(String sketchId, List<String> throughPointIds, {bool construction = false}) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/splines'),
              headers: _headers,
              body: jsonEncode({
                'through_point_ids': throughPointIds,
                'construction': construction,
              }),
            ),
        (body) => SplineDto.fromJson(body as Map<String, dynamic>),
      );

  /// Always creates from an existing anchor Point (mirrors how the client
  /// creates every other entity here). `font` is left to the backend's own
  /// default (currently the only allow-listed font, "Open Sans" - see the
  /// backend's `TextEntity`/`text_fonts` docstrings) since v1 has nothing
  /// for the client to offer a choice between yet.
  Future<TextDto> createText(
    String sketchId,
    String content,
    String anchorPointId, {
    double size = 10.0,
    double rotationDegrees = 0,
    bool construction = false,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/texts'),
              headers: _headers,
              body: jsonEncode({
                'content': content,
                'anchor_point_id': anchorPointId,
                'size': size,
                'rotation_degrees': rotationDegrees,
                'construction': construction,
              }),
            ),
        (body) => TextDto.fromJson(body as Map<String, dynamic>),
      );

  /// Toggles a Line's construction flag (Make-Construction/Make-Solid) -
  /// `length` is left null since this call never needs to also resize the
  /// line (see backend LineUpdate, where both fields are independently
  /// optional).
  Future<LineDto> updateLine(String sketchId, String lineId, {bool? construction, double? length}) =>
      _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/lines/$lineId'),
              headers: _headers,
              body: jsonEncode({
                if (length != null) 'length': length,
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => LineDto.fromJson(body as Map<String, dynamic>),
      );

  /// Toggles a Circle's construction flag - mirrors [updateLine].
  Future<CircleDto> updateCircle(String sketchId, String circleId, {bool? construction}) => _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/circles/$circleId'),
              headers: _headers,
              body: jsonEncode({
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => CircleDto.fromJson(body as Map<String, dynamic>),
      );

  /// Toggles an Arc's construction flag - mirrors [updateCircle].
  Future<ArcDto> updateArc(String sketchId, String arcId, {bool? construction}) => _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/arcs/$arcId'),
              headers: _headers,
              body: jsonEncode({
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => ArcDto.fromJson(body as Map<String, dynamic>),
      );

  /// Toggles an Ellipse's construction flag - mirrors [updateArc]. There is
  /// no radius field here: like Circle/Arc, both of an Ellipse's radii are
  /// now driven by real DistanceConstraints (see the Ellipse class's own
  /// docstring) - resize either one via [updateConstraintValue] against
  /// its `major_constraint_id`/`minor_constraint_id` instead.
  Future<EllipseDto> updateEllipse(String sketchId, String ellipseId, {bool? construction}) => _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/ellipses/$ellipseId'),
              headers: _headers,
              body: jsonEncode({
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => EllipseDto.fromJson(body as Map<String, dynamic>),
      );

  /// Toggles a Spline's construction flag - mirrors [updateArc]. There is
  /// no shape field here: a Spline's shape is driven entirely by its
  /// through-point/control-handle Points' own positions and its
  /// SplineTangentConstraints, not edited directly.
  Future<SplineDto> updateSpline(String sketchId, String splineId, {bool? construction}) => _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/splines/$splineId'),
              headers: _headers,
              body: jsonEncode({
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => SplineDto.fromJson(body as Map<String, dynamic>),
      );

  /// Updates any of a Text entity's own directly-editable fields - mirrors
  /// [updateEllipse]'s "several independently-optional fields" shape.
  /// Every field here is a plain direct edit (see the backend's
  /// `TextEntity`/`TextUpdate` docstrings) - omitted fields are left
  /// unchanged.
  Future<TextDto> updateText(
    String sketchId,
    String textId, {
    String? content,
    double? size,
    double? rotationDegrees,
    bool? construction,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/texts/$textId'),
              headers: _headers,
              body: jsonEncode({
                if (content != null) 'content': content,
                if (size != null) 'size': size,
                if (rotationDegrees != null) 'rotation_degrees': rotationDegrees,
                if (construction != null) 'construction': construction,
              }),
            ),
        (body) => TextDto.fromJson(body as Map<String, dynamic>),
      );

  Future<void> deletePoint(String sketchId, String pointId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/points/$pointId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteLine(String sketchId, String lineId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/lines/$lineId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteCircle(String sketchId, String circleId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/circles/$circleId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteArc(String sketchId, String arcId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/arcs/$arcId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteEllipse(String sketchId, String ellipseId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/ellipses/$ellipseId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteSpline(String sketchId, String splineId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/splines/$splineId'),
              headers: _headers,
            ),
        (_) {},
      );

  Future<void> deleteText(String sketchId, String textId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/texts/$textId'),
              headers: _headers,
            ),
        (_) {},
      );

  /// Direct-manipulation drag support: repositions a Point without
  /// re-solving (mirrors backend PointUpdate, which has no auto-solve) - the
  /// caller is expected to call [solve] itself once the drag ends.
  Future<PointDto> updatePoint(String sketchId, String pointId, double x, double y) => _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/points/$pointId'),
              headers: _headers,
              body: jsonEncode({'x': x, 'y': y}),
            ),
        (body) => PointDto.fromJson(body as Map<String, dynamic>),
      );

  Future<void> deleteConstraint(String sketchId, String constraintId) => _send(
        () => _httpClient.delete(
              _uri('/sketch/sketches/$sketchId/constraints/$constraintId'),
              headers: _headers,
            ),
        (_) {},
      );

  /// The angle-dimension ghost's confirm path - between two non-parallel
  /// Lines, mirrors [createVerticalConstraint]'s shape.
  Future<ConstraintDto> createAngleConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
    double angleDegrees,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'angle',
                'line1_id': line1Id,
                'line2_id': line2Id,
                'angle_degrees': angleDegrees,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<List<ConstraintDto>> listConstraints(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/constraints'), headers: _headers),
        (body) => (body as List)
            .map((e) => ConstraintDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Stage 13's Dimension workflow: creates a standalone `DistanceConstraint`
  /// between two existing Points - used for a line-length ghost (the line's
  /// own endpoints) and a V/H distance ghost (two tapped Points) alike, since
  /// the backend has no separate "line length" constraint type (see
  /// Sketch.add_distance_constraint).
  ///
  /// [orientation] (Prompt B item B3) is "linear" (default - the plain
  /// Euclidean distance), "horizontal", or "vertical" - the latter two pin
  /// only the X or Y separation, leaving the other axis free, so a
  /// horizontal/vertical dimension keeps its axis-locked nature after a
  /// solve instead of degrading into a plain linear distance.
  Future<ConstraintDto> createDistanceConstraint(
    String sketchId,
    String pointAId,
    String pointBId,
    double distance, {
    String orientation = 'linear',
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'point_a_id': pointAId,
                'point_b_id': pointBId,
                'distance': distance,
                'orientation': orientation,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createVerticalConstraint(String sketchId, String lineId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({'type': 'vertical', 'line_id': lineId}),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createHorizontalConstraint(String sketchId, String lineId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({'type': 'horizontal', 'line_id': lineId}),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Stage 15's value-less constraint buttons: each takes exactly two
  /// existing entity ids and has no numeric value to preview/confirm, unlike
  /// [createDistanceConstraint]/[createAngleConstraint] - mirrors
  /// [createVerticalConstraint]'s shape.
  Future<ConstraintDto> createCoincidentConstraint(
    String sketchId,
    String pointAId,
    String pointBId,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'coincident',
                'point_a_id': pointAId,
                'point_b_id': pointBId,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createParallelConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'parallel',
                'line1_id': line1Id,
                'line2_id': line2Id,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createPerpendicularConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'perpendicular',
                'line1_id': line1Id,
                'line2_id': line2Id,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createEqualLengthConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'equal_length',
                'line1_id': line1Id,
                'line2_id': line2Id,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ConstraintDto> createCollinearConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'collinear',
                'line1_id': line1Id,
                'line2_id': line2Id,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Stage 16 item 9's fix: a line-to-line distance dimension's confirm
  /// path now goes here instead of [createDistanceConstraint] - see
  /// LineDistanceConstraintDto's doc comment.
  Future<ConstraintDto> createLineDistanceConstraint(
    String sketchId,
    String line1Id,
    String line2Id,
    double distance,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'line_distance',
                'line1_id': line1Id,
                'line2_id': line2Id,
                'distance': distance,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Stage 21 item 3's midpoint fix: pins a Point onto a Line (perpendicular
  /// distance, typically 0) - see PointLineDistanceConstraintDto's doc comment.
  Future<ConstraintDto> createPointLineDistanceConstraint(
    String sketchId,
    String pointId,
    String lineId,
    double distance,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'point_line_distance',
                'point_id': pointId,
                'line_id': lineId,
                'distance': distance,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Stage 22 item 1's fix: pins a Point to a Line's geometric midpoint via
  /// the native SLVS_C_AT_MIDPOINT primitive - see AtMidpointConstraintDto's
  /// doc comment.
  Future<ConstraintDto> createAtMidpointConstraint(
    String sketchId,
    String pointId,
    String lineId,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'at_midpoint',
                'point_id': pointId,
                'line_id': lineId,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Slot tool's own tangency wiring - see TangentConstraintDto's doc comment.
  Future<ConstraintDto> createTangentConstraint(
    String sketchId,
    String circleOrArcId,
    String lineId,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'tangent',
                'circle_or_arc_id': circleOrArcId,
                'line_id': lineId,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Slot tool's own equal-radius wiring - see EqualRadiusConstraintDto's doc
  /// comment. [radius2PointId] optionally picks which of entity2's two rim
  /// Points (for an Arc) this tie is for - a Slot's second end-cap Arc needs
  /// this called twice, once per rim Point, since it has no single radius
  /// Point of its own once both its native radius constraints are removed.
  Future<ConstraintDto> createEqualRadiusConstraint(
    String sketchId,
    String entity1Id,
    String entity2Id, {
    String? radius2PointId,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'type': 'equal_radius',
                'entity1_id': entity1Id,
                'entity2_id': entity2Id,
                if (radius2PointId != null) 'radius2_point_id': radius2PointId,
              }),
            ),
        (body) => ConstraintDto.fromJson(body as Map<String, dynamic>),
      );

  /// Stage 13's dimension-edit PATCH: updates an existing `DistanceConstraint`
  /// or `AngleConstraint`'s numeric value and re-solves server-side - see
  /// app/sketch/router.py's `update_constraint_value`. The backend rejects
  /// Vertical/Horizontal targets with a 422, surfaced as an [ApiException].
  Future<SolveResultDto> updateConstraintValue(String sketchId, String constraintId, double value) =>
      _send(
        () => _httpClient.patch(
              _uri('/sketch/sketches/$sketchId/constraints/$constraintId'),
              headers: _headers,
              body: jsonEncode({'value': value}),
            ),
        (body) => SolveResultDto.fromJson(body as Map<String, dynamic>),
      );

  /// [anchorPointIds] pins those Points for this one solve only (drag-solve
  /// semantics - see the backend's `SolveRequest` doc comment): the Point(s)
  /// the user just dragged stay exactly where dropped while the rest of the
  /// Sketch settles around them. Omitted (the common case, every call site
  /// that isn't a drag-drop) sends no body at all, same request the backend
  /// already handled before this parameter existed.
  Future<SolveResultDto> solve(String sketchId, {List<String> anchorPointIds = const []}) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/solve'),
              headers: _headers,
              body: anchorPointIds.isEmpty
                  ? null
                  : jsonEncode({'anchor_point_ids': anchorPointIds}),
            ),
        (body) => SolveResultDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ProfileDetectionDto> getProfile(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/profile'), headers: _headers),
        (body) => ProfileDetectionDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
