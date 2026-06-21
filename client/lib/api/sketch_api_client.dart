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

  LineDto({
    required this.id,
    required this.startPointId,
    required this.endPointId,
    required this.length,
  });

  factory LineDto.fromJson(Map<String, dynamic> json) => LineDto(
        id: json['id'] as String,
        startPointId: json['start_point_id'] as String,
        endPointId: json['end_point_id'] as String,
        length: (json['length'] as num).toDouble(),
      );
}

class CircleDto {
  final String id;
  final String centerPointId;
  final String radiusPointId;
  final double radius;

  CircleDto({
    required this.id,
    required this.centerPointId,
    required this.radiusPointId,
    required this.radius,
  });

  factory CircleDto.fromJson(Map<String, dynamic> json) => CircleDto(
        id: json['id'] as String,
        centerPointId: json['center_point_id'] as String,
        radiusPointId: json['radius_point_id'] as String,
        radius: (json['radius'] as num).toDouble(),
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

  Future<LineDto> createLine(String sketchId, String startPointId, String endPointId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/lines'),
              headers: _headers,
              body: jsonEncode({
                'start_point_id': startPointId,
                'end_point_id': endPointId,
              }),
            ),
        (body) => LineDto.fromJson(body as Map<String, dynamic>),
      );

  Future<CircleDto> createCircle(String sketchId, String centerPointId, String radiusPointId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/circles'),
              headers: _headers,
              body: jsonEncode({
                'center_point_id': centerPointId,
                'radius_point_id': radiusPointId,
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

  Future<SolveResultDto> solve(String sketchId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/solve'),
              headers: _headers,
            ),
        (body) => SolveResultDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
