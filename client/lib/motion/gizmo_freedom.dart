/// Per-handle freedom of the Move/Rotate gizmo (plan S8), computed from a
/// `mate-motion` anchor: how much of each handle's unit motion the mates
/// allow, the screw axis a rotate handle really turns about, and whether the
/// free translations form a plane. Pure Dart (no Flutter), in the anchor's
/// frame (the focused Part's frame); the caller maps it to world space.
///
/// "Free fraction" of a handle = ‖P u‖ / ‖u‖ in the projection metric, where
/// `u` is the handle's unit twist on the grabbed member (translate: 1 mm
/// along the occurrence's own axis; rotate: 1 rad about it, which costs `L`
/// like the spec's metric says) and `P` the weighted projection onto the
/// anchor's free-motion rows (`docs/motion/projector-spec.md` §3-§4). 1 = the
/// handle moves exactly as dragged, 0 = blocked. Followers are in the metric
/// with their tiny weight, so "B's x handle drags C along" still reads free.
library;

import 'dart:math' as math;

import '../api/document_api_client.dart';
import 'free_motion_projector.dart';
import 'mate_motion_bridge.dart';
import 'se3.dart';
import 'weighted_basis.dart';

/// Below this free fraction a handle is shown locked (grey, short, not grabbable).
const double kHandleLockedBelow = 0.05;

/// At or above this free fraction a handle is shown at full strength.
const double kHandleFreeAtLeast = 0.95;

/// A rotate handle is re-pivoted onto the screw axis only if the axis is this close to the handle's own axis (cos).
const double kPivotAxisCos = 0.985;

/// ... and only if the axis is further than this × `L` from the occurrence origin (else the ring is already right).
const double kPivotMinOffsetFraction = 1e-3;

/// A translation direction counts as fully free at this many percent of its length.
const double kPlaneFreeAtLeast = 0.999;

class HandleFreedom {
  /// 0..1, see the library comment.
  final double fraction;

  /// Rotate handles only: a point on the screw axis (nearest the occurrence origin) and its unit direction
  /// (same sense as the handle's own axis), when the ring should be re-pivoted onto it. Anchor frame.
  final List<double>? pivot;
  final List<double>? pivotAxis;

  const HandleFreedom(this.fraction, {this.pivot, this.pivotAxis});

  bool get locked => fraction < kHandleLockedBelow;
  bool get free => fraction >= kHandleFreeAtLeast;
  bool get partial => !locked && !free;
}

class GizmoFreedom {
  /// Translate handles along the occurrence's own local x, y, z.
  final List<HandleFreedom> translate;

  /// Rotate handles about the occurrence's own local x, y, z (through its origin unless re-pivoted).
  final List<HandleFreedom> rotate;

  /// The occurrence's local axes (columns of its rotation) in the anchor frame.
  final List<List<double>> axes;

  /// Unit normal (anchor frame) of the plane the free pure translations span, when that space is exactly 2-D.
  final List<double>? planeNormal;

  /// Group dof and grounding from the response (`null` when the answer had none).
  final int? dof;
  final bool? grounded;

  /// Rank of the grabbed member's block of the basis.
  final int? mobility;

  const GizmoFreedom({
    required this.translate,
    required this.rotate,
    required this.axes,
    this.planeNormal,
    this.dof,
    this.grounded,
    this.mobility,
  });

  /// Nothing can move the grabbed component: the gizmo is hidden and [reason] says why.
  bool get immobile => dof == 0 || mobility == 0;

  String? get reason {
    if (dof == 0) return "Fully constrained by its mates - it can't be moved.";
    if (mobility == 0) return 'Its mates lock this component in place.';
    return null;
  }

  /// One line for the assembly panel: group dof and grounding.
  String get summary {
    final d = dof;
    if (d == null) return '';
    final parts = <String>[d == 0 ? 'Fully constrained (0 DOF)' : 'Group: $d DOF'];
    if (grounded == false) parts.add('not grounded');
    if (d > 0 && mobility == 0) parts.add('this component is locked');
    return parts.join(' - ');
  }
}

List<double> _col(Mat3 r, int c) => <double>[r.at(0, c), r.at(1, c), r.at(2, c)];

/// Builds the freedom from an already-built projector ([model]: refs + weighted rows + `L`).
GizmoFreedom gizmoFreedomFromModel(FreeMotionProjector model, {int? dof, bool? grounded, int? mobility}) {
  final pose = model.refs[0];
  final lever = model.lever;
  final width = 6 * model.members;
  final axes = <List<double>>[for (var i = 0; i < 3; i++) _col(pose.r, i)];

  List<double> twist(List<double> v, List<double> w) {
    final t = List<double>.filled(width, 0);
    for (var i = 0; i < 3; i++) {
      t[i] = v[i];
      t[3 + i] = w[i];
    }
    return t;
  }

  const zero = <double>[0, 0, 0];
  double fractionOf(List<double> t, List<double> projected) {
    final n = weightedNorm(model.scale, t);
    return n == 0 ? 0 : math.min(1.0, weightedNorm(model.scale, projected) / n);
  }

  final translate = <HandleFreedom>[];
  final rotate = <HandleFreedom>[];
  for (var i = 0; i < 3; i++) {
    final a = axes[i];
    final tt = twist(a, zero);
    translate.add(HandleFreedom(fractionOf(tt, projectOntoRows(model.rows, model.scale, tt))));

    final tr = twist(zero, a);
    final pr = projectOntoRows(model.rows, model.scale, tr);
    final f = fractionOf(tr, pr);
    List<double>? pivot, pivotAxis;
    if (f >= 0.2) {
      final w = <double>[pr[3], pr[4], pr[5]];
      final wn = norm3(w);
      if (wn > 1e-9) {
        final wh = <double>[w[0] / wn, w[1] / wn, w[2] / wn];
        if (wh[0] * a[0] + wh[1] * a[1] + wh[2] * a[2] >= kPivotAxisCos) {
          // Spatial translational part of the twist, then the axis point nearest the origin, then nearest the part.
          final wxt = cross3(w, pose.t);
          final u = <double>[pr[0] - wxt[0], pr[1] - wxt[1], pr[2] - wxt[2]];
          final wu = cross3(w, u);
          final q0 = <double>[wu[0] / (wn * wn), wu[1] / (wn * wn), wu[2] / (wn * wn)];
          final s = (pose.t[0] - q0[0]) * wh[0] + (pose.t[1] - q0[1]) * wh[1] + (pose.t[2] - q0[2]) * wh[2];
          final q = <double>[q0[0] + wh[0] * s, q0[1] + wh[1] * s, q0[2] + wh[2] * s];
          final off = norm3(<double>[q[0] - pose.t[0], q[1] - pose.t[1], q[2] - pose.t[2]]);
          if (off > kPivotMinOffsetFraction * math.max(lever, 1.0)) {
            pivot = q;
            pivotAxis = wh;
          }
        }
      }
    }
    // A pivot means the ring turns about a real screw axis of the free motion: dragged about it, it is fully free.
    rotate.add(HandleFreedom(pivot == null ? f : 1.0, pivot: pivot, pivotAxis: pivotAxis));
  }

  return GizmoFreedom(
    translate: translate,
    rotate: rotate,
    axes: axes,
    planeNormal: _planeNormal(model),
    dof: dof,
    grounded: grounded,
    mobility: mobility,
  );
}

/// Normal of the free pure-translation plane, or null unless that space is exactly 2-D: the eigen-decomposition of
/// `M_ij = ⟨[e_i,0], P [e_j,0]⟩` (anchor-frame unit vectors) has exactly two eigenvalues ≈ 1.
List<double>? _planeNormal(FreeMotionProjector model) {
  final width = 6 * model.members;
  final proj = <List<double>>[];
  final e = <List<double>>[];
  for (var j = 0; j < 3; j++) {
    final t = List<double>.filled(width, 0)..[j] = 1.0;
    e.add(t);
    proj.add(projectOntoRows(model.rows, model.scale, t));
  }
  final m = <List<double>>[
    for (var i = 0; i < 3; i++) <double>[for (var j = 0; j < 3; j++) weightedDot(model.scale, e[i], proj[j])],
  ];
  final (vals, vecs) = _jacobiEigen3(m);
  var free = 0;
  var lowest = 0;
  for (var k = 0; k < 3; k++) {
    if (vals[k] >= kPlaneFreeAtLeast) free++;
    if (vals[k] < vals[lowest]) lowest = k;
  }
  if (free != 2) return null;
  return <double>[vecs[0][lowest], vecs[1][lowest], vecs[2][lowest]];
}

/// Symmetric 3x3 Jacobi eigen-decomposition: (eigenvalues, eigenvectors as columns).
(List<double>, List<List<double>>) _jacobiEigen3(List<List<double>> input) {
  final a = <List<double>>[for (final r in input) List<double>.of(r)];
  final v = <List<double>>[
    <double>[1, 0, 0],
    <double>[0, 1, 0],
    <double>[0, 0, 1],
  ];
  for (var sweep = 0; sweep < 24; sweep++) {
    var off = 0.0;
    for (var p = 0; p < 3; p++) {
      for (var q = p + 1; q < 3; q++) {
        off += a[p][q] * a[p][q];
      }
    }
    if (off < 1e-30) break;
    for (var p = 0; p < 3; p++) {
      for (var q = p + 1; q < 3; q++) {
        if (a[p][q].abs() < 1e-300) continue;
        final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
        final t = (theta >= 0 ? 1.0 : -1.0) / (theta.abs() + math.sqrt(theta * theta + 1));
        final c = 1 / math.sqrt(t * t + 1);
        final s = t * c;
        for (var k = 0; k < 3; k++) {
          final akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (var k = 0; k < 3; k++) {
          final apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (var k = 0; k < 3; k++) {
          final vkp = v[k][p], vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  return (<double>[a[0][0], a[1][1], a[2][2]], v);
}

/// The freedom a `mate-motion` answer implies, or `null` when it carries no usable model (`converged:false`,
/// missing basis/chart): the gizmo then simply shows every handle as usual - a failed answer is never read as
/// "locked" nor as "free".
GizmoFreedom? gizmoFreedomFromAnchor(MateMotionDto r) {
  if (!r.converged) return null;
  final mobility = r.members.isEmpty ? null : r.members.first.mobility;
  final model = projectorFromMateMotion(r);
  if (model == null) {
    // dof 0 has an empty basis; the projector is still buildable (no rows), so null here means unusable.
    return null;
  }
  return gizmoFreedomFromModel(model, dof: r.dof, grounded: r.grounded, mobility: mobility);
}
