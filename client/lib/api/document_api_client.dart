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

/// C2: the wire (JSON) counterpart to the backend's `SubShapeRefSchema` -
/// `{body_id, shape_type, index}`. Plain data, `toJson`/`fromJson` only -
/// this is a value type sent/received as-is, no client-side resolution
/// logic of its own (that's the backend's job).
class SubShapeRefDto {
  final String bodyId;
  final String shapeType;
  final int index;

  const SubShapeRefDto({required this.bodyId, required this.shapeType, required this.index});

  factory SubShapeRefDto.fromJson(Map<String, dynamic> json) => SubShapeRefDto(
        bodyId: json['body_id'] as String,
        shapeType: json['shape_type'] as String,
        index: json['index'] as int,
      );

  Map<String, dynamic> toJson() => {'body_id': bodyId, 'shape_type': shapeType, 'index': index};
}

/// C2: the wire counterpart to the backend's `SketchEntityRefSchema` (C1's
/// `SketchEntityRef`) - `{sketch_id, entity_type, entity_id}`. Note
/// [sketchId] is the real `app.sketch.models.Sketch` id, not a Feature id -
/// see `SelectionEntityRef.sketchFeatureId`'s own doc comment for why those
/// two are different ids that `PartScreen` has to translate between.
class SketchEntityRefDto {
  final String sketchId;
  final String entityType;
  final String entityId;

  const SketchEntityRefDto({required this.sketchId, required this.entityType, required this.entityId});

  factory SketchEntityRefDto.fromJson(Map<String, dynamic> json) => SketchEntityRefDto(
        sketchId: json['sketch_id'] as String,
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
      );

  Map<String, dynamic> toJson() => {
        'sketch_id': sketchId,
        'entity_type': entityType,
        'entity_id': entityId,
      };
}

/// C4: the wire counterpart to the backend's `PointRefSchema` - exactly one
/// of [vertexRef]/[sketchPointRef] should be supplied (a Body vertex or a
/// Sketch Point), matching the backend `PointRef`'s own "one of two optional
/// fields" convention. Used by THREE_POINTS' `point_refs`, letting a single
/// Feature mix Body vertices and Sketch Points freely.
class PointRefDto {
  final SubShapeRefDto? vertexRef;
  final SketchEntityRefDto? sketchPointRef;

  const PointRefDto({this.vertexRef, this.sketchPointRef});

  factory PointRefDto.fromJson(Map<String, dynamic> json) => PointRefDto(
        vertexRef: json['vertex_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['vertex_ref'] as Map<String, dynamic>),
        sketchPointRef: json['sketch_point_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['sketch_point_ref'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        if (vertexRef != null) 'vertex_ref': vertexRef!.toJson(),
        if (sketchPointRef != null) 'sketch_point_ref': sketchPointRef!.toJson(),
      };
}

/// C5: the wire counterpart to the backend's `PlaneRefSchema` - exactly one
/// of [faceRef]/[fixedPlane]/[planeFeatureId] should be supplied (a Body
/// face, a fixed reference plane, or an existing `CreatePlaneFeature`),
/// matching the backend `PlaneRef`'s own "one of three optional fields"
/// convention. Each `CreatePlaneFeature.face_refs` entry (OFFSET_FACE/
/// MIDPLANE/PARALLEL_TO_FACE_THROUGH_VERTEX) is now one of these, not a
/// bare [SubShapeRefDto], so a Plane can be built from another Plane or a
/// fixed reference plane, not just a Body face.
class PlaneRefDto {
  final SubShapeRefDto? faceRef;
  final String? fixedPlane;
  final String? planeFeatureId;

  const PlaneRefDto({this.faceRef, this.fixedPlane, this.planeFeatureId});

  factory PlaneRefDto.fromJson(Map<String, dynamic> json) => PlaneRefDto(
        faceRef: json['face_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['face_ref'] as Map<String, dynamic>),
        fixedPlane: json['fixed_plane'] as String?,
        planeFeatureId: json['plane_feature_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (faceRef != null) 'face_ref': faceRef!.toJson(),
        if (fixedPlane != null) 'fixed_plane': fixedPlane,
        if (planeFeatureId != null) 'plane_feature_id': planeFeatureId,
      };
}

/// A Feature in a Part's history - a SketchFeature, an ExtrudeFeature, or
/// (C2) a CreatePlaneFeature, distinguished by [type] (the same
/// discriminator the backend's `FeatureResponse` union uses). [sketchId] is
/// only present on a `"sketch"` Feature (as is, since C3, [planeFeatureId]);
/// [sketchFeatureId]/[extrudeType]/[startDistance]/[endDistance] only on an
/// `"extrude"` one; [planeType]/[faceRefs]/[offset]/[lineRef]/[pointRef]/
/// [origin]/[normal]/[xAxis]/[yAxis] only on a `"create_plane"` one - kept
/// as one DTO (rather than three separate classes) since most call sites
/// (the Feature tree, the long-press menu) only care about [id]/[type]/
/// [locked] regardless of which kind a row is.
class FeatureDto {
  final String type;
  final String id;
  final bool locked;
  final String? sketchId;
  final String? sketchFeatureId;
  final String? extrudeType;
  final double? startDistance;
  final double? endDistance;

  /// C3: only present on a `"sketch"` Feature - the id of the
  /// CreatePlaneFeature this Sketch is anchored to, or null when it lives on
  /// one of the three fixed reference planes instead (the common case).
  final String? planeFeatureId;

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

  /// C2/C3: `"offset_face"`, `"normal_to_line_at_point"`, or (C3)
  /// `"midplane"` - only present on a `"create_plane"` Feature.
  final String? planeType;

  /// C2/C3/C5: `"offset_face"` has exactly one entry, `"midplane"` (C3) has
  /// exactly two, `"normal_to_line_at_point"` has none - see the backend's
  /// `CreatePlaneFeature.face_refs` (C3 generalized the old singular
  /// `face_ref` into this list so MIDPLANE could reuse the same field; C5
  /// generalized each entry from a bare [SubShapeRefDto] to a [PlaneRefDto]
  /// so it can name a Body face, a fixed reference plane, or an existing
  /// Plane).
  final List<PlaneRefDto> faceRefs;
  final double? offset;
  final SketchEntityRefDto? lineRef;
  final SketchEntityRefDto? pointRef;

  /// C4: only present on a `"create_plane"` Feature whose [planeType] is
  /// `"normal_to_edge_through_vertex"` ([edgeRef] + [vertexRef]) or
  /// `"parallel_to_face_through_vertex"` ([faceRefs] one entry + [vertexRef]).
  final SubShapeRefDto? edgeRef;
  final SubShapeRefDto? vertexRef;

  /// C4: only present (with exactly three entries) on a `"create_plane"`
  /// Feature whose [planeType] is `"three_points"`.
  final List<PointRefDto> pointRefs;

  /// C2: the resolved world-space plane geometry (see the backend's
  /// `ResolvedPlane`) - `[x, y, z]` triples, null whenever the backend
  /// couldn't currently resolve this Plane (e.g. its reference went stale -
  /// see `CreatePlaneFeatureResponse`'s own doc comment), never both-or-
  /// neither with the other (always both null or both non-null together).
  final List<double>? origin;
  final List<double>? normal;

  /// C3: the plane's own in-plane basis (see the backend's `ResolvedPlane.
  /// x_axis`/`y_axis`) - the exact orientation a Sketch anchored to this
  /// Plane embeds its local (x, y) geometry through, and what the viewport
  /// uses to orient the rendered quad consistently with that embedding.
  /// Null exactly when [origin]/[normal] are.
  final List<double>? xAxis;
  final List<double>? yAxis;

  /// Prompt D: only present on a `"fillet"` Feature - which Body edges it
  /// rounds (the backend's `FilletFeature.edge_refs`). A plain list of
  /// [SubShapeRefDto], never a [PlaneRefDto] - a Fillet only ever
  /// references Body edges, never a plane-like thing.
  final List<SubShapeRefDto> edgeRefs;

  /// Prompt D: only present on a `"fillet"` Feature - the shared radius
  /// applied to every one of [edgeRefs].
  final double? radius;

  /// Prompt E: only present on a `"chamfer"` Feature - the shared distance
  /// applied to every one of [edgeRefs]. A Chamfer reuses [edgeRefs] itself
  /// (never its own separate field) since a Feature is only ever one type
  /// at a time - mirrors how [radius]/[distance] are the only two fields
  /// that actually differ between Fillet's and Chamfer's wire shape.
  final double? distance;

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
    this.planeFeatureId,
    this.planeType,
    this.faceRefs = const [],
    this.offset,
    this.lineRef,
    this.pointRef,
    this.edgeRef,
    this.vertexRef,
    this.pointRefs = const [],
    this.origin,
    this.normal,
    this.xAxis,
    this.yAxis,
    this.edgeRefs = const [],
    this.radius,
    this.distance,
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
        planeFeatureId: json['plane_feature_id'] as String?,
        planeType: json['plane_type'] as String?,
        faceRefs: (json['face_refs'] as List?)
                ?.map((r) => PlaneRefDto.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        offset: (json['offset'] as num?)?.toDouble(),
        lineRef: json['line_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['line_ref'] as Map<String, dynamic>),
        pointRef: json['point_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['point_ref'] as Map<String, dynamic>),
        edgeRef: json['edge_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['edge_ref'] as Map<String, dynamic>),
        vertexRef: json['vertex_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['vertex_ref'] as Map<String, dynamic>),
        pointRefs: (json['point_refs'] as List?)
                ?.map((r) => PointRefDto.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        origin: (json['origin'] as List?)?.map((v) => (v as num).toDouble()).toList(),
        normal: (json['normal'] as List?)?.map((v) => (v as num).toDouble()).toList(),
        xAxis: (json['x_axis'] as List?)?.map((v) => (v as num).toDouble()).toList(),
        yAxis: (json['y_axis'] as List?)?.map((v) => (v as num).toDouble()).toList(),
        edgeRefs: (json['edge_refs'] as List?)
                ?.map((r) => SubShapeRefDto.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        radius: (json['radius'] as num?)?.toDouble(),
        distance: (json['distance'] as num?)?.toDouble(),
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
  // On-device feedback: faceEdgeIds[faceId] is the sorted list of edgeIds
  // bounding that face - lets the Fillet flow offer "tap a face to select
  // its whole edge loop" (see PartScreen._toggleFilletFaceEdges). Defaults
  // to const [] for the same backward-compatibility reason as the ids
  // above.
  final List<List<int>> faceEdgeIds;

  MeshDto({
    required this.vertices,
    required this.normals,
    required this.triangleIndices,
    this.edges = const [],
    this.faceIds = const [],
    this.edgeIds = const [],
    this.topologyVertices = const [],
    this.topologyVertexIds = const [],
    this.faceEdgeIds = const [],
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
        faceEdgeIds: (json['face_edge_ids'] as List?)
                ?.map((ids) => (ids as List).map((v) => v as int).toList())
                .toList() ??
            const [],
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
///
/// On-device follow-up (post hide/rollback bug fix): [hidden] is the
/// client's own plain Hide/Show state, echoed back rather than used to
/// drop the entry - every Body always has an entry here now, hidden or
/// not, so the Build Tree's Bodies section can keep listing (and offering
/// Show again for) a hidden one. `PartScreen` is responsible for excluding
/// a [hidden] entry from the 3D viewport/camera-fit itself; this DTO just
/// carries the flag through. Always `false` for the `source: "placeholder"`
/// case - there is nothing to hide yet at that point.
class BodyMeshDto {
  final String bodyId;
  final String source;
  final MeshDto mesh;
  final bool hidden;

  BodyMeshDto({
    required this.bodyId,
    required this.source,
    required this.mesh,
    this.hidden = false,
  });

  factory BodyMeshDto.fromJson(Map<String, dynamic> json) => BodyMeshDto(
        bodyId: json['body_id'] as String,
        source: json['source'] as String,
        mesh: MeshDto.fromJson(json['mesh'] as Map<String, dynamic>),
        hidden: json['hidden'] as bool? ?? false,
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

  /// C3: exactly one of [plane] or [planeFeatureId] should be supplied - a
  /// fixed reference plane, or an existing CreatePlaneFeature's id to anchor
  /// this Sketch to instead (see the backend's
  /// `_validate_sketch_feature_payload`, which enforces the combination and
  /// that [planeFeatureId] resolves to a real, currently-resolvable Plane).
  /// [plane] defaults to `'XY'` for every pre-C3 call site that never passes
  /// [planeFeatureId] - passing both, or neither, is rejected server-side.
  Future<FeatureDto> createSketchFeature(String partId, {String? plane = 'XY', String? planeFeatureId}) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/features/sketch'),
              headers: _headers,
              body: jsonEncode({
                if (planeFeatureId != null) 'plane_feature_id': planeFeatureId else 'plane': plane,
              }),
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

  /// Prompt D: creates a FilletFeature - rounds every edge in [edgeRefs]
  /// (all must belong to the same Body) with one shared [radius]. The
  /// backend validates payload shape and resolvability before persisting
  /// (`mixed_body_selection`/`fillet_failed`/`missing_reference` on
  /// failure - see `app.document.router.create_fillet_feature`), this
  /// method just serializes whatever it's given.
  Future<FeatureDto> createFilletFeature(
    String partId, {
    required List<SubShapeRefDto> edgeRefs,
    required double radius,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/fillet-features'),
              headers: _headers,
              body: jsonEncode({
                'edge_refs': edgeRefs.map((r) => r.toJson()).toList(),
                'radius': radius,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing FilletFeature - either/both of
  /// [edgeRefs]/[radius] may be supplied; omitted fields keep their
  /// current value. Used for the live-preview debounced re-solve, same
  /// pattern as [updateExtrudeFeature].
  Future<FeatureDto> updateFilletFeature(
    String partId,
    String featureId, {
    List<SubShapeRefDto>? edgeRefs,
    double? radius,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/fillet-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (edgeRefs != null) 'edge_refs': edgeRefs.map((r) => r.toJson()).toList(),
                if (radius != null) 'radius': radius,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Prompt E: creates a ChamferFeature - mirrors [createFilletFeature]
  /// exactly, substituting [distance] for `radius` (`mixed_body_selection`/
  /// `chamfer_failed`/`missing_reference` on failure - see
  /// `app.document.router.create_chamfer_feature`).
  Future<FeatureDto> createChamferFeature(
    String partId, {
    required List<SubShapeRefDto> edgeRefs,
    required double distance,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/chamfer-features'),
              headers: _headers,
              body: jsonEncode({
                'edge_refs': edgeRefs.map((r) => r.toJson()).toList(),
                'distance': distance,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing ChamferFeature - mirrors
  /// [updateFilletFeature] exactly.
  Future<FeatureDto> updateChamferFeature(
    String partId,
    String featureId, {
    List<SubShapeRefDto>? edgeRefs,
    double? distance,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/chamfer-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (edgeRefs != null) 'edge_refs': edgeRefs.map((r) => r.toJson()).toList(),
                if (distance != null) 'distance': distance,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// C2/C3/C4/C5: creates a CreatePlaneFeature of any of the six
  /// `planeType`s - exactly one combination of ([faceRefs], [offset])
  /// [OFFSET_FACE: one entry; MIDPLANE: two], ([lineRef], [pointRef]),
  /// ([edgeRef], [vertexRef]), ([faceRefs] one entry, [vertexRef]), or
  /// ([pointRefs], three entries) should be supplied, matching [planeType];
  /// the backend validates this combination and rejects a malformed one
  /// (see `_validate_create_plane_payload`), this method just serializes
  /// whatever it's given. Each [faceRefs] entry is a [PlaneRefDto] (C5) - a
  /// Body face, a fixed reference plane, or an existing Plane.
  Future<FeatureDto> createCreatePlaneFeature(
    String partId, {
    required String planeType,
    List<PlaneRefDto> faceRefs = const [],
    double? offset,
    SketchEntityRefDto? lineRef,
    SketchEntityRefDto? pointRef,
    SubShapeRefDto? edgeRef,
    SubShapeRefDto? vertexRef,
    List<PointRefDto> pointRefs = const [],
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/create-plane-features'),
              headers: _headers,
              body: jsonEncode({
                'plane_type': planeType,
                if (faceRefs.isNotEmpty) 'face_refs': faceRefs.map((r) => r.toJson()).toList(),
                if (offset != null) 'offset': offset,
                if (lineRef != null) 'line_ref': lineRef.toJson(),
                if (pointRef != null) 'point_ref': pointRef.toJson(),
                if (edgeRef != null) 'edge_ref': edgeRef.toJson(),
                if (vertexRef != null) 'vertex_ref': vertexRef.toJson(),
                if (pointRefs.isNotEmpty) 'point_refs': pointRefs.map((r) => r.toJson()).toList(),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing CreatePlaneFeature - same omitted-vs-
  /// current-value convention as [updateExtrudeFeature]; `plane_type`
  /// itself is never sent (see the backend's `CreatePlaneFeatureUpdate`).
  Future<FeatureDto> updateCreatePlaneFeature(
    String partId,
    String featureId, {
    List<PlaneRefDto>? faceRefs,
    double? offset,
    SketchEntityRefDto? lineRef,
    SketchEntityRefDto? pointRef,
    SubShapeRefDto? edgeRef,
    SubShapeRefDto? vertexRef,
    List<PointRefDto>? pointRefs,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/create-plane-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (faceRefs != null) 'face_refs': faceRefs.map((r) => r.toJson()).toList(),
                if (offset != null) 'offset': offset,
                if (lineRef != null) 'line_ref': lineRef.toJson(),
                if (pointRef != null) 'point_ref': pointRef.toJson(),
                if (edgeRef != null) 'edge_ref': edgeRef.toJson(),
                if (vertexRef != null) 'vertex_ref': vertexRef.toJson(),
                if (pointRefs != null) 'point_refs': pointRefs.map((r) => r.toJson()).toList(),
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

  /// Bug fix (post-C4): [hiddenFeatureIds] and [rollbackExcludedFeatureIds]
  /// are two deliberately separate sets, both re-sent on every fetch, both
  /// purely client-side and never persisted on the backend - see
  /// `app.document.router.get_part_mesh`'s own docstring for the full
  /// incident writeup of why conflating them (as this method originally
  /// did, under the single `hiddenFeatureIds` name) broke Create Plane.
  ///
  /// [hiddenFeatureIds] is `PartScreen._hiddenFeatureIds` - plain Hide/Show,
  /// purely cosmetic: every Body is still fully computed against the
  /// Part's real, unmodified history, so a Plane anchored to a hidden
  /// Body's face (and anything built on that Plane) keeps resolving
  /// normally; a hidden Body is just dropped from *this response*
  /// afterward.
  ///
  /// [rollbackExcludedFeatureIds] is B4 true-rollback's own "pretend these
  /// Features (and hence anything depending on them) don't exist yet"
  /// state (`PartScreen._rollbackExcludedFeatureIds`) - still genuinely
  /// excluded from the backend's recompute, so a downstream Feature
  /// correctly fails to resolve if what it depends on is being edited out
  /// from under it.
  ///
  /// Both are encoded as repeated query parameters
  /// (`?hidden_feature_ids=a&rollback_excluded_feature_ids=b`) matching
  /// FastAPI's `Query(default=[])` parsing on the other end.
  ///
  /// Prompt A3: parses the array-of-Bodies response Prompt A1 introduced -
  /// the top-level JSON is now a `List`, not a single object.
  Future<List<BodyMeshDto>> getPartMesh(
    String partId, {
    List<String> hiddenFeatureIds = const [],
    List<String> rollbackExcludedFeatureIds = const [],
  }) =>
      _send(
        () => _httpClient.get(
              _uri('/document/parts/$partId/mesh').replace(
                queryParameters: hiddenFeatureIds.isEmpty && rollbackExcludedFeatureIds.isEmpty
                    ? null
                    : {
                        if (hiddenFeatureIds.isNotEmpty) 'hidden_feature_ids': hiddenFeatureIds,
                        if (rollbackExcludedFeatureIds.isNotEmpty)
                          'rollback_excluded_feature_ids': rollbackExcludedFeatureIds,
                      },
              ),
              headers: _headers,
            ),
        (body) =>
            (body as List).map((b) => BodyMeshDto.fromJson(b as Map<String, dynamic>)).toList(),
      );

  void close() => _httpClient.close();
}
