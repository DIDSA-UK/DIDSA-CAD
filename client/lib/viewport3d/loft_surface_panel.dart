import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for a Loft Surface -
/// mirrors [LoftPanel] exactly, minus the Boss/Cut segmented control,
/// target-body picking, and the `thickness` field (a Loft Surface never
/// thickens itself into a solid - see the backend `LoftSurfaceFeature`'s own
/// docstring; a user wanting a solid chains the Thicken tool afterward). The
/// ordered section-count summary and the `Ruled`/guide-curve controls remain
/// - LoftSurfaceFeature reuses the full backend `LoftSectionSchema` shape,
/// same as LoftFeature does.
///
/// Every value change is reported immediately via [onChanged] - debouncing
/// the resulting PATCH/POST and mesh refresh is [PartScreen]'s job, not this
/// widget's, same as [LoftPanel].
class LoftSurfacePanel extends StatefulWidget {
  /// 'Loft Surface' when creating a brand-new Feature (default), 'Edit Loft
  /// Surface' when [PartScreen] opened this to edit an already-existing one
  /// instead.
  final String title;

  final String? tooltip;

  final bool initialRuled;

  /// Mirrors [LoftPanel.sectionCount] exactly.
  final int sectionCount;

  /// Mirrors [LoftPanel.guideCurveSet]/[LoftPanel.pickingGuideCurve] exactly.
  final bool guideCurveSet;
  final bool pickingGuideCurve;

  final VoidCallback onPickGuideCurve;
  final VoidCallback onClearGuideCurve;
  final VoidCallback onCancelGuideCurvePick;

  final void Function(bool ruled) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const LoftSurfacePanel({
    super.key,
    this.title = 'Loft Surface',
    this.tooltip,
    this.initialRuled = false,
    required this.sectionCount,
    this.guideCurveSet = false,
    this.pickingGuideCurve = false,
    required this.onPickGuideCurve,
    required this.onClearGuideCurve,
    required this.onCancelGuideCurvePick,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<LoftSurfacePanel> createState() => _LoftSurfacePanelState();
}

class _LoftSurfacePanelState extends State<LoftSurfacePanel> {
  late bool _ruled;

  @override
  void initState() {
    super.initState();
    _ruled = widget.initialRuled;
    // Mirrors LoftPanel's identical fix - without this, the live preview
    // underneath this panel doesn't appear until the user actually edits the
    // Ruled toggle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_ruled);
    });
  }

  void _onRuledChanged(bool ruled) {
    setState(() => _ruled = ruled);
    widget.onChanged(ruled);
  }

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sections: ${widget.sectionCount}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Ruled'),
            subtitle: const Text('Straight-line transitions instead of a smooth blend'),
            value: _ruled,
            onChanged: _onRuledChanged,
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Guide curve (optional)'),
            subtitle: Text(
              widget.pickingGuideCurve
                  ? 'Tap a line, arc, ellipse or spline in the viewport…'
                  : (widget.guideCurveSet ? 'Set' : 'Not set'),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: widget.pickingGuideCurve
                  ? [
                      TextButton(
                        onPressed: widget.onCancelGuideCurvePick,
                        child: const Text('Cancel'),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: widget.onPickGuideCurve,
                        child: Text(widget.guideCurveSet ? 'Change' : 'Pick'),
                      ),
                      if (widget.guideCurveSet)
                        IconButton(
                          tooltip: 'Clear guide curve',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: widget.onClearGuideCurve,
                        ),
                    ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: widget.onConfirm,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
