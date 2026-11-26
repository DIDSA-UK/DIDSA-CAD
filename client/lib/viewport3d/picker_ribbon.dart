import 'package:material_ui/material_ui.dart';

import '../layout/layout_mode.dart';
import 'keyboard_shortcuts.dart';

/// C5: where the desktop layout's prompt card ends (0: no card), a notifier the screen owns.
class PromptCardBottom extends ValueNotifier<double> {
  PromptCardBottom() : super(0);

  bool _disposed = false;

  /// Sets the edge unless the screen that owns this is gone (a card's last report can come a frame after it).
  void report(double bottom) {
    if (!_disposed && (value - bottom).abs() > 0.5) value = bottom;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// C5: the card sits at the top left of the viewport and the flyout tree opens below it, so neither covers the other. The screen provides the
/// notifier; a [PickerRibbon] drawn as the card reports its bottom edge (its height plus the gap above it) and resets it to 0 when it goes.
/// Without a scope the ribbon reports nothing.
class PickerPromptCardScope extends InheritedWidget {
  const PickerPromptCardScope({super.key, required this.bottom, required super.child});

  /// The card's bottom edge, in the viewport's own coordinates; 0 while there is no card.
  final PromptCardBottom bottom;

  static PromptCardBottom? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PickerPromptCardScope>()?.bottom;

  @override
  bool updateShouldNotify(PickerPromptCardScope old) => !identical(bottom, old.bottom);
}

/// Reports its child's bottom edge to the [PickerPromptCardScope] after each layout, and 0 when it leaves the tree.
class _PromptCardReporter extends StatefulWidget {
  const _PromptCardReporter({required this.child});
  final Widget child;

  @override
  State<_PromptCardReporter> createState() => _PromptCardReporterState();
}

class _PromptCardReporterState extends State<_PromptCardReporter> {
  PromptCardBottom? _bottom;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = PickerPromptCardScope.maybeOf(context);
    if (!identical(next, _bottom)) {
      _bottom?.report(0);
      _bottom = next;
    }
  }

  @override
  void dispose() {
    final bottom = _bottom;
    // After this frame: a notifier's listener must not rebuild a tree that is being torn down.
    if (bottom != null) WidgetsBinding.instance.addPostFrameCallback((_) => bottom.report(0));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bottom = _bottom;
      if (!mounted || bottom == null) return;
      final size = context.size;
      if (size == null) return;
      // The card's own height and the 12 dp the ribbon leaves around it (the prompt card's padding).
      final value = size.height + 12;
      bottom.report(value);
    });
    return widget.child;
  }
}

/// [ResizableToolPanel]'s sibling for a pure viewport-picking mode that has
/// no fields/form of its own yet (picking a Sweep path, a Profile, a plane
/// for a new Sketch, or the seed Body/Bodies for Mirror/Pattern) - on-
/// device feedback ("check the other tools for the same problem"): these
/// used to show a full-width banner floating at `top: 8`, blocking the
/// same corner FABs [ResizableToolPanel]'s own doc comment describes for
/// every panel-backed tool. Same title-plus-divider-plus-tooltip header,
/// but fixed height and non-scrollable (there is no further content below
/// it to make scrolling meaningful) and no drag handle.
///
/// [showConfirm] is `false` for a mode that auto-advances the instant
/// something is tapped (Pattern's/plane-selection's own single-pick steps,
/// which have never had a separate confirm action) - the button is
/// omitted outright, not just disabled, since there is no confirm step to
/// even land on. When `true` (Sweep's path picker, the Profile picker,
/// Mirror's body picker), [onConfirm] being `null` renders it present but
/// disabled - the same "pass null to disable" convention every
/// `FloatingActionButton.onPressed` here already uses - rather than
/// hidden, so the button doesn't pop in/out of existence as the picked
/// count crosses zero.
///
/// Pattern/Mirror scoping's Phase 6 (on-device feedback: "on the flyup
/// ribbon, there should be an extra button that says 'select feature'"):
/// [extraActionLabel]/[onExtraAction] add one optional extra button to the
/// button row, for a picking mode that offers a second way to add to the
/// same in-progress selection (Pattern's own `pickingBodies` step - see
/// `PartScreen._startPatternPicker` - can be seeded from a Body tap in the
/// viewport *or* a Feature-tree pick via this button, opening the Build
/// Tree's own multi-select picker without leaving `pickingBodies`). `null`
/// (the default) omits it entirely, same "omitted, not just disabled"
/// convention [showConfirm] uses.
///
/// Bug fix (on-device feedback: "the select ribbon with tool tip shows
/// overflow error"): title, divider, tooltip, [extraActionLabel] and
/// Cancel/Confirm used to all share one `Row`, which overflowed on narrow
/// phone screens the moment [extraActionLabel] was non-null and the
/// tooltip text was of any real length. The title/divider/tooltip now sit
/// in their own row (matching [ResizableToolPanel]'s own title-row
/// convention, which wraps the tooltip in an `Expanded` on a row of its
/// own) and the buttons sit below in a right-aligned `Wrap` - mirrors
/// every panel's own Cancel/Confirm row shape (see e.g. `PatternPanel`'s
/// `mainAxisAlignment: MainAxisAlignment.end` row), but wraps to a second
/// line instead of overflowing on the narrowest phone widths, where
/// [extraActionLabel] plus Cancel plus Confirm together still don't fit
/// on one line.
class PickerRibbon extends StatelessWidget {
  final String title;
  final String tooltip;
  final VoidCallback onCancel;
  final bool showConfirm;
  final VoidCallback? onConfirm;
  final String? extraActionLabel;
  final VoidCallback? onExtraAction;

  /// More text buttons beside Cancel (label, icon, callback), after [extraActionLabel]'s: "Pick origin" offers Plane origin and Auto this way.
  final List<PickerRibbonAction> extraActions;

  const PickerRibbon({
    super.key,
    required this.title,
    required this.tooltip,
    required this.onCancel,
    this.showConfirm = false,
    this.onConfirm,
    this.extraActionLabel,
    this.onExtraAction,
    this.extraActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    // Desktop layout (D6): a prompt card at the top left of the viewport, beside the docked tree (a picker often
    // picks from the tree), instead of a ribbon across the bottom.
    final desktop = LayoutModeScope.isDesktop(context);
    return Align(
      alignment: desktop ? Alignment.topLeft : Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: desktop ? const EdgeInsets.all(12) : EdgeInsets.zero,
          child: SizedBox(
          width: desktop ? 360 : null,
          child: _PromptCardReporterIf(desktop: desktop, child: Material(
          elevation: 4,
          borderRadius: desktop
              ? BorderRadius.circular(12)
              : const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desktop)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(tooltip,
                          style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  )
                else
                Row(
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
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
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    if (extraActionLabel != null)
                      TextButton.icon(
                        onPressed: onExtraAction,
                        icon: const Icon(Icons.account_tree_outlined, size: 16),
                        label: Text(extraActionLabel!),
                      ),
                    for (final action in extraActions)
                      TextButton.icon(
                        key: action.key,
                        onPressed: action.onPressed,
                        icon: Icon(action.icon, size: 16),
                        label: Text(action.label),
                      ),
                    ToolPanelKeys(onConfirm: onConfirm, onCancel: onCancel),
                    TextButton(onPressed: onCancel, child: const Text('Cancel')),
                    if (showConfirm)
                      IconButton.filled(
                        tooltip: 'Confirm',
                        onPressed: onConfirm,
                        icon: const Icon(Icons.check),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        )),
        ),
      ),
    );
  }
}

/// [_PromptCardReporter] for the desktop prompt card; the phone's bottom ribbon is not one.
class _PromptCardReporterIf extends StatelessWidget {
  const _PromptCardReporterIf({required this.desktop, required this.child});
  final bool desktop;
  final Widget child;

  @override
  Widget build(BuildContext context) => desktop ? _PromptCardReporter(child: child) : child;
}

/// One extra text button on a [PickerRibbon] (see [PickerRibbon.extraActions]).
class PickerRibbonAction {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Key? key;

  const PickerRibbonAction({required this.label, required this.icon, required this.onPressed, this.key});
}
