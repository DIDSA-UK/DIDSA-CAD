import 'dart:convert';
import 'dart:typed_data';

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

/// Pattern/Mirror scoping's Phase 2: the wire counterpart to the backend's
/// `PatternDirectionRefSchema` - exactly one of [edgeRef]/[sketchLineRef]/
/// [fixedAxis] should be supplied (a straight Body edge, a straight Sketch
/// Line, or a fixed world X/Y/Z axis), matching [PlaneRefDto]'s own "one of
/// three optional fields" convention.
class PatternDirectionRefDto {
  final SubShapeRefDto? edgeRef;
  final SketchEntityRefDto? sketchLineRef;
  final String? fixedAxis;

  const PatternDirectionRefDto({this.edgeRef, this.sketchLineRef, this.fixedAxis});

  factory PatternDirectionRefDto.fromJson(Map<String, dynamic> json) => PatternDirectionRefDto(
        edgeRef: json['edge_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['edge_ref'] as Map<String, dynamic>),
        sketchLineRef: json['sketch_line_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['sketch_line_ref'] as Map<String, dynamic>),
        fixedAxis: json['fixed_axis'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (edgeRef != null) 'edge_ref': edgeRef!.toJson(),
        if (sketchLineRef != null) 'sketch_line_ref': sketchLineRef!.toJson(),
        if (fixedAxis != null) 'fixed_axis': fixedAxis,
      };
}

/// Pattern/Mirror scoping's Phase 4: the wire counterpart to the backend's
/// `PatternAxisRefSchema` - exactly one of [edgeRef]/[faceRef]/
/// [sketchLineRef] should be supplied (a circular Body edge, a cylindrical
/// Body face, or a Sketch Line), matching [PatternDirectionRefDto]'s own
/// "one of three optional fields" convention.
class PatternAxisRefDto {
  final SubShapeRefDto? edgeRef;
  final SubShapeRefDto? faceRef;
  final SketchEntityRefDto? sketchLineRef;

  const PatternAxisRefDto({this.edgeRef, this.faceRef, this.sketchLineRef});

  factory PatternAxisRefDto.fromJson(Map<String, dynamic> json) => PatternAxisRefDto(
        edgeRef: json['edge_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['edge_ref'] as Map<String, dynamic>),
        faceRef: json['face_ref'] == null
            ? null
            : SubShapeRefDto.fromJson(json['face_ref'] as Map<String, dynamic>),
        sketchLineRef: json['sketch_line_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['sketch_line_ref'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        if (edgeRef != null) 'edge_ref': edgeRef!.toJson(),
        if (faceRef != null) 'face_ref': faceRef!.toJson(),
        if (sketchLineRef != null) 'sketch_line_ref': sketchLineRef!.toJson(),
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
/// Pattern/Mirror scoping's Phase 5 (`docs/pattern-mirror-scope.md`
/// §2.10/§4): whether a Mirror/Pattern Feature's realized instances stay
/// independent Bodies or get fused together into one - shared by both
/// [MirrorPanel] and [PatternPanel] (unlike [RevolveMode]/[PatternMode],
/// which each pick between two entirely different field groups, this is a
/// simple two-way toggle both Feature types share verbatim, so it lives
/// here rather than being duplicated per-panel). Mirrors [PatternMode]'s
/// own `apiValue`/`fromApiValue` str-enum convention, matching the
/// backend's `MergeMode` string values exactly.
enum MergeMode {
  keepSeparate,
  fuseIntoOne;

  String get apiValue => switch (this) {
        MergeMode.keepSeparate => 'keep_separate',
        MergeMode.fuseIntoOne => 'fuse_into_one',
      };

  static MergeMode fromApiValue(String value) =>
      MergeMode.values.firstWhere((m) => m.apiValue == value, orElse: () => MergeMode.keepSeparate);
}

/// Pattern/Mirror scoping's Phase 9 (`docs/pattern-mirror-scope.md` §2.12/§4):
/// which of a Feature's own two mutually-exclusive seed fields a long-press
/// "Pattern"/"Mirror" entry currently seeds through - [body] sends the
/// long-pressed Feature's id via `source_feature_ids` (patterns/mirrors the
/// Bodies it produces), [feature] sends it via `tool_feature_id` (repeats/
/// reflects its own Cut/Boss effect into its own shared target instead).
/// Shared by [PatternPanel.seedKind]/[MirrorPanel.seedKind] - a simple
/// two-way toggle both panels show verbatim, the same "not worth
/// duplicating per panel" reasoning [MergeMode] above already established.
enum PatternMirrorSeedKind { body, feature }

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

  /// Prompt F: only present on a `"revolve"` Feature - the Sketch Line
  /// reference the Profile is revolved around. Not required to belong to
  /// the same Sketch as [sketchFeatureId] (confirmed decision - see the
  /// backend's `RevolveFeature` docstring).
  final SketchEntityRefDto? axisRef;

  /// Prompt F: only present on a `"revolve"` Feature - the sweep angle in
  /// degrees, `(0, 360]`.
  final double? angle;

  /// Prompt F: only present on a `"revolve"` Feature - `"boss"`/`"cut"`,
  /// the same string convention [extrudeType] already uses (Boss/Cut parity
  /// with Extrude is this Feature's own resolved design decision).
  final String? mode;

  /// Prompt G: present on `"extrude"`/`"revolve"`/`"sweep"` Features - which
  /// outer profile(s) of the backing Sketch to use, each anchored by a
  /// Line/Circle entity known to belong to it. Empty (the default) means
  /// every outer profile currently detected, matching the backend's own
  /// `ExtrudeFeature.profile_refs`/`RevolveFeature.profile_refs`/
  /// `SweepFeature.profile_refs` default.
  final List<SketchEntityRefDto> profileRefs;

  /// Only present on a `"sweep"` Feature - the *ordered* list of Sketch Line
  /// references the Profile is swept along, each possibly naming a
  /// different Sketch (confirmed decision - see the backend's
  /// `SweepFeature` docstring). Order matters (it is the path's own
  /// traversal order); unlike [axisRef] this is a list, since a Sweep's
  /// path can bend across multiple segments rather than being a single
  /// straight reference.
  final List<SketchEntityRefDto> pathRefs;

  /// Sketcher-roadmap Phase 4.3 v1: only meaningful on a `"sketch"`
  /// Feature - true whenever at least one of its Sketch's external Body-
  /// vertex references no longer resolves (see the backend's
  /// `SketchFeatureResponse.has_lost_reference`'s own doc comment).
  /// Defaults to `false`, matching the backend's own default for a Sketch
  /// with no external references, or any Feature type that predates this
  /// field entirely.
  final bool hasLostReference;

  /// Pattern/Mirror scoping's Phase 1/6 - present on both `"mirror"` and
  /// `"pattern"` Features: which Body/Bodies (by id) are being reflected/
  /// repeated (the backend's `MirrorFeature`/`PatternFeature.source_
  /// body_ids` - 1+ entries as of Phase 1's own multi-body revision for
  /// Mirror and Phase 6's for Pattern - see `docs/pattern-mirror-scope.md`).
  final List<String> sourceBodyIds;

  /// Pattern/Mirror scoping's Phase 6 - present on both `"mirror"` and
  /// `"pattern"` Features: Feature-tree entries (by Feature id) named as
  /// additional sources, resolved server-side to their current output
  /// Body/Bodies and combined with [sourceBodyIds] (the backend's
  /// `MirrorFeature`/`PatternFeature.source_feature_ids`).
  final List<String> sourceFeatureIds;

  /// Pattern/Mirror scoping's Phase 1 - only present on a `"mirror"`
  /// Feature: the plane it's mirrored across (a Body face, a fixed
  /// reference plane, or an existing Plane - reuses [PlaneRefDto] verbatim,
  /// the same type `faceRefs` entries already use).
  final PlaneRefDto? mirrorPlane;

  /// Pattern/Mirror scoping's Phase 2 - only present on a `"pattern"`
  /// Feature: the first (required) repeat direction (a straight Body edge,
  /// a straight Sketch Line, or a fixed world axis - see
  /// [PatternDirectionRefDto]), how many instances ([count1]) [spacing1]
  /// apart, optionally flipped ([reverse1]).
  final PatternDirectionRefDto? direction1;
  final int? count1;
  final double? spacing1;
  final bool reverse1;

  /// Pattern/Mirror scoping's Phase 2 - only present (and only meaningful
  /// when [count2] > 1 - see the backend's `PatternFeature` docstring) on a
  /// `"pattern"` Feature: the optional second repeat direction for a 2D
  /// grid pattern, same shape as [direction1]/[count1]/[spacing1]/
  /// [reverse1].
  final PatternDirectionRefDto? direction2;
  final int count2;
  final double spacing2;
  final bool reverse2;

  /// Pattern/Mirror scoping's Phase 4 - only present on a `"pattern"`
  /// Feature: `"rectangular"` (the default) or `"circular"` - which of
  /// [direction1]/[direction2] (Rectangular) vs. [axis]/[countAngular]/
  /// [angleTotal]/[reverseAngular] (Circular) actually applies. Never
  /// revised by an edit (see the backend's `PatternFeatureUpdate` docstring
  /// - switching modes is a delete+recreate).
  final String? patternType;

  /// Pattern/Mirror scoping's Phase 4 - only present (and only meaningful
  /// when [patternType] is `"circular"`) on a `"pattern"` Feature: the axis
  /// to rotate around (a circular Body edge, a cylindrical Body face, or a
  /// Sketch Line - see [PatternAxisRefDto]).
  final PatternAxisRefDto? axis;
  final int countAngular;
  final double angleTotal;
  final bool reverseAngular;

  /// Pattern/Mirror scoping's Phase 3 - only present on a `"pattern"`
  /// Feature: linear indices (Rectangular's own `i * count_2 + j`, or
  /// Circular's own angular-step `i`) of instances suppressed rather than
  /// created - index `0` (the untouched seed) can never appear here.
  final List<int> skipIndices;

  /// Pattern/Mirror scoping's Phase 5 - present on both `"mirror"` and
  /// `"pattern"` Features: `"keep_separate"` (the default - every realized
  /// instance registers as its own Body) or `"fuse_into_one"` (every
  /// realized instance plus the original source Body/Bodies fused
  /// together via `BRepAlgoAPI_Fuse` - see the backend's `MergeMode`).
  /// Kept as the raw backend string here (like [mode]/[patternType]
  /// already are) - see [MergeMode] for the parsed Dart enum the panels
  /// themselves use.
  final String merge;

  /// Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
  /// §2.11/§4) - present on both `"mirror"` and `"pattern"` Features: a
  /// third, mutually-exclusive seed-picking mode naming an upstream
  /// Extrude/Revolve/Sweep Cut/Boss-into-target Feature instead of
  /// [sourceBodyIds]/[sourceFeatureIds]. Null for every ordinary Body-
  /// seeded Mirror/Pattern (the overwhelmingly common case) and for any
  /// Feature persisted before this field existed.
  final String? toolFeatureId;

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
    this.axisRef,
    this.angle,
    this.mode,
    this.profileRefs = const [],
    this.pathRefs = const [],
    this.hasLostReference = false,
    this.sourceBodyIds = const [],
    this.sourceFeatureIds = const [],
    this.mirrorPlane,
    this.direction1,
    this.count1,
    this.spacing1,
    this.reverse1 = false,
    this.direction2,
    this.count2 = 1,
    this.spacing2 = 0.0,
    this.reverse2 = false,
    this.patternType,
    this.axis,
    this.countAngular = 1,
    this.angleTotal = 360.0,
    this.reverseAngular = false,
    this.skipIndices = const [],
    this.merge = 'keep_separate',
    this.toolFeatureId,
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
        axisRef: json['axis_ref'] == null
            ? null
            : SketchEntityRefDto.fromJson(json['axis_ref'] as Map<String, dynamic>),
        angle: (json['angle'] as num?)?.toDouble(),
        mode: json['mode'] as String?,
        profileRefs: (json['profile_refs'] as List?)
                ?.map((r) => SketchEntityRefDto.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        pathRefs: (json['path_refs'] as List?)
                ?.map((r) => SketchEntityRefDto.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        hasLostReference: json['has_lost_reference'] as bool? ?? false,
        sourceBodyIds: (json['source_body_ids'] as List?)?.cast<String>() ?? const [],
        sourceFeatureIds: (json['source_feature_ids'] as List?)?.cast<String>() ?? const [],
        mirrorPlane: json['mirror_plane'] == null
            ? null
            : PlaneRefDto.fromJson(json['mirror_plane'] as Map<String, dynamic>),
        direction1: json['direction_1'] == null
            ? null
            : PatternDirectionRefDto.fromJson(json['direction_1'] as Map<String, dynamic>),
        count1: json['count_1'] as int?,
        spacing1: (json['spacing_1'] as num?)?.toDouble(),
        reverse1: json['reverse_1'] as bool? ?? false,
        direction2: json['direction_2'] == null
            ? null
            : PatternDirectionRefDto.fromJson(json['direction_2'] as Map<String, dynamic>),
        count2: json['count_2'] as int? ?? 1,
        spacing2: (json['spacing_2'] as num?)?.toDouble() ?? 0.0,
        reverse2: json['reverse_2'] as bool? ?? false,
        patternType: json['pattern_type'] as String?,
        axis: json['axis'] == null
            ? null
            : PatternAxisRefDto.fromJson(json['axis'] as Map<String, dynamic>),
        countAngular: json['count_angular'] as int? ?? 1,
        angleTotal: (json['angle_total'] as num?)?.toDouble() ?? 360.0,
        reverseAngular: json['reverse_angular'] as bool? ?? false,
        skipIndices: (json['skip_indices'] as List?)?.cast<int>() ?? const [],
        merge: json['merge'] as String? ?? 'keep_separate',
        toolFeatureId: json['tool_feature_id'] as String?,
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

/// What `POST /document/import/native` hands back once the full-replace
/// native-file import succeeds - the freshly-imported Document's id and
/// every Part id now in it. This app has no "pick an existing Part" UI (see
/// `PartScreen`'s own doc comment - a single Part is always created on
/// startup), so a native Open just points the current screen at
/// [partIds].first.
class NativeImportResultDto {
  final String documentId;
  final List<String> partIds;

  NativeImportResultDto({required this.documentId, required this.partIds});

  factory NativeImportResultDto.fromJson(Map<String, dynamic> json) => NativeImportResultDto(
        documentId: json['document_id'] as String,
        partIds: (json['part_ids'] as List).cast<String>(),
      );
}

/// `docs/gear-design/08-entry-screen-and-preview.md`: the wire counterpart
/// to the backend's `GearPreviewResponse` - [outlinePoints] is the full 2D
/// tooth-outline polyline (local frame, centred on the origin) the live
/// preview canvas draws directly; the rest are the reference-circle
/// overlay's own numbers. [pitchRadius]/[baseRadius]/[addendumRadius]/
/// [dedendumRadius]/[outerRadius] are only non-null for `gearKind`
/// `"external"`/`"internal"`; [pitchLineY]/[addendumLineY]/[dedendumLineY]/
/// [rackLength] only for `"rack"` - see the backend response's own doc
/// comment for why a rack has lines, not circles. [warnings] carries every
/// non-blocking `gear_math` validation (e.g. undercut risk) per
/// `00-conventions.md`'s validation-banner convention - a parameter
/// combination with no valid geometry at all is a 422 [ApiException]
/// instead, never a response with [warnings] set.
class GearPreviewDto {
  final String gearKind;
  final List<List<double>> outlinePoints;
  final double? pitchRadius;
  final double? baseRadius;
  final double? addendumRadius;
  final double? dedendumRadius;
  final double? outerRadius;
  final double? pitchLineY;
  final double? addendumLineY;
  final double? dedendumLineY;
  final double? rackLength;
  final List<String> warnings;

  GearPreviewDto({
    required this.gearKind,
    required this.outlinePoints,
    this.pitchRadius,
    this.baseRadius,
    this.addendumRadius,
    this.dedendumRadius,
    this.outerRadius,
    this.pitchLineY,
    this.addendumLineY,
    this.dedendumLineY,
    this.rackLength,
    this.warnings = const [],
  });

  factory GearPreviewDto.fromJson(Map<String, dynamic> json) => GearPreviewDto(
        gearKind: json['gear_kind'] as String,
        outlinePoints: (json['outline_points'] as List)
            .map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        pitchRadius: (json['pitch_radius'] as num?)?.toDouble(),
        baseRadius: (json['base_radius'] as num?)?.toDouble(),
        addendumRadius: (json['addendum_radius'] as num?)?.toDouble(),
        dedendumRadius: (json['dedendum_radius'] as num?)?.toDouble(),
        outerRadius: (json['outer_radius'] as num?)?.toDouble(),
        pitchLineY: (json['pitch_line_y'] as num?)?.toDouble(),
        addendumLineY: (json['addendum_line_y'] as num?)?.toDouble(),
        dedendumLineY: (json['dedendum_line_y'] as num?)?.toDouble(),
        rackLength: (json['rack_length'] as num?)?.toDouble(),
        warnings: (json['warnings'] as List?)?.cast<String>() ?? const [],
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

  /// Same request/error handling as [_send], but for an endpoint whose
  /// success body is raw binary (STEP/STL/glb) rather than JSON -
  /// [http.Response.bodyBytes] instead of [_send]'s `jsonDecode(response.
  /// body)`, which would corrupt or throw on arbitrary binary content.
  Future<Uint8List> _sendBytes(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request().timeout(ApiConfig.requestTimeout);
    } on Exception catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Server returned ${response.statusCode}: ${_detailOf(response)}');
    }
    return response.bodyBytes;
  }

  String _detailOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String) return detail;
        // Every gear/rack-feature (and now `/gear/preview`) failure uses a
        // structured `{"type": ..., "detail": "..."}` shape (see the
        // backend's `app.document.gear._invalid_gear_parameters` and its
        // siblings) rather than a plain string - surface the inner
        // human-readable detail instead of the raw dict.
        if (detail is Map<String, dynamic> && detail['detail'] is String) {
          return detail['detail'] as String;
        }
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
  ///
  /// Prompt G: [profileRefs] names which outer profile(s) of the Sketch to
  /// use - empty (the default) means every outer profile currently
  /// detected, matching the backend's own `ExtrudeFeatureCreate.
  /// profile_refs` default.
  Future<FeatureDto> createExtrudeFeature(
    String partId, {
    required String sketchFeatureId,
    required String extrudeType,
    required double startDistance,
    required double endDistance,
    List<String> targetBodyIds = const [],
    List<SketchEntityRefDto> profileRefs = const [],
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
                'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing ExtrudeFeature - any subset of
  /// [extrudeType]/[startDistance]/[endDistance]/[targetBodyIds]/
  /// [profileRefs] may be supplied, mirroring the backend's
  /// `ExtrudeFeatureUpdate` (omitted fields keep their current value -
  /// [targetBodyIds]/[profileRefs] null omits it, matching the others, so a
  /// live-preview re-solve that never touched target-body/profile picking
  /// doesn't accidentally clear it). Used for the live-preview debounced
  /// re-solve.
  Future<FeatureDto> updateExtrudeFeature(
    String partId,
    String featureId, {
    String? extrudeType,
    double? startDistance,
    double? endDistance,
    List<String>? targetBodyIds,
    List<SketchEntityRefDto>? profileRefs,
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
                if (profileRefs != null)
                  'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
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

  /// Pattern/Mirror scoping's Phase 1: creates a MirrorFeature reflecting
  /// [sourceBodyIds]' single Body (Phase 1 scope - see the backend's
  /// `_validate_mirror_source_body_ids`) across [mirrorPlane]. The backend
  /// validates payload shape and resolvability before persisting
  /// (`missing_reference`/`non_planar_reference`/`mirror_failed` on
  /// failure - see `app.document.router.create_mirror_feature`), this
  /// method just serializes whatever it's given, mirroring
  /// [createChamferFeature]'s own shape.
  Future<FeatureDto> createMirrorFeature(
    String partId, {
    required List<String> sourceBodyIds,
    required PlaneRefDto mirrorPlane,
    List<String> sourceFeatureIds = const [],
    MergeMode merge = MergeMode.keepSeparate,
    // Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
    // §2.11/§4): a third, mutually-exclusive seed-picking mode - see
    // `FeatureDto.toolFeatureId`'s own doc comment.
    String? toolFeatureId,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/mirror-features'),
              headers: _headers,
              body: jsonEncode({
                'source_body_ids': sourceBodyIds,
                'mirror_plane': mirrorPlane.toJson(),
                'source_feature_ids': sourceFeatureIds,
                'merge': merge.apiValue,
                if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing MirrorFeature - any of [sourceBodyIds]/
  /// [mirrorPlane]/[sourceFeatureIds]/[merge]/[toolFeatureId] may be
  /// supplied; omitted fields keep their current value. Used for the
  /// live-preview debounced re-solve, same pattern as [updateFilletFeature].
  Future<FeatureDto> updateMirrorFeature(
    String partId,
    String featureId, {
    List<String>? sourceBodyIds,
    PlaneRefDto? mirrorPlane,
    List<String>? sourceFeatureIds,
    MergeMode? merge,
    String? toolFeatureId,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/mirror-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (sourceBodyIds != null) 'source_body_ids': sourceBodyIds,
                if (mirrorPlane != null) 'mirror_plane': mirrorPlane.toJson(),
                if (sourceFeatureIds != null) 'source_feature_ids': sourceFeatureIds,
                if (merge != null) 'merge': merge.apiValue,
                if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Pattern/Mirror scoping's Phase 2/4: creates a PatternFeature repeating
  /// [sourceBodyIds]' single Body (exactly one entry - unlike Mirror,
  /// Pattern's own multi-body seeding remains Phase 6 scope, see the
  /// backend's `_validate_pattern_source_body_ids`), either Rectangular
  /// (`patternType='rectangular'`, the default) - along [direction1]
  /// ([count1] instances, [spacing1] apart), optionally crossed with
  /// [direction2] for a 2D grid - or Circular (`patternType='circular'`) -
  /// [countAngular] instances spread across [angleTotal] degrees around
  /// [axis]. The backend validates payload shape and resolvability before
  /// persisting (`missing_reference`/`non_linear_edge`/`unsupported_axis_edge`/
  /// `non_cylindrical_face`/`invalid_direction_ref`/`invalid_axis_ref`/
  /// `pattern_failed` on failure - see `app.document.router.
  /// create_pattern_feature`), this method just serializes whatever it's
  /// given, mirroring [createMirrorFeature]'s own shape.
  Future<FeatureDto> createPatternFeature(
    String partId, {
    required List<String> sourceBodyIds,
    List<String> sourceFeatureIds = const [],
    String patternType = 'rectangular',
    PatternDirectionRefDto? direction1,
    int count1 = 1,
    double spacing1 = 0.0,
    bool reverse1 = false,
    PatternDirectionRefDto? direction2,
    int count2 = 1,
    double spacing2 = 0.0,
    bool reverse2 = false,
    PatternAxisRefDto? axis,
    int countAngular = 1,
    double angleTotal = 360.0,
    bool reverseAngular = false,
    List<int> skipIndices = const [],
    MergeMode merge = MergeMode.keepSeparate,
    // Pattern/Mirror scoping's Phase 8: mirrors [createMirrorFeature]'s own
    // identical addition.
    String? toolFeatureId,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/pattern-features'),
              headers: _headers,
              body: jsonEncode({
                'source_body_ids': sourceBodyIds,
                'source_feature_ids': sourceFeatureIds,
                'pattern_type': patternType,
                if (direction1 != null) 'direction_1': direction1.toJson(),
                'count_1': count1,
                'spacing_1': spacing1,
                'reverse_1': reverse1,
                if (direction2 != null) 'direction_2': direction2.toJson(),
                'count_2': count2,
                'spacing_2': spacing2,
                'reverse_2': reverse2,
                if (axis != null) 'axis': axis.toJson(),
                'count_angular': countAngular,
                'angle_total': angleTotal,
                'reverse_angular': reverseAngular,
                'skip_indices': skipIndices,
                'merge': merge.apiValue,
                if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing PatternFeature - any subset of fields
  /// may be supplied; omitted fields keep their current value. Used for the
  /// live-preview debounced re-solve, same pattern as [updateMirrorFeature].
  /// `patternType` is deliberately not a parameter here at all - the
  /// backend never revises it on update (see `PatternFeatureUpdate`'s own
  /// docstring), so there is nothing for this method to send.
  Future<FeatureDto> updatePatternFeature(
    String partId,
    String featureId, {
    List<String>? sourceBodyIds,
    List<String>? sourceFeatureIds,
    PatternDirectionRefDto? direction1,
    int? count1,
    double? spacing1,
    bool? reverse1,
    PatternDirectionRefDto? direction2,
    int? count2,
    double? spacing2,
    bool? reverse2,
    PatternAxisRefDto? axis,
    int? countAngular,
    double? angleTotal,
    bool? reverseAngular,
    List<int>? skipIndices,
    MergeMode? merge,
    String? toolFeatureId,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/pattern-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (sourceBodyIds != null) 'source_body_ids': sourceBodyIds,
                if (sourceFeatureIds != null) 'source_feature_ids': sourceFeatureIds,
                if (direction1 != null) 'direction_1': direction1.toJson(),
                if (count1 != null) 'count_1': count1,
                if (spacing1 != null) 'spacing_1': spacing1,
                if (reverse1 != null) 'reverse_1': reverse1,
                if (direction2 != null) 'direction_2': direction2.toJson(),
                if (count2 != null) 'count_2': count2,
                if (spacing2 != null) 'spacing_2': spacing2,
                if (reverse2 != null) 'reverse_2': reverse2,
                if (axis != null) 'axis': axis.toJson(),
                if (countAngular != null) 'count_angular': countAngular,
                if (angleTotal != null) 'angle_total': angleTotal,
                if (reverseAngular != null) 'reverse_angular': reverseAngular,
                // Phase 3: `null` (omitted) leaves the Feature's current
                // skip set untouched; `[]` explicitly un-skips every
                // previously-skipped instance - see the backend's
                // `PatternFeatureUpdate.skip_indices` own docstring.
                if (skipIndices != null) 'skip_indices': skipIndices,
                if (merge != null) 'merge': merge.apiValue,
                if (toolFeatureId != null) 'tool_feature_id': toolFeatureId,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Prompt F: creates a RevolveFeature from an existing SketchFeature's
  /// closed Profile, revolved around [axisRef] (a Sketch Line, not required
  /// to belong to the same Sketch as [sketchFeatureId]) by [angle] degrees -
  /// mirrors [createExtrudeFeature] exactly, including [targetBodyIds]'
  /// Boss/Cut semantics (Boss: empty starts a brand-new Body; Cut: must be
  /// non-empty).
  Future<FeatureDto> createRevolveFeature(
    String partId, {
    required String sketchFeatureId,
    required SketchEntityRefDto axisRef,
    required double angle,
    required String mode,
    List<String> targetBodyIds = const [],
    List<SketchEntityRefDto> profileRefs = const [],
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/revolve-features'),
              headers: _headers,
              body: jsonEncode({
                'sketch_feature_id': sketchFeatureId,
                'axis_ref': axisRef.toJson(),
                'angle': angle,
                'mode': mode,
                'target_body_ids': targetBodyIds,
                'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing RevolveFeature - any subset of
  /// [axisRef]/[angle]/[mode]/[targetBodyIds]/[profileRefs] may be supplied,
  /// mirroring [updateExtrudeFeature]'s omitted-vs-current-value convention.
  /// Used for the live-preview debounced re-solve.
  Future<FeatureDto> updateRevolveFeature(
    String partId,
    String featureId, {
    SketchEntityRefDto? axisRef,
    double? angle,
    String? mode,
    List<String>? targetBodyIds,
    List<SketchEntityRefDto>? profileRefs,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/revolve-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (axisRef != null) 'axis_ref': axisRef.toJson(),
                if (angle != null) 'angle': angle,
                if (mode != null) 'mode': mode,
                if (targetBodyIds != null) 'target_body_ids': targetBodyIds,
                if (profileRefs != null)
                  'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Creates a SweepFeature from an existing SketchFeature's closed Profile,
  /// swept along [pathRefs] (an *ordered* list of Sketch Line references,
  /// each possibly naming a different Sketch - confirmed decision, see the
  /// backend's `SweepFeature` docstring) - mirrors [createRevolveFeature]
  /// exactly, substituting [pathRefs] for [axisRef]/`angle`.
  Future<FeatureDto> createSweepFeature(
    String partId, {
    required String sketchFeatureId,
    required List<SketchEntityRefDto> pathRefs,
    required String mode,
    List<String> targetBodyIds = const [],
    List<SketchEntityRefDto> profileRefs = const [],
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/sweep-features'),
              headers: _headers,
              body: jsonEncode({
                'sketch_feature_id': sketchFeatureId,
                'path_refs': pathRefs.map((r) => r.toJson()).toList(),
                'mode': mode,
                'target_body_ids': targetBodyIds,
                'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// Partial update for an existing SweepFeature - any subset of
  /// [pathRefs]/[mode]/[targetBodyIds]/[profileRefs] may be supplied,
  /// mirroring [updateRevolveFeature]'s omitted-vs-current-value
  /// convention. Used for the live-preview debounced re-solve.
  Future<FeatureDto> updateSweepFeature(
    String partId,
    String featureId, {
    List<SketchEntityRefDto>? pathRefs,
    String? mode,
    List<String>? targetBodyIds,
    List<SketchEntityRefDto>? profileRefs,
  }) =>
      _send(
        () => _httpClient.patch(
              _uri('/document/parts/$partId/sweep-features/$featureId'),
              headers: _headers,
              body: jsonEncode({
                if (pathRefs != null) 'path_refs': pathRefs.map((r) => r.toJson()).toList(),
                if (mode != null) 'mode': mode,
                if (targetBodyIds != null) 'target_body_ids': targetBodyIds,
                if (profileRefs != null)
                  'profile_refs': profileRefs.map((r) => r.toJson()).toList(),
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

  /// On-device feedback: read-only preview of exactly which Feature ids
  /// [cascadeDeleteFeature] would remove - the real dependency-graph
  /// cascade, not "everything after this one in the list" (a stale
  /// assumption [PartScreen._cascadeDeleteFeature] used to bake into its
  /// own confirmation dialog before this existed). Mutates nothing.
  Future<List<String>> previewCascadeDelete(String partId, String featureId) => _send(
        () => _httpClient.get(
              _uri('/document/parts/$partId/features/$featureId/cascade-preview'),
              headers: _headers,
            ),
        (body) => ((body as Map<String, dynamic>)['feature_ids'] as List).cast<String>(),
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

  /// Native Save: the whole in-memory Document (every Part's ordered
  /// Feature list) plus every Sketch referenced by any SketchFeature in it,
  /// as a plain JSON object - no cached mesh/geometry (see the backend's
  /// `app.document.native_format.export_native` docstring for the full
  /// "pure parametric tree" rationale). The caller is responsible for
  /// writing this to an actual file - client-owned files, this app has no
  /// project storage of its own.
  Future<Map<String, dynamic>> exportNative() => _send(
        () => _httpClient.get(_uri('/document/export/native'), headers: _headers),
        (body) => body as Map<String, dynamic>,
      );

  /// Native Load: the inverse of [exportNative] - a full replace, not a
  /// merge (client-owned files, locked-in scope): whatever Document/Sketches
  /// were open on the backend before this call are discarded entirely in
  /// favor of exactly what [nativeFileContents] describes. Throws
  /// [ApiException] (422) for anything malformed - an unsupported
  /// schema_version, an unknown Feature/entity/constraint type, a missing
  /// required field.
  Future<NativeImportResultDto> importNative(Map<String, dynamic> nativeFileContents) => _send(
        () => _httpClient.post(
              _uri('/document/import/native'),
              headers: _headers,
              body: jsonEncode(nativeFileContents),
            ),
        (body) => NativeImportResultDto.fromJson(body as Map<String, dynamic>),
      );

  /// Export: raw file bytes for `format` (`'step'`/`'stl'`/`'obj'`/`'glb'`)
  /// - the backend 400s if `partId` has no solid geometry yet (surfaced as
  /// an [ApiException] here, same as any other error response).
  Future<Uint8List> exportPart(String partId, String format) => _sendBytes(
        () => _httpClient.get(_uri('/document/parts/$partId/export/$format'), headers: _headers),
      );

  /// Import: brings [bytes] in as a fixed, non-parametric Body (locked-in
  /// scope - see the backend's `app.document.models.ImportFeature` own
  /// docstring). [sourceFormat] is `'step'`/`'stl'`/`'obj'`/`'gltf'`, base64-
  /// encoded into the JSON body rather than a multipart upload (no other
  /// endpoint here uses multipart - this mirrors the native file format's
  /// own "binary data as a plain JSON string" convention instead). The
  /// backend 422s (`invalid_import_data`/`import_failed`, surfaced as an
  /// [ApiException] here) for a file it can't turn into usable geometry.
  Future<FeatureDto> createImportFeature(String partId, {
    required String sourceFormat,
    required Uint8List bytes,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/import-features'),
              headers: _headers,
              body: jsonEncode({
                'source_format': sourceFormat,
                'data_base64': base64Encode(bytes),
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// `docs/gear-design/08-entry-screen-and-preview.md`: the cheap
  /// `/gear/preview` endpoint - runs only `gear_math` server-side (no OCCT,
  /// no tessellation), cheap enough to call on every debounced keystroke
  /// while [GearDesignScreen]'s form is being edited. [gearKind] is
  /// `'external'`/`'internal'`/`'rack'` - the only two Feature types that
  /// exist yet (see that workstream's own scoped-down v1 note); a future
  /// gear type widens this to one more string value, not a new method.
  /// [outerDiameter] is required for `'internal'`, [backingHeight] optional
  /// for `'rack'` (omitted resolves to the backend's own default) - same
  /// rules [createGearFeature]/[createRackFeature] themselves enforce.
  Future<GearPreviewDto> previewGear({
    required String gearKind,
    required double module,
    required int toothCount,
    double pressureAngleDegrees = 20.0,
    double profileShift = 0.0,
    double backlash = 0.0,
    double? outerDiameter,
    double? backingHeight,
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/gear/preview'),
              headers: _headers,
              body: jsonEncode({
                'gear_kind': gearKind,
                'module': module,
                'tooth_count': toothCount,
                'pressure_angle_degrees': pressureAngleDegrees,
                'profile_shift': profileShift,
                'backlash': backlash,
                if (outerDiameter != null) 'outer_diameter': outerDiameter,
                if (backingHeight != null) 'backing_height': backingHeight,
              }),
            ),
        (body) => GearPreviewDto.fromJson(body as Map<String, dynamic>),
      );

  /// `docs/gear-design/02-gear-feature.md`: creates the real `GearFeature`
  /// (external or internal involute spur gear) once the user hits "Create"
  /// on [GearDesignScreen] - [planeRef] omitted defaults to the fixed XY
  /// plane at the backend, same as every other call site that leaves it
  /// unset. [outerDiameter] is required when [isInternal] is true,
  /// rejected otherwise (`_validate_gear_feature_payload`).
  Future<FeatureDto> createGearFeature(
    String partId, {
    required String gearType,
    required bool isInternal,
    required double module,
    required int toothCount,
    required double faceWidth,
    double pressureAngleDegrees = 20.0,
    double profileShift = 0.0,
    double backlash = 0.0,
    double rootFilletRadius = 0.0,
    double? outerDiameter,
    PlaneRefDto? planeRef,
    List<String> targetBodyIds = const [],
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/gear-features'),
              headers: _headers,
              body: jsonEncode({
                if (planeRef != null) 'plane_ref': planeRef.toJson(),
                'gear_type': gearType,
                'is_internal': isInternal,
                'module': module,
                'tooth_count': toothCount,
                'face_width': faceWidth,
                'pressure_angle_degrees': pressureAngleDegrees,
                'profile_shift': profileShift,
                'backlash': backlash,
                'root_fillet_radius': rootFilletRadius,
                if (outerDiameter != null) 'outer_diameter': outerDiameter,
                'target_body_ids': targetBodyIds,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  /// `docs/gear-design/03-rack.md`: creates the real `RackFeature` once the
  /// user hits "Create" on [GearDesignScreen] with `gearKind == 'rack'` -
  /// mirrors [createGearFeature]'s exact shape. [backingHeight] omitted
  /// resolves to `2 * module` at the backend.
  Future<FeatureDto> createRackFeature(
    String partId, {
    required String rackType,
    required double module,
    required int toothCount,
    required double faceWidth,
    double pressureAngleDegrees = 20.0,
    double backlash = 0.0,
    double? backingHeight,
    PlaneRefDto? planeRef,
    List<String> targetBodyIds = const [],
  }) =>
      _send(
        () => _httpClient.post(
              _uri('/document/parts/$partId/rack-features'),
              headers: _headers,
              body: jsonEncode({
                if (planeRef != null) 'plane_ref': planeRef.toJson(),
                'rack_type': rackType,
                'module': module,
                'tooth_count': toothCount,
                'face_width': faceWidth,
                'pressure_angle_degrees': pressureAngleDegrees,
                'backlash': backlash,
                if (backingHeight != null) 'backing_height': backingHeight,
                'target_body_ids': targetBodyIds,
              }),
            ),
        (body) => FeatureDto.fromJson(body as Map<String, dynamic>),
      );

  void close() => _httpClient.close();
}
