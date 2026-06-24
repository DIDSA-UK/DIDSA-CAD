import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// Dimension mode's bottom fly-up bar (new work package): shows the
/// running list of entities picked so far (see
/// [SketchController.dimensionSelection]) plus an explicit Exit button -
/// makes clear which mode is active and what's been picked, the same way
/// [SketchConstructionMethodBar] does for draw mode's construction-method
/// choice. A plain non-modal [Material] panel, not a real
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
              child: Row(
                children: [
                  Expanded(
                    child: selection.isEmpty
                        ? const Text('Tap one or two entities to dimension')
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final entry in selection) _chip(entry),
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
      SelectionKind.constraint => 'Constraint',
    };
  }
}
