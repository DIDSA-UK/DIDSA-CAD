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

  /// Prompt A4: only present on an `"extrude"` Feature - which existing
  /// Bodies (by id) this one combines with, per A1's `target_body_ids`.
  /// Defaults to `[]` (matching the backend's `ExtrudeFeatureResponse`
  /// default) rather than being nullable, since it's always present on an
  /// extrude Feature and simply meaningless (never read) on a sketch one.
  final List<String> targetBodyIds;

  /// B1: what this Feature contributes - `"body"`/`"plane"`/`"surface"`/
  /// `"sketch"`/`"none"` (see backend `app.document.models.Produces`) -
  /// used by B3's feature-tree grouping (`groupFeaturesByProduces`). Kept as
  /// the raw backend string (like [type]/[extrudeType] already are) rather
  /// than a Dart enum, matching this DTO's existing convention. Defaults to
  /// `"none"` for any fixture/fake response built before B1 that omits the
  /// key entirely.
  final String produces;

  FeatureDto({
    required this.type,
    required this.id,
    required this.locked,
    this.sketchId,
    this.sketchFeatureId,
    this.extrudeType,
    this.startDistance,
    this.endDistance,
    this.targetBodyIds = const [],
    this.produces = 'none',
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
        targetBodyIds: (json['target_body_ids'] as List?)?.cast<String>() ?? const [],
        produces: json['produces'] as String? ?? 'none',
      );
}

/// A flat, JSON-shaped mesh: each of [vertices]/[normals] is a list of
/// `[x, y, z]` triples (parallel, same length), each entry in
/// [triangleIndices] is an `[a, b, c]` index triple into both, and [edges]
/// is a flat `[x1,y1,z1, x2,y2,z2, ...]` array of real OCCT edge polyline
/// segments (Stage 11 - see backend/app/document/mesh.py's
/// `_extract_edges`), independent of the triangle data above.
class MeshDto {
  final List<List<double>> vertices;
  final List<List<double>> normals;
  final List<List<int>> triangleIndices;
  final List<double> edges;
  // Stage 23: stable per-triangle/per-edge-segment/per-topology-vertex ids -
  // foundation for the 3D viewport's selection mode hit-testing. Default to
  // const [] for backward compatibility with fixtures/fakes that predate
  // this stage and omit these keys entirely (same pattern as `edges` above).
  final List<int> faceIds;
  final List<int> edgeIds;
  final List<List<double>> topologyVertices;
  final List<int> topologyVertexIds;

  MeshDto({
    required this.vertices,
    required this.normals,
    required this.triangleIndices,
    this.edges = const [],
    this.faceIds = const [],
    this.edgeIds = const [],
    this.topologyVertices = const [],
    this.topologyVertexIds = const [],
  });

  factory MeshDto.fromJson(Map<String, dynamic> json) => MeshDto(
        vertices: _triples(json['vertices'] as List),
        normals: _triples(json['normals'] as List),
        triangleIndices: (json['triangle_indices'] as List)
            .map((t) => (t as List).map((v) => v as int).toList())
            .toList(),
        // Defaults to empty rather than required: older fixtures/fakes in
        // tests predate Stage 11 and omit this key entirely.
        edges: (json['edges'] as List?)?.map((v) => (v as num).toDouble()).toList() ?? const [],
        faceIds: (json['face_ids'] as List?)?.map((v) => v as int).toList() ?? const [],
        edgeIds: (json['edge_ids'] as List?)?.map((v) => v as int).toList() ?? const [],
        topologyVertices: json['topology_vertices'] == null
            ? const []
            : _triples(json['topology_vertices'] as List),
        topologyVertexIds:
            (json['topology_vertex_ids'] as List?)?.map((v) => v as int).toList() ?? const [],
      );

  static List<List<double>> _triples(List raw) =>
      raw.map((t) => (t as List).map((v) => (v as num).toDouble()).toList()).toList();
}

/// Prompt A3: one entry of `GET /mesh`'s response, which the backend
/// (Prompt A1) changed from a single combined `{source, mesh}` object to a
/// JSON array of these - one per independently-tessellated Body, or a
/// single `source: "placeholder"` entry while the Part has no
/// ExtrudeFeature yet. [bodyId] is the stable, deterministic Body id (see
/// the backend's `ExtrudeFeature` docstring) - stable across recomputes as
/// long as the Body isn't merged into another. [mesh]'s `faceIds`/
/// `edgeIds`/`topologyVertexIds` are only unique *within* this one Body's
/// own tessellation, not globally across the array - see
/// `SelectionEntityRef.bodyId` for how the client keeps hit-test entities
/// globally unique despite that.
class BodyMeshDto {
  final String bodyId;
  final String source;
  final MeshDto mesh;

  BodyMeshDto({required this.bodyId, required this.source, required this.mesh});

  factory BodyMeshDto.fromJson(Map<String, dynamic> json) => BodyMeshDto(
        bodyId: json['body_id'] as String,
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

  /// Prompt A4: [targetBodyIds] names which existing Body/Bodies (by id)
  /// this Extrude combines with - see A1's `ExtrudeFeatureCreate.target_body_ids`
  /// docstring (Boss: empty starts a brand-new Body; Cut: must be non-empty).
  Future<FeatureDto> createExtrudeFeature(
    String partId, {
    required String sketchFeatureId,
    required String extrudeType,
    required double startDistance,
    required double endDistance,
    List<String> targetBodyIds = const [],
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
                'target_body_ids': targetBodyIds,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing ExtrudeFeature - any subset of
  /// [extrudeType]/[startDistance]/[endDistance]/[targetBodyIds] may be
  /// supplied, mirroring the backend's `ExtrudeFeatureUpdate` (omitted
  /// fields keep their current value - [targetBodyIds] null omits it,
  /// matching the others, so a live-preview re-solve that never touched
  /// target-body picking doesn't accidentally clear it). Used for the
  /// live-preview debounced re-solve.
  Future<FeatureDto> updateExtrudeFeature(
    String partId,
    String featureId, {
    String? extrudeType,
    double? startDistance,
    double? endDistance,
    List<String>? targetBodyIds,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/extrude-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (extrudeType != null) 'extrude_type': extrudeType,
                if (startDistance != null) 'start_distance': startDistance,
                if (endDistance != null) 'end_distance': endDistance,
                if (targetBodyIds != null) 'target_body_ids': targetBodyIds,
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

  /// [hiddenFeatureIds] is re-sent on every fetch (see
  /// `PartScreen._hiddenFeatureIds`) - purely client-side Hide/Show state,
  /// never persisted on the backend - and is encoded as a repeated query
  /// parameter (`?hidden_feature_ids=a&hidden_feature_ids=b`) matching
  /// FastAPI's `Query(default=[])` parsing on the other end.
  ///
  /// Prompt A3: parses the array-of-Bodies response Prompt A1 introduced -
  /// the top-level JSON is now a `List`, not a single object.
  Future<List<BodyMeshDto>> getPartMesh(String partId, {List<String> hiddenFeatureIds = const []}) =>
      _send(
        () => _httpClient.get(
              _uri('/document/parts/$partId/mesh').replace(
                queryParameters:
                    hiddenFeatureIds.isEmpty ? null : {'hidden_feature_ids': hiddenFeatureIds},
              ),
              headers: _headers,
            ),
        (body) =>
            (body as List).map((b) => BodyMeshDto.fromJson(b as Map<String, dynamic>)).toList(),
      );

  void close() => _httpClient.close();
}
