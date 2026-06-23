import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'sketch_api_client.dart' show ApiException;

class PartDto {
  final String id;
  final String name;
  final List<String> featureIds;

  PartDto({required this.id, required this.name, required this.featureIds});

  factory PartDto.fromJson(Map<String, dynamic> json) => PartDto(
        id: json['id'] as String,
        name: json['name'] as String,
        featureIds: (json['feature_ids'] as List).cast<String>(),
      );
}

/// A Feature in a Part's history - either a SketchFeature or an
/// ExtrudeFeature, distinguished by [type] (the same discriminator the
/// backend's `FeatureResponse` union uses). [sketchId] is only present on a
/// `"sketch"` Feature; [sketchFeatureId]/[extrudeType]/[startDistance]/
/// [endDistance] only on an `"extrude"` one - kept as one DTO (rather than
/// two separate classes) since most call sites (the Feature tree, the
/// long-press menu) only care about [id]/[type]/[locked] regardless of
/// which kind a row is.
class FeatureDto {
  final String type;
  final String id;
  final bool locked;
  final String? sketchId;
  final String? sketchFeatureId;
  final String? extrudeType;
  final double? startDistance;
  final double? endDistance;

  FeatureDto({
    required this.type,
    required this.id,
    required this.locked,
    this.sketchId,
    this.sketchFeatureId,
    this.extrudeType,
    this.startDistance,
    this.endDistance,
  });

  factory FeatureDto.fromJson(Map<String, dynamic> json) => FeatureDto(
        type: json['type'] as String,
        id: json['id'] as String,
        locked: json['locked'] as bool,
        sketchId: json['sketch_id'] as String?,
        sketchFeatureId: json['sketch_feature_id'] as String?,
        extrudeType: json['extrude_type'] as String?,
        startDistance: (json['start_distance'] as num?)?.toDouble(),
        endDistance: (json['end_distance'] as num?)?.toDouble(),
      );
}

/// A flat, JSON-shaped mesh: each of [vertices]/[normals] is a list of
/// `[x, y, z]` triples (parallel, same length), and each entry in
/// [triangleIndices] is an `[a, b, c]` index triple into both.
class MeshDto {
  final List<List<double>> vertices;
  final List<List<double>> normals;
  final List<List<int>> triangleIndices;

  MeshDto({required this.vertices, required this.normals, required this.triangleIndices});

  factory MeshDto.fromJson(Map<String, dynamic> json) => MeshDto(
        vertices: _triples(json['vertices'] as List),
        normals: _triples(json['normals'] as List),
        triangleIndices: (json['triangle_indices'] as List)
            .map((t) => (t as List).map((v) => v as int).toList())
            .toList(),
      );

  static List<List<double>> _triples(List raw) =>
      raw.map((t) => (t as List).map((v) => (v as num).toDouble()).toList()).toList();
}

class PartMeshDto {
  final String source;
  final MeshDto mesh;

  PartMeshDto({required this.source, required this.mesh});

  factory PartMeshDto.fromJson(Map<String, dynamic> json) => PartMeshDto(
        source: json['source'] as String,
        mesh: MeshDto.fromJson(json['mesh'] as Map<String, dynamic>),
      );
}

/// What a cascade delete actually removed - both the Features and the
/// Sketches each deleted SketchFeature owned - so a caller can confirm the
/// backend's view matches what it asked for, even though the client
/// re-fetches the Feature list afterward rather than trusting this alone.
class CascadeDeleteResultDto {
  final List<String> deletedFeatureIds;
  final List<String> deletedSketchIds;

  CascadeDeleteResultDto({required this.deletedFeatureIds, required this.deletedSketchIds});

  factory CascadeDeleteResultDto.fromJson(Map<String, dynamic> json) => CascadeDeleteResultDto(
        deletedFeatureIds: (json['deleted_feature_ids'] as List).cast<String>(),
        deletedSketchIds: (json['deleted_sketch_ids'] as List).cast<String>(),
      );
}

/// Thin wrapper over the backend's `/document` REST API - same shape and
/// conventions as [SketchApiClient], kept as a separate client rather than
/// merged into it because it talks to a different backend router
/// (app.document.router) with its own DTOs.
class DocumentApiClient {
  final http.Client _httpClient;

  DocumentApiClient({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

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

  Future<PartDto> createPart(String name) => _send(
        () => _httpClient.post(
              _uri('/document/parts'),
              headers: _headers,
              body: jsonEncode({'name': name}),
            ),
        (body) => PartDto.fromJson(body as Map<String, dynamic>),
      );

  Future<PartDto> getPart(String partId) => _send(
        () => _httpClient.get(_uri('/document/parts/$partId'), headers: _headers),
        (body) => PartDto.fromJson(body as Map<String, dynamic>),
      );

  Future<List<FeatureDto>> listFeatures(String partId) => _send(
        () => _httpClient.get(_uri('/document/parts/$partId/features'), headers: _headers),
        (body) => (body as List).map((f) => FeatureDto.fromJson(f as Map<String, dynamic>)).toList(),
      );

  Future<FeatureDto> getFeature(String partId, String featureId) => _send(
        () => _httpClient.get(_uri('/document/parts/$partId/features/$featureId'), headers: _headers),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  Future<FeatureDto> createSketchFeature(String partId, {String plane = 'XY'}) => _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/features/sketch'),
              headers: _headers,
              body: jsonEncode({'plane': plane}),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  Future<FeatureDto> createExtrudeFeature(
    String partId, {
    required String sketchFeatureId,
    required String extrudeType,
    required double startDistance,
    required double endDistance,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/extrude-features'),
              headers: _headers,
              body: jsonEncode({
                'sketch_feature_id': sketchFeatureId,
                'extrude_type': extrudeType,
                'start_distance': startDistance,
                'end_distance': endDistance,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing ExtrudeFeature - any subset of
  /// [extrudeType]/[startDistance]/[endDistance] may be supplied, mirroring
  /// the backend's `ExtrudeFeatureUpdate` (omitted fields keep their
  /// current value). Used for the live-preview debounced re-solve.
  Future<FeatureDto> updateExtrudeFeature(
    String partId,
    String featureId, {
    String? extrudeType,
    double? startDistance,
    double? endDistance,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/extrude-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (extrudeType != null) 'extrude_type': extrudeType,
                if (startDistance != null) 'start_distance': startDistance,
                if (endDistance != null) 'end_distance': endDistance,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  Future<void> deleteFeature(String partId, String featureId) => _send(
        () => _httpClient.delete(_uri('/document/parts/$partId/features/$featureId'), headers: _headers),
        (_) {},
      );

  /// Deletes [featureId] and every Feature after it in the Part's ordered
  /// list (plus each deleted SketchFeature's underlying Sketch) - distinct
  /// from [deleteFeature], which only ever removes a single, unlocked,
  /// last Feature. Callers must confirm with the user before calling this:
  /// it has no single-Feature mode.
  Future<CascadeDeleteResultDto> cascadeDeleteFeature(String partId, String featureId) => _send(
        () => _httpClient.delete(
              _uri('/document/parts/$partId/features/$featureId/cascade'),
              headers: _headers,
            ),
        (body) => CascadeDeleteResultDto.fromJson(body as Map<String, dynamic>),
      );

  Future<PartMeshDto> getPartMesh(String partId) => _send(
        () => _httpClient.get(_uri('/document/parts/$partId/mesh'), headers: _headers),
        (body) => PartMeshDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
