import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// LOD Phase 2 chunk 4 (`docs/lod-strategy/02-phase2-design.md` SS6 item 4):
/// the in-flight job-mode Feature-create request `PartScreen` should be
/// tracking - saved by `BevelDesignScreen`/`GearChainDesignScreen` the
/// moment a job-mode create call returns its `job_id` (before navigating to
/// `PartScreen`), and read back by `PartScreen` itself - both for the
/// ordinary "just started this job" case and the resume-on-reconnect case
/// (the app was closed/backgrounded while the job was still running
/// server-side, and a later launch reaches the same Part id again). One
/// slot only, matching this app's own "always start fresh, one Document/
/// Part in flight" convention (`PartScreen`'s own class doc comment) and
/// the backend's own one-job-at-a-time-per-process concurrency policy
/// (`02-phase2-design.md` SS5) - there is never more than one job-mode
/// create genuinely in flight at once.
class PendingFeatureJob {
  static const String kindBevelPair = 'bevel_pair';
  static const String kindPlanetaryGear = 'planetary_gear';

  final String partId;
  final String jobId;

  /// [kindBevelPair] or [kindPlanetaryGear] - which coarse-preview endpoint
  /// and job-mode create endpoint this job belongs to (see
  /// `DocumentApiClient.previewBevelPairFeatureCoarse`/
  /// `previewPlanetaryGearFeatureCoarse`).
  final String featureKind;

  /// The exact wire payload the job-mode create call was submitted with
  /// (`DocumentApiClient.bevelPairFeatureJson`/`planetaryGearFeatureJson`) -
  /// reused verbatim for the coarse-preview call, so the placeholder shown
  /// while polling is built from the same parameters the real job is
  /// resolving, not a re-derived approximation from whatever a design
  /// screen's own form fields happen to hold by the time it's read back.
  final Map<String, dynamic> coarsePreviewPayload;

  const PendingFeatureJob({
    required this.partId,
    required this.jobId,
    required this.featureKind,
    required this.coarsePreviewPayload,
  });

  Map<String, dynamic> toJson() => {
        'part_id': partId,
        'job_id': jobId,
        'feature_kind': featureKind,
        'coarse_preview_payload': coarsePreviewPayload,
      };

  factory PendingFeatureJob.fromJson(Map<String, dynamic> json) => PendingFeatureJob(
        partId: json['part_id'] as String,
        jobId: json['job_id'] as String,
        featureKind: json['feature_kind'] as String,
        coarsePreviewPayload: (json['coarse_preview_payload'] as Map).cast<String, dynamic>(),
      );
}

/// `shared_preferences`-backed persistence for [PendingFeatureJob] - same
/// load-then-read/save-per-call convention `ViewPreferences`
/// (`view_preferences.dart`) already establishes for this app's other
/// client-only local state, minus the in-memory cache (this is read/written
/// far less often - once per job, not once per frame).
class PendingJobStore {
  PendingJobStore._();

  static const String _prefKey = 'lod_pending_feature_job';

  static Future<void> save(PendingFeatureJob job) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(job.toJson()));
  }

  /// Null if nothing is pending, or if a stored entry exists but is
  /// unreadable (a future client version's own shape, corrupt storage) -
  /// either way, treated as "nothing to resume" rather than throwing.
  static Future<PendingFeatureJob?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null) return null;
    try {
      return PendingFeatureJob.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
