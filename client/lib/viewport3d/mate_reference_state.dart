import '../api/document_api_client.dart';

/// N1d (`docs/mates-storage-sessions-plan-2026-11-12.md`, "N1 plan" and "N1b results"): what the backend says about a mate's references,
/// as a row subtitle in the Assembly tree and the two reference actions of the mate context menu. Pure functions over [MateDto]; the
/// wire fields are parsed there. The VR client's twin is `scripts/mate_reference_state.gd` (DIDSA-VR PR #88).
///
/// Neither client changes how it picks or creates a mate, and a mates listing does not mark the document dirty (decision N-7).

/// What the row says: nothing, "followed" (info), "held" (amber, "check this mate") or "lost" (the reason).
enum MateReferenceKind { none, followed, held, lost }

class MateReferenceNote {
  final MateReferenceKind kind;
  final String text;
  const MateReferenceNote(this.kind, this.text);
  static const none = MateReferenceNote(MateReferenceKind.none, '');
}

/// The subtitle of a mate that followed an edit (kept client-side until "Got it").
const String kMateFollowedText = 'Followed the edit: same face, new number';

/// The amber subtitle of a held mate (the reason, when the backend gave one, is added after it).
const String kMateHeldText = 'Check this mate';

/// The reason codes the backend sends (`reference_reasons`), as a phrase. An unknown code reads as itself with the underscores removed.
const Map<String, String> kMateReferenceReasonText = {
  'no_match': 'its face is gone',
  'ambiguous': 'it cannot be told from a look-alike face',
  'body_missing': 'its body is gone',
  'unconfirmed': 'this file never confirmed which face it meant',
  'exact_place_among_twins': 'it followed the identical face in the same place',
  'nearest_radius': 'it followed the face of the same radius',
  'unique_fingerprint_far': 'the face moved a long way',
  'unique_fingerprint': 'it followed the face under its new number',
  'potentially_moved': 'the face may have moved',
};

String mateReferenceReasonText(String code) =>
    kMateReferenceReasonText[code] ?? code.replaceAll('_', ' ');

/// The first reason the backend gave for any of [paths] ("" when there is none).
String _firstReason(MateDto mate, List<String> paths) {
  for (final path in paths) {
    final code = mate.referenceReasons[path];
    if (code != null && code.isNotEmpty) return mateReferenceReasonText(code);
  }
  return '';
}

/// The one note a mate's row shows. Lost beats held beats followed (a mate can be held and have followed another reference). A mate from an
/// older backend, or one the backend flags nothing about, has none.
MateReferenceNote mateReferenceNote(MateDto mate) {
  if (mate.hasLostReference) {
    final why = _firstReason(mate, mate.lostReferences);
    return MateReferenceNote(MateReferenceKind.lost, why.isEmpty ? 'Lost a face' : 'Lost a face: $why');
  }
  if (mate.needsConfirm) {
    final why = _firstReason(mate, mate.movedReferences);
    return MateReferenceNote(MateReferenceKind.held, why.isEmpty ? kMateHeldText : '$kMateHeldText: $why');
  }
  if (mate.hasFollowedReference) return const MateReferenceNote(MateReferenceKind.followed, kMateFollowedText);
  return MateReferenceNote.none;
}

/// The context-menu actions this mate's references offer: Confirm only for a held mate (a lost one has nothing to confirm),
/// "Got it" only while a followed note is showing.
bool mateOffersConfirm(MateDto mate) => mate.needsConfirm;
bool mateOffersGotIt(MateDto mate) => mate.hasFollowedReference;

/// A followed reference is reported ONCE: the backend persists the new index, so the next listing is clean. The screen keeps what it was
/// told here (mate id -> paths and reasons), merges it back into every later listing, and forgets it on "Got it". No polling.
class MateFollowedNotes {
  final Map<String, List<String>> _paths = {};
  final Map<String, Map<String, String>> _reasons = {};

  bool get isEmpty => _paths.isEmpty;
  bool has(String mateId) => _paths.containsKey(mateId);

  /// Drops the note for [mateId] ("Got it").
  void dismiss(String mateId) {
    _paths.remove(mateId);
    _reasons.remove(mateId);
  }

  /// Remembers what [listed] newly reports as followed, forgets mates no longer listed, and returns [listed] with every kept note put back
  /// (the dictionaries of the backend's answer are not changed; a mate with a note comes back as a copy).
  List<MateDto> merge(List<MateDto> listed) {
    final ids = {for (final m in listed) m.id};
    _paths.removeWhere((id, _) => !ids.contains(id));
    _reasons.removeWhere((id, _) => !ids.contains(id));
    final out = <MateDto>[];
    for (final mate in listed) {
      if (mate.hasFollowedReference) {
        final kept = _paths.putIfAbsent(mate.id, () => []);
        for (final p in mate.followedReferences) {
          if (!kept.contains(p)) kept.add(p);
        }
        (_reasons.putIfAbsent(mate.id, () => {})).addAll({
          for (final p in mate.followedReferences)
            if (mate.referenceReasons[p] != null) p: mate.referenceReasons[p]!,
        });
      }
      final kept = _paths[mate.id];
      out.add(kept == null ? mate : mate.withFollowed(kept, _reasons[mate.id] ?? const {}));
    }
    return out;
  }
}
