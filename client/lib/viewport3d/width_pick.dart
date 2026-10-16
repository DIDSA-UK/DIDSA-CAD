import '../api/document_api_client.dart';
import '../assembly/occurrence_visibility.dart';
import 'selection_hit_test.dart';

/// The UI-only mate type of a Width mate (`docs/width-mate-plan.md`): the panel offers it next to the real types; what is
/// sent is a plain `coincident` (centred) or `distance` (offset from centre) mate whose two references are mid-planes.
const String kWidthMateType = 'width';

/// The UI-only mate type of a Symmetric mate (`docs/width-mate-plan.md` W5): two faces that mirror each other about a plane - a left and
/// a right bracket either side of a centre plane. Three picks: face 1, face 2, the mirror plane (a face of a third part). Sent as a
/// plain `coincident` mate of `[midplane(face 1, face 2), mirror plane]`: two faces mirror each other about P exactly when the plane
/// midway between them is P, so no new mate type or reference is needed (points and axes would need one; not built).
const String kSymmetricMateType = 'symmetric';

/// Whether [type] is picked as a [WidthPick] (several faces) rather than the usual two entities.
bool isMultiPickMateType(String type) => type == kWidthMateType || type == kSymmetricMateType;

/// The four-pick state of a Width mate being authored: the gap pair (two parallel faces, of one part or of two, e.g. the inner
/// faces of a frame or of two loose bars) and the tab pair (two parallel faces of the part(s) centred between them). Owned by the mate
/// panel; nothing here is ever sent anywhere except the finished [references].
class WidthPick {
  final List<SelectionEntityRef> picks;

  /// A Symmetric mate (3 picks: the two mirrored faces, then the mirror plane) rather than a Width mate (4 picks).
  final bool symmetric;

  const WidthPick([this.picks = const [], this.symmetric = false]);

  int get total => symmetric ? 3 : 4;

  bool get isComplete => picks.length == total;
  bool get isEmpty => picks.isEmpty;

  /// The faces in pick order: gap 1, gap 2, tab 1, tab 2.
  List<SelectionEntityRef> get entities => picks;

  List<SelectionEntityRef> get gap => picks.take(2).toList();
  List<SelectionEntityRef> get tab => picks.skip(2).take(2).toList();

  /// "1 of 4 - first face of the gap" ...; "Ready" once complete.
  String get progress {
    if (isComplete) return '$total of $total - ready';
    final n = picks.length + 1;
    return '$n of $total - ${_stepName(picks.length)}';
  }

  String _stepName(int index) => (symmetric
      ? const [
          'first face to mirror',
          'second face to mirror (on another part)',
          'a face of the mirror plane (on a third part)',
        ]
      : const [
          'first face of the gap',
          'second face of the gap (same part or another)',
          'first face of the part to centre',
          'second face of the part to centre (same part or another)',
        ])[index];

  /// The label of slot [index] in the panel list.
  String slotLabel(int index) => (symmetric
      ? const ['Face 1', 'Face 2', 'Mirror plane']
      : const ['Gap face 1', 'Gap face 2', 'Tab face 1', 'Tab face 2'])[index];

  /// Why [entity] cannot be the next pick, or `null` when it can. Faces only; the part(s) of the tab pair must differ from the part(s)
  /// of the gap pair. A pair may span two parts (the Width mate then involves 3 or 4 parts).
  String? rejection(SelectionEntityRef entity) {
    if (entity.kind != SelectionEntityKind.face) return '${symmetric ? 'A Symmetric' : 'A Width'} mate is made from faces';
    if (isComplete) return 'Already ${symmetric ? 'three' : 'four'} faces - remove one first';
    if (picks.contains(entity)) return null; // a toggle-off, handled by [toggle]
    // Either pair may be made of two parts (two loose bars, a plate of two parts); the part(s) to centre just must not be a part of
    // the gap itself.
    if (picks.length >= 2) {
      final gapParts = {for (final g in picks.take(2)) topLevelOccurrenceId(g.occurrenceId)};
      if (gapParts.contains(topLevelOccurrenceId(entity.occurrenceId))) {
        return symmetric
            ? 'The mirror plane must be a face of a different part from the two faces being mirrored'
            : 'The part to centre must be a different part from the gap';
      }
    }
    // Two mirrored faces on ONE part would be a Width (centred) mate, not a mirror of one part by another.
    if (symmetric &&
        picks.length == 1 &&
        topLevelOccurrenceId(picks.first.occurrenceId) == topLevelOccurrenceId(entity.occurrenceId)) {
      return 'The two mirrored faces must be on different parts';
    }
    return null;
  }

  /// Toggles [entity]: an already-picked face is removed (and every pick after it, which would no longer make sense), a new one
  /// is added when [rejection] allows. Returns the new state and the rejection reason, if any.
  (WidthPick, String?) toggle(SelectionEntityRef entity) {
    final at = picks.indexOf(entity);
    if (at != -1) return (WidthPick(picks.sublist(0, at), symmetric), null);
    final why = rejection(entity);
    if (why != null) return (this, why);
    return (WidthPick([...picks, entity], symmetric), null);
  }

  /// The last pick removed (the panel's Back).
  WidthPick back() => picks.isEmpty ? this : WidthPick(picks.sublist(0, picks.length - 1), symmetric);

  /// The two mid-plane references (gap first, tab second), when complete. Each is a mate reference whose `midplane` holds the
  /// two faces; the second face names its own occurrence when it differs from the first's.
  List<MateEntityRefDto> references() {
    assert(isComplete);
    MateEntityRefDto side(SelectionEntityRef a, SelectionEntityRef b) => MateEntityRefDto(
          occurrenceId: a.occurrenceId,
          midplane: MidplaneRefDto(
            a: PlaneRefDto(faceRef: SubShapeRefDto(bodyId: a.bodyId, shapeType: 'face', index: a.id)),
            b: PlaneRefDto(faceRef: SubShapeRefDto(bodyId: b.bodyId, shapeType: 'face', index: b.id)),
            bOccurrenceId: b.occurrenceId == a.occurrenceId ? null : b.occurrenceId,
          ),
        );
    if (symmetric) {
      // The mirror plane is an ordinary face reference on its own occurrence.
      final mirror = picks[2];
      return [
        side(picks[0], picks[1]),
        MateEntityRefDto(
          occurrenceId: mirror.occurrenceId,
          subshapeRef: SubShapeRefDto(bodyId: mirror.bodyId, shapeType: 'face', index: mirror.id),
        ),
      ];
    }
    return [side(picks[0], picks[1]), side(picks[2], picks[3])];
  }

  /// The mate type that is sent: a centred Width is a `coincident`; with an offset from the centre it is a `distance`.
  static String wireType(double? offset) => offset == null || offset == 0 ? 'coincident' : 'distance';

  /// The `value` that is sent for [offset] (`null` for the centred one).
  static double? wireValue(double? offset) => offset == null || offset == 0 ? null : offset;
}

/// Every top-level occurrence [mate] involves: its references' own, and the second face's of a Width reference spanning two parts.
Set<String> mateTopLevelOccurrences(MateDto mate) => {
      for (final r in mate.references) ...[
        topLevelOccurrenceId(r.occurrenceId),
        if (r.midplane?.bOccurrenceId != null) topLevelOccurrenceId(r.midplane!.bOccurrenceId!),
      ],
    };

/// A mate shown as "Symmetric": a mid-plane reference first and an ordinary one second (a Width mate has mid-planes on both sides).
bool isSymmetricMate(MateDto mate) =>
    mate.references.length == 2 && mate.references[0].midplane != null && mate.references[1].midplane == null;

/// A mate shown as "Width" in lists and titles: any of its references is a mid-plane.
bool isWidthMate(MateDto mate) => mate.references.any((r) => r.midplane != null) && !isSymmetricMate(mate);
