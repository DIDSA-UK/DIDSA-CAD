import 'dart:async';

import 'package:flutter/material.dart';
import '../viewport3d/resizable_tool_panel.dart';
import 'sketch_controller.dart';
import '../viewport3d/keyboard_shortcuts.dart';

/// Offset's own picking-phase bar (on-device feedback: "the tick/FAB
/// confirm button should live in the flyup ribbon instead of a FAB, for
/// every tool") - shown while [SketchController.offsetPreviewTargets] is
/// still null, i.e. before picking is done. A Circle tap skips this bar
/// entirely (straight to [OffsetValueBar] below - a Circle has no chain
/// endpoints to join with another pick, see [SketchController.
/// _handleOffsetTap]'s own doc comment), so this bar's own Tick only ever
/// needs to confirm one or more accumulated Line/Arc picks via
/// [SketchController.finishOffsetChain].
class OffsetPickBar extends StatelessWidget {
  final SketchController controller;

  const OffsetPickBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final count = controller.selectionSet.length;
        return ResizableToolPanel(
          title: 'Offset Entities',
          tooltip: count == 0
              ? 'Select line/curve/edge to offset'
              : count == 1
                  ? '1 entity picked'
                  : '$count entities picked',
          defaultHeightFraction: 0.22,
          minHeightFraction: 0.15,
          maxHeightFraction: 0.6,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: controller.exitToSelectMode, child: const Text('Exit')),
              const SizedBox(width: 8),
              FilledButton(onPressed: count > 0 ? controller.finishOffsetChain : null, child: const Text('Continue')),
            ],
          ),
        );
      },
    );
  }
}

/// On-device feedback round 2 ("in the offset tool, a ghost preview should
/// be shown so the user knows which is positive and negative. the screen
/// layout will need to change so the user can actually see the preview"):
/// [SketchMode.offset]'s own bottom fly-up bar, mirroring
/// [SketchDimensionBar]'s exact "plain non-modal [Material] panel, not a
/// real `showModalBottomSheet`" shape - the whole point is that the 3D
/// viewport (and [SketchController.offsetPreviewGhosts]' live preview,
/// rendered on top of it) stays fully visible and interactive underneath,
/// unlike the modal `showDialog` this replaces (see `sketch_ribbon.dart`'s
/// `showOffsetDialogFor`'s own doc comment for what still uses that
/// instead).
///
/// Visible only once [SketchController.offsetPreviewTargets] is non-null -
/// i.e. once picking is actually done (a Circle tap, or [OffsetPickBar]'s
/// own Tick for one or more Line/Arc picks) - the picking phase itself is
/// [OffsetPickBar] above, not this bar.
class OffsetValueBar extends StatelessWidget {
  final SketchController controller;

  const OffsetValueBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final targets = controller.offsetPreviewTargets;
        if (targets == null) return const SizedBox.shrink();
        // Keyed by the target list's own identity: [SketchController]
        // always assigns a *fresh* List instance for every new offset
        // session (see its own `_offsetPreviewTargets` doc comment), so a
        // new key here forces Flutter to drop the previous session's
        // State (and its now-stale typed text) and mount a clean one,
        // rather than a stateful text field silently carrying over a
        // number typed for a previous, already-confirmed pick.
        return _OffsetValueBarContent(
          key: ValueKey(targets),
          controller: controller,
          targetCount: targets.length,
        );
      },
    );
  }
}

class _OffsetValueBarContent extends StatefulWidget {
  final SketchController controller;
  final int targetCount;

  const _OffsetValueBarContent({super.key, required this.controller, required this.targetCount});

  @override
  State<_OffsetValueBarContent> createState() => _OffsetValueBarContentState();
}

class _OffsetValueBarContentState extends State<_OffsetValueBarContent> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Flips the side the offset goes to: the typed distance is sent to the controller negated while this is set (a
  /// typed minus sign still works too, and combines with it).
  bool _reversed = false;

  @override
  void dispose() {
    _text.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _pushDistance() {
    final value = double.tryParse(_text.text);
    widget.controller.updateOffsetPreviewDistance(value == null ? null : (_reversed ? -value : value));
  }

  void _confirm() {
    if (double.tryParse(_text.text) == null) return;
    _focusNode.unfocus();
    // Same post-frame deferral [GhostValueEditor]'s own `_confirm` uses -
    // avoids unmounting a still-focused TextField within the same frame
    // as its own focus-change request (see that method's own doc comment
    // for the exact framework assertion this sidesteps).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.confirmOffsetPreview());
    });
  }

  void _cancel() {
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.cancelOffsetPreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = double.tryParse(_text.text) != null && double.tryParse(_text.text) != 0;
    return ResizableToolPanel(
      title: 'Offset Entities',
      tooltip: widget.targetCount == 1 ? '1 entity picked' : '${widget.targetCount} entities picked',
      defaultHeightFraction: 0.3,
      minHeightFraction: 0.2,
      maxHeightFraction: 0.6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focusNode,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(isDense: true, hintText: 'Distance', suffixText: 'mm'),
                  onChanged: (_) {
                    _pushDistance();
                    setState(() {});
                  },
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () {
                  setState(() => _reversed = !_reversed);
                  _pushDistance();
                },
                isSelected: _reversed,
                tooltip: 'Reverse direction',
                icon: const Icon(Icons.flip),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ToolPanelKeys(onConfirm: canConfirm ? _confirm : null, onCancel: _cancel),
              TextButton(onPressed: _cancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: canConfirm ? _confirm : null, child: const Text('Offset')),
            ],
          ),
        ],
      ),
    );
  }
}
