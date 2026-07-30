import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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

/// Pattern/Mirror's own bottom fly-up bar, shown once [SketchController.
/// patternPreviewTargets] is non-null (picking is done) - mirrors
/// `OffsetValueBar`'s exact "plain non-modal [Material] panel, live ghost
/// preview computed client-side" shape (see [SketchController.
/// patternMirrorGhosts]), widened with a Pattern/Mirror [SegmentedButton]
/// (one [SketchMode.pattern] entry covers both operations, per this phase's
/// own scope-doc design) and Pattern's own count/spacing/direction/reverse
/// fields in place of Offset's single distance field.
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
        // Keyed by the target list's own identity - see OffsetValueBar's own
        // doc comment for why (a fresh session must never carry over a
        // previous session's own typed text/state).
        return _PatternValueBarContent(key: ValueKey(targets), controller: controller, targetCount: targets.length);
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
  late final TextEditingController _countText = TextEditingController(
    text: widget.controller.patternCount.toString(),
  );
  late final TextEditingController _spacingText = TextEditingController();

  @override
  void dispose() {
    _countText.dispose();
    _spacingText.dispose();
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
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.targetCount == 1 ? '1 entity picked' : '${widget.targetCount} entities picked',
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<SketchPatternMirrorOperation>(
                    segments: const [
                      ButtonSegment(value: SketchPatternMirrorOperation.pattern, label: Text('Pattern')),
                      ButtonSegment(value: SketchPatternMirrorOperation.mirror, label: Text('Mirror')),
                    ],
                    selected: {operation},
                    onSelectionChanged: (selection) => controller.setPatternMirrorOperation(selection.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (operation == SketchPatternMirrorOperation.pattern)
                _patternFields(controller)
              else
                _mirrorFields(controller),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(onPressed: _cancel, icon: const Icon(Icons.close), tooltip: 'Cancel'),
                  FilledButton(
                    onPressed: controller.canConfirmPatternMirror ? _confirm : null,
                    child: Text(operation == SketchPatternMirrorOperation.pattern ? 'Pattern' : 'Mirror'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _patternFields(SketchController controller) {
    final directionSummary = controller.patternDirectionLineId != null
        ? 'Direction: picked Line'
        : controller.patternDirectionFixedAxis != null
            ? 'Direction: ${controller.patternDirectionFixedAxis!.toUpperCase()} axis'
            : 'Direction: tap X/Y or a Line in the sketch';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(directionSummary),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'x', label: Text('X')),
                ButtonSegment(value: 'y', label: Text('Y')),
              ],
              selected: controller.patternDirectionFixedAxis != null ? {controller.patternDirectionFixedAxis!} : {},
              emptySelectionAllowed: true,
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                controller.setPatternDirectionFixedAxis(selection.first);
              },
            ),
            IconButton(
              onPressed: controller.togglePatternReverse,
              isSelected: controller.patternReverse,
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
                controller: _countText,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(isDense: true, labelText: 'Count'),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null) controller.setPatternCount(count);
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _spacingText,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(isDense: true, hintText: 'Spacing', suffixText: 'mm'),
                onChanged: (value) => controller.setPatternSpacing(double.tryParse(value)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _mirrorFields(SketchController controller) {
    return Text(
      controller.mirrorLineId != null ? 'Mirror line picked' : 'Tap a Line in the sketch to mirror across',
    );
  }
}
