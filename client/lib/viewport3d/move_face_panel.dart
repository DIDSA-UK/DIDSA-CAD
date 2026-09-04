import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, fifth/last entry - which of `MoveFaceFeature`'s
/// client-offered modes this panel is currently configuring. Mirrors
/// [PatternMode]'s own `apiValue`/`fromApiValue` str-enum convention,
/// matching the backend's field-presence-based mode discriminant (there is
/// no single `move_face_mode` wire field - exactly one of `offset_distance`/
/// `delta`/`direction_ref`+`direction_distance` being set on the wire IS the
/// mode, per `MoveFaceFeature`'s own docstring).
///
/// On-device feedback ("delta x,y,z function is duplicated in the direction
/// tab where x,y,z are selectable as directions - remove the dedicated
/// delta x,y,z tab"): the backend's own `delta` mode (an arbitrary
/// `[dx, dy, dz]` in one field) still exists and is still fully supported
/// server-side - only this client's own mode picker no longer offers it,
/// since [MoveFaceMode.direction]'s fixed X/Y/Z axis buttons already cover
/// the common case (move a fixed distance along one world axis) with a
/// clearer UI (one number, a Flip button) than three simultaneous fields.
/// The one real capability this drops from the client: a true diagonal
/// move (nonzero on 2+ axes at once) in a single Feature - Direction mode
/// only ever moves along one axis (or one picked edge/Sketch Line) at a
/// time. [_openMoveFacePanelForEdit] in `part_screen.dart` declines to open
/// for a pre-existing `delta`-mode Feature accordingly (rather than trying
/// to represent it through a mode this panel no longer has a segment for) -
/// see that function's own doc comment.
enum MoveFaceMode {
  offset,
  direction;

  String get label => switch (this) {
        MoveFaceMode.offset => 'Offset',
        MoveFaceMode.direction => 'Direction',
      };
}

/// Direct Editing family, fifth/last entry: the bottom-sheet-style panel
/// [PartScreen] opens once a single planar face is selected and "Move
/// Face" is chosen (see `selection_actions.dart`'s `contextActionsFor`
/// single-planar-face branch). [mode] picks between the two modes this
/// client offers, mirroring [PatternPanel]'s own Rectangular/Circular
/// `SegmentedButton` toggle:
/// - **Offset**: a single field, along the face's own outward normal -
///   mirrors [ScaleBodyPanel]'s own single-field shape (this panel's
///   original v1 client scope).
/// - **Direction**: a picked reference (a Body edge, a Sketch Line, or a
///   fixed world X/Y/Z axis - reuses [PatternDirectionRefDto] verbatim,
///   same type [PatternPanel]'s own Direction 1/2 already use) plus a
///   signed distance field and a Flip `IconButton` that negates the
///   distance in place - mirrors [ExtrudePanel]'s own flip-via-sign
///   convention, per `MoveFaceFeature.direction_ref`'s own backend
///   docstring ("the sign of `direction_distance` acting as the client's
///   own 'Flip direction' control... not a separate boolean field").
///
/// Unlike [mode] switching between entirely different field groups, the
/// face being moved itself is fixed once picked, for the whole session -
/// no re-picking a different face mid-session (see `docs/direct-editing-
/// scope.md`'s own "ambient-entry-only" reasoning, shared with
/// [DeleteFacePanel]).
class MoveFacePanel extends StatefulWidget {
  /// 'Move Face', or 'Edit Move Face' while editing an already-existing
  /// MoveFaceFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  final MoveFaceMode mode;
  final void Function(MoveFaceMode mode) onModeChanged;

  /// The live count of faces currently picked (`_currentMoveFaceRefs().
  /// length` in `part_screen.dart`) - mirrors [DeleteFacePanel.faceCount].
  /// V3: both modes now accept 1+ faces (Direction/Delta sweep the whole
  /// group as one rigid `TopoDS_Compound` - see `MoveFaceFeature`'s own
  /// backend docstring), so [faceCount] only gates the "at least one face
  /// picked" half of [_canConfirm], not a mode-specific face-count cap.
  final int faceCount;

  final double initialOffset;

  /// Fired on every valid offset edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [ScaleBodyPanel.onFactorChanged] already
  /// uses. Unlike a factor, an offset of exactly 0 is not meaningful (no
  /// move at all - the backend rejects it outright, `_validate_move_face_
  /// payload`'s own `offset_distance` != 0 check), so this mirrors
  /// [FilletPanel.onRadiusChanged]'s "must be non-zero" contract instead,
  /// just allowing negative values too (an offset can push either
  /// direction along the face's own normal).
  final void Function(double offset)? onOffsetChanged;

  /// Whether Direction mode's reference has been picked yet (an edge/
  /// Sketch-Line tap, or a fixed X/Y/Z axis button) - mirrors
  /// [PatternPanel.hasDirection1].
  final bool hasDirection;

  /// A short human-readable summary of Direction mode's current pick -
  /// e.g. "Edge selected", "Sketch Line selected", or "X axis" - or null
  /// when nothing is picked yet. Mirrors [PatternPanel.direction1Summary].
  final String? directionSummary;

  final void Function(String axis) onSetDirectionFixedAxis;

  final double initialDirectionDistance;

  /// Fired on every valid, non-zero distance edit - same "must be non-
  /// zero" contract [onOffsetChanged] already has (a zero distance is not
  /// a move at all).
  final void Function(double distance)? onDirectionDistanceChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MoveFacePanel({
    super.key,
    this.title = 'Move Face',
    this.tooltip,
    required this.mode,
    required this.onModeChanged,
    required this.faceCount,
    required this.initialOffset,
    this.onOffsetChanged,
    this.hasDirection = false,
    this.directionSummary,
    required this.onSetDirectionFixedAxis,
    this.initialDirectionDistance = 1.0,
    this.onDirectionDistanceChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<MoveFacePanel> createState() => _MoveFacePanelState();
}

class _MoveFacePanelState extends State<MoveFacePanel> {
  late final TextEditingController _offsetController;
  late final TextEditingController _directionDistanceController;

  /// Null once the offset field no longer parses as a non-zero number -
  /// mirrors [ScaleBodyPanel]'s own `_factor` null-on-invalid-input
  /// pattern, just allowing negative values (see [MoveFacePanel.
  /// onOffsetChanged]'s own doc comment).
  double? _offset;

  /// Null once the direction-distance field no longer parses as a non-zero
  /// number - mirrors [_offset]'s own "must be non-zero" contract.
  double? _directionDistance;

  @override
  void initState() {
    super.initState();
    _offsetController = TextEditingController(text: _formatNumber(widget.initialOffset));
    _offset = widget.initialOffset != 0 ? widget.initialOffset : null;
    _directionDistanceController =
        TextEditingController(text: _formatNumber(widget.initialDirectionDistance));
    _directionDistance = widget.initialDirectionDistance != 0 ? widget.initialDirectionDistance : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - mirrors every other panel's
    // identical fix. Only the initially-active mode's own callback fires -
    // the other mode's fields exist (so switching modes mid-session doesn't
    // lose whatever was typed into them) but aren't live until [widget.mode]
    // actually selects them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.mode) {
        case MoveFaceMode.offset:
          if (_offset != null) widget.onOffsetChanged?.call(_offset!);
        case MoveFaceMode.direction:
          if (_directionDistance != null) widget.onDirectionDistanceChanged?.call(_directionDistance!);
      }
    });
  }

  @override
  void dispose() {
    _offsetController.dispose();
    _directionDistanceController.dispose();
    super.dispose();
  }

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm {
    if (widget.faceCount == 0) return false;
    return switch (widget.mode) {
      MoveFaceMode.offset => _offset != null,
      MoveFaceMode.direction => widget.hasDirection && _directionDistance != null,
    };
  }

  void _emitOffsetChange() {
    final value = double.tryParse(_offsetController.text);
    final offset = (value != null && value != 0) ? value : null;
    setState(() => _offset = offset);
    if (offset != null) widget.onOffsetChanged?.call(offset);
  }

  void _emitDirectionDistanceChange() {
    final value = double.tryParse(_directionDistanceController.text);
    final distance = (value != null && value != 0) ? value : null;
    setState(() => _directionDistance = distance);
    if (distance != null) widget.onDirectionDistanceChanged?.call(distance);
  }

  /// Mirrors [ExtrudePanel]'s own `_flipDirection` - negates the field's
  /// sign in place, rather than a separate boolean field, per
  /// `MoveFaceFeature.direction_ref`'s own backend docstring.
  void _flipDirectionDistance() {
    final value = double.tryParse(_directionDistanceController.text);
    if (value == null) return;
    _directionDistanceController.text = _formatNumber(-value);
    _emitDirectionDistanceChange();
  }

  /// Mirrors [PatternPanel._pickAffordanceButton] - tapping this doesn't
  /// itself pick anything (the viewport is always live for an edge/
  /// Sketch-Line tap while this panel is open in Direction mode), it just
  /// surfaces the hint text as a visible, tappable prompt.
  Widget _pickAffordanceButton() => IconButton(
        tooltip: 'Tap an edge or Sketch Line to pick a direction',
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tap an edge or Sketch Line to pick a direction'),
            duration: Duration(seconds: 3),
          ),
        ),
        icon: const Icon(Icons.touch_app_outlined, size: 20),
      );

  /// Mirrors [PatternPanel._axisButton] - a fixed world X/Y/Z axis, no
  /// viewport pick needed (`PatternDirectionRef.fixed_axis`, reused
  /// verbatim by `MoveFaceFeature.direction_ref`).
  Widget _axisButton(String axis) => OutlinedButton(
        onPressed: () => widget.onSetDirectionFixedAxis(axis),
        style: OutlinedButton.styleFrom(minimumSize: const Size(40, 36), padding: EdgeInsets.zero),
        child: Text(axis.toUpperCase()),
      );

  /// V2 UX polish: the label/hint deliberately say "along the surface
  /// normal", not "radius" or a bare "Offset" - `BRepOffset_MakeOffset`
  /// applies [_offset] along *each* picked face's own local normal, and for
  /// a conical face that is not the same thing as its radius growing by
  /// [_offset] (radial growth = offset / cos(half-angle) - see
  /// `docs/direct-editing-scope.md`'s "Spike findings addendum" for the
  /// derivation). A per-face computed-radius readout would need the mesh
  /// response to carry each face's own surface type/geometry, which it
  /// doesn't yet - out of scope for this pass; the generic wording here is
  /// the cheap fix that avoids the field visibly lying for a cone.
  Widget _offsetSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _offsetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Offset (along surface normal)'),
            onChanged: (_) => _emitOffsetChange(),
          ),
          const SizedBox(height: 8),
          Text(
            _offset == null
                ? 'Enter a non-zero offset'
                : 'Offset: ${_formatNumber(_offset!)} along each face\'s own normal',
            style: TextStyle(
              color: _offset == null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      );

  Widget _directionSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.hasDirection
                      ? (widget.directionSummary ?? 'Direction selected')
                      : 'Tap an edge or Sketch Line, or pick a fixed axis',
                  style: TextStyle(
                    color: widget.hasDirection
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
              _pickAffordanceButton(),
              _axisButton('x'),
              const SizedBox(width: 4),
              _axisButton('y'),
              const SizedBox(width: 4),
              _axisButton('z'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _directionDistanceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Distance'),
                  onChanged: (_) => _emitDirectionDistanceChange(),
                ),
              ),
              IconButton(
                tooltip: 'Flip direction',
                onPressed: _flipDirectionDistance,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.faceCount == 0
                ? 'Tap one or more faces of the same body to move'
                : 'Moving ${widget.faceCount} ${widget.faceCount == 1 ? 'face' : 'faces'}',
            style: TextStyle(
              color: widget.faceCount == 0
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<MoveFaceMode>(
            segments: [
              for (final mode in MoveFaceMode.values)
                ButtonSegment(
                  value: mode,
                  label: Text(mode.label),
                ),
            ],
            selected: {widget.mode},
            onSelectionChanged: (selection) => widget.onModeChanged(selection.first),
          ),
          const SizedBox(height: 12),
          switch (widget.mode) {
            MoveFaceMode.offset => _offsetSection(context),
            MoveFaceMode.direction => _directionSection(context),
          },
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
    );
  }
}
