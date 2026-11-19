import 'package:material_ui/material_ui.dart';

import 'sketch_controller.dart';

/// Dimension mode's bottom fly-up bar (new work package): shows the
/// running list of entities picked so far (see
/// [SketchController.dimensionSelection]) plus an explicit Exit button -
/// makes clear which mode is active and what's been picked, the same way
/// [SketchConstructionMethodBar] does for draw mode's construction-method
/// choice. Part A of docs/bug-report-2026-11-18-plan.md added the option chips (the kinds of dimension that fit the pick). A plain non-modal [Material] panel, not a real
/// [showModalBottomSheet], for the same reason as that bar: a modal barrier
/// would block the canvas taps this very panel exists to accompany.
class SketchDimensionBar extends StatelessWidget {
  final SketchController controller;

  const SketchDimensionBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final selection = controller.dimensionSelection;
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
                children: [
                  // DIDSA-VR plan, phase 3: a reference dimension of what is picked (when the picks make one) and the ones the sketch already has, each removable.
                  if (controller.referenceDimensionKinds.isNotEmpty || controller.referenceDimensions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final kind in controller.referenceDimensionKinds)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ActionChip(
                                  key: ValueKey('reference-dimension-add-$kind'),
                                  avatar: const Icon(Icons.straighten, size: 16),
                                  label: Text('Reference ${kind.replaceAll('_', ' ')}'),
                                  onPressed: () => controller.addReferenceDimension(kind),
                                ),
                              ),
                            for (final dimension in controller.referenceDimensions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: InputChip(
                                  key: ValueKey('reference-dimension-${dimension.id}'),
                                  label: Text(controller.referenceDimensionLabelText(dimension.id)),
                                  onDeleted: () => controller.deleteReferenceDimension(dimension.id),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // Part A of docs/bug-report-2026-11-18-plan.md: the kinds of dimension that fit what is picked, the one being previewed at the
                  // cursor highlighted. A click picks the kind (it then stays); a click on the canvas drops it and opens its value.
                  if (controller.pendingDimensionOptions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final option in controller.pendingDimensionOptions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  key: ValueKey('dimension-option-${option.key}'),
                                  label: Text(option.displayLabel),
                                  selected: controller.pendingDimensionKey == option.key,
                                  onSelected: (_) => controller.selectPendingDimensionKind(option.key),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: selection.isEmpty
                            ? const Text('Tap one or two entities to dimension')
                            : SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final entry in selection) _chip(entry),
                                    if (controller.pendingDimensionGhost != null && controller.activeGhostKey == null)
                                      const Padding(
                                        padding: EdgeInsets.only(left: 4),
                                        child: Text('Move to place it, click to drop'),
                                      ),
                                  ],
                                ),
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chip(SketchSelection entry) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(label: Text(_labelFor(entry.kind))),
    );
  }

  String _labelFor(SelectionKind kind) {
    return switch (kind) {
      SelectionKind.point => 'Point',
      SelectionKind.line => 'Line',
      SelectionKind.circle => 'Circle',
      SelectionKind.arc => 'Arc',
      SelectionKind.ellipse => 'Ellipse',
      SelectionKind.ellipseArc => 'Ellipse Arc',
      SelectionKind.spline => 'Spline',
      SelectionKind.text => 'Text',
      SelectionKind.constraint => 'Constraint',
      // Never actually reachable - Dimension mode's own selection never
      // includes a Pattern/Mirror instance.
      SelectionKind.patternInstance => 'Pattern',
      SelectionKind.mirrorInstance => 'Mirror',
    };
  }
}
