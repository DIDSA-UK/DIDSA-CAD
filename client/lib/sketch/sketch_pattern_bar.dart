import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../viewport3d/resizable_tool_panel.dart';
import 'sketch_controller.dart';

/// Sketcher-roadmap Phase 7 (2D Pattern/Mirror): Pattern/Mirror's own
/// picking-phase bar, cloned from `sketch_offset_bar.dart`'s [OffsetPickBar]
/// (down to the doc comment shape) - shown while [SketchController.
/// patternPreviewTargets] is still null, i.e. before picking is done. Its
/// own Tick confirms one or more accumulated Line/Circle/Arc picks via
/// [SketchController.finishPatternPick].
class PatternPickBar extends StatelessWidget {
  final SketchController controller;

  const PatternPickBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final count = controller.selectionSet.length;
        return SafeArea(
          top: false,
          child: Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      count == 0
                          ? 'Select line/circle/curve to pattern or mirror'
                          : count == 1
                              ? '1 entity picked - tap the tick to continue'
                              : '$count entities picked - tap the tick to continue',
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (count > 0)
                    IconButton(
                      onPressed: controller.finishPatternPick,
                      tooltip: 'Finish picking',
                      icon: SvgPicture.asset(
                        'assets/icons/actions/action_finish.svg',
                        width: 26,
                        height: 26,
                        colorFilter: ColorFilter.mode(
                          Theme.of(context).colorScheme.primary,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: controller.exitToSelectMode,
                    icon: const Icon(Icons.close),
                    label: const Text('Exit'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pattern/Mirror's own configuring-phase panel, shown once
/// [SketchController.patternPreviewTargets] is non-null (picking is done).
///
/// On-device feedback ("the ribbon is untidy. match ribbon from other
/// pattern tool. extend by pulling and scrollable"): rebuilt on top of
/// `viewport3d/resizable_tool_panel.dart`'s shared [ResizableToolPanel] -
/// the exact same pull-to-resize, scrollable shell every 3D Feature panel
/// (Extrude/Revolve/Sweep/Fillet/Chamfer/Mirror/Pattern) already uses,
/// rather than the bespoke, fixed-height `Material` shell this bar
/// originally had (matching `OffsetValueBar`'s own older, single-field
/// shape, which never needed to scroll).
class PatternValueBar extends StatelessWidget {
  final SketchController controller;

  const PatternValueBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final targets = controller.patternPreviewTargets;
        if (targets == null) return const SizedBox.shrink();
        // Keyed by the target list's own identity plus whichever instance
        // (if any) is being edited and whether a second direction is
        // currently enabled - each of these implies a different set of
        // sensible initial text-field values, so each needs its own fresh
        // `State`/`TextEditingController`s rather than one reused across
        // them (mirrors `PatternPanel`'s own re-seeding key at its call
        // site in `part_screen.dart`).
        final key = ValueKey((
          targets,
          controller.editingPatternInstanceId,
          controller.editingMirrorInstanceId,
          controller.patternHasSecondDirection,
        ));
        return _PatternValueBarContent(key: key, controller: controller, targetCount: targets.length);
      },
    );
  }
}

class _PatternValueBarContent extends StatefulWidget {
  final SketchController controller;
  final int targetCount;

  const _PatternValueBarContent({super.key, required this.controller, required this.targetCount});

  @override
  State<_PatternValueBarContent> createState() => _PatternValueBarContentState();
}

class _PatternValueBarContentState extends State<_PatternValueBarContent> {
  late final TextEditingController _count1Text =
      TextEditingController(text: widget.controller.patternCount1.toString());
  late final TextEditingController _spacing1Text =
      TextEditingController(text: widget.controller.patternSpacing1?.toString() ?? '');
  late final TextEditingController _count2Text =
      TextEditingController(text: widget.controller.patternCount2.toString());
  late final TextEditingController _spacing2Text =
      TextEditingController(text: widget.controller.patternSpacing2?.toString() ?? '');

  @override
  void dispose() {
    _count1Text.dispose();
    _spacing1Text.dispose();
    _count2Text.dispose();
    _spacing2Text.dispose();
    super.dispose();
  }

  void _confirm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.confirmPatternMirrorPreview());
    });
  }

  void _cancel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.cancelPatternMirrorPreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final operation = controller.patternMirrorOperation;
    final editing = controller.editingPatternInstanceId != null || controller.editingMirrorInstanceId != null;
    final title = editing
        ? (operation == SketchPatternMirrorOperation.pattern ? 'Edit Pattern' : 'Edit Mirror')
        : (operation == SketchPatternMirrorOperation.pattern ? 'Pattern' : 'Mirror');

    return ResizableToolPanel(
      title: title,
      tooltip: '${widget.targetCount} ${widget.targetCount == 1 ? 'entity' : 'entities'} picked',
      dragHandleKey: const Key('patternValueBarDragHandle'),
      resizableAreaKey: const Key('patternValueBarResizableArea'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SegmentedButton<SketchPatternMirrorOperation>(
              segments: const [
                ButtonSegment(value: SketchPatternMirrorOperation.pattern, label: Text('Pattern')),
                ButtonSegment(value: SketchPatternMirrorOperation.mirror, label: Text('Mirror')),
              ],
              selected: {operation},
              onSelectionChanged: (selection) => controller.setPatternMirrorOperation(selection.first),
            ),
          ),
          if (operation == SketchPatternMirrorOperation.pattern)
            _patternFields(controller)
          else
            _mirrorFields(controller),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _cancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: controller.canConfirmPatternMirror ? _confirm : null,
                child: Text(editing ? 'Update' : (operation == SketchPatternMirrorOperation.pattern ? 'Pattern' : 'Mirror')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _directionSection(
    SketchController controller, {
    required String label,
    required String? directionLineId,
    required String? directionFixedAxis,
    required bool reverse,
    required TextEditingController countText,
    required TextEditingController spacingText,
    required void Function(String axis) onFixedAxis,
    required VoidCallback onReverse,
    required void Function(int count) onCount,
    required void Function(double? spacing) onSpacing,
    required int slot,
  }) {
    final summary = directionLineId != null
        ? '$label: picked Line'
        : directionFixedAxis != null
            ? '$label: ${directionFixedAxis.toUpperCase()} axis'
            : '$label: tap X/Y or a Line in the sketch';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(summary),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'x', label: Text('X')),
                ButtonSegment(value: 'y', label: Text('Y')),
              ],
              selected: directionFixedAxis != null ? {directionFixedAxis} : {},
              emptySelectionAllowed: true,
              onSelectionChanged: (selection) {
                controller.setPatternActiveDirectionSlot(slot);
                if (selection.isEmpty) return;
                onFixedAxis(selection.first);
              },
            ),
            IconButton(
              onPressed: onReverse,
              isSelected: reverse,
              tooltip: 'Reverse direction',
              icon: const Icon(Icons.flip),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 90,
              child: TextField(
                controller: countText,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(isDense: true, labelText: 'Count'),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null) onCount(count);
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: TextField(
                controller: spacingText,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(isDense: true, hintText: 'Spacing', suffixText: 'mm'),
                onChanged: (value) => onSpacing(double.tryParse(value)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _patternFields(SketchController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => controller.setPatternActiveDirectionSlot(1),
          child: _directionSection(
            controller,
            label: 'Direction 1',
            directionLineId: controller.patternDirectionLineId,
            directionFixedAxis: controller.patternDirectionFixedAxis,
            reverse: controller.patternReverse1,
            countText: _count1Text,
            spacingText: _spacing1Text,
            onFixedAxis: controller.setPatternDirectionFixedAxis,
            onReverse: controller.togglePatternReverse1,
            onCount: controller.setPatternCount1,
            onSpacing: controller.setPatternSpacing1,
            slot: 1,
          ),
        ),
        const SizedBox(height: 8),
        // On-device feedback ("allow pattern in two directions, check body
        // pattern tool for UX") - mirrors `PatternPanel`'s own "enable
        // Direction 2" checkbox, shown only once enabled (the active-slot
        // toggle has nothing to disambiguate before then).
        Row(
          children: [
            Checkbox(
              value: controller.patternHasSecondDirection,
              onChanged: (value) => controller.setPatternHasSecondDirection(value ?? false),
            ),
            const Text('Add a second direction'),
          ],
        ),
        if (controller.patternHasSecondDirection) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Direction 1')),
                ButtonSegment(value: 2, label: Text('Direction 2')),
              ],
              selected: {controller.patternActiveDirectionSlot},
              onSelectionChanged: (selection) => controller.setPatternActiveDirectionSlot(selection.first),
            ),
          ),
          GestureDetector(
            onTap: () => controller.setPatternActiveDirectionSlot(2),
            child: _directionSection(
              controller,
              label: 'Direction 2',
              directionLineId: controller.patternDirection2LineId,
              directionFixedAxis: controller.patternDirection2FixedAxis,
              reverse: controller.patternReverse2,
              countText: _count2Text,
              spacingText: _spacing2Text,
              onFixedAxis: controller.setPatternDirection2FixedAxis,
              onReverse: controller.togglePatternReverse2,
              onCount: controller.setPatternCount2,
              onSpacing: controller.setPatternSpacing2,
              slot: 2,
            ),
          ),
        ],
      ],
    );
  }

  Widget _mirrorFields(SketchController controller) {
    return Text(
      controller.mirrorLineId != null ? 'Mirror line picked' : 'Tap a Line in the sketch to mirror across',
    );
  }
}
