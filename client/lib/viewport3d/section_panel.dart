import 'package:flutter/material.dart';

import 'reference_planes.dart' show ReferencePlaneKind, ReferencePlaneKindX;
import 'resizable_tool_panel.dart';
import 'section_plane.dart';

/// Sectioning Tool's own tool panel - opened from [PartToolbar]'s "Section"
/// entry (not selection-gated, like Create Plane - see `part_toolbar.dart`).
/// Follows [MoveBodyPanel]/[CreatePlanePanel]'s established shape: a
/// [ResizableToolPanel] shell, `TextEditingController`+`onChanged` for the
/// one numeric field, and live-tap-driven placement (a face/plane tap while
/// this panel is open, no separate "arm the picker" step - mirrors
/// [MoveBodyPanel]'s own rotation-axis pick).
///
/// Unlike every other tool panel in this app, [sections]/[activeSectionId]
/// are plain [SectionPlane] view-state, not a Feature being created/edited -
/// see `section_plane.dart`'s own doc comment for why. `PartScreen` owns the
/// list; this panel is a fully controlled widget over it, the same
/// "controlled by the parent" convention `MoveBodyPanel.copy`/`hasRotationAxis`
/// already use for their own non-local state.
class SectionPanel extends StatefulWidget {
  final List<SectionPlane> sections;
  final String? activeSectionId;

  final VoidCallback onAddSection;
  final void Function(String id) onSelectSection;
  final void Function(String id) onRemoveSection;
  final void Function(String id, bool enabled) onToggleSection;
  final void Function(String id) onFlipSection;
  final void Function(ReferencePlaneKind plane) onQuickAnchor;

  /// Fired on every valid Offset edit for [activeSectionId]'s own plane -
  /// same live-preview-drives-a-debounced-fetch pattern
  /// [MoveBodyPanel.onDeltaChanged] already uses; see
  /// `docs/live-preview-pattern.md`.
  final void Function(String id, double offset)? onOffsetChanged;

  final VoidCallback onClose;

  const SectionPanel({
    super.key,
    required this.sections,
    required this.activeSectionId,
    required this.onAddSection,
    required this.onSelectSection,
    required this.onRemoveSection,
    required this.onToggleSection,
    required this.onFlipSection,
    required this.onQuickAnchor,
    this.onOffsetChanged,
    required this.onClose,
  });

  @override
  State<SectionPanel> createState() => _SectionPanelState();
}

class _SectionPanelState extends State<SectionPanel> {
  late final TextEditingController _offsetController;

  /// Which [SectionPlane.id] the offset controller's text currently reflects -
  /// [didUpdateWidget] resyncs the controller's text only when the active
  /// section *changes* (or its own offset moves for a reason other than this
  /// field's own edit, e.g. a gizmo drag) - never on every rebuild, which
  /// would otherwise fight the user's own in-progress typing (stomping the
  /// cursor position on every keystroke) the same bug class every other
  /// panel's own `initState`-only controller setup avoids by construction.
  String? _syncedSectionId;
  double? _syncedOffset;

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(3);

  SectionPlane? get _active {
    final id = widget.activeSectionId;
    if (id == null) return null;
    for (final section in widget.sections) {
      if (section.id == id) return section;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _offsetController = TextEditingController();
    _resyncOffsetControllerIfNeeded();
  }

  @override
  void didUpdateWidget(covariant SectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resyncOffsetControllerIfNeeded();
  }

  void _resyncOffsetControllerIfNeeded() {
    final active = _active;
    if (active == null) {
      _syncedSectionId = null;
      _syncedOffset = null;
      return;
    }
    // Bidirectional sync (per this tool's own brief: "dragging the gizmo
    // updates the field's displayed value; committing the field updates the
    // gizmo's rendered position") - resync whenever either the active
    // section itself changed, or its offset moved for a reason other than
    // this very field's own last edit (a gizmo drag, a quick-anchor button,
    // Flip).
    if (active.id != _syncedSectionId || active.offsetFromAnchor != _syncedOffset) {
      _syncedSectionId = active.id;
      _syncedOffset = active.offsetFromAnchor;
      _offsetController.text = _formatDistance(active.offsetFromAnchor);
    }
  }

  @override
  void dispose() {
    _offsetController.dispose();
    super.dispose();
  }

  void _emitOffsetChange() {
    final active = _active;
    if (active == null) return;
    final value = double.tryParse(_offsetController.text);
    if (value == null) return;
    _syncedOffset = value;
    widget.onOffsetChanged?.call(active.id, value);
  }

  Widget _quickAnchorButton(ReferencePlaneKind plane) => OutlinedButton(
        onPressed: widget.activeSectionId == null ? null : () => widget.onQuickAnchor(plane),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: colorFromReferencePlane(plane)),
          foregroundColor: colorFromReferencePlane(plane),
        ),
        child: Text(plane.apiValue),
      );

  Widget _sectionRow(SectionPlane section) {
    final selected = section.id == widget.activeSectionId;
    return Material(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onSelectSection(section.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Checkbox(
                value: section.enabled,
                onChanged: (value) => widget.onToggleSection(section.id, value ?? section.enabled),
              ),
              Expanded(
                child: Text(
                  '${section.flipped ? 'Flipped section' : 'Section'} '
                  '(offset ${_formatDistance(section.offsetFromAnchor)})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => widget.onRemoveSection(section.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return ResizableToolPanel(
      title: 'Section',
      tooltip: active == null
          ? 'Add a section, then tap a face or plane (or use XY/XZ/YZ) to place it'
          : 'Drag the triad, or tap a face/plane, to reposition the selected section',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: widget.onAddSection,
            icon: const Icon(Icons.add),
            label: const Text('Add Section'),
          ),
          const SizedBox(height: 8),
          if (widget.sections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No sections yet',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            )
          else
            ...widget.sections.map(_sectionRow),
          const SizedBox(height: 12),
          Text('Quick anchor', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _quickAnchorButton(ReferencePlaneKind.xy)),
              const SizedBox(width: 8),
              Expanded(child: _quickAnchorButton(ReferencePlaneKind.xz)),
              const SizedBox(width: 8),
              Expanded(child: _quickAnchorButton(ReferencePlaneKind.yz)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _offsetController,
                  enabled: active != null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Offset'),
                  onChanged: (_) => _emitOffsetChange(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: active == null ? null : () => widget.onFlipSection(active.id),
                icon: const Icon(Icons.swap_vert, size: 18),
                label: const Text('Flip'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(onPressed: widget.onClose, child: const Text('Done')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The exact same normal-axis color coding [ReferencePlaneKindX.tintColor]
/// already uses, as a plain [Color] for a plain Material `OutlinedButton` -
/// [ReferencePlaneKindX._baseColor] is private to `reference_planes.dart`,
/// so this is a small, deliberate duplication (this codebase's own
/// documented preference - see `section_gizmo.dart`'s helpers) rather than
/// widening that file's public surface for one extra caller.
Color colorFromReferencePlane(ReferencePlaneKind plane) => switch (plane) {
      ReferencePlaneKind.xy => const Color(0xFF3A7BD5),
      ReferencePlaneKind.xz => const Color(0xFF27AE60),
      ReferencePlaneKind.yz => const Color(0xFFE8364A),
    };
