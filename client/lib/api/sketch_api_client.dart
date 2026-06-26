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
  final String plane;
  final String originPointId;

  SketchDto({required this.id, required this.plane, required this.originPointId});

  factory SketchDto.fromJson(Map<String, dynamic> json) => SketchDto(
        id: json['id'] as String,
        plane: json['plane'] as String,
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
      default:
        return DistanceConstraintDto.fromJson(json);
    }
  }
}

class DistanceConstraintDto extends ConstraintDto {
  final String pointAId;
  final String pointBId;
  final double distance;

  const DistanceConstraintDto({
    required super.id,
    required this.pointAId,
    required this.pointBId,
    required this.distance,
  });

  factory DistanceConstraintDto.fromJson(Map<String, dynamic> json) => DistanceConstraintDto(
        id: json['id'] as String,
        pointAId: json['point_a_id'] as String,
        pointBId: json['point_b_id'] as String,
        distance: (json['distance'] as num).toDouble(),
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

class SolveResultDto {
  final bool converged;
  final int dof;
  final String detail;

  SolveResultDto({required this.converged, required this.dof, required this.detail});

  factory SolveResultDto.fromJson(Map<String, dynamic> json) => SolveResultDto(
        converged: json['converged'] as bool,
        dof: json['dof'] as int,
        detail: json['detail'] as String,
      );
}

/// Result of a Sketch's closed-Profile check. [status]/[detail] drive the
/// Extrude context-menu gate; [pointIds] (the closed loop's ordered Point
/// ids, when [isClosedLoop]) drives the sketch canvas's profile-area fill.
/// The backend's `branch_point_ids`/`loops` (multi-loop detail) aren't
/// needed by either consumer, so they're left unparsed.
class ProfileDetectionDto {
  static const String closedLoop = 'closed_loop';

  final String status;
  final String detail;
  final List<String>? pointIds;

  ProfileDetectionDto({required this.status, required this.detail, this.pointIds});

  bool get isClosedLoop => status == closedLoop;

  factory ProfileDetectionDto.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return ProfileDetectionDto(
      status: json['status'] as String,
      detail: json['detail'] as String,
      pointIds: profile == null ? null : (profile['point_ids'] as List<dynamic>).cast<String>(),
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
  Future<ConstraintDto> createDistanceConstraint(
    String sketchId,
    String pointAId,
    String pointBId,
    double distance,
  ) =>
      _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/constraints'),
              headers: _headers,
              body: jsonEncode({
                'point_a_id': pointAId,
                'point_b_id': pointBId,
                'distance': distance,
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

  Future<SolveResultDto> solve(String sketchId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/solve'),
              headers: _headers,
            ),
        (body) => SolveResultDto.fromJson(body as Map<String, dynamic>),
      );

  Future<ProfileDetectionDto> getProfile(String sketchId) => _send(
        () => _httpClient.get(_uri('/sketch/sketches/$sketchId/profile'), headers: _headers),
        (body) => ProfileDetectionDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
