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

  /// Sketcher restructure Phase 2 follow-up (P20): the 3D-embedded sketcher
  /// now supports every draw tool except Text (see `sketch_screen.dart`'s
  /// own doc comment on `_orbitViewActive`) - `handleCanvasTap`/
  /// `activeDrawGhost`/`sketchGeometry3DFrom` were already tool-agnostic
  /// (the P16-P18 cursor+ghost+commit retrofit and P8/P9's committed-
  /// geometry rendering never assumed Point/Line specifically), so the only
  /// real restriction left is Text - it creates a real Text entity fine
  /// (`_clickTextTool` is a plain, already-generic tap handler), but has no
  /// 3D glyph rendering at all (`sketchGeometry3DFrom`'s own doc comment:
  /// "a separate, larger piece of work") - selecting it here would silently
  /// place invisible geometry. P30: Trim/Extend no longer stays excluded
  /// here - its own tap-commit logic never depended on ghost-picking in the
  /// first place, so it was only ever blocked by this flag hiding its menu
  /// entry, not by any real 2D-specific dependency. P38: Dimensions no
  /// longer excluded either - both blockers this doc comment used to cite
  /// are gone: constraint-label/value rendering now exists in 3D (P32's
  /// `ConstraintOverlay`), and referencing an external Body's own vertex/
  /// edge (`SketchController.pickReferenceGhostVertex`/`pickReferenceGhostEdge`)
  /// already works in Orbit View too, via a *different*, already-existing
  /// mechanism (`PartViewport.preferEntityPick`/`onSketchEntityTap`,
  /// `sketch_screen.dart`'s own `_preferEntityPickOnTap`/
  /// `_handleEmbeddedSketchEntityTap`, built in P10 specifically for
  /// Dimension mode) - real Body geometry is already directly tappable in
  /// 3D via ordinary hit-testing, with no need for the 2D canvas's own
  /// projected-ghost-overlay trick at all.
  final bool restrictToEmbeddedTools;

  const SketchSpeedDial({super.key, required this.controller, this.restrictToEmbeddedTools = false});

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
        //
        // On-device feedback ("when I start the offset tool... there
        // should be a fly up menu at the bottom with a button to finish
        // the tool. same applies to trim/extend tool"): the same
        // "no visible way out" gap applies to every mode entered via the
        // new "Tools" category (Dimensions/Trim/Extend/Convert Entities/
        // Offset) - none of them auto-return to Select on their own, and
        // the only other way out (tapping the mode label in the toolbar)
        // isn't obviously a button. `exitToSelectMode` is the correct
        // "done" action for all four - none of them has its own
        // finish-and-commit step the way chain/spline drawing does.
        final activeToolMode = switch (controller.mode) {
          SketchMode.dimension || SketchMode.trim || SketchMode.convert || SketchMode.offset => true,
          _ => false,
        };
        final showPersistentFinish = controller.chainInProgress || controller.splineInProgress || activeToolMode;
        VoidCallback finishAction() {
          if (controller.chainInProgress) return controller.finishChain;
          if (controller.splineInProgress) return controller.finishSpline;
          return controller.exitToSelectMode;
        }

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
                  onPressed: finishAction(),
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
            svgAsset: 'assets/icons/actions/action_sketch_entities.svg',
            label: 'Sketch Entities',
            onPressed: controller.showSketchEntitiesCategory,
          ),
          // On-device feedback ("the tools trim/extend, convert/offset,
          // dimension should be grouped together in a 'tools' fab similar
          // to sketch entity tools"): replaces what used to be three (now
          // four, with Offset) separate top-level entries here - see the
          // FabMenuState.tools case below.
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_trim.svg',
            label: 'Tools',
            onPressed: controller.showToolsCategory,
          ),
        ];
      case FabMenuState.tools:
        // On-device feedback: grouped exactly like FabMenuState.
        // sketchEntities's own tool list - a Back button returns to the
        // top-level categories, mirrored below.
        return [
          // P38: Dimensions works in Orbit View now too - see
          // [restrictToEmbeddedTools]'s own doc comment for why both of
          // its old blockers no longer apply.
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_dimensions.svg',
            label: 'Dimensions',
            onPressed: controller.enterDimensionMode,
          ),
          // P30: Trim/Extend works in Orbit View now - its own tap-commit
          // logic never depended on the 2D-only reference-body ghost-
          // picking system in the first place (see
          // SketchController._handleTrimTap's own doc comment), so it was
          // only ever blocked by this menu hiding it.
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_trim.svg',
            label: 'Trim/Extend',
            onPressed: controller.enterTrimMode,
          ),
          // P48/P50 (Sketcher-roadmap Phase 9 v1/v2): Convert Entities - always
          // shown, same as Dimensions above, even though it only has
          // anything to do for a Part-backed Sketch with sibling Bodies -
          // a bare/no-Part Sketch just has no ghost geometry to tap,
          // mirroring how Dimension mode's own external-reference picking
          // already tolerates that case as a graceful no-op rather than
          // hiding the whole category.
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_convert_entities.svg',
            label: 'Convert Entities',
            onPressed: controller.enterConvertEntitiesMode,
          ),
          // On-device feedback: Offset's own cursor-driven mode (the
          // ribbon's single-selection "Offset" chip still exists
          // separately, for when something's already selected).
          _SpeedDialAction(
            svgAsset: 'assets/icons/ribbon/ribbon_offset.svg',
            label: 'Offset',
            onPressed: controller.enterOffsetMode,
          ),
          _SpeedDialAction(
            svgAsset: 'assets/icons/actions/action_back.svg',
            label: 'Back',
            onPressed: controller.backToFabCategories,
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
        //
        // On-device feedback ("opening the sketch tools FAB, all tools
        // should be 'off' - currently the last used tool is coloured
        // 'on'"): each chip's own `selected` check below now also requires
        // `controller.mode == SketchMode.draw` - `controller.activeTool` is
        // a plain field that survives a mode switch away from draw
        // (it's what `selectDrawTool`/re-entering draw mode resumes), so a
        // bare `activeTool == SketchTool.x` check kept showing the
        // last-used tool as "on" even while idle in Select mode with
        // nothing actually being placed.
        final allTools = [
          _SpeedDialAction(
            tool: SketchTool.circle,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_circle.svg',
            label: 'Circle',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.circle,
            onPressed: () => controller.selectDrawTool(SketchTool.circle),
          ),
          _SpeedDialAction(
            tool: SketchTool.arc,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_arc.svg',
            label: 'Arc',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.arc,
            onPressed: () => controller.selectDrawTool(SketchTool.arc),
          ),
          _SpeedDialAction(
            tool: SketchTool.line,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_line.svg',
            label: 'Line',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.line,
            onPressed: () => controller.selectDrawTool(SketchTool.line),
          ),
          _SpeedDialAction(
            tool: SketchTool.point,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_point.svg',
            label: 'Point',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.point,
            onPressed: () => controller.selectDrawTool(SketchTool.point),
          ),
          _SpeedDialAction(
            tool: SketchTool.rectangle,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_rectangle.svg',
            label: 'Rectangle',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.rectangle,
            onPressed: () => controller.selectDrawTool(SketchTool.rectangle),
          ),
          _SpeedDialAction(
            tool: SketchTool.polygon,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_polygon.svg',
            label: 'Polygon',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.polygon,
            onPressed: () => controller.selectDrawTool(SketchTool.polygon),
          ),
          _SpeedDialAction(
            tool: SketchTool.slot,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_slot.svg',
            label: 'Slot',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.slot,
            onPressed: () => controller.selectDrawTool(SketchTool.slot),
          ),
          _SpeedDialAction(
            tool: SketchTool.ellipse,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_ellipse.svg',
            label: 'Ellipse',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.ellipse,
            onPressed: () => controller.selectDrawTool(SketchTool.ellipse),
          ),
          _SpeedDialAction(
            tool: SketchTool.spline,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_spline.svg',
            label: 'Spline',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.spline,
            onPressed: () => controller.selectDrawTool(SketchTool.spline),
          ),
          _SpeedDialAction(
            tool: SketchTool.text,
            svgAsset: 'assets/icons/sketch_tools/sketch_tool_text.svg',
            label: 'Text',
            selected: controller.mode == SketchMode.draw && controller.activeTool == SketchTool.text,
            onPressed: () => controller.selectDrawTool(SketchTool.text),
          ),
        ];
        // P20: every tool except Text works in the 3D-embedded view now -
        // see [restrictToEmbeddedTools]'s own doc comment.
        final tools = restrictToEmbeddedTools
            ? allTools.where((action) => action.tool != SketchTool.text).toList()
            : allTools;
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

  /// Which [SketchTool] this action selects, if any - null for the
  /// category/Finish/Back actions, which aren't tool selections.  Used only
  /// to filter [SketchSpeedDial.restrictToEmbeddedTools]; doesn't affect
  /// rendering.
  final SketchTool? tool;

  const _SpeedDialAction({
    required this.svgAsset,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.tool,
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
