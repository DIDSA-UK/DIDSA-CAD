/// The live constrained-drag controller (plan S7; `docs/motion/projector-spec.md`
/// §7-§12). One instance per gizmo drag of a MATED occurrence.
///
/// It owns the projector state (DofHysteresis -> active model, MotionBlender,
/// ReanchorScheduler, MotionCounters) and the network loop, and nothing else:
/// pure Dart, an injected `mate-motion` call and an injected clock, so the whole
/// drag (request count, hold/resume, commit, restore) is testable without a
/// widget tree. The caller feeds it the hand's WISHED grabbed pose each frame
/// ([update]) and draws the returned poses for every member.
///
/// Composition order is the one DIDSA-VR `mates_tool.gd` measured (60-frame
/// drag = 6 requests): on an accepted anchor `old = peek(wish)` (or the HELD
/// poses after `blender.reset` when holding), `hysteresis.onAnchor`,
/// `blender.onAnchor(old, peek(wish))`; on a dof-rise adoption blend from the
/// poses the old directions showed; [acceptAnchor] gets the GRABBED pose the
/// current model projects the same wish to.
library;

import 'dart:async';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import 'anchor_acceptance.dart';
import 'dof_hysteresis.dart';
import 'free_motion_projector.dart';
import 'mate_motion_bridge.dart';
import 'motion_blender.dart';
import 'motion_counters.dart';
import 'reanchor_scheduler.dart';
import 'se3.dart';

/// The one endpoint the session needs; [DocumentApiClient.mateMotion] has exactly this shape.
typedef MateMotionCall = Future<MateMotionDto> Function(
  String partId,
  String occurrenceId, {
  RigidTransformDto? transform,
  double? leverArm,
  bool commit,
  List<MateMotionMemberDto>? reference,
});

/// Poses to draw for one frame, [ids] and [poses] in member order (grabbed first).
class DragFrame {
  final List<String> ids;
  final List<Pose> poses;

  /// `true` while the last poses are being held (converged:false / rejected anchor / transport error).
  final bool held;

  const DragFrame(this.ids, this.poses, {this.held = false});
}

/// Outcome of the release commit (spec §12).
class DragCommit {
  /// `true` = the backend stored the group; [poses] are the stored poses of every member.
  final bool committed;
  final Map<String, Pose> poses;

  /// The raw response (null after a transport failure), for diagnostics.
  final MateMotionDto? response;

  /// User-facing reason when nothing was stored.
  final String? message;

  const DragCommit({required this.committed, this.poses = const <String, Pose>{}, this.response, this.message});
}

class ConstrainedDragSession {
  final MateMotionCall _call;
  final String partId;
  final String grabbedId;
  final double Function() _nowMs;

  /// Fired at most once per second after 3 consecutive anchor misses (spec §11), e.g. to show "can't follow that move".
  final void Function(String message)? onCue;

  /// Warm start (default on): send the last accepted anchor's member poses as `reference` with every request after the
  /// first, so the backend measures "nearest" from where the drag is rather than from the grab-time pose. Measured on
  /// floating multi-part groups: follower jerk 40.7 -> 0.07 weighted mm/frame (`tools/motion_smoothness/`).
  final bool useReference;

  /// Instrumentation for the F1 gate; owned by the session (read it after [finish]).
  final MotionCounters counters;

  final DofHysteresis _hyst = DofHysteresis();
  final ReanchorScheduler _sched;
  MotionBlender _blender = MotionBlender(1);

  /// Sent on every request until the first accepted anchor, afterwards the echoed `chart.lever_arm`. 0 = unknown (omitted).
  double _lever;

  List<String> _ids = <String>[];
  MateMotionDto? _anchor;
  Pose? _lastWish;
  List<Pose>? _shown;
  List<Pose>? _held;
  bool _holding = false;
  bool _dirty = false;
  bool _finishing = false;
  int _token = 0;
  double _lastSentMs = -1e9;
  Future<void>? _firstRequest;
  Pose? _prevShownGrabbed;

  ConstrainedDragSession({
    required MateMotionCall call,
    required this.partId,
    required this.grabbedId,
    required double leverArm,
    required double Function() nowMs,
    this.onCue,
    MotionCounters? counters,
    this.useReference = true,
  })  : _call = call,
        _lever = leverArm,
        _nowMs = nowMs,
        _sched = ReanchorScheduler(nowMs),
        counters = counters ?? MotionCounters();

  /// `true` once an anchor has been accepted (a model exists).
  bool get hasModel => _hyst.active != null;

  /// `true` while the last poses are held (see [DragFrame.held]).
  bool get holding => _holding;

  /// The last accepted anchor response (group `dof`, `grounded`, per-member `mobility`), or null before the first.
  MateMotionDto? get anchor => _anchor;

  /// Member ids of the accepted model, grabbed first; empty before the first anchor.
  List<String> get memberIds => List<String>.unmodifiable(_ids);

  /// The hand's last wish.
  Pose? get lastWish => _lastWish;

  /// Completes when the grab anchor's response has been processed. Call once, at grab.
  Future<void> begin() => _firstRequest ??= _sendAnchor(reason: null);

  /// One frame: [wish] = the pose the hand wants for the grabbed occurrence. Schedules a re-anchor if due and returns the
  /// poses to draw for every member, or `null` while no model exists yet (nothing is shown moving; the caller keeps the
  /// pre-grab poses - the grab anchor is on its way).
  DragFrame? update(Pose wish) {
    if (_finishing) return null;
    _lastWish = wish;
    _maybeRequest();
    return _frame(wish);
  }

  /// Timer tick for an idle pointer: keeps the retry/re-anchor cadence going and returns a frame only when an anchor was
  /// accepted since the last frame (so a held drag resumes without waiting for the next pointer move).
  DragFrame? poll() {
    if (_finishing) return null;
    _maybeRequest();
    final wish = _lastWish;
    if (!_dirty || wish == null) return null;
    return _frame(wish);
  }

  DragFrame? _frame(Pose wish) {
    _dirty = false;
    if (!hasModel) return null;
    final ids = _ids;
    final List<Pose> poses = counters.timeFrame(() {
      if (_holding) return _held!;
      final frame = _hyst.frame(wish);
      final prev = frame.prevPoses;
      if (frame.event == 'adopted' && prev != null) _blender.onAnchor(prev, frame.poses);
      return _blender.shown(frame.poses);
    });
    if (!_holding) {
      _shown = poses;
      final before = _prevShownGrabbed;
      if (before != null) counters.recordShownStep(weightedDist(poses[0], before, _lever));
    }
    _prevShownGrabbed = poses[0];
    return DragFrame(ids, poses, held: _holding);
  }

  void _maybeRequest() {
    if (_finishing || _sched.inFlight) return;
    String? reason;
    if (!hasModel) {
      reason = 'grab';
    } else {
      final shown = _shown;
      final travel = (_holding || shown == null) ? 0.0 : _hyst.active!.travel(shown[0]);
      final d = _sched.check(travel);
      if (!d.reanchor) return;
      reason = d.reason;
    }
    // After a miss keep the normal cadence: never re-ask faster than the time cap (the scheduler's t_anchor is not restarted).
    if (_sched.consecutiveMisses > 0 && _nowMs() - _lastSentMs < kReanchorMs) return;
    unawaited(_sendAnchor(reason: reason == 'grab' ? null : reason));
  }

  Future<void> _sendAnchor({required String? reason}) async {
    final first = !hasModel;
    final wishSent = first ? null : _lastWish;
    final token = _token;
    _sched.onRequestSent();
    _lastSentMs = _nowMs();
    counters.recordRequest();
    if (reason != null && reason != 'grab') counters.recordReanchor(reason);
    MateMotionDto? response;
    String? failure;
    try {
      response = await _call(
        partId,
        grabbedId,
        transform: wishSent == null ? null : dtoOfPose(wishSent),
        leverArm: _lever > 0 ? _lever : null,
        commit: false,
        reference: useReference ? _anchor?.members : null,
      );
    } on ApiException catch (e) {
      failure = e.statusCode == null ? 'transport' : 'http_${e.statusCode}';
    } catch (_) {
      failure = 'transport';
    }
    if (token != _token || _finishing) return; // released while in flight: the answer is ignored, the commit follows
    counters.recordResponse();
    if (response == null) {
      _miss(failure ?? 'transport');
      return;
    }
    _handleResponse(response, wishSent);
  }

  void _handleResponse(MateMotionDto r, Pose? wishSent) {
    final model = projectorFromMateMotion(r);
    final usable = model != null;
    final lever = model?.lever ?? _lever;
    Pose? own;
    if (usable && hasModel && wishSent != null) own = _hyst.peek(wishSent)[0];
    final decision = acceptAnchor(
      converged: usable,
      residualInf: r.quality.residualInf,
      anchorGrabbed: usable ? model.refs[0] : null,
      ownProjection: own,
      lever: lever,
    );
    if (!decision.accept) {
      // A converged answer with no usable model (missing basis/chart) counts as not_converged, never "all free".
      _miss(r.converged && !usable ? 'not_converged' : decision.reason);
      return;
    }
    _accept(r, model!);
  }

  void _accept(MateMotionDto r, FreeMotionProjector model) {
    final ids = <String>[for (final m in r.members) m.occurrenceId];
    final wish = _lastWish;
    final first = !hasModel;
    if (first || !_sameIds(ids, _ids)) {
      // First anchor, or the group changed under the drag: a fresh model and blender.
      _ids = ids;
      _hyst.reset();
      _blender = MotionBlender(ids.length);
      _hyst.onAnchor(model);
      _holding = false;
      _held = null;
      _shown = null;
      _prevShownGrabbed = null;
    } else {
      final List<Pose> old = _holding ? _held! : _hyst.peek(wish!);
      if (_holding) _blender.reset();
      _hyst.onAnchor(model);
      _blender.onAnchor(old, _hyst.peek(wish!));
      _holding = false;
      _held = null;
    }
    _lever = model.lever;
    _anchor = r;
    _sched.onAccepted(maxStep: r.quality.maxStep, sigmaGap: r.quality.sigmaGap);
    counters.recordAccepted();
    _dirty = true;
  }

  void _miss(String reason) {
    _sched.onMiss();
    counters.recordRejected(reason);
    if (reason == 'transport') counters.recordTransportError();
    if (hasModel && !_holding) {
      // HOLD the last shown pose; a failed answer is never read as "all free" and there is no extrapolation.
      _holding = true;
      final wish = _lastWish;
      _held = _shown ?? (wish == null ? null : _hyst.peek(wish));
      if (_held == null) {
        _holding = false;
      } else {
        counters.recordHold();
      }
    }
    if (_sched.takeCue()) onCue?.call("Can't follow that move with the current mates");
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Release (spec §12): stops the loop, ignores any in-flight answer and sends ONE `commit: true` request with the
  /// release-time WISH ([wish], default the last wish; never the shown pose). A transport error is retried once; nothing
  /// else is. On success the response's member poses are the stored ones; otherwise nothing was stored and the caller
  /// restores every member to its pre-grab pose.
  Future<DragCommit> finish({Pose? wish}) async {
    _finishing = true;
    _token++;
    _sched.invalidate();
    final w = wish ?? _lastWish;
    MateMotionDto? result;
    String? message;
    for (var attempt = 0; attempt < 2; attempt++) {
      counters.recordRequest(commit: true);
      try {
        result = await _call(
          partId,
          grabbedId,
          transform: w == null ? null : dtoOfPose(w),
          leverArm: _lever > 0 ? _lever : null,
          commit: true,
          reference: useReference ? _anchor?.members : null,
        );
        break;
      } on ApiException catch (e) {
        if (e.statusCode == null) {
          counters.recordTransportError();
          message = e.message;
          if (attempt == 0) continue; // only a transport error (no HTTP answer at all) is retried, once
        } else {
          message = e.message;
        }
        break;
      } catch (e) {
        counters.recordTransportError();
        message = '$e';
        if (attempt == 0) continue;
        break;
      }
    }
    final r = result;
    if (r != null && r.converged && r.committed) {
      return DragCommit(
        committed: true,
        poses: <String, Pose>{for (final m in r.members) m.occurrenceId: poseOfDto(m.transform)},
        response: r,
      );
    }
    if (r != null) message = "The mates can't satisfy that move";
    return DragCommit(committed: false, response: r, message: message ?? 'Could not keep that move');
  }
}

/// Why the gizmo can't (or barely can) move a component, from an anchor / commit answer; `null` = nothing to say
/// (S8 adds the per-handle cues, this is text only).
String? constrainedDragNotice(MateMotionDto? r) {
  if (r == null || !r.converged) return null;
  if (r.dof == 0) return "Fully constrained by its mates - it can't be moved.";
  if (r.members.isNotEmpty && r.members.first.mobility == 0) return 'Its mates lock this component in place.';
  return null;
}
