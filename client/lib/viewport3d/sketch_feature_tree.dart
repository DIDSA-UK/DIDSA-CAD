import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';

import '../api/document_api_client.dart';
import '../assembly/assembly_tree_model.dart';
import 'assembly_tree_helpers.dart' show assemblyTreeDefaultWidthFraction;
import 'assembly_tree_view.dart';
import 'feature_tree_helpers.dart';

/// The Part's tree as the sketcher shows it (P3 of `docs/assembly-tree-overhaul-scope.md`): the one tree ([AssemblyTreeView]) over a copy of
/// the Part screen's tree and live part, read-mostly. Every row of the live part is locked with [lockedReason] (a tap says why in the banner,
/// a hover shows it), the sketch being edited is the selected row, and the Hide / Show eyes work ([onToggleVisibility]). In Convert Entities
/// ([TreeConvertPickScope] above this widget) the sketches earlier than the one being edited are pickable and tick when staged; the later ones
/// stay locked with their own reason.
///
/// The copy is this widget's own model: its open rows start as the Part screen's and are not stored, and its picker never reaches the Part
/// screen's tree.
class SketchFeatureTree extends StatefulWidget {
  const SketchFeatureTree({
    super.key,
    required this.tree,
    required this.livePart,
    required this.sketchFeatureId,
    required this.onClose,
    this.openKeys = const [],
    this.fetchedFrom,
    this.grouping = true,
    this.lockedReason = 'Exit the sketch first',
    this.onToggleVisibility,
    this.onFeaturesRequested,
    this.docked = false,
  });

  /// The Part screen's tree (a part opened alone: just its root).
  final AssemblyTreeResponseDto tree;

  /// The part being edited, live (spec section 13). Null lists the tree without it (its features are on their way).
  final AssemblyLivePart? livePart;

  /// The Feature id of the sketch being edited: its row is selected and has no eye.
  final String sketchFeatureId;
  final VoidCallback onClose;

  /// The Part screen's open rows when the tree was built; later changes on either side stay on that side. With [fetchedFrom] they are that
  /// model's keys, and are used only while its tree has [tree]'s root.
  final Iterable<String> openKeys;

  /// The Part screen's tree model: what it fetched (other parts' features, the Mates and Patterns rows, rows hidden for this session) is
  /// copied in, so those rows read as they do there. This tree fetches nothing itself. Only while that model's tree has [tree]'s root: its
  /// keys name rows from its own root, so on a seed rooted at another Part (the focused Part on its own while the Part screen's tree has no
  /// live row for it) they would put that root's features, hidden rows and open rows on the wrong Part. Then nothing is copied.
  final AssemblyTreeModel? fetchedFrom;
  final bool grouping;
  final String lockedReason;

  /// Hide / Show of a live row (a feature, a body, surface or curve, a default plane). Null leaves the eyes out.
  final void Function(AssemblyTreeRow row)? onToggleVisibility;

  /// A part row (or the root) was opened and its features are not in this tree: the Part screen reads them into [fetchedFrom] and this tree
  /// takes them from there (B3). Returns whether they were read; when not, the row asks again the next time it is opened. Asked only while
  /// [fetchedFrom] has this tree's root (its paths name the same rows then). Null leaves such a row without its features.
  final Future<bool> Function(List<String> path)? onFeaturesRequested;

  /// The desktop left pane (it fills it); otherwise the tree floats over the viewport with a resize handle on its right edge.
  final bool docked;

  @override
  State<SketchFeatureTree> createState() => _SketchFeatureTreeState();
}

class _SketchFeatureTreeState extends State<SketchFeatureTree> {
  late AssemblyTreeModel _model;
  final AssemblyTreeController _controller = AssemblyTreeController();
  String? _pickerSignature;

  /// The overlay's width as a fraction of the space it floats in, once the handle was dragged (null: the default width).
  double? _widthFraction;

  /// Whether [SketchFeatureTree.openKeys] were applied: not while the source had another root. B4 (P3's review): when the Part screen's tree
  /// only later gets this tree's root, its open rows are applied then (once; later changes on either side stay on that side).
  bool _sourceKeysApplied = false;

  @override
  void initState() {
    super.initState();
    _model = _newModel(_startKeys());
    // The sketch being edited may sit under closed rows (a part deep in an assembly): open the way to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.expandToSelection();
    });
  }

  /// [SketchFeatureTree.fetchedFrom] while its tree has this tree's root, else null.
  AssemblyTreeModel? get _source {
    final source = widget.fetchedFrom;
    return source != null && source.tree?.partId == widget.tree.partId ? source : null;
  }

  /// The open rows a new model starts with: [SketchFeatureTree.openKeys], unless they are the keys of a tree with another root.
  Iterable<String> _startKeys() {
    final usable = widget.fetchedFrom == null || _source != null;
    _sourceKeysApplied = usable;
    return usable ? widget.openKeys : const <String>[];
  }

  /// B4 (P3's review): the rows the person opened in this tree, carried to a tree with another root. Only the live part's own rows (its
  /// folders, the components under it) name the same rows there, under the live row's new key; the rest are dropped.
  static List<String> _carriedKeys(Iterable<String> open, String? oldLive, String? newLive) {
    if (oldLive == null || newLive == null) return const [];
    String? under(String key) {
      if (oldLive.isEmpty) return key.isEmpty ? newLive : (newLive.isEmpty || key.startsWith('#') ? '$newLive$key' : '$newLive/$key');
      if (key == oldLive) return newLive;
      for (final sep in const ['/', '#']) {
        if (key.startsWith('$oldLive$sep')) {
          final rest = key.substring(oldLive.length + 1);
          return newLive.isEmpty ? (sep == '#' ? '#$rest' : rest) : '$newLive$sep$rest';
        }
      }
      return null;
    }
    return [for (final k in open) under(k)].whereType<String>().toList();
  }

  AssemblyTreeModel _newModel(Iterable<String> openKeys) {
    final model = AssemblyTreeModel(tree: widget.tree, grouping: widget.grouping);
    model.openAll(openKeys, remember: false);
    final source = _source;
    if (source != null) {
      model.copyFetchedFrom(source);
    } else {
      // Which Parts are unsaved does not depend on the root: both trees mark the same Parts.
      model.setUnsavedPartIds(widget.fetchedFrom?.unsavedPartIds ?? const <String>[]);
    }
    model.setLivePart(widget.livePart);
    model.selectedKey = model.liveFeatureKey(widget.sketchFeatureId);
    _pickerSignature = null;
    return model;
  }

  @override
  void didUpdateWidget(SketchFeatureTree old) {
    super.didUpdateWidget(old);
    if (!identical(old.tree, widget.tree)) {
      if (old.tree.partId == widget.tree.partId) {
        _model.merge(widget.tree);
      } else {
        // Another root (the Part screen's tree arrived for the document, where a seed for the part was): start again from that tree's open
        // rows (the seed's keys name rows of another root), plus the rows opened here under the live part, under its new key.
        final carried = _carriedKeys(_model.openKeys, old.livePart?.key, widget.livePart?.key);
        _model = _newModel(_startKeys());
        _model.openAll(carried, remember: false);
      }
    } else if (!_sourceKeysApplied && _source != null) {
      // The Part screen's tree has this tree's root now (it had another when this tree started): its open rows apply from here on.
      _sourceKeysApplied = true;
      _model.openAll(widget.openKeys, remember: false);
    }
    // The sketch's row moved (another root, or the live row is another row of it): open the way to it again, as when the tree opened.
    if (old.tree.partId != widget.tree.partId || old.livePart?.key != widget.livePart?.key) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.expandToSelection();
      });
    }
    final source = _source;
    if (source != null) {
      _model.copyFetchedFrom(source);
    } else {
      _model.setUnsavedPartIds(widget.fetchedFrom?.unsavedPartIds ?? const <String>[]);
    }
    if (!identical(old.livePart, widget.livePart)) _model.setLivePart(widget.livePart);
    if (old.grouping != widget.grouping) _model.grouping = widget.grouping;
    _model.selectedKey = _model.liveFeatureKey(widget.sketchFeatureId);
  }

  /// The view asked for a row's features: the Part screen fetches them (this tree fetches nothing itself), and a request that could not be
  /// made or failed is forgotten so opening the row asks again, as the Part screen's own tree does.
  void _onFeaturesRequested(List<String> path) {
    final ask = widget.onFeaturesRequested;
    if (ask == null || _source == null) {
      _controller.forgetFeaturesRequest(path);
      return;
    }
    unawaited(ask(path).then((loaded) {
      if (!loaded && mounted) _controller.forgetFeaturesRequest(path);
    }));
  }

  /// The picker the rows follow: the lock, or Convert Entities' picks (spec section 13's convert pick).
  void _syncPicker(TreeConvertPick? convert) {
    String sorted(Iterable<String> ids) => (ids.toList()..sort()).join(',');
    final signature = convert == null
        ? 'lock'
        : 'convert|${sorted(convert.pickable)}|${sorted(convert.picked)}|${sorted(convert.later)}|${convert.laterReason}';
    if (signature == _pickerSignature) return; // the same picker object keeps the view's note of the last locked row tapped
    _pickerSignature = signature;
    _model.setPicker(convert == null
        ? AssemblyPicker.locked(widget.lockedReason)
        : AssemblyPicker.convert(
            pickableSketchIds: convert.pickable,
            pickedSketchIds: convert.picked.where(convert.pickable.contains),
            laterSketchIds: convert.later,
            laterReason: convert.laterReason,
            lockedReason: widget.lockedReason,
            banner: 'Tap an earlier sketch to convert',
          ));
  }

  void _onPick(AssemblyTreeRow row, TreeConvertPick? convert) {
    final id = row.featureId;
    if (convert == null || id == null || !convert.pickable.contains(id)) return;
    convert.onPick(id);
  }

  @override
  Widget build(BuildContext context) {
    final convert = TreeConvertPickScope.maybeOf(context);
    _syncPicker(convert);
    final toggle = widget.onToggleVisibility;
    Widget view(double width) => AssemblyTreeView(
          model: _model,
          controller: _controller,
          docked: widget.docked,
          width: width,
          title: 'Build Tree',
          onClose: widget.onClose,
          onFeaturesRequested: _onFeaturesRequested,
          onRowPick: (row) => _onPick(row, convert),
          onVisibilityToggle: toggle == null
              ? null
              : (row) {
                  if (row.live) toggle(row);
                },
          lockedEyes: true,
        );
    if (widget.docked) return view(320);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fraction = _widthFraction ?? assemblyTreeDefaultWidthFraction(MediaQuery.sizeOf(context));
        final width = fraction * constraints.maxWidth;
        return Align(
          alignment: Alignment.topLeft,
          child: SafeArea(
            // 12 px wider than the tree, so the handle's right half is inside the Stack and takes pointers.
            child: Stack(
              children: [
                Padding(padding: const EdgeInsets.only(right: 12), child: view(width)),
                Positioned(top: 0, bottom: 0, left: width - 12, child: _resizeHandle(constraints.maxWidth)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The resize handle the Part screen's floating tree has: 28% to 75% of the width.
  Widget _resizeHandle(double totalWidth) => MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          key: const ValueKey('sketch-tree-resize-handle'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            if (totalWidth <= 0) return;
            final current = _widthFraction ?? assemblyTreeDefaultWidthFraction(MediaQuery.sizeOf(context));
            setState(() => _widthFraction = (current + details.delta.dx / totalWidth).clamp(0.28, 0.75));
          },
          child: SizedBox(
            width: 24,
            child: Center(
              child: Container(
                width: 6,
                height: 64,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.outlineVariant, borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ),
        ),
      );
}
