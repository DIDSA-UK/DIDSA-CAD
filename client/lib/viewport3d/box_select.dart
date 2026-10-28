import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show Rect, Size, Offset;
import 'package:flutter_scene/scene.dart' show Camera;
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart' show edgeSegmentsFromMesh;
import 'selection_hit_test.dart';

/// Desktop input D7: 3D box select, as a pure function so it can be tested
/// headless against known cameras (the June 2026 attempts could only be
/// checked on a device). It projects the model's own meshes with the camera
/// (the same transform every screen overlay already uses), works out what the
/// camera can actually see, and returns what a window box (wholly inside) or
/// a crossing box (touching) picks.

/// What a box picks. The caller chooses from the selection filter and the
/// context: edges inside a part, whole components in an assembly.
enum BoxSelectTarget { edges, vertices, faces, bodies, components }

/// One Body's mesh as the box sees it.
class BoxSelectShape {
  final String bodyId;

  /// The placed instance this Body belongs to (a joined occurrence path), or
  /// empty for the Part's own Bodies.
  final String occurrenceId;
  final MeshDto mesh;

  /// Mesh space to world space; null is identity.
  final vm.Matrix4? transform;

  /// False for geometry that is drawn and so hides things behind it, but is
  /// not offered for picking (a placed instance outside the focused one).
  final bool pickable;

  const BoxSelectShape({
    required this.bodyId,
    this.occurrenceId = '',
    required this.mesh,
    this.transform,
    this.pickable = true,
  });
}

/// Longest gap between visibility samples along an edge, in pixels.
const double kBoxSelectSampleSpacingPixels = 6;

/// Most samples taken along one edge segment.
const int kBoxSelectMaxSamplesPerSegment = 32;

/// The depth buffer's cell size is chosen so the grid is at most this many
/// cells across.
const int kBoxSelectMaxGridCells = 256;

List<SelectionEntityRef> boxSelect({
  required Camera camera,
  required Size viewportSize,
  required List<BoxSelectShape> shapes,
  required Rect rect,
  required bool crossing,
  required BoxSelectTarget target,
  bool occlude = true,
}) {
  final box = rect.intersect(Offset.zero & viewportSize);
  if (box.isEmpty || box.width < 1 || box.height < 1) return const [];

  final viewProjection = camera.getViewTransform(viewportSize);

  final projections = [for (final shape in shapes) _ProjectedShape(shape, viewProjection, camera, viewportSize)];

  final needsGrid = occlude || target == BoxSelectTarget.faces || target == BoxSelectTarget.bodies || target == BoxSelectTarget.components;
  final grid = needsGrid ? _DepthGrid(box, projections) : null;

  switch (target) {
    case BoxSelectTarget.edges:
      return _pickEdges(projections, box, crossing, occlude ? grid : null);
    case BoxSelectTarget.vertices:
      return _pickVertices(projections, box, occlude ? grid : null);
    case BoxSelectTarget.faces:
      return _pickFaces(projections, box, crossing, grid!);
    case BoxSelectTarget.bodies:
      return _pickGroups(projections, box, crossing, grid!, byOccurrence: false);
    case BoxSelectTarget.components:
      return _pickGroups(projections, box, crossing, grid!, byOccurrence: true);
  }
}

/// A shape's vertices in screen space plus view depth.
class _ProjectedShape {
  final BoxSelectShape shape;
  final vm.Matrix4 toWorld;
  final vm.Matrix4 viewProjection;
  final Camera camera;
  final Size viewport;

  late final Float64List x;
  late final Float64List y;
  late final Float64List depth;
  late final Float64List w;
  late final List<bool> valid;

  _ProjectedShape(this.shape, this.viewProjection, this.camera, this.viewport)
      : toWorld = shape.transform ?? vm.Matrix4.identity() {
    final count = shape.mesh.vertices.length;
    x = Float64List(count);
    y = Float64List(count);
    depth = Float64List(count);
    w = Float64List(count);
    valid = List.filled(count, false);
    for (var i = 0; i < count; i++) {
      final v = shape.mesh.vertices[i];
      final p = project(vm.Vector3(v[0], v[1], v[2]));
      if (p == null) continue;
      x[i] = p.$1;
      y[i] = p.$2;
      depth[i] = p.$3;
      w[i] = p.$4;
      valid[i] = true;
    }
  }

  /// Screen x, y, view depth and clip w of a mesh-space point; null behind the camera.
  (double, double, double, double)? project(vm.Vector3 meshPoint) {
    final world = toWorld.transformed3(meshPoint);
    final clip = viewProjection * vm.Vector4(world.x, world.y, world.z, 1) as vm.Vector4;
    if (clip.w <= 0) return null;
    return (
      (clip.x / clip.w + 1) / 2 * viewport.width,
      (1 - clip.y / clip.w) / 2 * viewport.height,
      (world - camera.position).dot(camera.forward),
      clip.w,
    );
  }

  /// The nearest triangle's depth at ([px], [py]) by plane extrapolation, or
  /// null when its corners are not all in front of the camera.
  double? depthOfTriangleAt(int triangle, double px, double py) {
    final t = shape.mesh.triangleIndices[triangle];
    if (!valid[t[0]] || !valid[t[1]] || !valid[t[2]]) return null;
    final bary = _barycentric(px, py, x[t[0]], y[t[0]], x[t[1]], y[t[1]], x[t[2]], y[t[2]]);
    if (bary == null) return null;
    return _interpolateDepth(bary, depth[t[0]], depth[t[1]], depth[t[2]], w[t[0]], w[t[1]], w[t[2]]);
  }
}

List<double>? _barycentric(double px, double py, double ax, double ay, double bx, double by, double cx, double cy) {
  final denominator = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
  if (denominator.abs() < 1e-12) return null;
  final l0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / denominator;
  final l1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / denominator;
  return [l0, l1, 1 - l0 - l1];
}

/// Perspective-correct depth: with clip w equal for every corner (an
/// orthographic camera) this is plain linear interpolation.
double _interpolateDepth(List<double> l, double d0, double d1, double d2, double w0, double w1, double w2) {
  final i0 = l[0] / w0, i1 = l[1] / w1, i2 = l[2] / w2;
  final invW = i0 + i1 + i2;
  if (invW.abs() < 1e-12) return d0;
  return (i0 * d0 + i1 * d1 + i2 * d2) / invW;
}

/// The nearest triangle in each cell of the box, found by rasterising every
/// triangle that overlaps it.
class _DepthGrid {
  final Rect box;
  final List<_ProjectedShape> shapes;
  late final int cell;
  late final int nx;
  late final int ny;
  late final Float64List nearest;
  late final Int32List ownerShape;
  late final Int32List ownerTriangle;

  _DepthGrid(this.box, this.shapes) {
    cell = math.max(1, (math.max(box.width, box.height) / kBoxSelectMaxGridCells).ceil());
    nx = (box.width / cell).ceil();
    ny = (box.height / cell).ceil();
    nearest = Float64List(nx * ny)..fillRange(0, nx * ny, double.infinity);
    ownerShape = Int32List(nx * ny)..fillRange(0, nx * ny, -1);
    ownerTriangle = Int32List(nx * ny)..fillRange(0, nx * ny, -1);
    for (var s = 0; s < shapes.length; s++) {
      _rasterise(s, shapes[s]);
    }
  }

  void _rasterise(int shapeIndex, _ProjectedShape p) {
    final triangles = p.shape.mesh.triangleIndices;
    for (var t = 0; t < triangles.length; t++) {
      final tri = triangles[t];
      final a = tri[0], b = tri[1], c = tri[2];
      if (!p.valid[a] || !p.valid[b] || !p.valid[c]) continue;
      final minX = math.min(p.x[a], math.min(p.x[b], p.x[c]));
      final maxX = math.max(p.x[a], math.max(p.x[b], p.x[c]));
      final minY = math.min(p.y[a], math.min(p.y[b], p.y[c]));
      final maxY = math.max(p.y[a], math.max(p.y[b], p.y[c]));
      if (maxX < box.left || minX > box.right || maxY < box.top || minY > box.bottom) continue;
      final cx0 = math.max(0, ((minX - box.left) / cell).floor());
      final cx1 = math.min(nx - 1, ((maxX - box.left) / cell).floor());
      final cy0 = math.max(0, ((minY - box.top) / cell).floor());
      final cy1 = math.min(ny - 1, ((maxY - box.top) / cell).floor());
      for (var cy = cy0; cy <= cy1; cy++) {
        for (var cx = cx0; cx <= cx1; cx++) {
          final px = box.left + (cx + 0.5) * cell;
          final py = box.top + (cy + 0.5) * cell;
          final bary = _barycentric(px, py, p.x[a], p.y[a], p.x[b], p.y[b], p.x[c], p.y[c]);
          if (bary == null || bary[0] < 0 || bary[1] < 0 || bary[2] < 0) continue;
          final d = _interpolateDepth(bary, p.depth[a], p.depth[b], p.depth[c], p.w[a], p.w[b], p.w[c]);
          final index = cy * nx + cx;
          if (d < nearest[index]) {
            nearest[index] = d;
            ownerShape[index] = shapeIndex;
            ownerTriangle[index] = t;
          }
        }
      }
    }
  }

  /// True when something at screen ([px], [py]) and view depth [d] is not
  /// behind the nearest surface there.
  bool isVisible(double px, double py, double d) {
    final cx = ((px - box.left) / cell).floor().clamp(0, nx - 1);
    final cy = ((py - box.top) / cell).floor().clamp(0, ny - 1);
    final index = cy * nx + cx;
    final shapeIndex = ownerShape[index];
    if (shapeIndex < 0) return true;
    // The nearest triangle's own plane at the sample, not the cell centre's
    // depth, so a face seen at a grazing angle doesn't hide its own edges.
    final surface = shapes[shapeIndex].depthOfTriangleAt(ownerTriangle[index], px, py) ?? nearest[index];
    return d <= surface + math.max(kFaceOcclusionEpsilon, d * 0.004);
  }

  /// Every (shape, triangle) that is the nearest surface in some cell.
  Iterable<(int, int)> visibleTriangles() sync* {
    final seen = <int>{};
    for (var i = 0; i < ownerShape.length; i++) {
      if (ownerShape[i] < 0) continue;
      final key = ownerShape[i] * 0x1000000 + ownerTriangle[i];
      if (seen.add(key)) yield (ownerShape[i], ownerTriangle[i]);
    }
  }
}

bool _inside(Rect box, double x, double y) => x >= box.left && x <= box.right && y >= box.top && y <= box.bottom;

List<SelectionEntityRef> _pickEdges(List<_ProjectedShape> projections, Rect box, bool crossing, _DepthGrid? grid) {
  final picked = <SelectionEntityRef>[];
  final spacing = math.max(1.0, math.min(kBoxSelectSampleSpacingPixels, math.min(box.width, box.height) / 2));
  for (final p in projections) {
    if (!p.shape.pickable) continue;
    final mesh = p.shape.mesh;
    final segments = edgeSegmentsFromMesh(mesh);
    final byEdge = <int, List<int>>{};
    for (var i = 0; i < segments.length && i < mesh.edgeIds.length; i++) {
      byEdge.putIfAbsent(mesh.edgeIds[i], () => []).add(i);
    }
    for (final entry in byEdge.entries) {
      var allInside = true;
      var anyVisibleInside = false;
      var anyVisible = false;
      for (final segmentIndex in entry.value) {
        final (a, b) = segments[segmentIndex];
        final pa = p.project(a);
        final pb = p.project(b);
        if (pa == null || pb == null) {
          allInside = false;
          continue;
        }
        if (!_inside(box, pa.$1, pa.$2) || !_inside(box, pb.$1, pb.$2)) allInside = false;
        final length = (Offset(pa.$1, pa.$2) - Offset(pb.$1, pb.$2)).distance;
        final steps = math.min(kBoxSelectMaxSamplesPerSegment, math.max(1, (length / spacing).ceil()));
        for (var s = 0; s <= steps; s++) {
          final t = s / steps;
          final sample = p.project(a + (b - a) * t);
          if (sample == null) continue;
          final inside = _inside(box, sample.$1, sample.$2);
          final visible = !inside ? false : (grid == null || grid.isVisible(sample.$1, sample.$2, sample.$3));
          if (visible) anyVisibleInside = true;
          if (visible || (grid == null && inside)) anyVisible = true;
        }
      }
      final hit = crossing ? anyVisibleInside : (allInside && anyVisible);
      if (hit) {
        picked.add(SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: p.shape.bodyId, id: entry.key, occurrenceId: p.shape.occurrenceId));
      }
    }
  }
  return picked;
}

List<SelectionEntityRef> _pickVertices(List<_ProjectedShape> projections, Rect box, _DepthGrid? grid) {
  final picked = <SelectionEntityRef>[];
  for (final p in projections) {
    if (!p.shape.pickable) continue;
    final mesh = p.shape.mesh;
    for (var i = 0; i < mesh.topologyVertices.length && i < mesh.topologyVertexIds.length; i++) {
      final v = mesh.topologyVertices[i];
      final point = p.project(vm.Vector3(v[0], v[1], v[2]));
      if (point == null || !_inside(box, point.$1, point.$2)) continue;
      if (grid != null && !grid.isVisible(point.$1, point.$2, point.$3)) continue;
      picked.add(SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: p.shape.bodyId, id: mesh.topologyVertexIds[i], occurrenceId: p.shape.occurrenceId));
    }
  }
  return picked;
}

List<SelectionEntityRef> _pickFaces(List<_ProjectedShape> projections, Rect box, bool crossing, _DepthGrid grid) {
  final visibleFaces = <(int, int)>{};
  for (final (shapeIndex, triangle) in grid.visibleTriangles()) {
    if (!projections[shapeIndex].shape.pickable) continue;
    final mesh = projections[shapeIndex].shape.mesh;
    if (triangle < mesh.faceIds.length) visibleFaces.add((shapeIndex, mesh.faceIds[triangle]));
  }
  final picked = <SelectionEntityRef>[];
  for (final (shapeIndex, faceId) in visibleFaces) {
    final p = projections[shapeIndex];
    if (!crossing && !_faceWhollyInside(p, faceId, box)) continue;
    picked.add(SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: p.shape.bodyId, id: faceId, occurrenceId: p.shape.occurrenceId));
  }
  return picked;
}

bool _faceWhollyInside(_ProjectedShape p, int faceId, Rect box) {
  final mesh = p.shape.mesh;
  for (var t = 0; t < mesh.triangleIndices.length && t < mesh.faceIds.length; t++) {
    if (mesh.faceIds[t] != faceId) continue;
    for (final index in mesh.triangleIndices[t]) {
      if (!p.valid[index] || !_inside(box, p.x[index], p.y[index])) return false;
    }
  }
  return true;
}

/// Bodies (one per Body) or components (one per placed instance, all its
/// Bodies together): wholly inside for a window, anything visible inside for
/// a crossing.
List<SelectionEntityRef> _pickGroups(
  List<_ProjectedShape> projections,
  Rect box,
  bool crossing,
  _DepthGrid grid, {
  required bool byOccurrence,
}) {
  String keyOf(_ProjectedShape p) => byOccurrence ? p.shape.occurrenceId : '${p.shape.occurrenceId}|${p.shape.bodyId}';
  final visible = <String>{};
  for (final (shapeIndex, _) in grid.visibleTriangles()) {
    final p = projections[shapeIndex];
    if (!p.shape.pickable || (byOccurrence && p.shape.occurrenceId.isEmpty)) continue;
    visible.add(keyOf(p));
  }
  final wholly = <String, bool>{};
  for (final p in projections) {
    if (!p.shape.pickable || (byOccurrence && p.shape.occurrenceId.isEmpty)) continue;
    final key = keyOf(p);
    var inside = wholly[key] ?? true;
    if (inside) {
      for (var i = 0; i < p.valid.length; i++) {
        if (!p.valid[i] || !_inside(box, p.x[i], p.y[i])) {
          inside = false;
          break;
        }
      }
    }
    wholly[key] = inside;
  }
  final picked = <SelectionEntityRef>[];
  final done = <String>{};
  for (final p in projections) {
    if (!p.shape.pickable || (byOccurrence && p.shape.occurrenceId.isEmpty)) continue;
    final key = keyOf(p);
    if (!done.add(key) || !visible.contains(key)) continue;
    if (!crossing && wholly[key] != true) continue;
    picked.add(
      byOccurrence
          ? SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: p.shape.occurrenceId)
          : SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: p.shape.bodyId, occurrenceId: p.shape.occurrenceId),
    );
  }
  return picked;
}
