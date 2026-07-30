import 'package:flutter/material.dart';

/// On-device feedback ("the tooltip at the top of the screen blocks the
/// FABs to recentre and to switch between select/orbit"): every tool's
/// bottom-sheet-style panel (Extrude, Revolve, Sweep, Fillet, Chamfer,
/// Mirror, Pattern) used to render its own fixed-height, non-scrollable
/// `Align > SafeArea > Material > Padding > Column` shell, while a
/// *separate* full-width banner floated at `top: 8` naming the current
/// picking step ("Select bodies to cut", "Select an Edge... for the
/// Axis", etc.) - that banner sat directly on top of the viewport's own
/// corner FABs (hamburger/feature-tree top-left, select-orbit/reset-view
/// top-right) on every tool, not just Extrude.
///
/// This factors out that shell into one shared, reusable widget (mirrors
/// [PatternPanel]'s own pull-to-resize/scrollable panel, the one tool that
/// had already been fixed this way - see its own former doc comment on
/// `_heightFraction`) so every tool's panel gets the same fix at once:
/// [tooltip], when non-null, renders to the right of [title] in the title
/// row itself (separated by a subtle vertical divider) instead of a
/// separate floating banner - the banner is simply deleted at each call
/// site, freeing the corner FABs. [child] is everything else the panel
/// used to put below its own title `Text` (fields, the Cancel/Confirm
/// row, etc.) - unchanged, just re-parented under this shared shell's own
/// scrollable, resizable body.
class ResizableToolPanel extends StatefulWidget {
  final String title;

  /// The picking-step banner text this tool used to show in a separate,
  /// full-width `Positioned(top: 8)` overlay - see this class's own doc
  /// comment. Null (once nothing further needs picking, e.g. a preview
  /// already exists) renders the title row exactly as before this fix,
  /// with no divider/second line.
  final String? tooltip;

  /// Everything below the title row - unchanged from what each panel used
  /// to put directly in its own `Column` after the title `Text`.
  final Widget child;

  final double defaultHeightFraction;
  final double minHeightFraction;
  final double maxHeightFraction;

  /// Exposed so [PatternPanel] (already using these exact keys before this
  /// refactor - see `pattern_panel_test.dart`) keeps them unchanged, rather
  /// than every existing resize test needing new key literals.
  final Key? dragHandleKey;
  final Key? resizableAreaKey;

  const ResizableToolPanel({
    super.key,
    required this.title,
    this.tooltip,
    required this.child,
    this.defaultHeightFraction = 0.5,
    this.minHeightFraction = 0.25,
    this.maxHeightFraction = 0.85,
    this.dragHandleKey,
    this.resizableAreaKey,
  });

  @override
  State<ResizableToolPanel> createState() => _ResizableToolPanelState();
}

class _ResizableToolPanelState extends State<ResizableToolPanel> {
  late double _heightFraction = widget.defaultHeightFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        final panelHeight = (_heightFraction * totalHeight).clamp(
          widget.minHeightFraction * totalHeight,
          widget.maxHeightFraction * totalHeight,
        );
        return Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            child: SizedBox(
              key: widget.resizableAreaKey,
              height: panelHeight,
              child: Material(
                elevation: 4,
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDragHandle(totalHeight),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildTitleRow(context),
                              const SizedBox(height: 12),
                              widget.child,
                            ],
                          ),
                        ),
                      ),
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

  Widget _buildTitleRow(BuildContext context) {
    final titleText = Text(widget.title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16));
    final tooltip = widget.tooltip;
    if (tooltip == null) return titleText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        titleText,
        const SizedBox(width: 12),
        SizedBox(
          height: 18,
          child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            tooltip,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// The top-edge resize grip - see [PatternPanel]'s former identical copy
  /// of this exact method (mirrors `FeatureTreePanel._buildDragHandle`'s
  /// own drag-to-resize convention): dragging up (negative `dy`) extends
  /// the panel, dragging down retracts it, clamped so it can never be
  /// dragged down to unusable or up past covering the whole viewport.
  Widget _buildDragHandle(double totalHeight) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        key: widget.dragHandleKey,
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) {
          if (totalHeight <= 0) return;
          setState(() {
            _heightFraction =
                (_heightFraction - details.delta.dy / totalHeight).clamp(
              widget.minHeightFraction,
              widget.maxHeightFraction,
            );
          });
        },
        child: SizedBox(
          height: 20,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 56,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
