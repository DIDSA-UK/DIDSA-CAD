import '../api/document_api_client.dart';
import '../assembly/occurrence_visibility.dart';
import 'selection_hit_test.dart';

/// The UI-only mate type of a Width mate (`docs/width-mate-plan.md`): the panel offers it next to the real types; what is
/// sent is a plain `coincident` (centred) or `distance` (offset from centre) mate whose two references are mid-planes.
const String kWidthMateType = 'width';

/// The four-pick state of a Width mate being authored: the gap pair (two parallel faces of one part, e.g. the two inner
/// faces of a frame) and the tab pair (two parallel faces of the part that is centred between them). Owned by the mate
/// panel; nothing here is ever sent anywhere except the finished [references].
class WidthPick {
  final List<SelectionEntityRef> picks;

  const WidthPick([this.picks = const []]);

  static const int total = 4;

  bool get isComplete => picks.length == total;
  bool get isEmpty => picks.isEmpty;

  /// The faces in pick order: gap 1, gap 2, tab 1, tab 2.
  List<SelectionEntityRef> get entities => picks;

  List<SelectionEntityRef> get gap => picks.take(2).toList();
  List<SelectionEntityRef> get tab => picks.skip(2).take(2).toList();

  /// "1 of 4 - first face of the gap" ...; "Ready" once complete.
  String get progress {
    if (isComplete) return '4 of 4 - ready';
    final n = picks.length + 1;
    return '$n of $total - ${_stepName(picks.length)}';
  }

  static String _stepName(int index) => const [
        'first face of the gap',
        'second face of the gap (same part)',
        'first face of the part to centre',
        'second face of the part to centre (same part)',
      ][index];

  /// The label of slot [index] in the panel list.
  static String slotLabel(int index) => const ['Gap face 1', 'Gap face 2', 'Tab face 1', 'Tab face 2'][index];

  /// Why [entity] cannot be the next pick, or `null` when it can. Faces only; the second face of a pair must be another face
  /// under the same top-level occurrence; the tab pair must belong to a different top-level occurrence than the gap's.
  String? rejection(SelectionEntityRef entity) {
    if (entity.kind != SelectionEntityKind.face) return 'A Width mate is made from faces';
    if (isComplete) return 'Already four faces - remove one first';
    if (picks.contains(entity)) return null; // a toggle-off, handled by [toggle]
    final index = picks.length;
    if (index == 1 || index == 3) {
      final first = picks[index - 1];
      if (topLevelOccurrenceId(entity.occurrenceId) != topLevelOccurrenceId(first.occurrenceId)) {
        return 'Both faces of a pair must belong to the same part';
      }
    }
    if (index >= 2) {
      final gapTop = topLevelOccurrenceId(picks.first.occurrenceId);
      if (topLevelOccurrenceId(entity.occurrenceId) == gapTop) {
        return 'The part to centre must be a different part from the gap';
      }
    }
    return null;
  }

  /// Toggles [entity]: an already-picked face is removed (and every pick after it, which would no longer make sense), a new one
  /// is added when [rejection] allows. Returns the new state and the rejection reason, if any.
  (WidthPick, String?) toggle(SelectionEntityRef entity) {
    final at = picks.indexOf(entity);
    if (at != -1) return (WidthPick(picks.sublist(0, at)), null);
    final why = rejection(entity);
    if (why != null) return (this, why);
    return (WidthPick([...picks, entity]), null);
  }

  /// The last pick removed (the panel's Back).
  WidthPick back() => picks.isEmpty ? this : WidthPick(picks.sublist(0, picks.length - 1));

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
    return [side(picks[0], picks[1]), side(picks[2], picks[3])];
  }

  /// The mate type that is sent: a centred Width is a `coincident`; with an offset from the centre it is a `distance`.
  static String wireType(double? offset) => offset == null || offset == 0 ? 'coincident' : 'distance';

  /// The `value` that is sent for [offset] (`null` for the centred one).
  static double? wireValue(double? offset) => offset == null || offset == 0 ? null : offset;
}

/// A mate shown as "Width" in lists and titles: any of its references is a mid-plane.
bool isWidthMate(MateDto mate) => mate.references.any((r) => r.midplane != null);
