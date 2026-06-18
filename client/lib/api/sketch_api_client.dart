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

  SketchDto({required this.id, required this.plane});

  factory SketchDto.fromJson(Map<String, dynamic> json) =>
      SketchDto(id: json['id'] as String, plane: json['plane'] as String);
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
      throw ApiException('Server returned ${response.statusCode}: ${response.body}');
    }
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    return onSuccess(decoded);
  }

  Future<SketchDto> createSketch({String plane = 'XY'}) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches'),
              headers: _headers,
              body: jsonEncode({'plane': plane}),
            ),
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

  Future<SolveResultDto> solve(String sketchId) => _send(
        () => _httpClient.post(
              _uri('/sketch/sketches/$sketchId/solve'),
              headers: _headers,
            ),
        (body) => SolveResultDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
