import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The tool switcher: a single small FAB that expands into Line/Circle tool
/// selectors and the Click/Finish actions, replacing what used to be a
/// permanently-visible button row so the canvas gets that screen space
/// back. Collapsed by default; tapping the main FAB toggles the menu open
/// or closed (mirrors Flutter's standard expandable-FAB pattern). Once
/// open, tapping a mini action performs it without auto-closing the menu,
/// since Click in particular is meant to be tapped repeatedly.
class SketchSpeedDial extends StatefulWidget {
  final SketchController controller;

  const SketchSpeedDial({super.key, required this.controller});

  @override
  State<SketchSpeedDial> createState() => _SketchSpeedDialState();
}

class _SketchSpeedDialState extends State<SketchSpeedDial> with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      _open ? _animation.forward() : _animation.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        // Finish only ends a Line chain - a Circle's two-click creation is
        // self-terminating, so the action is irrelevant (and hidden) when
        // the Circle tool is active.
        final showFinish = controller.activeTool == SketchTool.line && controller.chainInProgress;

        final actions = <Widget>[
          if (showFinish)
            _SpeedDialAction(
              icon: Icons.check_circle_outline,
              label: 'Finish',
              onPressed: controller.finishChain,
            ),
          _SpeedDialAction(
            icon: Icons.circle_outlined,
            label: 'Circle',
            selected: controller.activeTool == SketchTool.circle,
            onPressed: () => controller.setTool(SketchTool.circle),
          ),
          _SpeedDialAction(
            icon: Icons.show_chart,
            label: 'Line',
            selected: controller.activeTool == SketchTool.line,
            onPressed: () => controller.setTool(SketchTool.line),
          ),
          _SpeedDialAction(
            icon: Icons.touch_app,
            label: 'Click',
            onPressed: controller.busy ? null : controller.click,
          ),
        ];

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final action in actions)
              SizeTransition(
                sizeFactor: _animation,
                axisAlignment: 1,
                child: FadeTransition(
                  opacity: _animation,
                  child: Padding(padding: const EdgeInsets.only(bottom: 8), child: action),
                ),
              ),
            FloatingActionButton(
              heroTag: null,
              onPressed: _toggle,
              child: AnimatedRotation(
                turns: _open ? 0.125 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(_open ? Icons.close : Icons.add),
              ),
            ),
          ],
        );
      },
    );
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
