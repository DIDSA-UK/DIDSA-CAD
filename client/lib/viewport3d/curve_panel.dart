import 'package:flutter/material.dart';

/// Which of the two `CurveFeature` construction methods [CurvePanel] shows -
/// mirrors [CreatePlaneMode]'s own "picked by PartScreen before the panel
/// opens" convention, though for a Curve feature the mode is chosen by the
/// user directly (a segmented toggle at the top of the panel), not derived
/// from an ambient selection - a Helix and an Intersection curve have no
/// natural "already selected something in the viewport" trigger the way
/// Create Plane's face-selection-driven modes do.
enum CurveMode { helix, intersection }

/// A named Sketch feature, for the two dropdown pickers
/// [CurvePanel.intersection] uses - kept minimal (just what the dropdown
/// needs to display and identify a choice) rather than depending on this
/// file importing the full `document_api_client.dart` `FeatureDto`.
class SketchFeatureChoice {
  final String featureId;
  final String label;

  const SketchFeatureChoice({required this.featureId, required this.label});
}

/// The bottom-sheet-style panel for creating a Helix or an Intersection
/// curve - mirrors [CreatePlanePanel]'s own "dumb display, all picks/API
/// calls done by PartScreen" shape. v1 client scope: a Helix's axis is
/// always one of the three fixed reference planes (no 3D-viewport face/
/// plane picking yet - see `document_api_client.createCurveFeature`'s own
/// doc comment), and an Intersection curve's two Sketches are chosen from a
/// dropdown of this Part's existing Sketch features rather than tapped in
/// the viewport (neither a Body edge nor an existing Curve feature is a
/// selectable/tappable entity yet).
class CurvePanel extends StatefulWidget {
  final String title;
  final List<SketchFeatureChoice> sketchFeatureChoices;

  /// Fired on every valid Helix parameter edit (all four - `axisPlane`,
  /// `radius`, `pitch`, `turns` - plus `rightHanded` are always valid once
  /// present, so this only fires once all four numeric fields parse).
  final void Function({
    required String axisPlane,
    required double radius,
    required double pitch,
    required double turns,
    required bool rightHanded,
  })? onHelixChanged;

  /// Fired whenever both Intersection curve Sketch pickers have a value.
  final void Function({required String sketchFeatureIdA, required String sketchFeatureIdB})?
      onIntersectionChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const CurvePanel({
    super.key,
    this.title = 'Curve',
    this.sketchFeatureChoices = const [],
    this.onHelixChanged,
    this.onIntersectionChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<CurvePanel> createState() => _CurvePanelState();
}

class _CurvePanelState extends State<CurvePanel> {
  CurveMode _mode = CurveMode.helix;

  String _axisPlane = 'XY';
  bool _rightHanded = true;
  late final TextEditingController _radiusController;
  late final TextEditingController _pitchController;
  late final TextEditingController _turnsController;
  double? _radius = 5.0;
  double? _pitch = 2.0;
  double? _turns = 3.0;

  String? _sketchFeatureIdA;
  String? _sketchFeatureIdB;

  @override
  void initState() {
    super.initState();
    _radiusController = TextEditingController(text: '5');
    _pitchController = TextEditingController(text: '2');
    _turnsController = TextEditingController(text: '3');
  }

  @override
  void dispose() {
    _radiusController.dispose();
    _pitchController.dispose();
    _turnsController.dispose();
    super.dispose();
  }

  bool get _canConfirm => switch (_mode) {
        CurveMode.helix => _radius != null && _pitch != null && _turns != null,
        CurveMode.intersection => _sketchFeatureIdA != null &&
            _sketchFeatureIdB != null &&
            _sketchFeatureIdA != _sketchFeatureIdB,
      };

  void _emitHelixChange() {
    setState(() {
      _radius = double.tryParse(_radiusController.text);
      _pitch = double.tryParse(_pitchController.text);
      _turns = double.tryParse(_turnsController.text);
    });
    final radius = _radius, pitch = _pitch, turns = _turns;
    if (radius != null && pitch != null && turns != null) {
      widget.onHelixChanged?.call(
        axisPlane: _axisPlane,
        radius: radius,
        pitch: pitch,
        turns: turns,
        rightHanded: _rightHanded,
      );
    }
  }

  void _emitIntersectionChange() {
    final a = _sketchFeatureIdA, b = _sketchFeatureIdB;
    if (a != null && b != null && a != b) {
      widget.onIntersectionChanged?.call(sketchFeatureIdA: a, sketchFeatureIdB: b);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 4,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                SegmentedButton<CurveMode>(
                  segments: const [
                    ButtonSegment(value: CurveMode.helix, label: Text('Helix')),
                    ButtonSegment(value: CurveMode.intersection, label: Text('Intersection')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) => setState(() => _mode = selection.first),
                ),
                const SizedBox(height: 12),
                if (_mode == CurveMode.helix) ..._buildHelixFields() else ..._buildIntersectionFields(),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _canConfirm ? widget.onConfirm : null,
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildHelixFields() => [
        DropdownButtonFormField<String>(
          initialValue: _axisPlane,
          decoration: const InputDecoration(labelText: 'Axis plane'),
          items: const [
            DropdownMenuItem(value: 'XY', child: Text('XY')),
            DropdownMenuItem(value: 'XZ', child: Text('XZ')),
            DropdownMenuItem(value: 'YZ', child: Text('YZ')),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _axisPlane = value);
            _emitHelixChange();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _radiusController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Radius'),
          onChanged: (_) => _emitHelixChange(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pitchController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(labelText: 'Pitch (height per turn)'),
          onChanged: (_) => _emitHelixChange(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _turnsController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Turns'),
          onChanged: (_) => _emitHelixChange(),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Right-handed'),
          value: _rightHanded,
          onChanged: (value) {
            setState(() => _rightHanded = value);
            _emitHelixChange();
          },
        ),
        if (_radius == null || _pitch == null || _turns == null)
          Text(
            'Radius, pitch, and turns must all be valid numbers',
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
          ),
      ];

  List<Widget> _buildIntersectionFields() => [
        DropdownButtonFormField<String>(
          initialValue: _sketchFeatureIdA,
          decoration: const InputDecoration(labelText: 'Sketch A'),
          items: widget.sketchFeatureChoices
              .map((c) => DropdownMenuItem(value: c.featureId, child: Text(c.label)))
              .toList(),
          onChanged: (value) {
            setState(() => _sketchFeatureIdA = value);
            _emitIntersectionChange();
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _sketchFeatureIdB,
          decoration: const InputDecoration(labelText: 'Sketch B'),
          items: widget.sketchFeatureChoices
              .map((c) => DropdownMenuItem(value: c.featureId, child: Text(c.label)))
              .toList(),
          onChanged: (value) {
            setState(() => _sketchFeatureIdB = value);
            _emitIntersectionChange();
          },
        ),
        const SizedBox(height: 8),
        Text(
          'The 3D curve where each Sketch\'s own profile, extruded normal '
          'to its own plane, intersects the other',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
        ),
      ];
}
