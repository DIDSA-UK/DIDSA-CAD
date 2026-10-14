import 'dart:async';

import 'package:flutter/material.dart';

import '../viewport3d/resizable_tool_panel.dart';
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
        return ResizableToolPanel(
          title: 'Convert Entities',
          tooltip: total == 0
              ? 'Tap a body vertex, edge, or face to convert'
              : total == 1
                  ? '1 entity selected'
                  : '$total entities selected',
          defaultHeightFraction: 0.22,
          minHeightFraction: 0.15,
          maxHeightFraction: 0.6,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  controller.discardPendingConvertSelection();
                  controller.exitToSelectMode();
                },
                child: const Text('Exit'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: total > 0 ? () => unawaited(controller.confirmConvertSelection()) : null,
                child: const Text('Convert'),
              ),
            ],
          ),
        );
      },
    );
  }
}
