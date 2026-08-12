import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'svg_icon.dart';

/// The display name for the Feature at [index] in [features] - shared
/// between the tree's own rows and anything else (e.g. the cascade-delete
/// confirmation dialog) that needs to name a Feature the same way the tree
/// does, so the two never drift out of sync. Named per Feature type (e.g.
/// "Sketch 2", "Extrude 1", "Plane 1") rather than by overall position,
/// counting only same-type Features up to and including [index].
String featureDisplayName(List<FeatureDto> features, int index) {
  final feature = features[index];
  final label = switch (feature.type) {
    'extrude' => 'Extrude',
    'create_plane' => 'Plane',
    'fillet' => 'Fillet',
    'chamfer' => 'Chamfer',
    'revolve' => 'Revolve',
    'sweep' => 'Sweep',
    'loft' => 'Loft',
    'import' => 'Import',
    'mirror' => 'Mirror',
    'pattern' => 'Pattern',
    // Gear-tree UX: the gear-family Feature types (built straight from
    // parameters via their own dedicated design screen - GearDesignScreen/
    // BevelDesignScreen/GearChainDesignScreen - never through a Sketch, see
    // `00-conventions.md`'s "gear teeth are not Sketch entities" decision)
    // used to fall into the default arm below and show up mislabelled as a
    // generic "Sketch". Labels match the vocabulary each Feature type's own
    // design screen already uses for it (e.g. GearChainDesignScreen's
    // "Chain"/"Planetary" segmented-button labels), not a bare `feature.type`
    // dump, so a tapped tree row reads the same as the screen it reopens.
    'gear' => 'Gear',
    'rack' => 'Rack',
    'gear_chain' => 'Gear Chain',
    'planetary_gear' => 'Planetary Gear',
    'bevel_gear' => 'Bevel Gear',
    'bevel_pair' => 'Bevel Pair',
    _ => 'Sketch',
  };
  final ordinal = features.take(index + 1).where((f) => f.type == feature.type).length;
  return '$label $ordinal';
}

/// On-device feedback: whether a Feature of [type] has an actual edit panel
/// to open - an `ImportFeature` has none (a fixed, non-parametric Body
/// wrapping whatever file it imported, see the backend's own docstring for
/// why), so it was showing "Editable" in the tree despite tapping it doing
/// nothing editable at all. Every other type today does have a real edit
/// panel (see `PartScreen._onFeatureTap`'s own per-type dispatch, reachable
/// for any Feature since B4 - not just the last one) - this stays a plain
/// negative check rather than an allow-list so it doesn't need updating for
/// every future Feature type that keeps following that same pattern.
bool _hasEditPanel(String type) => type != 'import';

/// Maps a Feature's `type` string to its tree-row glyph. `'sketch'` and
/// `'create_plane'` reuse the same asset their own dedicated section already
/// shows (Sketches don't get their own section, but Planes do - both still
/// appear here too since Features lists every Feature unfiltered).
String _featureTypeAsset(String type) => switch (type) {
      'sketch' => 'assets/icons/feature/feature_new_sketch.svg',
      'extrude' => 'assets/icons/feature/feature_extrude.svg',
      'create_plane' => 'assets/icons/feature/feature_plane.svg',
      'fillet' => 'assets/icons/feature/feature_fillet.svg',
      'chamfer' => 'assets/icons/feature/feature_chamfer.svg',
      'revolve' => 'assets/icons/feature/feature_revolve.svg',
      'sweep' => 'assets/icons/feature/feature_sweep.svg',
      'loft' => 'assets/icons/feature/feature_loft.svg',
      'import' => 'assets/icons/feature/parttoolbar_import.svg',
      'mirror' => 'assets/icons/feature/feature_mirror.svg',
      'pattern' => 'assets/icons/feature/feature_pattern.svg',
      // Gear-tree UX: one shared "gear" category glyph for every gear-family
      // Feature type (spur/internal gear, rack, bevel gear, bevel pair, gear
      // chain, planetary set) - they're all built by the same family of
      // dedicated design screens and read as one recognizable category in the
      // tree, the same way `featureDisplayName` above still gives each its
      // own distinct text label.
      'gear' ||
      'rack' ||
      'gear_chain' ||
      'planetary_gear' ||
      'bevel_gear' ||
      'bevel_pair' =>
        'assets/icons/feature/feature_gear.svg',
      _ => 'assets/icons/feature/feature_new_sketch.svg',
    };

/// The "Build Tree": a Part's currently-computed Bodies (top, collapsible)
/// followed by its user-authored Features (Sketch/Extrude/etc, also
/// collapsible), in creation order. B3 revision, off on-device feedback:
/// Bodies are real produced objects (`bodyIds`/`bodyNames`), not Feature
/// rows - a single Feature that splits into multiple Bodies (A1's
/// multi-solid amendment) now genuinely shows as multiple Body entries
/// here, which the original B3 pass deliberately (and, per that feedback,
/// wrongly) avoided doing. Planes/Surfaces sections are meant to sit
/// alongside Bodies once Create Plane/Fillet (C/D/E) actually produce
/// something to list - no such data source exists yet, so there is nothing
/// to render for them today.
///
/// On-device feedback ("we now have the ability to edit parent features and
/// parametric flow is working - I think [the Locked badge] can be
/// removed"): every row, not just the last Feature, now shows its own
/// type glyph and "Editable"/"Imported" subtitle - since B4, tapping *any*
/// Feature (not just the last) opens it for editing, so a "Locked" badge
/// implying otherwise was actively misleading. [onFeatureTap] still decides
/// what a tap actually does; this tree is purely a display concern. A
/// long-press on any row invokes [onFeatureLongPress], which can lead to a
/// cascade-delete - that flow (via [showCascadeDeleteDialog]) is what now
/// warns the user, by naming every Feature involved, when deleting a
/// non-last Feature would also remove everything after it that depends on
/// it, rather than a permanent per-row badge doing that job less
/// specifically. Tapping a Body row calls [onBodyTap] instead - Bodies
/// aren't edited directly, only selected/highlighted (the same way tapping
/// one in the 3D viewport already does).
///
/// Hidden by default so the 3D viewport gets full space - slides in from
/// the left (same [AnimatedSlide] pattern as [SketchRibbon]) when
/// [visible], starting at 40% of the available width (never past
/// [_maxWidthFraction] or below [_minWidthFraction]) so the viewport stays
/// visible alongside it rather than being fully covered - a drag handle on
/// its trailing edge (see [_buildDragHandle]) lets the user widen it
/// themselves rather than being stuck at that default, which on-device
/// feedback found too narrow: row text was wrapping onto a second line
/// (e.g. "Extrude 1" breaking into "Extru" / "de 1") instead of eliding.
/// Has its own close button ([onClose]) rather than relying solely on the
/// toolbar toggle that opened it.
///
/// Bodies and Planes start collapsed ([_buildBodiesSection]/
/// [_buildPlanesSection]'s own `initiallyExpanded: false`) since they're
/// derived/read-only sections most sessions don't need open; Features
/// starts expanded ([_buildFeaturesSection]'s `initiallyExpanded: true`)
/// since it's the one section every edit/rollback/delete action actually
/// targets.
class FeatureTreePanel extends StatefulWidget {
  final bool visible;
  final List<FeatureDto> features;
  final String? selectedFeatureId;
  final void Function(FeatureDto feature) onFeatureTap;
  final void Function(FeatureDto feature) onFeatureLongPress;
  final VoidCallback onClose;

  /// The Part's currently-computed Body ids (from `GET /mesh`, `source:
  /// "computed"` entries only - the dev-time placeholder box is never a
  /// real Body and never appears here) - [PartScreen] already fetches
  /// these for the 3D viewport itself, so no separate network call is
  /// needed just to populate this section.
  final List<String> bodyIds;

  /// Stable "Body 1"/"Body 2"... display names for [bodyIds] - see
  /// `body_naming.dart`'s `bodyDisplayNames`, the same map
  /// [SelectionListDrawer] uses so a Body is called the same thing
  /// everywhere.
  final Map<String, String> bodyNames;

  /// Tapping a row in the Bodies section - selects/highlights that Body,
  /// mirroring what tapping it directly in the 3D viewport already does.
  final void Function(String bodyId) onBodyTap;

  /// On-device feedback: long-pressing a Bodies-section row toggles that
  /// Body's own Hide/Show state, same as long-pressing its owning Feature's
  /// row under Features already does - [PartScreen] resolves [bodyId] back
  /// to the Feature that produced it (`baseFeatureId`, `body_naming.dart`)
  /// itself, since Hide/Show is always Feature-scoped. `null` disables the
  /// long-press entirely (defensive default for any test/fixture built
  /// before this).
  final void Function(String bodyId)? onBodyLongPress;

  /// Feature ids hidden from the 3D viewport (see [PartScreen]'s Hide/Show
  /// context-menu action) - shown here as a dimmed row with an eye-slash
  /// icon, so hidden state is visible from the tree, not just invisible by
  /// its absence in the 3D view.
  final Set<String> hiddenFeatureIds;

  /// On-device feedback: Body ids the backend tagged `hidden` (see
  /// `app.document.router.get_part_mesh`'s own docstring) - unlike
  /// [hiddenFeatureIds] (Feature-scoped), Bodies-section rows are styled
  /// off this directly, since a `body_id` and the Feature id that produced
  /// it are related but distinct strings (`baseFeatureId` maps one to the
  /// other, but a hidden Body still needs to keep appearing here at all,
  /// which is the whole point of this on-device follow-up).
  final Set<String> hiddenBodyIds;

  /// Prompt D: true while the tree is acting as a Sketch picker for a
  /// pending Extrude (entered from the "Add" FAB's Feature > Extrude entry
  /// when no eligible Sketch is already selected) - shows the picker banner
  /// below and switches every row's tap from [onFeatureTap] to
  /// [onSketchPicked].
  final bool isSketchPickerMode;

  /// While [isSketchPickerMode], the ids of Sketch Features with a closed
  /// profile - the rest (including every non-Sketch Feature) render dimmed.
  /// Purely a visual aid: [onSketchPicked] re-validates the tapped Sketch
  /// itself, so a stale/in-flight value here never lets an ineligible
  /// Sketch through.
  final Set<String> pickableSketchIds;

  /// [isSketchPickerMode]'s tap handler - called for a Sketch Feature row
  /// tap instead of [onFeatureTap]. Unused (and may be left null) outside
  /// picker mode.
  final void Function(FeatureDto feature)? onSketchPicked;

  /// Pattern/Mirror scoping's Phase 6 (`docs/pattern-mirror-scope.md`
  /// §2.8/§4): true while the tree is acting as a *multi-select* Feature
  /// picker for a pending Mirror/Pattern's `source_feature_ids` - entered
  /// from a button inside [MirrorPanel]/[PatternPanel] itself (not the
  /// guided "Add" FAB), exited by a confirm/cancel action [PartScreen]
  /// itself owns (mirroring the checkmark-FAB shape Mirror's own
  /// `pickingBodies` step already uses, not a button embedded in this
  /// panel). Unlike [isSketchPickerMode] (single-pick, commits
  /// immediately), a row tap here toggles membership in
  /// [selectedFeaturePickerIds] and the picker stays open - this codebase
  /// had no existing multi-select entry point into the Build Tree at all
  /// before this (confirmed by reading this file in full - every prior
  /// mode here is single-pick), so this is new machinery, not a reuse.
  final bool isFeaturePickerMode;

  /// While [isFeaturePickerMode], the Feature ids eligible to be picked as
  /// a source (every body-producing Feature type except the Mirror/Pattern
  /// currently being configured itself) - the rest render dimmed and
  /// don't respond to a tap, mirroring [pickableSketchIds]'s own visual-aid
  /// role.
  final Set<String> pickableFeaturePickerIds;

  /// While [isFeaturePickerMode], the Feature ids currently toggled on -
  /// shown with a checkbox-style trailing indicator instead of the normal
  /// hidden/lost-reference one.
  final Set<String> selectedFeaturePickerIds;

  /// [isFeaturePickerMode]'s tap handler - called for an eligible
  /// ([pickableFeaturePickerIds]) Feature row tap instead of [onFeatureTap],
  /// toggling that Feature's membership in [selectedFeaturePickerIds].
  /// Unused (and may be left null) outside picker mode.
  final void Function(FeatureDto feature)? onFeaturePickerToggle;

  /// [isFeaturePickerMode]'s own inline banner text (before the running
  /// "N selected" suffix) - defaults to the original Pattern/Mirror
  /// source-feature-picker wording so that flow's own call site doesn't
  /// need updating; a Loft section picker (the only other caller of this
  /// mode) passes its own, since "source Features" would be a confusing
  /// label for picking ordered Loft sections.
  final String featurePickerLabel;

  const FeatureTreePanel({
    super.key,
    required this.visible,
    required this.features,
    required this.selectedFeatureId,
    required this.onFeatureTap,
    required this.onFeatureLongPress,
    required this.onClose,
    required this.onBodyTap,
    this.onBodyLongPress,
    this.bodyIds = const [],
    this.bodyNames = const {},
    this.hiddenFeatureIds = const {},
    this.hiddenBodyIds = const {},
    this.isSketchPickerMode = false,
    this.pickableSketchIds = const {},
    this.onSketchPicked,
    this.isFeaturePickerMode = false,
    this.pickableFeaturePickerIds = const {},
    this.selectedFeaturePickerIds = const {},
    this.onFeaturePickerToggle,
    this.featurePickerLabel = 'Select source Features',
  });

  @override
  State<FeatureTreePanel> createState() => _FeatureTreePanelState();
}

class _FeatureTreePanelState extends State<FeatureTreePanel> {
  static const double _defaultWidthFraction = 0.4;
  static const double _minWidthFraction = 0.28;
  static const double _maxWidthFraction = 0.75;

  /// Same non-wrapping, size-13 treatment for every row title (Body/Plane/
  /// Feature alike) - on-device feedback found the default `ListTile`/
  /// `ExpansionTile` text size wrapped mid-word at the panel's original
  /// default width (e.g. "Extrude 1" -> "Extru" / "de 1"); paired with the
  /// drag handle below (so a user who wants the full name can just widen
  /// the panel instead), an explicit `maxLines: 1` + ellipsis is the other
  /// half of the fix - wrapping is never acceptable here regardless of
  /// width, since a row is one line of tree structure, not a paragraph.
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
                                      'Build Tree',
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
                            // Prompt D: an inline banner (not a dialog) naming the
                            // picker mode the user is in - sits below the header so
                            // the close (X) button stays usable to cancel the
                            // pending Extrude.
                            if (widget.isSketchPickerMode)
                              Container(
                                width: double.infinity,
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: Text(
                                  'Select a sketch to extrude',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            // Pattern/Mirror Phase 6: names how many sources
                            // are currently toggled on, since (unlike the
                            // single-pick sketch banner above) there's no
                            // other on-screen indication of the running
                            // selection count while this panel is open.
                            if (widget.isFeaturePickerMode)
                              Container(
                                width: double.infinity,
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: Text(
                                  '${widget.featurePickerLabel}'
                                  '${widget.selectedFeaturePickerIds.isEmpty ? '' : ' - ${widget.selectedFeaturePickerIds.length} selected'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            Expanded(child: _buildGroupedTree(context)),
                          ],
                        ),
                      ),
                      Positioned(top: 0, bottom: 0, right: -7, child: _buildDragHandle(totalWidth)),
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

  /// The trailing-edge resize grip - a 14px-wide invisible hit target
  /// (comfortable for touch even though the visible grip inside it is
  /// slimmer) that adjusts [_widthFraction] by the same fraction of
  /// [totalWidth] the user's finger/pointer actually moved, clamped to
  /// [_minWidthFraction]/[_maxWidthFraction] so the panel can never be
  /// dragged down to unreadable or out past covering the whole viewport.
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
          width: 14,
          child: Center(
            child: Container(
              width: 4,
              height: 56,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// B3 revision: Bodies (real produced objects) at the top, Features
  /// (Sketch/Extrude/etc, the full unfiltered creation-order list) below -
  /// both collapsible, mirroring [PartToolbar]'s File/View/Selection-
  /// Filters [ExpansionTile] convention rather than inventing a new
  /// grouping widget. Neither section reorders anything - Bodies are
  /// ordered by `bodyDisplayNames` (Feature-creation order, then split
  /// index), and Features keep [FeatureTreePanel.features]' own creation/
  /// graph order exactly as before this prompt.
  Widget _buildGroupedTree(BuildContext context) {
    return ListView(
      children: [
        if (widget.bodyIds.isNotEmpty) _buildBodiesSection(context),
        if (widget.features.any((f) => f.type == 'create_plane')) _buildPlanesSection(context),
        _buildFeaturesSection(context),
      ],
    );
  }

  /// The Bodies section - omitted entirely when [FeatureTreePanel.bodyIds]
  /// is empty (e.g. a Part with no real geometry yet), rather than shown as
  /// an empty/error section. Row order follows [FeatureTreePanel.bodyNames]'
  /// own iteration order (a `LinkedHashMap`, so it preserves
  /// `bodyDisplayNames`' already-correct "Body 1", "Body 2", ... insertion
  /// order) rather than re-sorting [FeatureTreePanel.bodyIds] here by the
  /// display name *string* - "Body 10" would otherwise sort before "Body 2".
  /// Starts collapsed - a derived, read-only section most sessions don't
  /// need open by default.
  Widget _buildBodiesSection(BuildContext context) {
    final orderedIds = widget.bodyNames.keys.where(widget.bodyIds.contains).toList();
    return ExpansionTile(
      initiallyExpanded: false,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const SvgIcon('assets/icons/viewport/selection_body.svg', size: 26),
      title: const Text('Bodies', maxLines: 1, overflow: TextOverflow.ellipsis, style: _sectionTitleStyle),
      children: [for (final bodyId in orderedIds) _buildBodyTile(bodyId)],
    );
  }

  /// One Body's row inside the Bodies section. On-device feedback: a hidden
  /// Body keeps its row here (same dimmed-plus-eye-slash treatment a hidden
  /// Feature row already gets under Features) rather than disappearing, and
  /// a long press toggles it back - previously the only way to un-hide a
  /// Body was to remember which Feature produced it and find that row
  /// instead.
  Widget _buildBodyTile(String bodyId) {
    final hidden = widget.hiddenBodyIds.contains(bodyId);
    return Opacity(
      opacity: hidden ? 0.5 : 1.0,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const SvgIcon('assets/icons/viewport/selection_body.svg', size: 24),
        title: Text(
          widget.bodyNames[bodyId] ?? bodyId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _rowTitleStyle,
        ),
        trailing: hidden ? const Icon(Icons.visibility_off, size: 18) : null,
        onTap: () => widget.onBodyTap(bodyId),
        onLongPress: widget.onBodyLongPress == null ? null : () => widget.onBodyLongPress!(bodyId),
      ),
    );
  }

  /// C2: the Planes section - real produced Plane objects, one row per
  /// CreatePlaneFeature (always 1:1, unlike Bodies' potential Feature-to-
  /// multiple-Bodies split, so this needs no separate id/name map the way
  /// [_buildBodiesSection] does). Omitted entirely when there are none yet
  /// (see [_buildGroupedTree]'s own check), same "no empty section" rule
  /// [_buildBodiesSection] follows. Tapping a row reuses [FeatureTreePanel.
  /// onFeatureTap] - same B4 rollback/edit flow a Features-section row
  /// already opens for this same Feature, not a separate select-only action
  /// the way tapping a Body row is. Starts collapsed, same reasoning as
  /// [_buildBodiesSection].
  Widget _buildPlanesSection(BuildContext context) {
    final planeFeatures = widget.features.where((f) => f.type == 'create_plane').toList();
    return ExpansionTile(
      initiallyExpanded: false,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const SvgIcon('assets/icons/feature/feature_plane.svg', size: 26),
      title: const Text('Planes', maxLines: 1, overflow: TextOverflow.ellipsis, style: _sectionTitleStyle),
      children: [
        for (final feature in planeFeatures)
          Builder(builder: (context) {
            final hidden = widget.hiddenFeatureIds.contains(feature.id);
            return Opacity(
              opacity: hidden ? 0.5 : 1.0,
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const SvgIcon('assets/icons/feature/feature_plane.svg', size: 24),
                title: Text(
                  featureDisplayName(widget.features, widget.features.indexOf(feature)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _rowTitleStyle,
                ),
                trailing: hidden ? const Icon(Icons.visibility_off, size: 18) : null,
                onTap: () => widget.onFeatureTap(feature),
                // Bug fix: this row (a shortcut into the same Feature the
                // "Features" section below already lists) never wired
                // long-press at all - Hide/Show (and every other
                // FeatureContextMenuAction) was only reachable via that
                // other row, not from here, despite this looking like an
                // equally normal place to long-press for it.
                onLongPress: () => widget.onFeatureLongPress(feature),
              ),
            );
          }),
      ],
    );
  }

  /// The Features section - always shown (even if empty, which can only
  /// happen for a brand-new Part with nothing in it yet - an
  /// [ExpansionTile] with no children is a normal, sane empty state, not an
  /// error one). Starts expanded, unlike Bodies/Planes above - this is the
  /// section every edit/rollback/delete action targets.
  Widget _buildFeaturesSection(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const SvgIcon('assets/icons/feature/feature_tree.svg', size: 26),
      title: const Text('Features', maxLines: 1, overflow: TextOverflow.ellipsis, style: _sectionTitleStyle),
      children: [for (final feature in widget.features) _buildFeatureTile(context, feature)],
    );
  }

  /// One Feature's row inside the Features section - unchanged in
  /// behaviour from before B3's revision, just denser/non-wrapping text.
  Widget _buildFeatureTile(BuildContext context, FeatureDto feature) {
    final index = widget.features.indexWhere((f) => f.id == feature.id);
    final selected = feature.id == widget.selectedFeatureId;
    final hidden = widget.hiddenFeatureIds.contains(feature.id);
    final isSketch = feature.type == 'sketch';
    // Dimmed (but still tappable - an ineligible tap surfaces a SnackBar via
    // onSketchPicked rather than being inert) whenever picking and this row
    // isn't a Sketch with a known-closed profile.
    final pickerDimmed =
        widget.isSketchPickerMode && (!isSketch || !widget.pickableSketchIds.contains(feature.id));
    // Pattern/Mirror Phase 6: the analogous dim rule for the multi-select
    // Feature picker - unlike the sketch picker above, an ineligible row
    // here is fully inert (no tap callback at all, see onTap below), the
    // dimming alone communicates ineligibility.
    final featurePickerDimmed =
        widget.isFeaturePickerMode && !widget.pickableFeaturePickerIds.contains(feature.id);
    final featurePickerSelected =
        widget.isFeaturePickerMode && widget.selectedFeaturePickerIds.contains(feature.id);
    return Opacity(
      opacity: hidden || pickerDimmed || featurePickerDimmed ? 0.5 : 1.0,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected || featurePickerSelected,
        // Sketcher-roadmap Phase 4.3 v1: hasLostReference is its own,
        // independent overlay badge - kept alongside (not instead of) the
        // type glyph below.
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            SvgIcon(
              _featureTypeAsset(feature.type),
              size: 26,
              color: Theme.of(context).colorScheme.primary,
            ),
            if (feature.hasLostReference)
              Positioned(
                right: -2,
                bottom: -2,
                child: Icon(Icons.warning_rounded, size: 14, color: Colors.amber.shade800),
              ),
          ],
        ),
        title: Text(
          featureDisplayName(widget.features, index),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _rowTitleStyle,
        ),
        subtitle: Text(
          feature.hasLostReference
              ? 'Lost reference'
              : _hasEditPanel(feature.type)
                  ? 'Editable'
                  : 'Imported',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: feature.hasLostReference
              ? _rowSubtitleStyle.copyWith(color: Colors.amber.shade800, fontWeight: FontWeight.bold)
              : _rowSubtitleStyle,
        ),
        trailing: widget.isFeaturePickerMode
            ? (featurePickerSelected ? const Icon(Icons.check_circle, size: 18) : null)
            : (hidden ? const Icon(Icons.visibility_off, size: 18) : null),
        onTap: () {
          if (widget.isSketchPickerMode) {
            if (isSketch) widget.onSketchPicked?.call(feature);
          } else if (widget.isFeaturePickerMode) {
            if (!featurePickerDimmed) widget.onFeaturePickerToggle?.call(feature);
          } else {
            widget.onFeatureTap(feature);
          }
        },
        onLongPress: widget.isSketchPickerMode || widget.isFeaturePickerMode
            ? null
            : () => widget.onFeatureLongPress(feature),
      ),
    );
  }
}
