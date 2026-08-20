import 'package:flutter/material.dart';

/// Shown while a create/save call is in flight for a shape that can
/// genuinely take a while to build server-side (helical/herringbone gears,
/// bevel gears/pairs) - deliberately generic (no gear-type-specific
/// wording) so the same string covers every screen with a slow-build case,
/// present or future, instead of each screen inventing its own phrasing.
const String kComplexShapeBuildHint = 'This is a complex shape - it can take longer to generate...';

/// A tappable "?" - every numeric field in [GearDesignScreen]'s form gets
/// one as its `InputDecoration.suffixIcon`, explaining what the field
/// means.
///
/// On-device feedback (a plain `Icon` wrapped in `Tooltip(triggerMode:
/// tap)` never actually showed anything - tapping it just focused the
/// surrounding `TextField`/opened the surrounding `DropdownButtonFormField`
/// instead, since the field's own tap-to-focus/tap-to-open gesture won the
/// arena over the bare `Tooltip`'s own): an `IconButton` is a real,
/// independently-hit-tested interactive widget the same way a decorated
/// field's own "clear text" suffix button already is, so wrapping the
/// actual tap handling in one (rather than relying on `Tooltip`'s own
/// automatic gesture detection) reliably wins that same arena. The
/// `Tooltip` itself uses `TooltipTriggerMode.manual` and is shown
/// explicitly via `ensureTooltipVisible()` from the button's `onPressed` -
/// confirmed on-device this actually pops the bubble, unlike the
/// `TooltipTriggerMode.tap` attempt.
class FieldHelpIcon extends StatefulWidget {
  final String helpText;

  const FieldHelpIcon(this.helpText, {super.key});

  @override
  State<FieldHelpIcon> createState() => _FieldHelpIconState();
}

class _FieldHelpIconState extends State<FieldHelpIcon> {
  final _tooltipKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      key: _tooltipKey,
      message: widget.helpText,
      triggerMode: TooltipTriggerMode.manual,
      child: IconButton(
        icon: const Icon(Icons.help_outline, size: 18),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: () => _tooltipKey.currentState?.ensureTooltipVisible(),
      ),
    );
  }
}

/// Convenience wrapper so call sites keep the previous function-call shape
/// (`fieldHelpIcon('...')`) rather than every one spelling out `FieldHelpIcon(...)`.
Widget fieldHelpIcon(String helpText) => FieldHelpIcon(helpText);
