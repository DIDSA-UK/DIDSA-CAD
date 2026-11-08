// Pure (no GPU) logic behind the batched edge rendering of `PartViewport`
// (docs/assembly-perf-mates-and-ui-plan.md, A1-A3).
//
// Body edges used to be one `PolylineGeometry` per segment, rebuilt at every gesture end - about 298,000 GPU
// buffers for a 12,000-segment model. They are now one `LineSegmentsGeometry` per Part body (A1), built once and
// shared by every placed instance (A2), sized per frame from the camera, and optionally hidden while the view moves
// on very large models (A3). Everything here is plain Dart so `flutter test` can cover it without a GPU.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import 'section_gizmo.dart' show clipSegmentsByPlanes;
import 'section_plane.dart';

/// World units covered by one screen pixel, at distance [distance] from the camera (perspective) or anywhere
/// (orthographic). [viewportHeight] is in the same pixels the edge width is expressed in.
///
/// Orthographic: exactly `2 * halfHeight / viewportHeight`. Perspective: `2 * d * tan(fovY / 2) / viewportHeight`.
double worldUnitsPerPixel({
  required bool perspective,
  required double viewportHeight,
  double halfHeight = 1,
  double fovRadiansY = math.pi / 4,
  double distance = 1,
}) {
  if (viewportHeight <= 0) return 0;
  if (!perspective) return 2 * halfHeight / viewportHeight;
  return 2 * math.max(distance, 0) * math.tan(fovRadiansY / 2) / viewportHeight;
}

/// The world-space ribbon width that draws as [pixelWidth] pixels.
double edgeWorldWidth(double pixelWidth, double unitsPerPixel) => pixelWidth * unitsPerPixel;

/// Returns the width to apply, or null to keep [current]. The batched geometry rescans its endpoints for bounds
/// whenever its width is set, so a change below [tolerance] (a fraction, default 1 %) is not applied.
double? nextEdgeWidth(double? current, double desired, {double tolerance = 0.01}) {
  if (desired <= 0) return null;
  if (current == null || current <= 0) return desired;
  return (desired - current).abs() / current > tolerance ? desired : null;
}

/// The offset that nudges an edge node [bias] world units from [nodeCentre] towards [cameraPosition], replacing the
/// old per-point CPU bias (`biasSegmentsTowardCamera`), which had to be rebuilt whenever the camera moved. A node
/// exactly at the camera gets no offset.
vm.Vector3 edgeDepthOffset(vm.Vector3 nodeCentre, vm.Vector3 cameraPosition, double bias) {
  final direction = cameraPosition - nodeCentre;
  if (direction.length2 < 1e-12) return vm.Vector3.zero();
  return direction.normalized() * bias;
}

/// The node transform for an edge node: [base] (the instance's world transform) with [offset] added to its
/// translation, i.e. `translate(offset) * base`.
vm.Matrix4 offsetTransform(vm.Matrix4 base, vm.Vector3 offset) {
  final out = base.clone();
  out.setTranslation(out.getTranslation() + offset);
  return out;
}

/// Segment count of a flat `[x1,y1,z1,x2,y2,z2,...]` edge list (`MeshDto.edges`); a trailing partial run is ignored.
int edgeSegmentCount(List<double> flat) => flat.length ~/ 6;

/// [flat] as the `Float32List` the batched geometry takes (six floats per segment, a trailing partial run dropped).
Float32List edgePositions(List<double> flat) {
  final count = edgeSegmentCount(flat) * 6;
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    out[i] = flat[i];
  }
  return out;
}

/// [edgePositions] after transforming every point by [transform] (null = identity) and clipping the segments by the
/// enabled section [planes] in that (world) space. A section makes the segments instance-specific, which is why
/// [EdgeBatchKey.sectionSignature] is part of the cache key.
Float32List clippedEdgePositions(List<double> flat, vm.Matrix4? transform, List<SectionPlane> planes) {
  final count = edgeSegmentCount(flat);
  var segments = <(vm.Vector3, vm.Vector3)>[
    for (var i = 0; i < count; i++)
      (
        _point(flat, i * 6, transform),
        _point(flat, i * 6 + 3, transform),
      ),
  ];
  return positionsFromSegments(clipSegmentsByPlanes(segments, planes));
}

/// The flat six-floats-per-segment form of [segments].
Float32List positionsFromSegments(List<(vm.Vector3, vm.Vector3)> segments) {
  final out = Float32List(segments.length * 6);
  for (var i = 0; i < segments.length; i++) {
    final (a, b) = segments[i];
    out[i * 6] = a.x;
    out[i * 6 + 1] = a.y;
    out[i * 6 + 2] = a.z;
    out[i * 6 + 3] = b.x;
    out[i * 6 + 4] = b.y;
    out[i * 6 + 5] = b.z;
  }
  return out;
}

/// The centre of the axis-aligned box of [positions] (six floats per segment); the origin when empty.
vm.Vector3 edgePositionsCentre(Float32List positions) {
  if (positions.length < 3) return vm.Vector3.zero();
  var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity, maxZ = double.negativeInfinity;
  for (var i = 0; i + 2 < positions.length; i += 3) {
    minX = math.min(minX, positions[i]);
    maxX = math.max(maxX, positions[i]);
    minY = math.min(minY, positions[i + 1]);
    maxY = math.max(maxY, positions[i + 1]);
    minZ = math.min(minZ, positions[i + 2]);
    maxZ = math.max(maxZ, positions[i + 2]);
  }
  return vm.Vector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
}

vm.Vector3 _point(List<double> flat, int i, vm.Matrix4? transform) {
  final p = vm.Vector3(flat[i], flat[i + 1], flat[i + 2]);
  return transform == null ? p : transform.transformed3(p);
}

/// A stable text form of the enabled section planes, for cache keys: equal sections give equal text, any change to a
/// plane (position, normal, flip, enabled) gives different text. Empty when no plane is enabled.
String sectionSignature(List<SectionPlane> planes) {
  final enabled = planes.where((p) => p.enabled);
  if (enabled.isEmpty) return '';
  String v(vm.Vector3 x) => '${x.x},${x.y},${x.z}';
  return enabled.map((p) => '${v(p.origin)}|${v(p.normal)}|${p.flipped ? 1 : 0}').join(';');
}

/// What identifies one cached edge geometry: the Part body it was built from, and (only while a section is on) the
/// instance and planes it was clipped for.
class EdgeBatchKey {
  const EdgeBatchKey({required this.partId, required this.bodyId, this.instanceKey = '', this.sectionSignature = ''});

  final String partId;
  final String bodyId;

  /// Empty unless the geometry is clipped per instance (a section is on).
  final String instanceKey;
  final String sectionSignature;

  @override
  bool operator ==(Object other) =>
      other is EdgeBatchKey &&
      other.partId == partId &&
      other.bodyId == bodyId &&
      other.instanceKey == instanceKey &&
      other.sectionSignature == sectionSignature;

  @override
  int get hashCode => Object.hash(partId, bodyId, instanceKey, sectionSignature);

  @override
  String toString() => 'EdgeBatchKey($partId/$bodyId/$instanceKey/$sectionSignature)';
}

/// Builds each edge geometry once per [EdgeBatchKey] and mesh identity, however many nodes use it and however often
/// the camera moves. [T] is the geometry type (a `LineSegmentsGeometry` in the viewport; anything in tests); [onEvict]
/// releases one that is dropped.
class EdgeBatchCache<T> {
  EdgeBatchCache({void Function(T value)? onEvict}) : _onEvict = onEvict;

  final void Function(T value)? _onEvict;
  final Map<EdgeBatchKey, _Entry<T>> _entries = {};
  final Set<EdgeBatchKey> _touched = {};

  /// How many times [build] has run (for tests and diagnostics).
  int buildCount = 0;

  int get length => _entries.length;

  /// The cached value for [key], built with [build] when missing or when [source] (the mesh the data came from) is
  /// not the same object as last time.
  T obtain(EdgeBatchKey key, Object source, T Function() build) {
    _touched.add(key);
    final existing = _entries[key];
    if (existing != null && identical(existing.source, source)) return existing.value;
    if (existing != null) _onEvict?.call(existing.value);
    buildCount++;
    final value = build();
    _entries[key] = _Entry(source, value);
    return value;
  }

  /// Marks the start of a sync pass: keys not [obtain]ed before the matching [endPass] are evicted.
  void beginPass() => _touched.clear();

  /// Evicts what the pass did not use (a removed instance, a changed section, a replaced mesh).
  void endPass() {
    final stale = _entries.keys.where((k) => !_touched.contains(k)).toList();
    for (final key in stale) {
      _onEvict?.call(_entries.remove(key)!.value);
    }
  }

  void clear() {
    for (final entry in _entries.values) {
      _onEvict?.call(entry.value);
    }
    _entries.clear();
    _touched.clear();
  }
}

class _Entry<T> {
  _Entry(this.source, this.value);
  final Object source;
  final T value;
}

/// A3's gate: whether edges are hidden right now. Only while [enabled], only while the view is [moving] (pointer
/// down, a view animation, the turntable), and only when the visible edge count exceeds [limit].
bool shouldHideEdges({required bool enabled, required bool moving, required int segmentCount, required int limit}) =>
    enabled && moving && segmentCount > limit;

/// A3's slider steps (edge segments): log-spaced.
const List<int> kEdgeLimitSteps = [5000, 10000, 20000, 50000, 100000, 200000];

/// Decision A-a: off by default, limit 50,000 segments.
const bool kHideEdgesWhileMovingDefault = false;
const int kEdgeLimitDefault = 50000;

/// [value] snapped to the nearest [kEdgeLimitSteps] entry (by ratio, as the steps are log-spaced).
int snapEdgeLimit(int value) {
  var best = kEdgeLimitSteps.first;
  var bestDistance = double.infinity;
  for (final step in kEdgeLimitSteps) {
    final d = (math.log(math.max(value, 1)) - math.log(step)).abs();
    if (d < bestDistance) {
      best = step;
      bestDistance = d;
    }
  }
  return best;
}
