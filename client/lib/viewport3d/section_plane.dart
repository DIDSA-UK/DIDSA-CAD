import 'package:vector_math/vector_math.dart' as vm;

/// Sectioning Tool: one live, transient clipping plane the user has placed
/// in the 3D viewport. Deliberately **not** a `Feature` - see this app's
/// document/section-tool brief ("this is a transient, non-persisted VIEW
/// setting - sections are NOT a modeling Feature"): a [SectionPlane] never
/// touches `DocumentApiClient`'s Feature DTOs or the backend's parametric
/// tree at all. It lives only in [PartScreen]'s own transient viewport
/// state (a plain `List<SectionPlane>`, the same convention every other
/// session-only viewport toggle on that screen already uses - e.g.
/// `_referencePlanesHidden`), gets rendered live by `PartViewport`, and is
/// carried into/out of the native save file as a client-only stash (mirrors
/// `hidden_feature_ids`'s own stash - see `PartScreen._buildNativeExportBytes`/
/// `_openNativeFile`), never through `native_format.py`'s own Feature-tree
/// export.
///
/// [origin]/[normal] together define the actual infinite cutting plane sent
/// to the backend's `POST .../section-preview` endpoint (`{origin, normal,
/// flipped}` per plane). [anchorOrigin] is a *separate* point - wherever
/// [origin] was when this plane was last explicitly (re)placed (a face/
/// plane tap, one of the three quick-anchor buttons, or "Add Section"'s own
/// default placement) - purely so the tool panel's numeric "Offset" field
/// can show/edit a small, human-friendly delta along the plane's own normal
/// instead of an absolute world coordinate; see [offsetFromAnchor].
class SectionPlane {
  final String id;
  final vm.Vector3 origin;
  final vm.Vector3 normal;
  final vm.Vector3 anchorOrigin;
  final bool flipped;
  final bool enabled;

  const SectionPlane({
    required this.id,
    required this.origin,
    required this.normal,
    required this.anchorOrigin,
    this.flipped = false,
    this.enabled = true,
  });

  /// The "Offset" field's own value: how far [origin] has moved along
  /// [normal] away from [anchorOrigin] since the plane was last (re)placed.
  /// Purely derived - translating the plane in-plane (the gizmo's X/Y
  /// translate handles, or any future in-plane nudge) never changes this,
  /// since an in-plane displacement is, by construction, perpendicular to
  /// [normal] and so contributes nothing to this dot product - only a move
  /// along the normal (the gizmo's Z handle, or a typed Offset edit) does.
  double get offsetFromAnchor => (origin - anchorOrigin).dot(normal);

  /// Moves [origin] to sit exactly [offset] world units along [normal] from
  /// [anchorOrigin] - the typed "Offset" field's own write path, and the
  /// inverse of [offsetFromAnchor].
  SectionPlane withOffset(double offset) => copyWith(origin: anchorOrigin + normal * offset);

  /// Re-anchors this plane at a freshly-picked [origin]/[normal] (a face/
  /// plane tap, or a quick XY/XZ/YZ button) - both the live cutting geometry
  /// and the Offset field's own zero point reset together, so the field
  /// reads `0` immediately after a fresh placement rather than carrying over
  /// a stale delta from wherever it was before.
  SectionPlane reanchored(vm.Vector3 newOrigin, vm.Vector3 newNormal) => copyWith(
        origin: newOrigin,
        normal: newNormal.normalized(),
        anchorOrigin: newOrigin,
      );

  SectionPlane copyWith({
    vm.Vector3? origin,
    vm.Vector3? normal,
    vm.Vector3? anchorOrigin,
    bool? flipped,
    bool? enabled,
  }) =>
      SectionPlane(
        id: id,
        origin: origin ?? this.origin,
        normal: normal ?? this.normal,
        anchorOrigin: anchorOrigin ?? this.anchorOrigin,
        flipped: flipped ?? this.flipped,
        enabled: enabled ?? this.enabled,
      );

  /// The exact `{origin, normal, flipped}` shape `POST .../section-preview`
  /// expects per plane (see that endpoint's own contract) - [enabled]/[id]/
  /// [anchorOrigin] carry no meaning to the backend, so a disabled plane
  /// must be filtered out of the request list by the caller *before* this
  /// is used, not represented in this shape at all.
  Map<String, dynamic> toRequestJson() => {
        'origin': [origin.x, origin.y, origin.z],
        'normal': [normal.x, normal.y, normal.z],
        'flipped': flipped,
      };

  /// The client-only native-file stash shape (see this class's own doc
  /// comment) - every field, so a reopened file restores a section exactly
  /// as it was left, not just its cutting geometry.
  Map<String, dynamic> toJson() => {
        'id': id,
        'origin': [origin.x, origin.y, origin.z],
        'normal': [normal.x, normal.y, normal.z],
        'anchor_origin': [anchorOrigin.x, anchorOrigin.y, anchorOrigin.z],
        'flipped': flipped,
        'enabled': enabled,
      };

  static vm.Vector3 _vectorFromJson(dynamic raw) {
    final list = (raw as List).map((v) => (v as num).toDouble()).toList();
    return vm.Vector3(list[0], list[1], list[2]);
  }

  /// The inverse of [toJson] - tolerant of a missing/malformed entry (throws
  /// [FormatException]) so a single corrupt section in an otherwise-valid
  /// native file doesn't need to be handled specially by the caller; see
  /// `PartScreen._openNativeFile`'s own try/catch around its whole
  /// `hidden_feature_ids`/`section_planes` restore step.
  factory SectionPlane.fromJson(Map<String, dynamic> json) {
    final origin = _vectorFromJson(json['origin']);
    return SectionPlane(
      id: json['id'] as String,
      origin: origin,
      normal: _vectorFromJson(json['normal']),
      // Older/foreign files never wrote anchor_origin - falling back to
      // origin itself just means the Offset field reads 0 on first open,
      // the same "nothing to offset from yet" state a freshly-placed plane
      // starts in.
      anchorOrigin: json['anchor_origin'] != null ? _vectorFromJson(json['anchor_origin']) : origin,
      flipped: json['flipped'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

/// An arbitrary but deterministic orthonormal (x, y) basis perpendicular to
/// [normal] - the exact same construction as the backend's own
/// `app.document.plane_geometry.arbitrary_perpendicular_basis` (picks
/// whichever of world +Z or +Y is *less* parallel to [normal] as a
/// reference vector, to avoid the degenerate near-parallel cross-product
/// case, then derives `xAxis = normalize(reference x normal)`, `yAxis =
/// normal x xAxis`). Replicated here (not shared - there is no Dart/Python
/// shared-code mechanism in this repo) so the gizmo's rendered orientation
/// for a given normal never "spins" unpredictably between rebuilds, the
/// same determinism guarantee the backend's own version documents for a
/// resolved custom Plane.
(vm.Vector3, vm.Vector3) arbitraryPerpendicularBasis(vm.Vector3 normal) {
  final n = normal.normalized();
  final reference = n.z.abs() < 0.9 ? vm.Vector3(0, 0, 1) : vm.Vector3(0, 1, 0);
  final xAxis = reference.cross(n).normalized();
  final yAxis = n.cross(xAxis);
  return (xAxis, yAxis);
}

/// A fresh [SectionPlane] with a new client-generated id, anchored at
/// [origin]/[normal] with nothing offset/flipped yet - shared by every
/// placement path ("Add Section"'s own default, a quick XY/XZ/YZ button, a
/// face/plane tap) so they all produce the exact same shape of plane.
SectionPlane newSectionPlane(String id, vm.Vector3 origin, vm.Vector3 normal) => SectionPlane(
      id: id,
      origin: origin,
      normal: normal.normalized(),
      anchorOrigin: origin,
    );
