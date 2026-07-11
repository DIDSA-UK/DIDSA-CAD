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
        // On-device feedback: "is there a finish button" - the Sketch
        // Entities category's own "Finish" action (below) only shows while
        // that category is open, and every tool selection auto-closes the
        // whole menu (see selectDrawTool) so there's a clear canvas to draw
        // on - meaning a mid-Spline/mid-chain user had no visible way to
        // finish without first reopening the menu and navigating back into
        // Sketch Entities. This persistent copy shows regardless of
        // fabMenu's own open/closed state, right above the main FAB, for as
        // long as a Line chain or Spline is actually in progress.
        final showPersistentFinish = controller.chainInProgress || controller.splineInProgress;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showPersistentFinish)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SpeedDialAction(
                  icon: Icons.check_circle_outline,
                  label: 'Finish',
                  onPressed: controller.chainInProgress ? controller.finishChain : controller.finishSpline,
                ),
              ),
            if (actions.isNotEmpty)
              // Bounded + scrollable rather than a bare unconstrained
              // Column: the Sketch Entities tool list has grown past what
              // reliably fits above the main FAB on a short viewport (this
              // Positioned sits in a Stack, which clips by default) - a
              // plain Column here silently clipped its topmost action off-
              // screen once Ellipse became the list's 8th tool. Bounding to
              // a fraction of the screen height keeps this a no-op on any
              // viewport tall enough to fit everything (every real device
              // this has been tested on so far), and only engages the
              // scroll on a short one.
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final action in actions)
                        Padding(padding: const EdgeInsets.only(bottom: 8), child: action),
                    ],
                  ),
                ),
              ),
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
        final showFinishChain = controller.activeTool == SketchTool.line && controller.chainInProgress;
        final showFinishSpline =
            controller.activeTool == SketchTool.spline && controller.splineInProgress;
        return [
          if (showFinishChain)
            _SpeedDialAction(
              icon: Icons.check_circle_outline,
              label: 'Finish',
              onPressed: controller.finishChain,
            ),
          if (showFinishSpline)
            _SpeedDialAction(
              icon: Icons.check_circle_outline,
              label: 'Finish',
              onPressed: controller.finishSpline,
            ),
          _SpeedDialAction(
            icon: Icons.circle_outlined,
            label: 'Circle',
            selected: controller.activeTool == SketchTool.circle,
            onPressed: () => controller.selectDrawTool(SketchTool.circle),
          ),
          _SpeedDialAction(
            icon: Icons.donut_large,
            label: 'Arc',
            selected: controller.activeTool == SketchTool.arc,
            onPressed: () => controller.selectDrawTool(SketchTool.arc),
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
            icon: Icons.hexagon_outlined,
            label: 'Polygon',
            selected: controller.activeTool == SketchTool.polygon,
            onPressed: () => controller.selectDrawTool(SketchTool.polygon),
          ),
          _SpeedDialAction(
            icon: Icons.rectangle_outlined,
            label: 'Slot',
            selected: controller.activeTool == SketchTool.slot,
            onPressed: () => controller.selectDrawTool(SketchTool.slot),
          ),
          _SpeedDialAction(
            icon: Icons.egg_outlined,
            label: 'Ellipse',
            selected: controller.activeTool == SketchTool.ellipse,
            onPressed: () => controller.selectDrawTool(SketchTool.ellipse),
          ),
          _SpeedDialAction(
            icon: Icons.gesture,
            label: 'Spline',
            selected: controller.activeTool == SketchTool.spline,
            onPressed: () => controller.selectDrawTool(SketchTool.spline),
          ),
          _SpeedDialAction(
            icon: Icons.text_fields,
            label: 'Text',
            selected: controller.activeTool == SketchTool.text,
            onPressed: () => controller.selectDrawTool(SketchTool.text),
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
