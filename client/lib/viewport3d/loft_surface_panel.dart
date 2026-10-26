import 'package:flutter/material.dart';

import 'loft_guides.dart';
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

  /// Mirrors [LoftPanel.alignmentPointsSet] exactly.
  final List<bool> alignmentPointsSet;

  /// Mirror [LoftPanel.guideSegmentCounts]/[LoftPanel.draftGuideSegments]/[LoftPanel.pickingGuideCurve]/
  /// [LoftPanel.warnings] exactly.
  final List<int> guideSegmentCounts;
  final int draftGuideSegments;
  final bool pickingGuideCurve;
  final List<String> warnings;

  /// Mirrors [LoftPanel.pickingAlignmentPointIndex] exactly.
  final int? pickingAlignmentPointIndex;

  /// Mirrors [LoftPanel.onPickAlignmentPoint]/[LoftPanel.onClearAlignmentPoint]/
  /// [LoftPanel.onCancelAlignmentPointPick] exactly.
  final void Function(int sectionIndex) onPickAlignmentPoint;
  final void Function(int sectionIndex) onClearAlignmentPoint;
  final VoidCallback onCancelAlignmentPointPick;

  final VoidCallback onPickGuideCurve;
  final VoidCallback onFinishGuideCurve;
  final void Function(int guideIndex) onRemoveGuideCurve;
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
    this.alignmentPointsSet = const [],
    this.guideSegmentCounts = const [],
    this.draftGuideSegments = 0,
    this.pickingGuideCurve = false,
    this.warnings = const [],
    this.pickingAlignmentPointIndex,
    required this.onPickAlignmentPoint,
    required this.onClearAlignmentPoint,
    required this.onCancelAlignmentPointPick,
    required this.onPickGuideCurve,
    required this.onFinishGuideCurve,
    required this.onRemoveGuideCurve,
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
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: ValueKey('loft-guides-tile-${widget.guideSegmentCounts.isNotEmpty || widget.pickingGuideCurve}'),
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: widget.guideSegmentCounts.isNotEmpty || widget.pickingGuideCurve,
              title: Text(
                widget.guideSegmentCounts.isEmpty
                    ? 'Guide curves'
                    : 'Guide curves (${widget.guideSegmentCounts.length})',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                _ruled ? 'Ignored while Ruled is on' : 'Curves through every section that shape the surface',
                style: const TextStyle(fontSize: 11),
              ),
              childrenPadding: EdgeInsets.zero,
              children: [
                LoftGuidesSection(
                  guideSegmentCounts: widget.guideSegmentCounts,
                  picking: widget.pickingGuideCurve,
                  draftSegments: widget.draftGuideSegments,
                  onAddGuide: widget.onPickGuideCurve,
                  onFinishGuide: widget.onFinishGuideCurve,
                  onCancelGuide: widget.onCancelGuideCurvePick,
                  onRemoveGuide: widget.onRemoveGuideCurve,
                ),
              ],
            ),
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Alignment points (advanced)', style: TextStyle(fontSize: 13)),
              subtitle: const Text('Slide a section so its point meets the first section\'s', style: TextStyle(fontSize: 11)),
              childrenPadding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < widget.sectionCount; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('Section ${i + 1} alignment point'),
                    subtitle: Text(
                      widget.pickingAlignmentPointIndex == i
                          ? 'Tap a point in the viewport…'
                          : (i < widget.alignmentPointsSet.length && widget.alignmentPointsSet[i]
                              ? 'Set'
                              : 'Not set'),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: widget.pickingAlignmentPointIndex == i
                          ? [
                              TextButton(
                                onPressed: widget.onCancelAlignmentPointPick,
                                child: const Text('Cancel'),
                              ),
                            ]
                          : [
                              TextButton(
                                onPressed: widget.pickingAlignmentPointIndex == null
                                    ? () => widget.onPickAlignmentPoint(i)
                                    : null,
                                child: Text(
                                  i < widget.alignmentPointsSet.length && widget.alignmentPointsSet[i]
                                      ? 'Change'
                                      : 'Pick',
                                ),
                              ),
                              if (i < widget.alignmentPointsSet.length && widget.alignmentPointsSet[i])
                                IconButton(
                                  tooltip: 'Clear alignment point',
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () => widget.onClearAlignmentPoint(i),
                                ),
                            ],
                    ),
                  ),
              ],
            ),
          ),
          LoftWarnings(warnings: widget.warnings),
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
