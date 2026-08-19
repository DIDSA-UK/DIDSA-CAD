import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
        // On-device feedback ("the tick/FAB confirm button should live in
        // the flyup ribbon instead of a FAB"): Line/Spline are the only two
        // draw tools with a multi-tap "profile" in progress that a tick can
        // meaningfully complete (every other tool commits its one shape in
        // a single fixed tap sequence, with nothing left to "finish") - see
        // [SketchController.finishChain]/[finishSpline].
        final showFinishChain = controller.activeTool == SketchTool.line && controller.chainInProgress;
        final showFinishSpline = controller.activeTool == SketchTool.spline && controller.splineInProgress;
        final showFinish = showFinishChain || showFinishSpline;
        return SafeArea(
          top: false,
          child: Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: ConstrainedBox(
              // On-device feedback: this bar sits on top of (and is meant to
              // fully hide) `SketchScreen`'s own "+" tool speed-dial FAB,
              // positioned bottom:16 - a standard 56px FAB, so its top edge
              // sits 72px up from the bottom. This bar's own content
              // (padding + one row of chips/text) used to come out just
              // under that, leaving the FAB's rounded top peeking out from
              // behind it, which read as something accidentally left
              // exposed rather than a deliberately layered UI. minHeight
              // comfortably clears 72px with room to spare.
              constraints: const BoxConstraints(minHeight: 88),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: switch (controller.activeTool) {
                        SketchTool.point => const Text('Tap to place a point'),
                        SketchTool.arc => const Text('Tap center, then start, then end'),
                        SketchTool.slot => const Text('Tap centerline start, end, then width'),
                        SketchTool.ellipse => const Text('Tap center, major axis, then minor radius'),
                        SketchTool.ellipseArc => const Text(
                            'Tap center, major axis, minor radius, then start and end',
                          ),
                        SketchTool.spline => const Text('Tap through-points, then Finish'),
                        SketchTool.text => const Text('Tap to place text'),
                        SketchTool.polygon => _PolygonSidesControl(controller: controller),
                        SketchTool.line || SketchTool.circle || SketchTool.rectangle =>
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: _methodChips()),
                          ),
                      },
                    ),
                    const SizedBox(width: 8),
                    if (showFinish)
                      IconButton(
                        onPressed: () {
                          if (showFinishChain) {
                            controller.finishChain();
                          } else {
                            unawaited(controller.finishSpline());
                          }
                        },
                        tooltip: 'Complete this profile and start a new one',
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
                      icon: SvgPicture.asset(
                        'assets/icons/dimbar/dimbar_exit.svg',
                        width: 26,
                        height: 26,
                        colorFilter: ColorFilter.mode(
                          Theme.of(context).colorScheme.primary,
                          BlendMode.srcIn,
                        ),
                      ),
                      label: const Text('Exit'),
                    ),
                  ],
                ),
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
    if (controller.activeTool == SketchTool.rectangle) {
      return [
        _chip(
          label: 'Two corner',
          selected: controller.rectangleConstructionMethod == RectangleConstructionMethod.twoCorner,
          onTap: () => controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner),
        ),
        const SizedBox(width: 8),
        _chip(
          label: 'Centre + corner',
          selected: controller.rectangleConstructionMethod == RectangleConstructionMethod.centreCorner,
          onTap: () => controller.setRectangleConstructionMethod(RectangleConstructionMethod.centreCorner),
        ),
        const SizedBox(width: 8),
        _chip(
          label: 'Three point',
          selected: controller.rectangleConstructionMethod == RectangleConstructionMethod.threePoint,
          onTap: () => controller.setRectangleConstructionMethod(RectangleConstructionMethod.threePoint),
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

/// Polygon's "how do you want to build this" isn't a choice of construction
/// method (there's only one: center then first vertex) - it's a side count,
/// so this replaces [SketchConstructionMethodBar._methodChips]'s chip row
/// with a plain -/+ stepper instead, same row slot every other tool's
/// chips/message occupies.
class _PolygonSidesControl extends StatelessWidget {
  final SketchController controller;

  const _PolygonSidesControl({required this.controller});

  @override
  Widget build(BuildContext context) {
    final sides = controller.polygonSides;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    // On-device feedback: the "reference circles" control used to sit in
    // the same scrollable row as the sides stepper, sharing whatever width
    // was left over once the Exit button took its share - not enough for
    // its own label to stay fully visible. A Switch (not a button posing as
    // a toggle) on its own row below the stepper (mirroring _methodChips'
    // own Line/Circle/Rectangle chip row for the stepper alone) gives the
    // label a full row's width, and reads as the on/off toggle it actually
    // is rather than a tappable button.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$sides sides'),
              IconButton(
                icon: SvgPicture.asset(
                  'assets/icons/dimbar/dimbar_polygon_sides_decrease.svg',
                  width: 30,
                  height: 30,
                  colorFilter: ColorFilter.mode(
                    sides > 3 ? onSurface : Theme.of(context).disabledColor,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: sides > 3 ? () => controller.setPolygonSides(sides - 1) : null,
              ),
              IconButton(
                icon: SvgPicture.asset(
                  'assets/icons/dimbar/dimbar_polygon_sides_increase.svg',
                  width: 30,
                  height: 30,
                  colorFilter: ColorFilter.mode(
                    sides < 20 ? onSurface : Theme.of(context).disabledColor,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: sides < 20 ? () => controller.setPolygonSides(sides + 1) : null,
              ),
            ],
          ),
        ),
        // On-device feedback ("it should be renamed as appropriately"):
        // toggles whether placing a Polygon also creates two real,
        // solver-tracked circumscribed/inscribed Circles (selectable/
        // dimensionable/deletable like any other Circle), not just a
        // dashed preview - see SketchController.createPolygonReferenceCircles's
        // own doc comment.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Reference circles', softWrap: false, overflow: TextOverflow.visible),
            Switch(
              value: controller.createPolygonReferenceCircles,
              onChanged: (_) => controller.togglePolygonReferenceCircles(),
            ),
          ],
        ),
      ],
    );
  }
}
