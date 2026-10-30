import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One small button of the [StartButton]'s quick column.
class QuickColumnButton {
  const QuickColumnButton({
    required this.key,
    required this.tooltip,
    required this.child,
    required this.onPressed,
    this.selected = false,
    this.badge = false,
  });

  final Key key;
  final String tooltip;
  final Widget child;
  final VoidCallback onPressed;

  /// Drawn filled (a mode that is on).
  final bool selected;

  /// A small dot in the corner (something is hidden, say).
  final bool badge;
}

/// The phone layout's Start button (`docs/touch-viewport-ux-plan.md` section 5), one widget for the FAB and its quick column
/// so both sit in the Scaffold's floating-action-button slot and move together when a SnackBar lifts it.
///
/// A tap runs [onStart] (open the Start menu). A swipe up past 24 dp or a fling up, or a long press, opens the quick
/// column above it; while it is open the button shows an X and a tap on that (or a swipe down) closes it, never opening the
/// menu. A tap on a quick button runs it and closes the column. The drag recognizer sits on this button only, never on the
/// viewport, so orbit, pan and pinch are untouched.
///
/// Whether the column is open is the parent's ([columnOpen] / [onColumnOpenChanged]), so it can close it when a tool
/// opens or the Start menu does.
class StartButton extends StatefulWidget {
  const StartButton({
    super.key,
    required this.enabled,
    required this.menuOpen,
    required this.columnOpen,
    required this.onStart,
    required this.onColumnOpenChanged,
    required this.quickButtons,
    this.backgroundColor,
    this.foregroundColor,
    this.modeBadge,
    this.showSwipeHint = false,
    this.onColumnOpenedByUser,
  });

  /// False greys the button out (the screen is busy).
  final bool enabled;

  /// The Start menu is showing: the button draws an X, as it does while the column is open.
  final bool menuOpen;

  final bool columnOpen;
  final VoidCallback onStart;
  final ValueChanged<bool> onColumnOpenChanged;

  /// The quick buttons, nearest the Start button first (drawn bottom-up).
  final List<QuickColumnButton> quickButtons;

  final Color? backgroundColor;
  final Color? foregroundColor;

  /// A mode glyph drawn on the button's corner (Selection mode is on), so the mode stays readable while its own button is
  /// behind a swipe.
  final Widget? modeBadge;

  /// A small chevron above the button hinting that it swipes; the parent drops it after the column has been opened a few
  /// times.
  final bool showSwipeHint;

  /// Called when a gesture (not the parent) opened the column, so the parent can count the opens for [showSwipeHint].
  final VoidCallback? onColumnOpenedByUser;

  /// How far up a swipe has to travel, in dp.
  static const double swipeDistance = 24;

  /// How fast an upward fling has to be, in dp per second.
  static const double flingVelocity = 300;

  @override
  State<StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<StartButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: widget.columnOpen ? 1 : 0,
  );

  double _downY = 0;
  bool _dragHandled = false;

  @override
  void didUpdateWidget(StartButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.columnOpen != oldWidget.columnOpen) {
      if (widget.columnOpen) {
        unawaited(_controller.forward());
      } else {
        unawaited(_controller.reverse());
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openByGesture() {
    if (!widget.enabled || widget.columnOpen) return;
    unawaited(HapticFeedback.selectionClick());
    widget.onColumnOpenedByUser?.call();
    widget.onColumnOpenChanged(true);
  }

  void _onTap() {
    if (widget.columnOpen) {
      widget.onColumnOpenChanged(false);
    } else {
      widget.onStart();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showX = widget.menuOpen || widget.columnOpen;
    final button = GestureDetector(
      onVerticalDragDown: (details) {
        _downY = details.globalPosition.dy;
        _dragHandled = false;
      },
      onVerticalDragUpdate: (details) {
        if (_dragHandled) return;
        final travelled = details.globalPosition.dy - _downY;
        if (!widget.columnOpen && travelled < -StartButton.swipeDistance) {
          _dragHandled = true;
          _openByGesture();
        } else if (widget.columnOpen && travelled > StartButton.swipeDistance) {
          _dragHandled = true;
          widget.onColumnOpenChanged(false);
        }
      },
      onVerticalDragEnd: (details) {
        if (_dragHandled) return;
        final velocity = details.primaryVelocity ?? 0;
        if (!widget.columnOpen && velocity < -StartButton.flingVelocity) {
          _openByGesture();
        } else if (widget.columnOpen && velocity > StartButton.flingVelocity) {
          widget.onColumnOpenChanged(false);
        }
      },
      onLongPress: widget.enabled ? _openByGesture : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The Tooltip is a manual one: the default (long press) would take the long press this button opens the column
          // with, and win it.
          Tooltip(
            message: showX ? 'Close' : 'Start',
            triggerMode: TooltipTriggerMode.manual,
            child: FloatingActionButton(
              key: const ValueKey('start-fab'),
              heroTag: 'start-fab',
              onPressed: widget.enabled ? _onTap : null,
              backgroundColor: widget.backgroundColor,
              foregroundColor: widget.foregroundColor,
              child: Icon(showX ? Icons.close : Icons.apps),
            ),
          ),
          if (widget.modeBadge != null && !showX)
            Positioned(
              top: -2,
              right: -2,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('start-mode-badge'),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.surface, width: 1.5),
                  ),
                  child: IconTheme(
                    data: IconThemeData(color: theme.colorScheme.onPrimary, size: 12),
                    child: Center(child: widget.modeBadge),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final visible = _controller.value > 0;
        final count = widget.quickButtons.length;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (visible)
              IgnorePointer(
                ignoring: !widget.columnOpen,
                child: Column(
                  key: const ValueKey('quick-column'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Furthest from the thumb first (top), the nearest button last.
                    for (var i = count - 1; i >= 0; i--)
                      _QuickButton(
                        button: widget.quickButtons[i],
                        // Every quick button closes the column once it has run (plan section 5.3).
                        onRan: () => widget.onColumnOpenChanged(false),
                        // Staggered: the nearest button appears first.
                        animation: CurvedAnimation(
                          parent: _controller,
                          curve: Interval(count == 1 ? 0 : 0.5 * i / (count - 1), 0.5 + (count == 1 ? 0.5 : 0.5 * i / (count - 1))),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              )
            else if (widget.showSwipeHint && widget.enabled)
              Icon(
                Icons.keyboard_arrow_up,
                key: const ValueKey('start-swipe-hint'),
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            button,
          ],
        );
      },
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.button, required this.animation, required this.onRan});

  final QuickColumnButton button;
  final VoidCallback onRan;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: animation,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              FloatingActionButton.small(
                key: button.key,
                heroTag: button.key.toString(),
                tooltip: button.tooltip,
                backgroundColor: button.selected ? theme.colorScheme.primaryContainer : null,
                onPressed: () {
                  button.onPressed();
                  onRan();
                },
                child: button.child,
              ),
              if (button.badge)
                Positioned(
                  top: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('quick-badge'),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error,
                        shape: BoxShape.circle,
                        border: Border.all(color: theme.colorScheme.surface, width: 1.5),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
