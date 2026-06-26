import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The tool switcher FAB. Two-level menu driven entirely by
/// [SketchController.fabMenu]: tapping the main FAB opens a "categories"
/// list ("Sketch Entities" / "Dimensions"); tapping "Sketch Entities"
/// expands in place into the tool list (Line/Circle/Finish) with a "Back"
/// action; tapping "Dimensions" enters dimension mode directly and closes
/// the menu. The open/closed/category state lives on the controller (not
/// local widget State) so [SketchScreen]'s tap-outside barrier can close
/// the menu independently of this widget.
class SketchSpeedDial extends StatelessWidget {
  final SketchController controller;

  const SketchSpeedDial({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final actions = _actionsFor(controller);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final action in actions)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: action),
            FloatingActionButton(
              heroTag: null,
              onPressed: controller.fabMenu == FabMenuState.closed
                  ? controller.openFabMenu
                  : controller.closeFabMenu,
              child: Icon(controller.fabMenu == FabMenuState.closed ? Icons.add : Icons.close),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _actionsFor(SketchController controller) {
    switch (controller.fabMenu) {
      case FabMenuState.closed:
        return const [];
      case FabMenuState.categories:
        return [
          _SpeedDialAction(
            icon: Icons.straighten,
            label: 'Dimensions',
            onPressed: controller.enterDimensionMode,
          ),
          _SpeedDialAction(
            icon: Icons.edit,
            label: 'Sketch Entities',
            onPressed: controller.showSketchEntitiesCategory,
          ),
        ];
      case FabMenuState.sketchEntities:
        final showFinish = controller.activeTool == SketchTool.line && controller.chainInProgress;
        return [
          if (showFinish)
            _SpeedDialAction(
              icon: Icons.check_circle_outline,
              label: 'Finish',
              onPressed: controller.finishChain,
            ),
          _SpeedDialAction(
            icon: Icons.circle_outlined,
            label: 'Circle',
            selected: controller.activeTool == SketchTool.circle,
            onPressed: () => controller.selectDrawTool(SketchTool.circle),
          ),
          _SpeedDialAction(
            icon: Icons.show_chart,
            label: 'Line',
            selected: controller.activeTool == SketchTool.line,
            onPressed: () => controller.selectDrawTool(SketchTool.line),
          ),
          _SpeedDialAction(
            icon: Icons.control_point,
            label: 'Point',
            selected: controller.activeTool == SketchTool.point,
            onPressed: () => controller.selectDrawTool(SketchTool.point),
          ),
          _SpeedDialAction(
            icon: Icons.crop_square,
            label: 'Rectangle',
            selected: controller.activeTool == SketchTool.rectangle,
            onPressed: () => controller.selectDrawTool(SketchTool.rectangle),
          ),
          _SpeedDialAction(
            icon: Icons.arrow_back,
            label: 'Back',
            onPressed: controller.backToFabCategories,
          ),
        ];
    }
  }
}

class _SpeedDialAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  const _SpeedDialAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FloatingActionButton.small(
      heroTag: null,
      tooltip: label,
      backgroundColor: selected ? colorScheme.primary : null,
      foregroundColor: selected ? colorScheme.onPrimary : null,
      onPressed: onPressed,
      child: Icon(icon),
    );
  }
}
