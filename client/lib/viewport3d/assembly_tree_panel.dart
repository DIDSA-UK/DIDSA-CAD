import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// The display name for the Occurrence at [index] in [occurrences] - mirrors
/// `feature_tree_panel.dart`'s `featureDisplayName` (same "shared between the
/// tree's own rows and anywhere else that needs to name this the same way"
/// role), just for Components instead of Features. [OccurrenceDto.
/// nameOverride] wins when set (the user's own chosen name); otherwise falls
/// back to [externalRef]'s file basename (e.g. "parts/bolt.didsa" -> "bolt"),
/// since that's the most recognizable thing about an unresolved-or-unnamed
/// occurrence; failing both, "Component N" counting only occurrences seen so
/// far (not a stable id-based count), same ordinal convention
/// [featureDisplayName] itself uses.
String occurrenceDisplayName(List<OccurrenceDto> occurrences, int index) {
  final occurrence = occurrences[index];
  if (occurrence.nameOverride != null && occurrence.nameOverride!.isNotEmpty) {
    return occurrence.nameOverride!;
  }
  final ref = occurrence.externalRef;
  if (ref != null && ref.isNotEmpty) {
    final fileName = ref.split('/').last;
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }
  final ordinal = occurrences.take(index + 1).length;
  return 'Component $ordinal';
}

/// The display name for the Mate at [index] in [mates] - mirrors
/// [occurrenceDisplayName]/`featureDisplayName`'s "Type N" convention
/// (ordinal counts only same-type mates up to and including [index]), since a
/// [MateDto] has no user-chosen name field of its own (unlike
/// [OccurrenceDto.nameOverride]).
String mateDisplayName(List<MateDto> mates, int index) {
  final mate = mates[index];
  final label = switch (mate.type) {
    'coincident' => 'Coincident',
    'concentric' => 'Concentric',
    'parallel' => 'Parallel',
    'distance' => 'Distance',
    'angle' => 'Angle',
    _ => mate.type,
  };
  final ordinal = mates.take(index + 1).where((m) => m.type == mate.type).length;
  return '$label $ordinal';
}

/// Assembly support Phase 3: the side panel shown in Assembly lens, the
/// direct analog of [FeatureTreePanel] shown in Part lens - see
/// `docs/assembly-scope.md`'s "lens toggle" decision (the 3D viewport itself
/// never changes between lenses; only this side panel and the toolbar swap).
/// Deliberately simpler than [FeatureTreePanel]: no picker-mode machinery
/// (Sketch/Feature multi-select picking has no Assembly-lens equivalent yet -
/// those modes will be added, if needed, once Phase 5's gizmo/Phase 7's mate
/// authoring actually need an in-tree picker) and no Bodies/Planes/Surfaces
/// sections (those stay Part-lens-only, scoped to whichever Part is
/// currently focused - see Phase 6). Plain data + callbacks only, same
/// "reusable leaf widget" shape confirmed for [FeatureTreePanel] during
/// Phase 3 planning.
class AssemblyTreePanel extends StatefulWidget {
  final bool visible;
  final List<OccurrenceDto> occurrences;
  final List<MateDto> mates;
  final String? selectedOccurrenceId;
  final void Function(OccurrenceDto occurrence) onOccurrenceTap;
  final void Function(OccurrenceDto occurrence) onOccurrenceLongPress;
  final void Function(MateDto mate)? onMateTap;
  final void Function(MateDto mate)? onMateLongPress;
  final VoidCallback onClose;

  const AssemblyTreePanel({
    super.key,
    required this.visible,
    required this.occurrences,
    required this.mates,
    required this.selectedOccurrenceId,
    required this.onOccurrenceTap,
    required this.onOccurrenceLongPress,
    required this.onClose,
    this.onMateTap,
    this.onMateLongPress,
  });

  @override
  State<AssemblyTreePanel> createState() => _AssemblyTreePanelState();
}

class _AssemblyTreePanelState extends State<AssemblyTreePanel> {
  // Same width-fraction constants/behavior as `FeatureTreePanel` - a user who
  // has already learned to grab this panel's edge to resize it should find
  // the same affordance here, at the same default width.
  static const double _defaultWidthFraction = 0.4;
  static const double _minWidthFraction = 0.28;
  static const double _maxWidthFraction = 0.75;

  static const TextStyle _rowTitleStyle = TextStyle(fontSize: 13);
  static const TextStyle _rowSubtitleStyle = TextStyle(fontSize: 11);
  static const TextStyle _sectionTitleStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

  double _widthFraction = _defaultWidthFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final panelWidth = (_widthFraction * totalWidth).clamp(
          _minWidthFraction * totalWidth,
          _maxWidthFraction * totalWidth,
        );
        return Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: AnimatedSlide(
              offset: widget.visible ? Offset.zero : const Offset(-1.05, 0),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: SafeArea(
                child: SizedBox(
                  width: panelWidth,
                  height: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Material(
                        elevation: 2,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(12),
                          bottomRight: Radius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Assembly Tree',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Close',
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: widget.onClose,
                                  ),
                                ],
                              ),
                            ),
                            Expanded(child: _buildGroupedTree(context)),
                          ],
                        ),
                      ),
                      Positioned(top: 0, bottom: 0, right: -12, child: _buildDragHandle(totalWidth)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDragHandle(double totalWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) {
          if (totalWidth <= 0) return;
          setState(() {
            _widthFraction = (_widthFraction + details.delta.dx / totalWidth).clamp(
              _minWidthFraction,
              _maxWidthFraction,
            );
          });
        },
        child: SizedBox(
          width: 24,
          child: Center(
            child: Container(
              width: 6,
              height: 64,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Components above Mates, both starting expanded - unlike
  /// `FeatureTreePanel`'s Bodies/Planes/Surfaces (derived, read-only, most
  /// sessions don't need them open), both of these sections are exactly what
  /// Assembly-lens editing targets, so there's no "read-only, collapse by
  /// default" case here. Shows a plain empty-state message when there is
  /// nothing at all yet, rather than two empty section headers with no
  /// explanation - a fresh assembly file inserts nothing until the user
  /// actually adds a component (Phase 3's insert flow).
  Widget _buildGroupedTree(BuildContext context) {
    if (widget.occurrences.isEmpty && widget.mates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No components yet',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
      );
    }
    return ListView(
      children: [
        _buildComponentsSection(context),
        if (widget.mates.isNotEmpty) _buildMatesSection(context),
      ],
    );
  }

  Widget _buildComponentsSection(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.view_in_ar_outlined, size: 26),
      title: const Text('Components', maxLines: 1, overflow: TextOverflow.ellipsis, style: _sectionTitleStyle),
      children: [
        for (int i = 0; i < widget.occurrences.length; i++) _buildOccurrenceTile(context, i),
      ],
    );
  }

  Widget _buildOccurrenceTile(BuildContext context, int index) {
    final occurrence = widget.occurrences[index];
    final selected = occurrence.id == widget.selectedOccurrenceId;
    // Bug precedent from `FeatureTreePanel.hiddenFeatureIds`: an unresolved
    // occurrence (`resolvedPartId == null` - the referenced file couldn't be
    // found/read, see `AssemblyGraphComposer`) still needs to keep appearing
    // here, styled as a lost reference, rather than silently vanishing - the
    // same "still visible, clearly flagged" treatment
    // `FeatureDto.hasLostReference` already gets elsewhere in this codebase.
    final unresolved = occurrence.resolvedPartId == null;
    return Opacity(
      opacity: occurrence.hidden ? 0.5 : 1.0,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        leading: const Icon(Icons.view_in_ar_outlined, size: 24),
        title: Text(
          occurrenceDisplayName(widget.occurrences, index),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _rowTitleStyle,
        ),
        subtitle: unresolved
            ? Text(
                'Missing file',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _rowSubtitleStyle.merge(const TextStyle(color: Colors.red)),
              )
            : occurrence.suppressed
                ? const Text('Suppressed', maxLines: 1, overflow: TextOverflow.ellipsis, style: _rowSubtitleStyle)
                : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (unresolved) const Icon(Icons.link_off, size: 18, color: Colors.red),
            if (occurrence.hidden) const Icon(Icons.visibility_off, size: 18),
          ],
        ),
        onTap: () => widget.onOccurrenceTap(occurrence),
        onLongPress: () => widget.onOccurrenceLongPress(occurrence),
      ),
    );
  }

  Widget _buildMatesSection(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.link, size: 26),
      title: const Text('Mates', maxLines: 1, overflow: TextOverflow.ellipsis, style: _sectionTitleStyle),
      children: [
        for (int i = 0; i < widget.mates.length; i++) _buildMateTile(context, i),
      ],
    );
  }

  Widget _buildMateTile(BuildContext context, int index) {
    final mate = widget.mates[index];
    return Opacity(
      opacity: mate.suppressed ? 0.5 : 1.0,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.link, size: 24),
        title: Text(
          mateDisplayName(widget.mates, index),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _rowTitleStyle,
        ),
        trailing: mate.suppressed ? const Icon(Icons.visibility_off, size: 18) : null,
        onTap: widget.onMateTap == null ? null : () => widget.onMateTap!(mate),
        onLongPress: widget.onMateLongPress == null ? null : () => widget.onMateLongPress!(mate),
      ),
    );
  }
}
