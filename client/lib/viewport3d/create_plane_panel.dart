import 'package:flutter/material.dart';

import 'curve_panel.dart' show SketchFeatureChoice;

/// Which of the three v1 plane-construction flows [CreatePlanePanel] is
/// currently showing - decided by [PartScreen] from the selection that
/// enabled the Create Plane button (see `selection_actions.dart`'s
/// `contextActionsFor`), not by anything this panel picks itself.
///
/// C3 adds [midplane] (equidistant between two selected Faces) alongside
/// C2's original [offsetFace]/[normalToLineAtPoint]. C4 adds
/// [normalToEdgeThroughVertex] (normal to a selected straight Edge, through
/// a selected Vertex), [parallelToFaceThroughVertex] (parallel to a selected
/// planar Face, through a selected Vertex), and [threePoints] (through three
/// selected points, each a Body Vertex or a Sketch Point).
/// On-device feedback ("allow 'point and curve' as a valid combination to
/// create a plane, on point and normal to arc"): [normalToArcAtPoint] adds a
/// seventh flow, [normalToLineAtPoint]'s Arc-shaped sibling - a selected
/// Sketch Arc plus the Point that's one of its own two endpoints.
enum CreatePlaneMode {
  offsetFace,
  normalToLineAtPoint,
  midplane,
  normalToEdgeThroughVertex,
  parallelToFaceThroughVertex,
  threePoints,
  normalToArcAtPoint,

  /// Curve features: an eighth flow, [normalToArcAtPoint]'s CurveFeature-
  /// shaped sibling - normal to an existing Helix/Intersection curve's own
  /// tangent at a point along it, given as a live 0-1 arc-length-fraction
  /// slider (this panel's own field, like [offsetFace]'s numeric offset)
  /// rather than a tapped Sketch Point - a Helix/Intersection curve has no
  /// 2D point of its own to tap. Which curve feature is picked is a
  /// dropdown built from this Part's existing Curve features, same "no 3D-
  /// viewport picking yet" scope [CurvePanel]'s own Intersection mode has.
  normalToCurveFeatureAtParameter,
}

/// The bottom-sheet-style panel [PartScreen] opens once Create Plane is
/// enabled (a single planar Body Face selected, two Faces selected, or a
/// Sketch Line plus the Point that's its own endpoint) - mirrors
/// [ExtrudePanel]'s Confirm/Cancel session shape and slide-up presentation.
///
/// [CreatePlaneMode.offsetFace] shows a numeric offset field (Confirm
/// enabled once it parses); every other mode ([CreatePlaneMode.
/// normalToLineAtPoint], [CreatePlaneMode.midplane], and C4's
/// [CreatePlaneMode.normalToEdgeThroughVertex]/
/// [CreatePlaneMode.parallelToFaceThroughVertex]/[CreatePlaneMode.threePoints])
/// has no numeric input at all - all are fully determined by the references
/// alone, so Confirm is enabled unconditionally (those refs are already
/// guaranteed selected by the time this panel is even open -
/// `contextActionsFor` only enables the button once they are).
class CreatePlanePanel extends StatefulWidget {
  /// 'Create Plane' when creating a brand-new Feature (default),
  /// 'Edit Plane' when [PartScreen] opened this to edit an already-existing
  /// one instead - purely a label, same convention as
  /// [ExtrudePanel.title].
  final String title;

  final CreatePlaneMode mode;
  final double initialOffset;

  /// Only meaningful (and only ever called) while [mode] is
  /// [CreatePlaneMode.offsetFace] - fired on every valid offset edit, same
  /// live-preview-drives-a-debounced-PATCH pattern [ExtrudePanel.onChanged]
  /// already uses.
  final void Function(double offset)? onOffsetChanged;

  /// Only meaningful while [mode] is
  /// [CreatePlaneMode.normalToCurveFeatureAtParameter] - this Part's
  /// existing Curve features, for the curve-picker dropdown.
  final List<SketchFeatureChoice> curveFeatureChoices;

  /// Only meaningful while [mode] is [CreatePlaneMode.
  /// normalToCurveFeatureAtParameter] - pre-selects this curve in the
  /// dropdown (the one already tapped/selected in the viewport when
  /// [PartScreen] opened this panel - see `PartScreen._onCreatePlaneTapped`),
  /// so choosing a curve a second time isn't needed. `null` leaves the
  /// dropdown unselected, same as before this field existed.
  final String? initialCurveFeatureId;
  final double initialCurveParameter;

  /// Only meaningful (and only ever called) while [mode] is
  /// [CreatePlaneMode.normalToCurveFeatureAtParameter] - fired on every
  /// valid curve-feature-id-and-parameter combination, same live-preview
  /// convention [onOffsetChanged] already uses.
  final void Function({required String curveFeatureId, required double curveParameter})?
      onCurveParameterChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const CreatePlanePanel({
    super.key,
    this.title = 'Create Plane',
    required this.mode,
    this.initialOffset = 0.0,
    this.onOffsetChanged,
    this.curveFeatureChoices = const [],
    this.initialCurveFeatureId,
    this.initialCurveParameter = 0.5,
    this.onCurveParameterChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<CreatePlanePanel> createState() => _CreatePlanePanelState();
}

class _CreatePlanePanelState extends State<CreatePlanePanel> {
  late final TextEditingController _offsetController;

  /// Null once the offset field no longer parses as a number - mirrors
  /// [ExtrudePanel]'s own `_depth` null-on-invalid-input pattern. Always
  /// non-null (and never consulted by [_canConfirm]) for
  /// [CreatePlaneMode.normalToLineAtPoint].
  double? _offset;

  /// Only meaningful for [CreatePlaneMode.normalToCurveFeatureAtParameter] -
  /// null until a curve is picked from [CreatePlanePanel.curveFeatureChoices].
  String? _curveFeatureId;
  double _curveParameter = 0.5;

  @override
  void initState() {
    super.initState();
    _offsetController = TextEditingController(text: _formatDistance(widget.initialOffset));
    _offset = widget.initialOffset;
    _curveFeatureId = widget.initialCurveFeatureId;
    _curveParameter = widget.initialCurveParameter;
  }

  @override
  void dispose() {
    _offsetController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  static String _descriptionFor(CreatePlaneMode mode) {
    switch (mode) {
      case CreatePlaneMode.midplane:
        return 'Plane equidistant between the two selected faces';
      case CreatePlaneMode.normalToLineAtPoint:
        return 'Plane normal to the selected line, through the selected point';
      case CreatePlaneMode.normalToArcAtPoint:
        return 'Plane normal to the selected arc, through the selected point';
      case CreatePlaneMode.normalToEdgeThroughVertex:
        return 'Plane normal to the selected edge, through the selected vertex';
      case CreatePlaneMode.parallelToFaceThroughVertex:
        return 'Plane parallel to the selected face, through the selected vertex';
      case CreatePlaneMode.threePoints:
        return 'Plane through the three selected points';
      case CreatePlaneMode.offsetFace:
      case CreatePlaneMode.normalToCurveFeatureAtParameter:
        throw StateError('offsetFace/normalToCurveFeatureAtParameter have their own branch, not this description');
    }
  }

  bool get _canConfirm => switch (widget.mode) {
        CreatePlaneMode.offsetFace => _offset != null,
        CreatePlaneMode.normalToCurveFeatureAtParameter => _curveFeatureId != null,
        _ => true,
      };

  void _emitOffsetChange() {
    final value = double.tryParse(_offsetController.text);
    setState(() => _offset = value);
    if (value != null) widget.onOffsetChanged?.call(value);
  }

  void _emitCurveParameterChange() {
    final curveFeatureId = _curveFeatureId;
    if (curveFeatureId != null) {
      widget.onCurveParameterChanged?.call(curveFeatureId: curveFeatureId, curveParameter: _curveParameter);
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
                if (widget.mode == CreatePlaneMode.offsetFace) ...[
                  TextField(
                    controller: _offsetController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Offset'),
                    onChanged: (_) => _emitOffsetChange(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _offset == null ? 'Enter a valid offset' : 'Offset: ${_formatDistance(_offset!)}',
                    style: TextStyle(
                      color: _offset == null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ] else if (widget.mode == CreatePlaneMode.normalToCurveFeatureAtParameter) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _curveFeatureId,
                    decoration: const InputDecoration(labelText: 'Curve'),
                    items: widget.curveFeatureChoices
                        .map((c) => DropdownMenuItem(value: c.featureId, child: Text(c.label)))
                        .toList(),
                    onChanged: (value) {
                      setState(() => _curveFeatureId = value);
                      _emitCurveParameterChange();
                    },
                  ),
                  const SizedBox(height: 8),
                  Text('Position along curve: ${(_curveParameter * 100).round()}%'),
                  Slider(
                    value: _curveParameter,
                    onChanged: (value) {
                      setState(() => _curveParameter = value);
                      _emitCurveParameterChange();
                    },
                  ),
                  if (_curveFeatureId == null)
                    Text(
                      'Select a curve',
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                    ),
                ] else
                  Text(
                    _descriptionFor(widget.mode),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
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
}
