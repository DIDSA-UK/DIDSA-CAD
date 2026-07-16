import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
                  svgAsset: 'assets/icons/actions/action_finish.svg',
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
            svgAsset: 'assets/icons/actions/action_dimensions.svg',
            label: 'Dimensions',
            onPressed: controller.enterDimensionMode,
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_sketch_entities.svg',
            label: 'Sketch Entities',
            onPressed: controller.showSketchEntitiesCategory,
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_trim.svg',
            label: 'Trim/Extend',
            onPressed: controller.enterTrimMode,
          ),
        ];
      case FabMenuState.sketchEntities:
        final showFinishChain = controller.activeTool == SketchTool.line && controller.chainInProgress;
        final showFinishSpline =
            controller.activeTool == SketchTool.spline && controller.splineInProgress;
        // On-device feedback: 10 tools in one vertical column ran too tall
        // even with the scroll fallback above - two rows of 5 keeps the
        // whole menu roughly square instead of a long ladder, so it fits
        // above the main FAB on more viewports without scrolling.
        final tools = [
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_circle.svg',
            label: 'Circle',
            selected: controller.activeTool == SketchTool.circle,
            onPressed: () => controller.selectDrawTool(SketchTool.circle),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_arc.svg',
            label: 'Arc',
            selected: controller.activeTool == SketchTool.arc,
            onPressed: () => controller.selectDrawTool(SketchTool.arc),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_line.svg',
            label: 'Line',
            selected: controller.activeTool == SketchTool.line,
            onPressed: () => controller.selectDrawTool(SketchTool.line),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_point.svg',
            label: 'Point',
            selected: controller.activeTool == SketchTool.point,
            onPressed: () => controller.selectDrawTool(SketchTool.point),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_rectangle.svg',
            label: 'Rectangle',
            selected: controller.activeTool == SketchTool.rectangle,
            onPressed: () => controller.selectDrawTool(SketchTool.rectangle),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_polygon.svg',
            label: 'Polygon',
            selected: controller.activeTool == SketchTool.polygon,
            onPressed: () => controller.selectDrawTool(SketchTool.polygon),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_slot.svg',
            label: 'Slot',
            selected: controller.activeTool == SketchTool.slot,
            onPressed: () => controller.selectDrawTool(SketchTool.slot),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_ellipse.svg',
            label: 'Ellipse',
            selected: controller.activeTool == SketchTool.ellipse,
            onPressed: () => controller.selectDrawTool(SketchTool.ellipse),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_spline.svg',
            label: 'Spline',
            selected: controller.activeTool == SketchTool.spline,
            onPressed: () => controller.selectDrawTool(SketchTool.spline),
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_text.svg',
            label: 'Text',
            selected: controller.activeTool == SketchTool.text,
            onPressed: () => controller.selectDrawTool(SketchTool.text),
          ),
        ];
        final splitAt = (tools.length / 2).ceil();
        Widget rowOf(List<_SpeedDialAction> rowTools) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < rowTools.length; i++)
                  Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                    child: rowTools[i],
                  ),
              ],
            );
        return [
          if (showFinishChain)
            _SpeedDialAction(
              svgAsset: 'assets/icons/actions/action_finish.svg',
              label: 'Finish',
              onPressed: controller.finishChain,
            ),
          if (showFinishSpline)
            _SpeedDialAction(
              svgAsset: 'assets/icons/actions/action_finish.svg',
              label: 'Finish',
              onPressed: controller.finishSpline,
            ),
          rowOf(tools.sublist(0, splitAt)),
          rowOf(tools.sublist(splitAt)),
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_back.svg',
            label: 'Back',
            onPressed: controller.backToFabCategories,
          ),
        ];
    }
  }
}

class _SpeedDialAction extends StatelessWidget {
  final String svgAsset;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  const _SpeedDialAction({
    required this.svgAsset,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Every glyph here uses `currentColor` for its own fill/stroke (see the
    // didsa-cad-icons hand-off brief's own spec) - a ColorFilter with
    // BlendMode.srcIn re-tints every non-transparent pixel uniformly,
    // mirroring how Icon(icon, color: ...) already tints Material's own
    // icon font glyphs, so selected/unselected reads exactly like the
    // IconData-based FABs elsewhere in the sketcher.
    final foreground = selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;
    return FloatingActionButton.small(
      heroTag: null,
      tooltip: label,
      backgroundColor: selected ? colorScheme.primary : null,
      foregroundColor: foreground,
      onPressed: onPressed,
      child: SvgPicture.asset(
        svgAsset,
        width: 30,
        height: 30,
        colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn),
      ),
    );
  }
}
