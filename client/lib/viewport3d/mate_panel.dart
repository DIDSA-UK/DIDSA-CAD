import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

import 'resizable_tool_panel.dart';
import 'selection_hit_test.dart';
import 'svg_icon.dart';
import 'width_pick.dart';

/// Phase 6 (`docs/assembly-scope.md` §3): the five Mate types this app's
/// backend supports (`app.document.models.MateType`) - kept as a plain
/// `String` wire value directly (matching `MateDto.type`'s own shape)
/// rather than a Dart enum with its own to/from-wire mapping, since nothing
/// else client-side needs a richer type for this yet.
const List<String> kMateTypes = ['coincident', 'concentric', 'parallel', 'distance', 'angle', 'gear', 'rack_pinion', 'screw'];

/// The coupler ("motion") mates (`docs/gears-and-motion-plan.md`): they place nothing, they keep a relation between how far the two
/// parts MOVE. Two axis picks (a round face, a circular or a straight edge; the rack's second a straight edge), a value (ratio, travel
/// per turn, lead) and a sense. `value` stays empty for gear and rack and pinion to take it from the parts' gear features.
const List<String> kCouplerMateTypes = ['gear', 'rack_pinion', 'screw'];

bool isCouplerMateType(String type) => kCouplerMateTypes.contains(type);

String mateTypeLabel(String type) => switch (type) {
      'coincident' => 'Coincident',
      'concentric' => 'Concentric',
      'parallel' => 'Parallel',
      'distance' => 'Distance',
      'angle' => 'Angle',
      'gear' => 'Gear',
      'rack_pinion' => 'Rack and pinion',
      'screw' => 'Screw',
      kWidthMateType => 'Width',
      kSymmetricMateType => 'Symmetric',
      _ => type,
    };

/// The label of a stored [mate]: "Width" when its references are mid-planes, else its type's label.
String mateLabel(MateDto mate) => isSymmetricMate(mate)
    ? mateTypeLabel(kSymmetricMateType)
    : (isWidthMate(mate) ? mateTypeLabel(kWidthMateType) : mateTypeLabel(mate.type));

/// Phase 2b: the sentence shown while the ghost preview needs earlier mates on their other branch
/// ([MateSolvePreviewDto.branchChanges]), or cannot get there ([blockedBy] = mates the user set that stand in the
/// way, [conflicting] = a genuine conflict). `null` when there is nothing to say. [mates] names them by type.
String? mateBranchNotice(
  List<BranchChangeDto> changes,
  List<MateDto> mates, {
  List<String> blockedBy = const [],
  List<String> conflicting = const [],
}) {
  String describe(Iterable<String> ids) {
    final labels = <String>[];
    for (final id in ids) {
      final found = mates.where((m) => m.id == id);
      labels.add(found.isEmpty ? 'a mate' : '${mateLabel(found.first)} mate');
    }
    return labels.join(', ');
  }

  if (changes.isNotEmpty) {
    final ids = <String>{for (final c in changes) c.mateId};
    return ids.length == 1
        ? 'To fit, an earlier mate (${describe(ids)}) moves to its other side or orientation. Confirm applies it.'
        : 'To fit, ${ids.length} earlier mates (${describe(ids)}) move to their other side or orientation. Confirm applies them.';
  }
  if (blockedBy.isNotEmpty) {
    return 'A mate you set to one side or orientation stands in the way (${describe(blockedBy)}). Change it to allow this mate.';
  }
  if (conflicting.isNotEmpty) {
    return 'This mate conflicts with an earlier mate (${describe(conflicting)}).';
  }
  return null;
}

/// Whether [type] needs a numeric [MatePanel.value] - mirrors the backend's
/// own `_validate_mate_create` requirement (`distance`/`angle` reject a
/// missing `value` with a 422) exactly, so the Confirm button's own
/// `_canConfirm` never lets a request through the backend would reject
/// anyway.
bool mateTypeNeedsValue(String type) => type == 'distance' || type == 'angle' || type == 'screw';

/// Whether the panel shows a value field for [type]: the ones that need one, and the couplers that may leave it empty (Auto).
bool mateTypeHasValueField(String type) => mateTypeNeedsValue(type) || isCouplerMateType(type);

/// The label of [type]'s value field.
String mateValueLabel(String type) => switch (type) {
      'angle' => 'Angle (degrees)',
      'gear' => 'Ratio (B turns per A turn)',
      'rack_pinion' => 'Travel per turn (mm)',
      'screw' => 'Lead (mm per turn)',
      _ => 'Distance (mm)',
    };

/// The hint under [type]'s value field when it is empty and may stay so (gear, rack and pinion: taken from the teeth), else `null`.
String? mateValueHelper(String type, {double? autoValue}) {
  if (type != 'gear' && type != 'rack_pinion') return null;
  if (autoValue != null) return 'Auto: ${_trimNumber(autoValue)}${type == 'rack_pinion' ? ' mm per turn' : ''} (from the teeth)';
  return 'Leave empty to take it from the teeth';
}

String _trimNumber(double x) => x.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

/// The second line of a coupler mate's row: "1 : 2" (A turns for one of B), "62.832 mm per turn", "lead 2 mm". `null` for other mates.
String? mateValueSummary(MateDto mate) {
  final value = mate.value;
  if (value == null || !isCouplerMateType(mate.type)) return null;
  return switch (mate.type) {
    'gear' => '1 : ${_trimNumber(1 / value)}',
    'rack_pinion' => '${_trimNumber(value)} mm per turn',
    _ => 'lead ${_trimNumber(value)} mm',
  };
}

/// Phase 3: the label of the `secondary_flip` control for a mate of [type] - what the flag means there. (Which mates HAVE the
/// control, and which have an alignment, is the backend's call: `MateSolvePreviewDto.controls`.)
String mateSecondaryFlipLabel(String type) => switch (type) {
      'distance' => 'Flip side',
      'concentric' => 'Flip spin',
      'angle' => 'Supplement',
      'gear' || 'rack_pinion' => 'Reverse',
      'screw' => 'Left-hand',
      _ => 'Flip',
    };

String mateAlignmentLabel(String alignment, [String type = '']) =>
    type == 'angle' ? (alignment == 'aligned' ? 'Positive' : 'Negative') : (alignment == 'aligned' ? 'Aligned' : 'Anti-aligned');

/// The title of the `alignment` control: for an ANGLE about a hinge it is the direction the lid swings (+theta / -theta), for
/// everything else whether the two directions point the same way.
String mateAlignmentTitle(String type) => type == 'angle' ? 'Swing direction' : 'Orientation';

/// Phase 3: [text] as a mate value, or `null` when it is not a number - or a negative DISTANCE (the side of a distance is
/// the "Flip side" control; the backend refuses a negative one).
double? parseMateValue(String type, String text) {
  final value = double.tryParse(text);
  if (value == null) return null;
  if (type == 'distance' && value < 0) return null;
  if (isCouplerMateType(type) && value <= 0) return null;
  return value;
}

/// [text] as a Width offset from the centre: empty = centred (`null`), otherwise a non-negative number (the side is "Flip side").
double? parseWidthOffset(String text) {
  final value = double.tryParse(text.trim());
  return value == null || value < 0 ? null : value;
}

/// The hint under the Width offset field for [text], or `null` when it is fine.
String? widthOffsetError(String text) {
  if (text.trim().isEmpty) return null;
  final value = double.tryParse(text.trim());
  if (value == null) return 'Enter a number, or leave empty to centre';
  return value < 0 ? 'The offset cannot be negative - use Flip side' : null;
}

/// The hint under a value field for [text], or `null` when it is fine.
String? mateValueError(String type, String text) {
  final value = double.tryParse(text);
  if (isCouplerMateType(type) && text.trim().isNotEmpty && (value == null || value <= 0)) {
    return type == 'screw' ? 'Enter a number above zero' : 'Enter a number above zero, or leave empty for Auto';
  }
  return type == 'distance' && value != null && value < 0 ? 'A distance cannot be negative - use Flip side' : null;
}

/// Phase 3: where the placement the preview shows sits among [alternatives] (`null` when it matches none, e.g. nothing converged).
/// [alignment] / [secondaryFlip] are the EFFECTIVE values (what the user chose, else what the preview resolved), `null` for a field
/// the geometry has no control for.
int? mateAlternativeIndex(List<MateSolveAlternativeDto> alternatives, String? alignment, bool? secondaryFlip) {
  for (var i = 0; i < alternatives.length; i++) {
    if (alternatives[i].alignment == alignment && alternatives[i].secondaryFlip == secondaryFlip) return i;
  }
  return null;
}

/// "Next solution": the alternative after the one currently shown (wrapping), or the nearest one when none matches. `null`
/// without at least two alternatives - there is nothing to step to.
MateSolveAlternativeDto? mateNextAlternative(
  List<MateSolveAlternativeDto> alternatives,
  String? alignment,
  bool? secondaryFlip,
) {
  if (alternatives.length < 2) return null;
  final current = mateAlternativeIndex(alternatives, alignment, secondaryFlip);
  return alternatives[current == null ? 0 : (current + 1) % alternatives.length];
}

/// Phase 3: the branch controls of a mate under construction or being edited, driven by the preview's `controls` (the client never
/// works out geometry kinds). [alignment] / [secondaryFlip] are the user's explicit choices (`null` = Closest, the "(auto)"
/// hint); [resolvedAlignment] / [resolvedSecondaryFlip] are what the ghost shows. "Next solution" steps through the preview's
/// alternatives, which also reaches roots no single control does.
class MateBranchControls extends StatelessWidget {
  final String mateType;
  final List<String> controls;
  final String? alignment;
  final String? resolvedAlignment;
  final bool? secondaryFlip;
  final bool? resolvedSecondaryFlip;

  /// A coupler's sense (`secondary_flip`) means nothing on its own (it depends on which way each axis happens to point), so the
  /// control reads "Reverse" / "Left-hand" RELATIVE to [senseBase]: the sense the backend chose by default (new mate), or the one the
  /// mate had when the editor opened. Null for every other mate.
  final bool? senseBase;
  final int alternativeCount;
  final int? alternativeIndex;
  final ValueChanged<String> onAlignmentChanged;
  final ValueChanged<bool> onSecondaryFlipChanged;
  final VoidCallback? onNextSolution;

  const MateBranchControls({
    super.key,
    required this.mateType,
    required this.controls,
    required this.alignment,
    required this.resolvedAlignment,
    required this.secondaryFlip,
    required this.resolvedSecondaryFlip,
    this.senseBase,
    required this.alternativeCount,
    required this.alternativeIndex,
    required this.onAlignmentChanged,
    required this.onSecondaryFlipChanged,
    required this.onNextSolution,
  });

  @override
  Widget build(BuildContext context) {
    final hasAlignment = controls.contains('alignment');
    final hasFlip = controls.contains('secondary_flip');
    final showNext = alternativeCount > 1 && onNextSolution != null;
    if (!hasAlignment && !hasFlip && !showNext) return const SizedBox.shrink();
    final effectiveAlignment = alignment ?? resolvedAlignment;
    final effectiveFlip = secondaryFlip ?? resolvedSecondaryFlip ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasAlignment) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text(mateAlignmentTitle(mateType), style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              if (alignment == null)
                Text('(auto)', key: const ValueKey('mate-alignment-auto'), style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            key: const ValueKey('mate-alignment'),
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(value: 'aligned', label: Text(mateAlignmentLabel('aligned', mateType))),
              ButtonSegment(value: 'anti_aligned', label: Text(mateAlignmentLabel('anti_aligned', mateType))),
            ],
            selected: effectiveAlignment == null ? const <String>{} : {effectiveAlignment},
            onSelectionChanged: (picked) {
              if (picked.isNotEmpty) onAlignmentChanged(picked.first);
            },
          ),
        ],
        if (hasFlip && isCouplerMateType(mateType) && senseBase != null)
          CheckboxListTile(
            key: const ValueKey('mate-secondary-flip'),
            value: (secondaryFlip ?? senseBase) != senseBase,
            onChanged: (checked) => onSecondaryFlipChanged((checked ?? false) ? !senseBase! : senseBase!),
            title: Text(mateSecondaryFlipLabel(mateType)),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          )
        else if (hasFlip)
          CheckboxListTile(
            key: const ValueKey('mate-secondary-flip'),
            value: effectiveFlip,
            onChanged: (checked) => onSecondaryFlipChanged(checked ?? false),
            title: Text(mateSecondaryFlipLabel(mateType)),
            subtitle: secondaryFlip == null ? const Text('(auto)', style: TextStyle(fontSize: 11)) : null,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        if (showNext)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('mate-next-solution'),
              onPressed: onNextSolution,
              icon: const Icon(Icons.skip_next, size: 18),
              label: Text(
                alternativeIndex == null
                    ? 'Next solution ($alternativeCount available)'
                    : 'Next solution (${alternativeIndex! + 1} of $alternativeCount)',
              ),
            ),
          ),
      ],
    );
  }
}

/// Test report item 4: whether [type] has a meaningful "Allow rotation"
/// choice - `concentric` only, mirroring `Mate.allow_rotation`'s own
/// backend docstring ("`CONCENTRIC`-only, ignored by every other
/// `MateType`"). A plain concentric axis-to-axis lock already leaves
/// rotation about (and translation along) the shared axis free; unchecking
/// this additionally locks the spin DOF - see `assembly_solver.py`'s own
/// CONCENTRIC branch for how.
bool mateTypeHasAllowRotation(String type) => type == 'concentric';

/// Phase 6: the bottom-sheet-style panel [PartScreen] opens while picking a
/// Mate's two references - structural clone of [FilletPanel]'s
/// Confirm/Cancel shape on the same [ResizableToolPanel] shell, with
/// [MeasurementPanel]'s own selected-entity list reused for showing which
/// two entities have been picked so far (0, 1, or 2 - [PartScreen.
/// _mateSelectionFilter] only ever allows vertex/edge/face entities,
/// including ones on a placed Occurrence via `hitTestComponentInstanceEntities`
/// - Phase 6a's own real prerequisite for this panel to exist at all).
class MatePanel extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;
  final Map<String, String> bodyNames;

  final String mateType;
  final double? value;

  /// Phase 3: the branch controls (see [MateBranchControls]) - `null` while there is no preview to take them from.
  final MateBranchControls? branchControls;

  /// A gear / rack and pinion mate with its value left empty: the value the backend would take from the teeth (the preview's `coupler_value`).
  final double? autoValue;

  /// Test report item 4: [mateTypeHasAllowRotation]'s own live value -
  /// meaningless (but still passed) while `mateType != 'concentric'`.
  final bool allowRotation;

  final ValueChanged<String> onMateTypeChanged;
  final ValueChanged<double?> onValueChanged;
  final ValueChanged<bool> onAllowRotationChanged;

  /// Minimal movement: move only the mated part when that is enough, and let connected parts follow only when it is
  /// not (the app asks the backend for its `auto` movement mode). The checkbox is shown only when
  /// [onMinimalMovementChanged] is given.
  final bool minimalMovement;
  final ValueChanged<bool>? onMinimalMovementChanged;

  final bool saving;
  final String? error;

  /// The Width flow (`mateType == kWidthMateType`): the four-pick state, the pair error ("faces not parallel"), the optional
  /// offset from the centre and its callbacks. Null for every other type.
  final WidthPick? widthPick;
  final String? widthError;
  final double? widthOffset;
  final ValueChanged<double?>? onWidthOffsetChanged;
  final VoidCallback? onWidthBack;

  /// Phase 2b: informational line under the controls (see [mateBranchNotice]); shown in the normal text colour.
  final String? notice;

  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  /// Bug report 2026-10-14, item 8: the only way to reset the references used
  /// to be the undiscoverable "a third distinct tap starts fresh" rule. When
  /// given, a "Clear selection" button appears under the references (only
  /// while something is selected), and [onRemoveEntity] adds a per-row X so
  /// one wrong pick can be undone without losing the other.
  final VoidCallback? onClearSelection;
  final ValueChanged<SelectionEntityRef>? onRemoveEntity;

  const MatePanel({
    super.key,
    required this.selectedEntities,
    required this.bodyNames,
    required this.mateType,
    required this.value,
    this.branchControls,
    this.autoValue,
    required this.allowRotation,
    required this.onMateTypeChanged,
    required this.onValueChanged,
    required this.onAllowRotationChanged,
    this.minimalMovement = false,
    this.onMinimalMovementChanged,
    required this.saving,
    required this.error,
    this.notice,
    required this.onConfirm,
    required this.onCancel,
    this.onClearSelection,
    this.onRemoveEntity,
    this.widthPick,
    this.widthError,
    this.widthOffset,
    this.onWidthOffsetChanged,
    this.onWidthBack,
  });

  bool get _isWidth => isMultiPickMateType(mateType) && widthPick != null;

  String? get _tooltip => _isWidth
      ? (mateType == kSymmetricMateType
          ? 'Symmetric: pick the two faces to mirror (on two parts), then a face of the mirror plane (on a third part)'
          : 'Width: pick the two faces of the gap, then the two faces of the part to centre in it')
      : switch (selectedEntities.length) {
        0 => 'Select a face, edge, or vertex for the first side of the mate',
        1 => 'Select a face, edge, or vertex for the second side of the mate',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: 'Add Mate',
      tooltip: _tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isWidth) ..._widthRows(context),
          if (!_isWidth && selectedEntities.isNotEmpty) ..._selectionRows(context),
          if (selectedEntities.isNotEmpty && onClearSelection != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: saving ? null : onClearSelection,
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear selection'),
              ),
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: mateType,
            decoration: const InputDecoration(labelText: 'Mate type'),
            items: [
              for (final type in [...kMateTypes, if (widthPick != null) ...[kWidthMateType, kSymmetricMateType]]) DropdownMenuItem(value: type, child: Text(mateTypeLabel(type))),
            ],
            onChanged: (type) {
              if (type != null) onMateTypeChanged(type);
            },
          ),
          if (mateTypeHasValueField(mateType)) ...[
            const SizedBox(height: 8),
            TextFormField(
              key: ValueKey('mate-value-$mateType'),
              initialValue: value?.toString() ?? '',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: mateValueLabel(mateType), helperText: mateValueHelper(mateType, autoValue: value == null ? autoValue : null)),
              autovalidateMode: AutovalidateMode.always,
              validator: (text) => mateValueError(mateType, text ?? ''),
              onChanged: (text) => onValueChanged(parseMateValue(mateType, text)),
            ),
          ],
          if (_isWidth && mateType == kWidthMateType && onWidthOffsetChanged != null) ...[
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('width-offset'),
              initialValue: widthOffset?.toString() ?? '',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Offset from centre (mm, optional)',
                helperText: 'Leave empty to centre exactly',
              ),
              autovalidateMode: AutovalidateMode.always,
              validator: (text) => widthOffsetError(text ?? ''),
              onChanged: (text) => onWidthOffsetChanged!(parseWidthOffset(text)),
            ),
          ],
          if (branchControls != null) branchControls!,
          if (mateTypeHasAllowRotation(mateType))
            CheckboxListTile(
              value: allowRotation,
              onChanged: (checked) => onAllowRotationChanged(checked ?? true),
              title: const Text('Allow rotation'),
              subtitle: const Text('Free to spin about the shared axis', style: TextStyle(fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          if (onMinimalMovementChanged != null)
            CheckboxListTile(
              value: minimalMovement,
              onChanged: (checked) => onMinimalMovementChanged!(checked ?? false),
              title: const Text('Minimal movement'),
              subtitle: const Text("Moves only this part if it can; connected parts follow only if it can't", style: TextStyle(fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          if (saving) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(notice!, key: const ValueKey('mate-branch-notice'), style: const TextStyle(fontSize: 13)),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: saving ? null : onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: saving ? null : onConfirm, child: const Text('Confirm')),
            ],
          ),
        ],
      ),
    );
  }

  /// The Width pick list: "N of 4" progress, the four slots (filled or waiting), Back for the last pick, and the pair error.
  List<Widget> _widthRows(BuildContext context) {
    final pick = widthPick!;
    final scheme = Theme.of(context).colorScheme;
    return [
      Text(pick.progress, key: const ValueKey('width-progress'), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      for (var i = 0; i < pick.total; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              // One colour per pair: the gap's faces and the part-to-centre's faces read apart in the list.
              Container(width: 10, height: 10, color: i < 2 ? scheme.primary : scheme.tertiary), // symmetric: the mirror plane takes the second colour
              const SizedBox(width: 8),
              SizedBox(width: 18, height: 18, child: i < pick.picks.length ? _iconFor(SelectionEntityKind.face) : null),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  i < pick.picks.length ? '${pick.slotLabel(i)}: ${_titleFor(pick.picks[i])}' : pick.slotLabel(i),
                  style: TextStyle(
                    color: i < pick.picks.length ? scheme.onSurface : scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (widthError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(widthError!, key: const ValueKey('width-error'), style: TextStyle(color: scheme.error, fontSize: 13)),
        ),
      if (pick.picks.isNotEmpty && onWidthBack != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('width-back'),
            onPressed: saving ? null : onWidthBack,
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Back (undo last pick)'),
          ),
        ),
    ];
  }

  // Same small private `_iconFor`/`_labelFor`/`_titleFor` subset
  // `measurement_panel.dart`'s own copy documents copying rather than
  // sharing - this one is narrower still (vertex/edge/face only, matching
  // `PartScreen._mateSelectionFilter`).
  List<Widget> _selectionRows(BuildContext context) => [
        for (final entity in selectedEntities)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 18, height: 18, child: _iconFor(entity.kind)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _titleFor(entity),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                if (onRemoveEntity != null)
                  IconButton(
                    tooltip: 'Remove from selection',
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                    onPressed: saving ? null : () => onRemoveEntity!(entity),
                  ),
              ],
            ),
          ),
      ];

  Widget _iconFor(SelectionEntityKind kind) => switch (kind) {
        SelectionEntityKind.face => const SvgIcon('assets/icons/viewport/selection_face.svg'),
        SelectionEntityKind.edge => const SvgIcon('assets/icons/viewport/selection_edge.svg'),
        SelectionEntityKind.vertex => const SvgIcon('assets/icons/viewport/selection_vertex.svg'),
        _ => const SizedBox.shrink(),
      };

  String _labelFor(SelectionEntityKind kind) => switch (kind) {
        SelectionEntityKind.face => 'Face',
        SelectionEntityKind.edge => 'Edge',
        SelectionEntityKind.vertex => 'Vertex',
        _ => 'Entity',
      };

  String _titleFor(SelectionEntityRef entity) {
    final bodyName = bodyNames[entity.bodyId] ?? 'Body';
    final owner = entity.occurrenceId.isEmpty ? bodyName : '$bodyName (component)';
    return '$owner - ${_labelFor(entity.kind)} #${entity.id}';
  }
}
