/// M3 (`docs/mates-storage-sessions-plan-2026-11-12.md`): the glide preview of a mate. The real parts move from their STORED pose to the pose
/// `preview-mate-solve` returned (about a quarter of a second, ease in-out) instead of a translucent copy appearing there; a new preview glides from where
/// the part is; Cancel glides it back; Confirm keeps it there (the backend stores exactly that pose), so nothing jumps.
///
/// Pure (no Flutter): the model of where each previewed occurrence is at a given time. `PartScreen` owns one, drives it from a timer and draws the poses
/// it returns through the same instance override the constrained drag uses. Poses are local to the focused part (the frame `Occurrence.transform` is in).
library;

import '../api/document_api_client.dart';
import '../motion/mate_motion_bridge.dart';
import '../motion/se3.dart';
import 'assembly_instance_render.dart' show MatePreviewMember;

/// How long a glide takes. Feel is the owner's to judge on the device.
const double kMatePreviewGlideSeconds = 0.25;

double _ease(double t) => t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2) / 2;

class _Move {
  _Move(this.from, this.to, this.startedAt);
  final Pose from;
  final Pose to;
  final double startedAt;
}

class MatePreviewGlide {
  MatePreviewGlide({this.seconds = kMatePreviewGlideSeconds});

  final double seconds;

  /// occurrence id -> the pose the backend has (where Cancel goes). Set the first time the occurrence is previewed and kept until it is home again.
  final Map<String, Pose> _stored = <String, Pose>{};
  final Map<String, _Move> _moves = <String, _Move>{};

  /// Ids whose glide is going back to the stored pose: dropped once it arrives.
  final Set<String> _homeward = <String>{};

  /// Whether anything is previewed or still on its way home.
  bool get isActive => _moves.isNotEmpty;

  /// The occurrence ids the glide draws (previewed ones and ones gliding home).
  Iterable<String> get ids => _moves.keys;

  Pose _poseAt(_Move m, double now) {
    final t = seconds <= 0 ? 1.0 : ((now - m.startedAt) / seconds).clamp(0.0, 1.0);
    if (t >= 1.0) return m.to;
    final d = poseDelta(m.to, m.from);
    final e = _ease(t);
    return applyDelta(m.from, <double>[for (final x in d) x * e]);
  }

  /// The pose [id] shows at [now] (null when the glide does not draw it).
  Pose? poseOf(String id, double now) {
    final m = _moves[id];
    return m == null ? null : _poseAt(m, now);
  }

  /// A new preview: every member glides from where it is now to its solved pose; an occurrence that was previewed but is not in [members] any more glides home.
  void retarget(List<MatePreviewMember> members, double now) {
    final wanted = <String>{for (final m in members) m.occurrenceId};
    for (final id in _moves.keys.toList()) {
      if (wanted.contains(id)) continue;
      final here = _poseAt(_moves[id]!, now);
      _moves[id] = _Move(here, _stored[id]!, now);
      _homeward.add(id);
    }
    for (final member in members) {
      final id = member.occurrenceId;
      _stored.putIfAbsent(id, () => poseOfDto(member.previous));
      final existing = _moves[id];
      final from = existing == null ? _stored[id]! : _poseAt(existing, now);
      _moves[id] = _Move(from, poseOfDto(member.next), now);
      _homeward.remove(id);
    }
  }

  /// Cancel (or a preview with nothing to show): everything glides back.
  void cancel(double now) => retarget(const <MatePreviewMember>[], now);

  /// Confirm: the parts stay exactly where the preview put them. The glide jumps to the end of its move (nothing to animate: the stored poses are about to be
  /// these) and keeps drawing them until [clear], so the overlay can be dropped once the refreshed poses are in.
  void commit() {
    for (final id in _moves.keys.toList()) {
      final m = _moves[id]!;
      _moves[id] = _Move(m.to, m.to, -1e18); // long finished
    }
    _homeward.clear();
  }

  /// Drops the moves that finished going home. True when something was dropped (a repaint is due once more).
  bool settle(double now) {
    var dropped = false;
    for (final id in _homeward.toList()) {
      final m = _moves[id];
      if (m == null || now - m.startedAt >= seconds) {
        _moves.remove(id);
        _stored.remove(id);
        _homeward.remove(id);
        dropped = true;
      }
    }
    return dropped;
  }

  /// Whether any move is still under way at [now].
  bool isAnimating(double now) => _moves.values.any((m) => now - m.startedAt < seconds);

  /// The poses of every drawn occurrence at [now], as wire poses (local to the focused part).
  Map<String, RigidTransformDto> posesAt(double now) => <String, RigidTransformDto>{
        for (final e in _moves.entries) e.key: dtoOfPose(_poseAt(e.value, now)),
      };

  /// The outline that stays behind: each occurrence being previewed (not the ones going home) at its STORED pose, in the shape the ghost rendering takes.
  List<MatePreviewMember> outline() => <MatePreviewMember>[
        for (final e in _moves.entries)
          if (!_homeward.contains(e.key))
            MatePreviewMember(occurrenceId: e.key, previous: dtoOfPose(_stored[e.key]!), next: dtoOfPose(_stored[e.key]!)),
      ];

  /// Forgets everything at once (the refreshed stored poses are in, or the screen is closing).
  void clear() {
    _moves.clear();
    _stored.clear();
    _homeward.clear();
  }
}
