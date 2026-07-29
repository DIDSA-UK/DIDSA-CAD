import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'sketch_controller.dart';

/// Trim/Extend's bottom fly-up bar (on-device feedback: "the tick/FAB
/// confirm button should live in the flyup ribbon instead of a FAB, for
/// every tool") - mirrors [SketchConstructionMethodBar]'s shape (tooltip
/// text plus an Exit button), with one addition: a "Trim"/"Corner" mode
/// toggle (on-device feedback: "add a new mode to create a corner by
/// extending two lines or curves to a common intersect"). Plain trim/extend
/// (the default) needs no confirm step - every tap commits immediately, same
/// as before - so no Tick shows outside Corner mode; Corner mode's own Tick
/// only appears once two Lines/Arcs are picked (see
/// [SketchController.confirmTrimCorner]), confirming the pair and creating
/// the corner while leaving the tool open for another one.
class SketchTrimBar extends StatelessWidget {
  final SketchController controller;

  const SketchTrimBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final cornerMode = controller.trimCornerMode;
        final pickCount = cornerMode ? controller.selectionSet.length : 0;
        final message = cornerMode
            ? (pickCount < 2
                ? 'Tap two lines or curves to extend to a corner'
                : 'Tap the tick to create the corner')
            : 'Tap a line, circle, or curve to trim/extend';
        return SafeArea(
          top: false,
          child: Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _chip(label: 'Trim', selected: !cornerMode, onTap: () => controller.setTrimCornerMode(false)),
                      const SizedBox(width: 8),
                      _chip(label: 'Corner', selected: cornerMode, onTap: () => controller.setTrimCornerMode(true)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: Text(message)),
                      const SizedBox(width: 8),
                      if (cornerMode && pickCount == 2)
                        IconButton(
                          onPressed: () => unawaited(controller.confirmTrimCorner()),
                          tooltip: 'Create corner',
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chip({required String label, required bool selected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
