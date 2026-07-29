import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'sketch_controller.dart';

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
                    child: Text(
                      count == 0
                          ? 'Select line/curve/edge to offset'
                          : count == 1
                              ? '1 entity picked - tap the tick to continue'
                              : '$count entities picked - tap the tick to continue',
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (count > 0)
                    IconButton(
                      onPressed: controller.finishOffsetChain,
                      tooltip: 'Finish picking',
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

  @override
  void dispose() {
    _text.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.controller.updateOffsetPreviewDistance(double.tryParse(value));
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
                child: Text(
                  widget.targetCount == 1 ? '1 entity picked' : '${widget.targetCount} entities picked',
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _text,
                  focusNode: _focusNode,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(isDense: true, hintText: 'Distance', suffixText: 'mm'),
                  onChanged: (value) {
                    _onChanged(value);
                    setState(() {});
                  },
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _cancel, icon: const Icon(Icons.close), tooltip: 'Cancel'),
              FilledButton(onPressed: canConfirm ? _confirm : null, child: const Text('Offset')),
            ],
          ),
        ),
      ),
    );
  }
}
