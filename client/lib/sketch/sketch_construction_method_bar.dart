import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The "how do you want to build this entity" panel that flies up from the
/// bottom of the screen whenever a draw tool is active. Deliberately *not*
/// a real [showModalBottomSheet] - that would put a barrier over the canvas
/// and block the taps this very panel is meant to accompany - so it's a
/// plain [Material] panel that [SketchScreen] slides in/out with
/// [AnimatedSlide], positioned above the rest of the canvas Stack.
class SketchConstructionMethodBar extends StatelessWidget {
  final SketchController controller;

  const SketchConstructionMethodBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
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
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: _methodChips()),
                    ),
                  ),
                  const SizedBox(width: 8),
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

  List<Widget> _methodChips() {
    if (controller.activeTool == SketchTool.line) {
      return [
        _chip(
          label: 'End to end',
          selected: controller.lineConstructionMethod == LineConstructionMethod.endToEnd,
          onTap: () => controller.setLineConstructionMethod(LineConstructionMethod.endToEnd),
        ),
        const SizedBox(width: 8),
        _chip(
          label: 'Midpoint',
          selected: controller.lineConstructionMethod == LineConstructionMethod.midpoint,
          onTap: () => controller.setLineConstructionMethod(LineConstructionMethod.midpoint),
        ),
      ];
    }
    return [
      _chip(
        label: 'Center + radius',
        selected: controller.circleConstructionMethod == CircleConstructionMethod.centerRadius,
        onTap: () => controller.setCircleConstructionMethod(CircleConstructionMethod.centerRadius),
      ),
      const SizedBox(width: 8),
      _chip(
        label: 'Three point',
        selected: controller.circleConstructionMethod == CircleConstructionMethod.threePoint,
        onTap: () => controller.setCircleConstructionMethod(CircleConstructionMethod.threePoint),
      ),
    ];
  }

  Widget _chip({required String label, required bool selected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
