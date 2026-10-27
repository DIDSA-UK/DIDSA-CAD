import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Which of the two `CurveFeature` construction methods [CurvePanel] shows -
/// mirrors [CreatePlaneMode]'s own "picked by PartScreen before the panel
/// opens" convention, though for a Curve feature the mode is chosen by the
/// user directly (a segmented toggle at the top of the panel), not derived
/// from an ambient selection - a Helix and an Intersection curve have no
/// natural "already selected something in the viewport" trigger the way
/// Create Plane's face-selection-driven modes do.
enum CurveMode { helix, intersection }

/// How a Helix's diameter changes along it: not at all, to an end diameter, or by a taper angle (the
/// backend stores the end radius and returns both; the panel shows the one not being typed read-only).
/// Bug report: the panel takes diameters (the helix's mean, wire-centreline diameter), not radii;
/// the backend API and file format still hold radii, so the panel halves what it sends.
enum HelixTaper { none, endDiameter, angle }

/// One stretch of a Helix: [turns] revolutions at [pitch] (axis advance per revolution; the sign is
/// the direction along the axis, the same for every segment). The backend's `segments` entry.
class HelixSegmentValue {
  final double pitch;
  final double turns;

  const HelixSegmentValue({required this.pitch, required this.turns});
}

/// An existing Helix's stored values, to open [CurvePanel] for editing it. Radii, as stored.
class HelixInitialValues {
  final double radius;
  final double? endRadius;
  final List<HelixSegmentValue> segments;
  final bool rightHanded;

  const HelixInitialValues({
    required this.radius,
    this.endRadius,
    required this.segments,
    this.rightHanded = true,
  });
}

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

  /// Fired on every valid Helix parameter edit: only once the diameter, the taper value (if any) and
  /// every segment's pitch and turns parse. [radius] / [endRadius] are half the typed diameters (what
  /// the backend takes). At most one of [endRadius] / [taperAngleDegrees] is set (neither for a
  /// constant diameter); the backend converts an angle to an end radius.
  final void Function({
    required String axisPlane,
    required double radius,
    double? endRadius,
    double? taperAngleDegrees,
    required List<HelixSegmentValue> segments,
    required bool rightHanded,
  })? onHelixChanged;

  /// Fired whenever both Intersection curve Sketch pickers have a value.
  final void Function({required String sketchFeatureIdA, required String sketchFeatureIdB})? onIntersectionChanged;

  /// When set, a Helix's axis is already determined by a plane/face already
  /// selected in the viewport when this panel was opened (see
  /// `PartScreen._startHelix`'s own doc comment) - shown as a read-only
  /// "Axis: <label>" row instead of the fixed-plane dropdown, mirroring
  /// [CreatePlanePanel]'s own "fully determined by refs, no input needed"
  /// treatment for its own ambient-selection-driven modes. `null` (the
  /// default) keeps the ordinary XY/XZ/YZ dropdown. Purely display text -
  /// [onHelixChanged]'s own `axisPlane` argument is simply ignored by the
  /// caller in this case (the caller already knows the real axis), so no
  /// callback signature change is needed here.
  final String? preSelectedAxisLabel;

  /// Opens the Helix form on an existing Helix's values (editing it); null starts from the defaults.
  /// Also hides the Helix / Intersection toggle: a Curve feature's type never changes on edit.
  final HelixInitialValues? initialHelix;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const CurvePanel({
    super.key,
    this.title = 'Curve',
    this.sketchFeatureChoices = const [],
    this.onHelixChanged,
    this.onIntersectionChanged,
    this.preSelectedAxisLabel,
    this.initialHelix,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<CurvePanel> createState() => _CurvePanelState();
}

/// The text fields behind one row of the segments list.
class _SegmentRow {
  final TextEditingController pitch;
  final TextEditingController turns;

  _SegmentRow({String pitch = '2', String turns = '3'})
      : pitch = TextEditingController(text: pitch),
        turns = TextEditingController(text: turns);

  void dispose() {
    pitch.dispose();
    turns.dispose();
  }
}

class _CurvePanelState extends State<CurvePanel> {
  CurveMode _mode = CurveMode.helix;

  String _axisPlane = 'XY';
  bool _rightHanded = true;
  HelixTaper _taper = HelixTaper.none;
  late final TextEditingController _diameterController;
  late final TextEditingController _taperController;
  final List<_SegmentRow> _segmentRows = [];
  double? _diameter;
  double? _taperValue;
  List<HelixSegmentValue>? _segments;

  String? _sketchFeatureIdA;
  String? _sketchFeatureIdB;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialHelix;
    final segments = initial?.segments ?? const [HelixSegmentValue(pitch: 2, turns: 3)];
    _diameter = 2 * (initial?.radius ?? 5.0);
    _diameterController = TextEditingController(text: _format(_diameter!));
    final endRadius = initial?.endRadius;
    _taper = endRadius == null ? HelixTaper.none : HelixTaper.endDiameter;
    _taperValue = endRadius == null ? null : 2 * endRadius;
    _taperController = TextEditingController(text: endRadius == null ? '' : _format(2 * endRadius));
    _segmentRows
        .addAll([for (final seg in segments) _SegmentRow(pitch: _format(seg.pitch), turns: _format(seg.turns))]);
    _segments = segments;
    _rightHanded = initial?.rightHanded ?? true;
  }

  /// A stored number as the user would type it: no trailing ".0", no float noise.
  static String _format(double value) {
    final rounded = double.parse(value.toStringAsFixed(6));
    return rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  }

  @override
  void dispose() {
    _diameterController.dispose();
    _taperController.dispose();
    for (final row in _segmentRows) {
      row.dispose();
    }
    super.dispose();
  }

  /// Sum of |pitch| x turns over the segments, or null while any of them does not parse.
  double? get _totalHeight {
    final segments = _segments;
    if (segments == null) return null;
    return segments.fold<double>(0, (sum, s) => sum + s.pitch.abs() * s.turns);
  }

  /// The taper shown read-only next to the field being typed: the angle for an end diameter, the end
  /// diameter for an angle. Null when it can't be worked out yet.
  String? get _taperReadout {
    final diameter = _diameter, height = _totalHeight, value = _taperValue;
    if (diameter == null || height == null || height == 0 || value == null) return null;
    switch (_taper) {
      case HelixTaper.none:
        return null;
      case HelixTaper.endDiameter:
        final angle = math.atan((value - diameter) / 2 / height) * 180 / math.pi;
        return 'Taper angle: ${angle.toStringAsFixed(2)}\u00B0';
      case HelixTaper.angle:
        if (value <= -90 || value >= 90) return null;
        final end = diameter + 2 * height * math.tan(value * math.pi / 180);
        return 'End diameter: ${end.toStringAsFixed(3)}';
    }
  }

  bool get _taperValid => switch (_taper) {
        HelixTaper.none => true,
        HelixTaper.endDiameter => _taperValue != null && _taperValue! > 0,
        HelixTaper.angle => _taperValue != null && _taperValue! > -90 && _taperValue! < 90,
      };

  bool get _helixValid => _diameter != null && _diameter! > 0 && _segments != null && _taperValid;

  bool get _canConfirm => switch (_mode) {
        CurveMode.helix => _helixValid,
        CurveMode.intersection =>
          _sketchFeatureIdA != null && _sketchFeatureIdB != null && _sketchFeatureIdA != _sketchFeatureIdB,
      };

  void _emitHelixChange() {
    setState(() {
      _diameter = double.tryParse(_diameterController.text);
      _taperValue = double.tryParse(_taperController.text);
      final parsed = <HelixSegmentValue>[];
      var ok = true;
      for (final row in _segmentRows) {
        final pitch = double.tryParse(row.pitch.text);
        final turns = double.tryParse(row.turns.text);
        if (pitch == null || turns == null || pitch == 0 || turns <= 0) {
          ok = false;
          break;
        }
        parsed.add(HelixSegmentValue(pitch: pitch, turns: turns));
      }
      // Every segment advances the same way along the axis.
      if (ok && parsed.any((s) => (s.pitch > 0) != (parsed.first.pitch > 0))) ok = false;
      _segments = ok ? parsed : null;
    });
    final diameter = _diameter, segments = _segments, taperValue = _taperValue;
    if (diameter == null || segments == null || !_helixValid) return;
    widget.onHelixChanged?.call(
      axisPlane: _axisPlane,
      radius: diameter / 2,
      endRadius: _taper == HelixTaper.endDiameter && taperValue != null ? taperValue / 2 : null,
      taperAngleDegrees: _taper == HelixTaper.angle ? _taperValue : null,
      segments: segments,
      rightHanded: _rightHanded,
    );
  }

  void _addSegment() {
    setState(() => _segmentRows.add(_SegmentRow(pitch: _segmentRows.last.pitch.text, turns: '1')));
    _emitHelixChange();
  }

  void _removeSegment(int index) {
    if (_segmentRows.length < 2) return;
    setState(() => _segmentRows.removeAt(index).dispose());
    _emitHelixChange();
  }

  void _emitIntersectionChange() {
    final a = _sketchFeatureIdA, b = _sketchFeatureIdB;
    if (a != null && b != null && a != b) {
      widget.onIntersectionChanged?.call(sketchFeatureIdA: a, sketchFeatureIdB: b);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Bug report: on a phone the keyboard covered the field being typed in. The shared tool-panel
    // shell scrolls and resizes like every other tool's; lifting it by the keyboard's height keeps the
    // focused field (which the scroll view brings into view) above the keyboard.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ResizableToolPanel(
        title: widget.title,
        defaultHeightFraction: 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.initialHelix == null) ...[
              SegmentedButton<CurveMode>(
                segments: const [
                  ButtonSegment(value: CurveMode.helix, label: Text('Helix')),
                  ButtonSegment(value: CurveMode.intersection, label: Text('Intersection')),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) => setState(() => _mode = selection.first),
              ),
              const SizedBox(height: 12),
            ],
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
    );
  }

  List<Widget> _buildHelixFields() => [
        if (widget.preSelectedAxisLabel != null)
          Text('Axis: ${widget.preSelectedAxisLabel}')
        else
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
          key: const ValueKey('helix-diameter-field'),
          controller: _diameterController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Diameter (at the start)',
            helperText: 'Mean diameter, through the wire centre',
          ),
          onChanged: (_) => _emitHelixChange(),
        ),
        const SizedBox(height: 8),
        SegmentedButton<HelixTaper>(
          key: const ValueKey('helix-taper-mode'),
          segments: const [
            ButtonSegment(value: HelixTaper.none, label: Text('Constant')),
            ButtonSegment(value: HelixTaper.endDiameter, label: Text('End diameter')),
            ButtonSegment(value: HelixTaper.angle, label: Text('Taper angle')),
          ],
          selected: {_taper},
          onSelectionChanged: (selection) {
            setState(() {
              _taper = selection.first;
              _taperController.clear();
            });
            _emitHelixChange();
          },
        ),
        if (_taper != HelixTaper.none) ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('helix-taper-field'),
            controller: _taperController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: _taper == HelixTaper.endDiameter ? 'End diameter' : 'Taper angle (degrees, + widens)',
              helperText: _taperReadout,
            ),
            onChanged: (_) => _emitHelixChange(),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: Text('Segments', style: TextStyle(fontWeight: FontWeight.w600))),
            if (_totalHeight != null)
              Text('Height ${_totalHeight!.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
        for (var i = 0; i < _segmentRows.length; i++)
          Row(
            key: ValueKey('helix-segment-$i'),
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('helix-segment-$i-pitch'),
                  controller: _segmentRows[i].pitch,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Pitch (height per turn)'),
                  onChanged: (_) => _emitHelixChange(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: ValueKey('helix-segment-$i-turns'),
                  controller: _segmentRows[i].turns,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Turns'),
                  onChanged: (_) => _emitHelixChange(),
                ),
              ),
              IconButton(
                key: ValueKey('helix-segment-$i-remove'),
                tooltip: 'Remove segment ${i + 1}',
                icon: const Icon(Icons.close, size: 18),
                onPressed: _segmentRows.length > 1 ? () => _removeSegment(i) : null,
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('helix-add-segment'),
            onPressed: _addSegment,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add segment'),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Right-handed'),
          value: _rightHanded,
          onChanged: (value) {
            setState(() => _rightHanded = value);
            _emitHelixChange();
          },
        ),
        if (!_helixValid)
          Text(
            _segments == null
                ? 'Each segment needs a non-zero pitch and positive turns, all advancing the same way'
                : (!_taperValid ? 'The taper value is not valid' : 'The diameter must be a positive number'),
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
