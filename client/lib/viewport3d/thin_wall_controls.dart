import 'package:material_ui/material_ui.dart';

/// On-device feedback ("add option to thicken in, out or from the middle"): which side of the sketched wire a thin wall grows on -
/// mirrors the backend's `thickness_direction` string values exactly, same `apiValue` / `fromApiValue` convention as `ExtrudeType`.
/// For a closed profile it reads against the profile's material (out = away from it); for a thin Revolve of an open chain it reads
/// against the revolve axis (out = away from the axis), see [ThinWallControls.openProfile].
enum ThicknessDirection {
  outward,
  inward,
  symmetric;

  String get apiValue => name;

  static ThicknessDirection fromApiValue(String value) =>
      ThicknessDirection.values.firstWhere((d) => d.apiValue == value, orElse: () => ThicknessDirection.outward);
}

/// The thin-wall block Extrude and Revolve share (Flutter-testing feedback 2026-11-11, item 5, lifted out of `ExtrudePanel` rather than
/// copied): a checkbox, a wall-thickness field and an Out / In / Middle choice. A dumb display: the owner keeps the state and the
/// controller, and re-reads [controller] when [onChanged] fires.
class ThinWallControls extends StatelessWidget {
  const ThinWallControls({
    super.key,
    required this.title,
    required this.isThin,
    required this.onThinChanged,
    required this.controller,
    required this.direction,
    required this.onDirectionChanged,
    required this.onChanged,
    this.thinDisabledSubtitle,
    this.locked = false,
    this.lockedHint,
    this.openProfile = false,
  });

  /// The checkbox label ("Thin extrude" / "Thin wall").
  final String title;
  final bool isThin;

  /// Null disables the checkbox (Extrude: draft is on).
  final ValueChanged<bool>? onThinChanged;
  final TextEditingController controller;
  final ThicknessDirection direction;
  final ValueChanged<ThicknessDirection> onDirectionChanged;

  /// The thickness field was edited.
  final VoidCallback onChanged;

  /// Shown under the checkbox while [onThinChanged] is null ("Not available with draft").
  final String? thinDisabledSubtitle;

  /// Thin is on and cannot be turned off (a Sketch with only an open profile can only be revolved as a thin wall).
  final bool locked;
  final String? lockedHint;

  /// An open profile has no inside or outside, so the direction is read against the axis: "Away from axis / Toward axis / Both sides".
  final bool openProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const ValueKey('thin-wall-toggle'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(title),
          subtitle: locked
              ? (lockedHint == null ? null : Text(lockedHint!))
              : (onThinChanged == null && thinDisabledSubtitle != null ? Text(thinDisabledSubtitle!) : null),
          value: isThin || locked,
          onChanged: locked || onThinChanged == null ? null : (value) => onThinChanged!(value ?? false),
        ),
        if (isThin || locked) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              key: const ValueKey('thin-wall-thickness'),
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Wall thickness'),
              onChanged: (_) => onChanged(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<ThicknessDirection>(
              key: const ValueKey('thin-wall-direction'),
              segments: [
                ButtonSegment(value: ThicknessDirection.outward, label: Text(openProfile ? 'Away from axis' : 'Out')),
                ButtonSegment(value: ThicknessDirection.inward, label: Text(openProfile ? 'Toward axis' : 'In')),
                ButtonSegment(value: ThicknessDirection.symmetric, label: Text(openProfile ? 'Both sides' : 'Middle')),
              ],
              selected: {direction},
              onSelectionChanged: (selection) => onDirectionChanged(selection.first),
            ),
          ),
        ],
      ],
    );
  }
}
