import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// The "boss" or "cut" choice for a Sweep - Boss/Cut parity with
/// Extrude/Revolve (this feature's own resolved decision) - mirrors
/// `revolve_panel.dart`'s [RevolveMode] exactly, as its own separate enum
/// rather than a shared one, matching this codebase's "each Feature type
/// owns its own enum" convention.
enum SweepMode {
  boss,
  cut;

  String get apiValue => name;

  static SweepMode fromApiValue(String value) =>
      SweepMode.values.firstWhere((m) => m.apiValue == value, orElse: () => SweepMode.boss);
}

/// The bottom-sheet-style panel [PartScreen] opens for Sweep - structurally
/// mirrors [RevolvePanel]'s Boss/Cut toggle + target-body-count session shape,
/// substituting a read-only path summary line for the angle field: unlike
/// Revolve's axis (picked live while its panel is open), a Sweep's path is
/// picked once, before this panel ever opens (see [PartScreen]'s
/// path-picking flow) and never re-picked for the rest of the create/edit
/// session (create-time-only picking, same as [profileRefs] already is) - so
/// there is nothing about the path for this panel to let the user change.
///
/// Every value change is reported immediately via [onChanged] - debouncing
/// the resulting PATCH/POST and mesh refresh is [PartScreen]'s job, not this
/// widget's, same as [RevolvePanel].
class SweepPanel extends StatefulWidget {
  /// 'Sweep' when creating a brand-new Feature (default), 'Edit Sweep' when
  /// [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [RevolvePanel.title].
  final String title;

  final SweepMode initialMode;

  /// How many path segments were picked, and whether they form a closed
  /// (looping) path or an open one - both confirmed in scope, see
  /// `app.document.models.SweepFeature`'s own docstring. Purely
  /// informational (no field here changes it).
  final int pathSegmentCount;
  final bool pathIsClosed;

  /// How many target bodies are currently picked in the 3D viewport - same
  /// meaning and same live-read convention as [RevolvePanel.targetBodyCount].
  /// Drives Cut's "requires 1+" rule below.
  final int targetBodyCount;

  final void Function(SweepMode mode) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SweepPanel({
    super.key,
    this.title = 'Sweep',
    this.initialMode = SweepMode.boss,
    required this.pathSegmentCount,
    required this.pathIsClosed,
    required this.targetBodyCount,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<SweepPanel> createState() => _SweepPanelState();
}

class _SweepPanelState extends State<SweepPanel> {
  late SweepMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  /// Confirm is disabled for a Cut with nothing picked yet (mirrors
  /// [RevolvePanel]'s own rule) - Boss has no target-body requirement, 0
  /// selected is exactly how a Boss starts a brand-new Body. The path is
  /// always already valid by the time this panel is showing (the
  /// path-picking flow that preceded it only ever hands over a confirmed,
  /// resolvable path - see [PartScreen]'s own path-picking state), so there
  /// is no path-validity condition to gate on here.
  bool get _canConfirm => !(_mode == SweepMode.cut && widget.targetBodyCount == 0);

  void _onModeChanged(SweepMode mode) {
    setState(() => _mode = mode);
    widget.onChanged(mode);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 4,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                SegmentedButton<SweepMode>(
                  segments: const [
                    ButtonSegment(
                      value: SweepMode.boss,
                      label: Text('Boss'),
                      icon: SvgIcon('assets/icons/feature/feature_boss.svg'),
                    ),
                    ButtonSegment(
                      value: SweepMode.cut,
                      label: Text('Cut'),
                      icon: SvgIcon('assets/icons/feature/feature_cut.svg'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) => _onModeChanged(selection.first),
                ),
                const SizedBox(height: 12),
                Text(
                  'Path: ${widget.pathSegmentCount} segment'
                  '${widget.pathSegmentCount == 1 ? '' : 's'}, '
                  '${widget.pathIsClosed ? 'closed' : 'open'}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                // Mirrors RevolvePanel's own Cut target-body status line -
                // picking itself happens in the 3D viewport behind this
                // panel, driven by PartScreen, not by any field in here.
                if (_mode == SweepMode.cut)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      widget.targetBodyCount == 0
                          ? 'Select at least one target body in the viewport'
                          : '${widget.targetBodyCount} target body/bodies selected',
                      style: TextStyle(
                        color: widget.targetBodyCount == 0
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _canConfirm ? widget.onConfirm : null,
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
