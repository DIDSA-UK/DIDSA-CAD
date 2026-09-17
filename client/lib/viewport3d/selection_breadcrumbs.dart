import 'package:flutter/material.dart';

import 'selection_hit_test.dart';
import 'svg_icon.dart';

/// Phase 6b (`docs/assembly-scope.md` §3): one rung of a selection's own
/// containment chain - the user's own proposal was "face → body → feature →
/// part → assembly"; the "feature that created this face" tier is
/// deliberately absent here (per that same §3 item: "per-face OCCT history
/// attribution doesn't appear to exist anywhere in the backend today... scope
/// that tier separately once someone has actually checked what OCCT can
/// report" - not silently dropped, genuinely not built yet). The real chain
/// this app can support today is entity (face/edge/vertex) -> body ->
/// component (only present when the entity sits on a placed Occurrence,
/// Phase 6a's own `occurrenceId` attribution).
enum BreadcrumbTier { entity, body, component }

/// One tappable rung - [target] is the [SelectionEntityRef] tapping this
/// tier's own icon should select (see [breadcrumbTiersFor]), already fully
/// formed (no further hit-testing needed - every field a containment level
/// up or down needs is already present on the *original* entity that
/// produced this whole chain, since [SelectionEntityRef] carries `bodyId`/
/// `occurrenceId` regardless of `kind`).
@immutable
class BreadcrumbTierInfo {
  final BreadcrumbTier tier;
  final SelectionEntityRef target;
  final String label;

  const BreadcrumbTierInfo({required this.tier, required this.target, required this.label});

  @override
  bool operator ==(Object other) =>
      other is BreadcrumbTierInfo && other.tier == tier && other.target == target && other.label == label;

  @override
  int get hashCode => Object.hash(tier, target, label);
}

/// The subset of [SelectionEntityKind] a breadcrumb chain exists for at
/// all - a mesh sub-entity (vertex/edge/face), a whole Body, or a whole
/// Component. Every other kind (sketch entities, reference/created planes)
/// has no body/component containment concept in this app, so
/// [breadcrumbTiersFor] returns an empty list for them - "no breadcrumb bar
/// shown" is the correct, deliberate result, not a gap.
bool _hasBreadcrumbChain(SelectionEntityKind kind) =>
    kind == SelectionEntityKind.face ||
    kind == SelectionEntityKind.edge ||
    kind == SelectionEntityKind.vertex ||
    kind == SelectionEntityKind.body ||
    kind == SelectionEntityKind.component;

String _entityLabel(SelectionEntityKind kind) => switch (kind) {
      SelectionEntityKind.face => 'Face',
      SelectionEntityKind.edge => 'Edge',
      SelectionEntityKind.vertex => 'Vertex',
      _ => 'Entity',
    };

/// `entity`'s own containment chain, nearest-to-farthest (the entity itself
/// first, then its owning Body, then - only when `entity.occurrenceId` is
/// non-empty, i.e. it sits on a placed Occurrence rather than the root
/// Part's own geometry - the owning Component). Pure data transformation,
/// no hit-testing: every field each tier's own [SelectionEntityRef] needs
/// (`bodyId`/`occurrenceId`) is already present on `entity` itself,
/// regardless of its `kind` (`SelectionEntityRef`'s own "every field
/// carries meaning appropriate to `kind`, `occurrenceId` now populated for
/// every kind on placed-instance geometry since Phase 6a" convention).
///
/// A [SelectionEntityKind.component] entity has nowhere finer to name (it
/// *is* the coarsest tier already) and no separate Body to distinguish (an
/// Occurrence's own Body attribution isn't tracked at that granularity) -
/// its own chain is therefore just itself, one entry long. A
/// [SelectionEntityKind.body] entity's chain is itself, plus a component
/// tier when it has one.
List<BreadcrumbTierInfo> breadcrumbTiersFor(SelectionEntityRef entity) {
  if (!_hasBreadcrumbChain(entity.kind)) return const [];

  final tiers = <BreadcrumbTierInfo>[];
  if (entity.kind == SelectionEntityKind.component) {
    tiers.add(BreadcrumbTierInfo(tier: BreadcrumbTier.component, target: entity, label: 'Component'));
    return tiers;
  }

  if (entity.kind != SelectionEntityKind.body) {
    tiers.add(BreadcrumbTierInfo(tier: BreadcrumbTier.entity, target: entity, label: _entityLabel(entity.kind)));
  }
  final bodyRef = SelectionEntityRef(
    kind: SelectionEntityKind.body,
    bodyId: entity.bodyId,
    occurrenceId: entity.occurrenceId,
  );
  tiers.add(BreadcrumbTierInfo(tier: BreadcrumbTier.body, target: bodyRef, label: 'Body'));

  if (entity.occurrenceId.isNotEmpty) {
    final componentRef = SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: entity.occurrenceId);
    tiers.add(BreadcrumbTierInfo(tier: BreadcrumbTier.component, target: componentRef, label: 'Component'));
  }
  return tiers;
}

/// Phase 6b: a horizontal row of [breadcrumbTiersFor]'s own tappable icons -
/// the user's own proposal ("an unintrusive horizontal breadcrumb bar... as
/// tappable icons, each one retargeting the selection up a level"), reusing
/// `select_other_sheet.dart`'s own hover-preview/tap-commit interaction
/// *grammar* (a tap commits immediately; a hovered/held tier previews via
/// [onPreview]) per that Mate's own doc comment pointing at it as "the
/// closest existing precedent... reuse that interaction grammar rather than
/// inventing a new one").
///
/// Bug fix (on-device feedback: a standalone floating pill over the 3D
/// viewport obscured part of [SelectionListDrawer]'s own sheet no matter
/// where it sat): this used to render itself inside its own [Material] pill,
/// positioned as a floating overlay. It's now embedded directly inside
/// [SelectionContextPanel] instead (that panel already supplies its own
/// [Material]/padding), so this returns a bare [Row] - no card of its own,
/// no floating position to fight the drawer over.
///
/// Bug fix (on-device feedback, "reverse the order of the breadcrumbs,
/// parents on the left"): [breadcrumbTiersFor] itself still returns nearest-
/// to-farthest (entity, then Body, then Component - see its own doc
/// comment, unchanged since other callers/tests key off that exact order);
/// this widget reverses *only its own rendering* of that list, so the
/// coarsest (parent-most) tier paints left, the tapped entity itself right -
/// the conventional "ancestors first" breadcrumb reading order.
class SelectionBreadcrumbBar extends StatefulWidget {
  final SelectionEntityRef entity;
  final ValueChanged<SelectionEntityRef> onSelect;

  /// Fired with the tier under the pointer/finger while held, and `null`
  /// once released - lets the caller feed a live highlight into the 3D
  /// view the same way `PartViewport.highlightOverride` already does for
  /// `showSelectOtherSheet`. Optional - a caller with no live-highlight
  /// concept can simply omit it.
  final ValueChanged<SelectionEntityRef?>? onPreview;

  const SelectionBreadcrumbBar({super.key, required this.entity, required this.onSelect, this.onPreview});

  @override
  State<SelectionBreadcrumbBar> createState() => _SelectionBreadcrumbBarState();
}

class _SelectionBreadcrumbBarState extends State<SelectionBreadcrumbBar> {
  SelectionEntityRef? _previewed;

  void _setPreview(SelectionEntityRef? target) {
    if (_previewed == target) return;
    setState(() => _previewed = target);
    widget.onPreview?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final tiers = breadcrumbTiersFor(widget.entity);
    if (tiers.length < 2) {
      // A single-tier chain (a bare Component, or an entity/Body with
      // nothing coarser to climb to) has nothing to disambiguate - showing
      // one lone, unclickable-feeling icon would just be visual noise for
      // no real affordance.
      return const SizedBox.shrink();
    }
    final colorScheme = Theme.of(context).colorScheme;
    // Parents-on-the-left: reverse [tiers]' own nearest-to-farthest order
    // purely for display (see this class's own doc comment) - every index
    // below refers to this reversed list, not [breadcrumbTiersFor]'s
    // original one.
    final displayTiers = tiers.reversed.toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < displayTiers.length; i++) ...[
          if (i > 0) Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant),
          _BreadcrumbTierButton(
            tierInfo: displayTiers[i],
            previewed: _previewed == displayTiers[i].target,
            onTap: () => widget.onSelect(displayTiers[i].target),
            onPreviewStart: () => _setPreview(displayTiers[i].target),
            onPreviewEnd: () => _setPreview(null),
          ),
        ],
      ],
    );
  }
}

class _BreadcrumbTierButton extends StatelessWidget {
  final BreadcrumbTierInfo tierInfo;
  final bool previewed;
  final VoidCallback onTap;
  final VoidCallback onPreviewStart;
  final VoidCallback onPreviewEnd;

  const _BreadcrumbTierButton({
    required this.tierInfo,
    required this.previewed,
    required this.onTap,
    required this.onPreviewStart,
    required this.onPreviewEnd,
  });

  Widget _icon() => switch (tierInfo.tier) {
        BreadcrumbTier.entity => switch (tierInfo.target.kind) {
            SelectionEntityKind.face => const SvgIcon('assets/icons/viewport/selection_face.svg'),
            SelectionEntityKind.edge => const SvgIcon('assets/icons/viewport/selection_edge.svg'),
            SelectionEntityKind.vertex => const SvgIcon('assets/icons/viewport/selection_vertex.svg'),
            _ => const SizedBox.shrink(),
          },
        BreadcrumbTier.body => const SvgIcon('assets/icons/viewport/selection_body.svg'),
        BreadcrumbTier.component => const Icon(Icons.view_in_ar_outlined, size: 18),
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => onPreviewStart(),
      onExit: (_) => onPreviewEnd(),
      child: GestureDetector(
        onLongPressStart: (_) => onPreviewStart(),
        onLongPressEnd: (_) => onPreviewEnd(),
        onLongPressCancel: onPreviewEnd,
        onTap: onTap,
        child: Tooltip(
          message: tierInfo.label,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: previewed ? colorScheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(width: 20, height: 20, child: _icon()),
          ),
        ),
      ),
    );
  }
}
