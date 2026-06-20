import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The contextual action panel for whatever is currently selected, or for
/// the idle canvas itself when nothing is selected - slides in from the
/// left edge whenever a bare tap on the canvas (see
/// [SketchController.handleCanvasTap]) results in a selection, or lands on
/// blank idle-canvas space. A separate concern from [SketchSpeedDial]
/// (which chooses what to draw, not what to act on) - kept as its own
/// widget rather than merged into it.
class SketchRibbon extends StatelessWidget {
  final SketchController controller;

  const SketchRibbon({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Only pinned to the top-left corner (not stretched edge-to-edge
        // via top:0/bottom:0) so the panel shrink-wraps to its own content
        // height instead of covering the full canvas height.
        return Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: AnimatedSlide(
              offset: controller.ribbonVisible ? Offset.zero : const Offset(-1.05, 0),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: SafeArea(
                bottom: false,
                child: Material(
                  elevation: 4,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                  child: SizedBox(
                    width: 220,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RibbonHeader(text: _headingFor(controller.selection), onClose: controller.closeRibbon),
                          ..._actionsFor(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _headingFor(SketchSelection? selection) {
    if (selection == null) return 'Sketch';
    return switch (selection.kind) {
      SelectionKind.point => 'Point selected',
      SelectionKind.line => 'Line selected',
      SelectionKind.circle => 'Circle selected',
    };
  }

  List<Widget> _actionsFor(BuildContext context) {
    final selection = controller.selection;
    if (selection == null) {
      return [
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Exit Sketch'),
          // No "outside a sketch" app state exists yet (that's the future
          // 3D navigation shell) - this is a placeholder until it does.
          subtitle: const Text('Not wired up yet'),
          onTap: () => _showExitPlaceholder(context),
        ),
      ];
    }

    final blockedReason =
        selection.kind == SelectionKind.point ? controller.selectedPointDeleteBlockedReason : null;

    return [
      ListTile(
        leading: const Icon(Icons.delete_outline),
        title: const Text('Delete'),
        subtitle: blockedReason == null ? null : Text(blockedReason),
        enabled: blockedReason == null && !controller.busy,
        onTap: controller.deleteSelected,
      ),
    ];
  }

  void _showExitPlaceholder(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Exit Sketch isn't wired up yet - no outside-sketch view exists.")),
    );
  }
}

/// The panel's top row: a bold heading plus an explicit close button - an
/// always-available way to dismiss the ribbon, alongside tapping blank
/// idle canvas space (see [SketchController.handleCanvasTap]).
class _RibbonHeader extends StatelessWidget {
  final String text;
  final VoidCallback onClose;

  const _RibbonHeader({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
