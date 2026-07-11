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
                    child: switch (controller.activeTool) {
                      SketchTool.point => const Text('Tap to place a point'),
                      SketchTool.arc => const Text('Tap center, then start, then end'),
                      SketchTool.slot => const Text('Tap centerline start, end, then width'),
                      SketchTool.ellipse => const Text('Tap center, major axis, then minor radius'),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$sides sides'),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: sides > 3 ? () => controller.setPolygonSides(sides - 1) : null,
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: sides < 20 ? () => controller.setPolygonSides(sides + 1) : null,
        ),
        const SizedBox(width: 8),
        // Feedback round: toggles the circumscribed/inscribed guide-circle
        // preview every real regular polygon's vertices/edge-midpoints
        // land on - see SketchController.showPolygonGuideCircles's own doc
        // comment.
        IconButton(
          icon: Icon(controller.showPolygonGuideCircles ? Icons.circle_outlined : Icons.circle),
          tooltip: controller.showPolygonGuideCircles ? 'Hide guide circles' : 'Show guide circles',
          onPressed: controller.togglePolygonGuideCircles,
        ),
      ],
    );
  }
}
