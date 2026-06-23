import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The contextual action panel for whatever is currently selected (one or
/// more entities, see [SketchController.selectionSet]), or for the idle
/// canvas itself when nothing is selected - slides in from the left edge
/// whenever a bare tap on the canvas (see
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
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RibbonHeader(text: _heading(), onClose: controller.closeRibbon),
                          _body(context),
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

  String _heading() {
    final selectionSet = controller.selectionSet;
    if (selectionSet.isEmpty) return 'Sketch';
    if (selectionSet.length > 1) return '${selectionSet.length} selected';
    return switch (selectionSet.first.kind) {
      SelectionKind.point => 'Point selected',
      SelectionKind.line => 'Line selected',
      SelectionKind.circle => 'Circle selected',
    };
  }

  Widget _body(BuildContext context) {
    final selectionSet = controller.selectionSet;
    if (selectionSet.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.logout),
        title: const Text('Exit Sketch'),
        // Same exit path as the back button (both just pop this route) -
        // PartScreen's _openSketch refreshes the 3D viewport once this
        // pop is observed there, regardless of which path triggered it.
        onTap: () => Navigator.of(context).pop(),
      );
    }

    final blockedReason =
        selectionSet.length == 1 && selectionSet.first.kind == SelectionKind.point
            ? controller.selectedPointDeleteBlockedReason
            : null;
    final isConstruction = controller.selectedIsConstruction;

    final chips = <Widget>[
      if (isConstruction != null)
        _RibbonActionChip(
          icon: isConstruction ? Icons.architecture : Icons.architecture_outlined,
          label: isConstruction ? 'Make Solid' : 'Make Construction',
          onTap: controller.busy ? null : controller.toggleSelectedConstruction,
        ),
      for (final option in controller.availableConstraintOptions)
        _RibbonActionChip(
          icon: _iconFor(option.type),
          label: option.label,
          onTap: option.wired && !controller.busy
              ? () => controller.applyConstraintOption(option.type)
              : null,
        ),
      _RibbonActionChip(
        icon: Icons.delete_outline,
        label: 'Delete',
        tooltip: blockedReason,
        onTap: blockedReason == null && !controller.busy ? controller.deleteSelected : null,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: chips),
      ),
    );
  }

  IconData _iconFor(ConstraintOptionType type) {
    return switch (type) {
      ConstraintOptionType.vertical => Icons.height,
      ConstraintOptionType.horizontal => Icons.swap_horiz,
      ConstraintOptionType.parallel => Icons.drag_handle,
      ConstraintOptionType.perpendicular => Icons.add,
      ConstraintOptionType.equalLength => Icons.straighten,
      ConstraintOptionType.coincident => Icons.join_full,
      ConstraintOptionType.concentric => Icons.adjust,
      ConstraintOptionType.equalRadius => Icons.radio_button_unchecked,
      ConstraintOptionType.tangent => Icons.circle,
    };
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

/// One action button in the flyout's horizontally-scrolling action row -
/// an icon over a small label, greyed out (and non-tappable) when [onTap]
/// is null, which is how unwired [ConstraintOption]s and blocked actions
/// (e.g. Delete on a still-referenced Point) render per Stage 13 item 6.
class _RibbonActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;

  const _RibbonActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? Colors.grey : null;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(icon: Icon(icon, color: color), onPressed: onTap),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
    if (tooltip == null) return column;
    return Tooltip(message: tooltip!, child: column);
  }
}
