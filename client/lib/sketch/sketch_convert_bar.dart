import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'sketch_controller.dart';

/// Convert Entities' bottom fly-up bar (on-device feedback: "the tick/FAB
/// confirm button should live in the flyup ribbon instead of a FAB, for
/// every tool") - mirrors [SketchDimensionBar]'s exact shape (a plain
/// non-modal [Material] panel, tooltip text while nothing's picked yet, a
/// chip row once something is). Convert Entities now stages a Body
/// vertex/edge/face pick rather than converting it immediately (see
/// [SketchController.stageConvertVertex]/[stageConvertEdge]/
/// [stageConvertFaceEdges]) - this bar's own Tick
/// ([SketchController.confirmConvertSelection]) is what actually converts
/// everything staged, keeping the tool open for further picks; Exit
/// ([SketchController.discardPendingConvertSelection]) discards whatever's
/// staged without converting any of it.
class SketchConvertBar extends StatelessWidget {
  final SketchController controller;

  const SketchConvertBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final vertexCount = controller.pendingConvertVertices.length;
        final edgeCount = controller.pendingConvertEdges.length;
        final total = vertexCount + edgeCount;
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
                      total == 0
                          ? 'Tap a body vertex, edge, or face to convert'
                          : total == 1
                              ? '1 entity selected - tap the tick to convert'
                              : '$total entities selected - tap the tick to convert',
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (total > 0)
                    IconButton(
                      onPressed: () => unawaited(controller.confirmConvertSelection()),
                      tooltip: 'Convert selected entities',
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
                    onPressed: () {
                      controller.discardPendingConvertSelection();
                      controller.exitToSelectMode();
                    },
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
