import 'dart:math' as math;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../ai/ai_theme.dart' show AiPalette;
import '../api/document_api_client.dart';
import '../assembly/assembly_tree_model.dart';
import '../layout/layout_mode.dart';
import 'action_sheet.dart' show MouseContextMenuRegion;
import 'edit_alone_row.dart';

/// Row height (A3, `docs/assembly-tree-overhaul-scope.md` 9.6): fixed, so the list can scroll to any row without building the ones in between.
const double kAssemblyTreeRowHeightDesktop = 30;
const double kAssemblyTreeRowHeightPhone = 48;

/// Scrolls an [AssemblyTreeView] to a row. Create one, pass it to the view, call [reveal] (for example when a 3D pick selects a part).
/// [refresh] repaints the view after the host changed the model by hand (`setFeatures`, `merge`, `setUnsavedPartIds`...).
class AssemblyTreeController {
  _AssemblyTreeViewState? _state;
  List<String>? _pendingPath;
  bool _pendingSelect = false;

  /// Opens every ancestor (and the group row, with grouping on) of the occurrence at [path], then scrolls its row into view. With
  /// [select] the row is also marked selected (the model's `selectedKey`). A path the tree does not know does nothing. Called before the view
  /// is built, it is kept and applied when the view attaches.
  void reveal(List<String> path, {bool select = false}) {
    final s = _state;
    if (s == null) {
      _pendingPath = List.of(path);
      _pendingSelect = select;
      return;
    }
    s._reveal(path, select: select);
  }

  /// Opens the tree down to the selected row and scrolls to it (the header's "Expand to selection"). Nothing without a selection.
  void expandToSelection() => _state?._expandToSelection();

  /// Rebuilds the rows from the model's current state. Also retries what was waiting for data: a [reveal] made before the tree loaded, and
  /// the root's features when the tree has just arrived.
  void refresh() => _state?._refresh();

  /// A features fetch asked for through `onFeaturesRequested` failed (or the host cleared the features): forget that it was asked, so
  /// opening the row asks again. The view otherwise asks once per path until `setFeatures`, a `merge` or a model swap.
  void forgetFeaturesRequest(List<String> path) => _state?._forgetRequest(path);

  void _attach(_AssemblyTreeViewState s) {
    _state = s;
    final p = _pendingPath;
    if (p != null) {
      _pendingPath = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_state == s && s.mounted) s._reveal(p, select: _pendingSelect);
      });
    }
  }

  void _detach(_AssemblyTreeViewState s) {
    if (_state == s) _state = null;
  }
}

/// The assembly tree (A3): draws [AssemblyTreeModel.visibleRows] in one fixed-height `ListView.builder`, following the rules of
/// `docs/assembly-tree-overhaul-scope.md` section 3 (a healthy row is one line; one state slot; counts on collapsed rows; no buttons in
/// phone rows) and the spec's rows (`docs/assembly-tree/spec.md` sections 5 to 7). It does not replace the old panel yet; it takes the
/// same `visible` / `docked` / Edit Alone / focus inputs so it can sit where that panel sits.
///
/// It reads and edits the model it is given (open keys, `selectedKey`, `grouping`) and reports every other change through a callback:
/// the host saves the grouping toggle, fetches features, acts on the selection bar. It owns no data.
class AssemblyTreeView extends StatefulWidget {
  const AssemblyTreeView({
    super.key,
    required this.model,
    this.controller,
    this.visible = true,
    this.docked = false,
    this.width = 320,
    this.title = 'Assembly',
    this.editAloneLabel,
    this.onEditAloneDone,
    this.focusedLabel,
    this.onExitFocus,
    this.onClose,
    this.onRowTap,
    this.onRowLongPress,
    this.onRowContextMenu,
    this.onVisibilityToggle,
    this.onFeaturesRequested,
    this.onGroupingChanged,
    this.isMultiSelectMode = false,
    this.selectedKeys = const {},
    this.onMultiSelectToggle,
    this.multiSelectHeader,
    this.onHideSelected,
    this.onIsolateSelected,
    this.onFocusSelected,
    this.onZoomSelected,
    this.onAloneSelected,
    this.onMoreSelected,
    this.statusLine,
    this.flashItemIds = const {},
    this.flashToken = 0,
  });

  final AssemblyTreeModel model;
  final AssemblyTreeController? controller;

  /// Overlay mode slides the panel off to the left when false; docked mode (desktop) is simply not drawn.
  final bool visible;

  /// Desktop layout: fills its parent (the left pane), no slide.
  final bool docked;

  /// Width of the overlay panel (ignored when [docked]).
  final double width;
  final String title;

  /// Edit Alone: "Editing <label> [Done]" as the first row under the header.
  final String? editAloneLabel;
  final VoidCallback? onEditAloneDone;

  /// Focus: a "Focused on <label> [Exit]" row under the header while set.
  final String? focusedLabel;
  final VoidCallback? onExitFocus;
  final VoidCallback? onClose;

  /// Tap on any row (the model's `selectedKey` is already set). For a row that can open, the chevron opens it; a group or folder row also
  /// opens on tap.
  final void Function(AssemblyTreeRow row)? onRowTap;
  final void Function(AssemblyTreeRow row)? onRowLongPress;

  /// Mouse right click; [position] is global. Not called during a multi-select.
  final void Function(AssemblyTreeRow row, Offset position)? onRowContextMenu;

  /// The desktop hover eye, and a tap on the eye-off icon of a hidden row. Null leaves the eye out.
  final void Function(AssemblyTreeRow row)? onVisibilityToggle;

  /// A part row was opened and its features are not in the model yet: fetch them and call `model.setFeatures` (then
  /// [AssemblyTreeController.refresh]). Also asked for the root, once, when it has features.
  final void Function(List<String> path)? onFeaturesRequested;

  /// The grouping toggle changed. The model is already updated; the host saves the choice.
  final ValueChanged<bool>? onGroupingChanged;

  /// Multi-select (today's behaviour): while on, a tap or long-press on an occurrence row calls [onMultiSelectToggle] and nothing else;
  /// [selectedKeys] are the rows drawn as picked. [multiSelectHeader] replaces the title row while set.
  final bool isMultiSelectMode;
  final Set<String> selectedKeys;
  final void Function(AssemblyTreeRow row)? onMultiSelectToggle;
  final Widget? multiSelectHeader;

  /// The phone selection bar (Hide, Isolate, Focus, Alone, More): shown under the list for a selected occurrence row. A null callback
  /// leaves its button out; with none set there is no bar.
  final void Function(AssemblyTreeRow row)? onHideSelected;
  final void Function(AssemblyTreeRow row)? onIsolateSelected;
  final void Function(AssemblyTreeRow row)? onFocusSelected;

  /// Zoom to selection: frame the camera on the selected row's parts (shown next to Focus in the phone selection bar).
  final void Function(AssemblyTreeRow row)? onZoomSelected;
  final void Function(AssemblyTreeRow row)? onAloneSelected;
  final void Function(AssemblyTreeRow row)? onMoreSelected;

  /// One quiet line under the header (A4: the motion summary, "Group: 5 DOF"...); null or empty shows nothing.
  final String? statusLine;

  /// Mates a pattern edit just left broken (A4, the old panel's pulse): their rows pulse about three times over two seconds each time
  /// [flashToken] changes, and the Mates folder opens if it was closed so the pulse is seen. [flashItemIds] are mate ids (`row.itemId`).
  final Set<String> flashItemIds;
  final int flashToken;

  @override
  State<AssemblyTreeView> createState() => _AssemblyTreeViewState();
}

class _AssemblyTreeViewState extends State<AssemblyTreeView> with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();

  /// The pulse of [AssemblyTreeView.flashItemIds]: 0 -> 1 over two seconds, read as three pulses by [_flashPulse].
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));
  AssemblyTreeResponseDto? _colourTree;
  Map<String, Color> _setColours = const {};

  /// The tree the view last saw: a new one (a `merge`, or the first load) forgets what was asked for.
  AssemblyTreeResponseDto? _seenTree;

  /// Feature fetches asked for and not answered yet (row key -> path), so a reopen or a reveal through an open ancestor does not ask twice.
  final Map<String, List<String>> _requested = {};

  /// A [reveal] made before the model had a tree, kept until it has one.
  List<String>? _pendingReveal;
  bool _pendingSelect = false;

  /// A row to scroll to once the list exists (a docked tree that is not shown has none).
  String? _pendingScrollKey;

  /// The filter (B2, spec section 11). Desktop shows the field always; a phone shows an icon that turns the header into the field
  /// ([_filterOpen]). [_query] is what is typed; the filter is on while it holds more than spaces.
  final TextEditingController _filterText = TextEditingController();
  final FocusNode _filterFocus = FocusNode();
  String _query = '';
  bool _filterOpen = false;

  bool get _filtering => _query.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _seenTree = widget.model.tree;
    widget.controller?._attach(this);
    _syncModel();
  }

  @override
  void didUpdateWidget(AssemblyTreeView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (old.model != widget.model) {
      _requested.clear();
      _seenTree = widget.model.tree;
    }
    _syncModel();
    if (widget.flashToken != old.flashToken && widget.flashItemIds.isNotEmpty) {
      // After this frame: the mate rows may only just have arrived with the refresh that brought the first broken mate.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.model.setOpen('#mates', true);
        setState(() {});
        _flash.forward(from: 0);
      });
    }
  }

  /// 0..1: three pulses over the animation, fading out.
  double get _flashPulse {
    final t = _flash.value;
    if (_flash.isDismissed || t >= 1.0) return 0.0;
    return (0.5 - 0.5 * math.cos(2 * math.pi * 3 * t)) * (1.0 - t * 0.4);
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _flash.dispose();
    _scroll.dispose();
    _filterText.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    _syncModel();
    setState(() {});
  }

  /// What depends on the model's data: forget answered or stale feature requests, ask for the root's features once the tree is there, and
  /// retry a reveal that was waiting for the tree. Never calls setState (it runs from didUpdateWidget); the host callbacks run after the frame.
  void _syncModel() {
    final m = widget.model;
    if (!identical(m.tree, _seenTree)) {
      _seenTree = m.tree;
      _requested.clear();
    } else {
      _requested.removeWhere((_, path) => m.hasFeatures(path));
    }
    final tree = m.tree;
    if (tree != null && tree.featureCount > 0) _askForFeatures(const [], root: true);
    final pending = _pendingReveal;
    if (pending != null && tree != null) {
      _pendingReveal = null;
      _doReveal(pending, select: _pendingSelect);
    }
  }

  void _forgetRequest(List<String> path) => _requested.remove(path.join('/'));

  /// Asks the host for [path]'s features, once until answered. Deferred to after the frame so the host may setState.
  void _askForFeatures(List<String>? path, {bool root = false}) {
    final cb = widget.onFeaturesRequested;
    if (cb == null || path == null || (path.isEmpty && !root)) return;
    final m = widget.model;
    if (!root) {
      final node = m.nodeAtPath(path);
      if (node == null || node.kind == 'missing' || (node.featureCount ?? 0) <= 0) return;
    }
    if (m.hasFeatures(path)) return;
    final key = path.join('/');
    if (_requested.containsKey(key)) return;
    _requested[key] = List.of(path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _requested.containsKey(key)) cb(path);
    });
  }

  // While a filter is on the chevrons are inert (spec section 11): what is open is not changed from a list that shows only the matches.
  bool _canToggle(AssemblyTreeRow r) => r.expandable && r.kind != AssemblyRowKind.root && !_filtering;

  void _toggle(AssemblyTreeRow row) {
    if (!_canToggle(row)) return;
    widget.model.toggle(row.key);
    setState(() {});
    if (!row.open) _askForFeatures(row.path);
  }

  void _tap(AssemblyTreeRow row) {
    if (widget.isMultiSelectMode) {
      if (row.path != null && row.path!.isNotEmpty) widget.onMultiSelectToggle?.call(row);
      return;
    }
    widget.model.selectedKey = row.key;
    final groupLike =
        row.kind == AssemblyRowKind.group || row.kind == AssemblyRowKind.matesFolder || row.kind == AssemblyRowKind.patternsFolder;
    if (groupLike && !_filtering) {
      widget.model.toggle(row.key);
      if (!row.open) _askForFeatures(row.path);
    }
    setState(() {});
    widget.onRowTap?.call(row);
  }

  void _longPress(AssemblyTreeRow row) {
    if (widget.isMultiSelectMode) {
      if (row.path != null && row.path!.isNotEmpty) widget.onMultiSelectToggle?.call(row);
      return;
    }
    widget.onRowLongPress?.call(row);
  }

  void _reveal(List<String> path, {required bool select}) {
    _doReveal(path, select: select);
    setState(() {});
  }

  /// Opens the ancestors, selects, and schedules the scroll. With no tree yet the path is kept for [_syncModel]; a path the loaded tree does
  /// not know is dropped.
  void _doReveal(List<String> path, {required bool select}) {
    final m = widget.model;
    if (m.tree == null) {
      _pendingReveal = List.of(path);
      _pendingSelect = select;
      return;
    }
    if (m.nodeAtPath(path) == null) return;
    m.revealAndOpen(path);
    final key = path.join('/');
    if (select) m.selectedKey = key;
    for (var i = 1; i < path.length; i++) {
      _askForFeatures(path.sublist(0, i));
    }
    _scheduleScroll(key);
  }

  void _scheduleScroll(String key) {
    _pendingScrollKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushScroll());
  }

  /// Scrolls to [_pendingScrollKey] when the list exists; with no list yet (docked and not shown) the key stays until it does.
  void _flushScroll() {
    final key = _pendingScrollKey;
    if (!mounted || key == null || !_scroll.hasClients) return;
    _pendingScrollKey = null;
    final i = _indexOfRow(key);
    if (i < 0) return;
    final h = _rowHeight();
    final p = _scroll.position;
    final top = i * h;
    double? target;
    if (top < p.pixels) {
      target = top;
    } else if (top + h > p.pixels + p.viewportDimension) {
      target = top + h - p.viewportDimension;
    }
    if (target == null) return;
    // Not clamped to maxScrollExtent: it can still be the extent from before the rows were opened. The row exists, so the target is in range.
    _scroll.jumpTo(math.max(target, p.minScrollExtent));
  }

  /// Collapse all, but the selected row stays listed: its ancestors reopen, or (a group, feature or folder row) the selection is dropped.
  void _collapseAll() {
    final m = widget.model;
    m.closeAll();
    final sel = m.selectedKey;
    if (sel != null) {
      final path = m.selectedPath;
      if (path != null && path.isNotEmpty) m.revealAndOpen(path);
      if (m.indexOf(sel) < 0 && sel.isNotEmpty) m.selectedKey = null;
    }
    setState(() {});
    final keep = m.selectedKey;
    if (keep != null && m.indexOf(keep) >= 0) {
      _scheduleScroll(keep);
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  /// Expand to selection (spec section 12): opens the ancestors of the selected row (and, with grouping on, its group) and scrolls to it.
  void _expandToSelection() {
    final m = widget.model;
    final sel = m.selectedKey;
    if (sel == null || sel.isEmpty) return;
    final path = m.selectedPath;
    if (path != null && path.isNotEmpty) {
      _doReveal(path, select: false);
    } else {
      m.expandToSelection();
      _scheduleScroll(sel);
    }
    setState(() {});
  }

  void _setQuery(String value) {
    final wasFiltering = _filtering;
    setState(() => _query = value);
    if (wasFiltering != _filtering && _scroll.hasClients) _scroll.jumpTo(0);
    // Clearing the filter reveals the selected row (spec section 11): it may sit in a collapsed branch the matches had opened up.
    if (wasFiltering && !_filtering) _expandToSelection();
  }

  /// Clears the filter; a phone also turns the header back from the field to the title.
  void _closeFilter() {
    _filterText.clear();
    _filterFocus.unfocus();
    _filterOpen = false;
    _setQuery('');
  }

  void _openFilter() {
    setState(() => _filterOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  int _indexOfRow(String key) {
    if (!_filtering) return widget.model.indexOf(key);
    return widget.model.filteredRows(_query).rows.indexWhere((r) => r.key == key);
  }

  double _rowHeight() => LayoutModeScope.isDesktop(context) ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;

  /// One colour per rigid set in the whole tree (sorted by set id, so it does not move as rows open), cached per loaded tree.
  Map<String, Color> _rigidColours() {
    final tree = widget.model.tree;
    if (identical(tree, _colourTree)) return _setColours;
    _colourTree = tree;
    final ids = <String>{};
    final stack = <AssemblyTreeNodeDto>[...?tree?.children];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      final s = n.constraint?.rigidSet;
      if (s != null) ids.add(s);
      stack.addAll(n.children);
    }
    const palette = <Color>[
      Color(0xFF1E88E5),
      Color(0xFFF4511E),
      Color(0xFF43A047),
      Color(0xFF8E24AA),
      Color(0xFFFDD835),
      Color(0xFF00ACC1)
    ];
    final sorted = ids.toList()..sort();
    // Six fixed colours, then golden-angle hues, so no two of the first dozens of sets share one (a huge number of sets can still look alike).
    Color colourAt(int i) => i < palette.length ? palette[i] : HSLColor.fromAHSL(1, (i * 137.508) % 360, 0.65, i.isEven ? 0.45 : 0.6).toColor();
    _setColours = {for (var i = 0; i < sorted.length; i++) sorted[i]: colourAt(i)};
    return _setColours;
  }

  @override
  Widget build(BuildContext context) {
    final desktop = LayoutModeScope.isDesktop(context);
    final model = widget.model;
    final filter = _filtering ? model.filteredRows(_query) : null;
    final rows = filter?.rows ?? model.visibleRows();
    final h = desktop ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;
    final colours = _rigidColours();
    final scheme = Theme.of(context).colorScheme;
    if (_pendingScrollKey != null) WidgetsBinding.instance.addPostFrameCallback((_) => _flushScroll());

    final selectedIndex = model.selectedKey == null ? -1 : _indexOfRow(model.selectedKey!);
    final selectedRow = selectedIndex < 0 ? null : rows[selectedIndex];
    final showBar = !desktop &&
        !widget.isMultiSelectMode &&
        selectedRow != null &&
        selectedRow.path != null &&
        selectedRow.path!.isNotEmpty &&
        (widget.onHideSelected != null ||
            widget.onIsolateSelected != null ||
            widget.onFocusSelected != null ||
            widget.onZoomSelected != null ||
            widget.onAloneSelected != null ||
            widget.onMoreSelected != null);

    final body = Material(
      color: scheme.surface,
      elevation: widget.docked ? 0 : 6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.multiSelectHeader ?? _header(context, desktop),
          // Desktop: the filter box is always there; a phone has the field in the header while it is open.
          if (widget.multiSelectHeader == null && desktop) _desktopFilterRow(context),
          if (filter != null) _filterNotes(context, filter),
          // Not while the floating tree is closed: the pill at the top of the viewport is the way out then.
          if (widget.editAloneLabel != null && widget.onEditAloneDone != null && (widget.visible || widget.docked))
            EditAloneRow(label: widget.editAloneLabel!, onDone: widget.onEditAloneDone!),
          if (widget.focusedLabel != null) _focusRow(context),
          if (widget.statusLine != null && widget.statusLine!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.statusLine!,
                  key: const ValueKey('assembly-motion-summary'),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('Nothing to show yet'))
                : filter != null && rows.length == 1 && filter.unknown.isEmpty
                    ? Center(
                        child: Text('Nothing matches',
                            key: const ValueKey('tree-filter-empty'), style: TextStyle(color: scheme.onSurfaceVariant)))
                    : ListView.builder(
                        key: const ValueKey('assembly-tree-list'),
                        controller: _scroll,
                        itemExtent: h,
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          final flashing = r.kind == AssemblyRowKind.mate && r.itemId != null && widget.flashItemIds.contains(r.itemId);
                          Widget rowWidget(double pulse) => _TreeRow(
                                key: ValueKey('tree-row:${r.key}'),
                                pulse: pulse,
                                row: r,
                                height: h,
                                desktop: desktop,
                                selected: widget.isMultiSelectMode ? widget.selectedKeys.contains(r.key) : r.key == model.selectedKey,
                                multiSelect: widget.isMultiSelectMode,
                                bracket: _bracketFor(r, colours),
                                canToggle: _canToggle(r),
                                showEye: widget.onVisibilityToggle != null,
                                onToggle: () => _toggle(r),
                                onTap: () => _tap(r),
                                onLongPress: () => _longPress(r),
                                onContextMenu: widget.isMultiSelectMode || widget.onRowContextMenu == null
                                    ? null
                                    : (at) => widget.onRowContextMenu!(r, at),
                                onEye: () => widget.onVisibilityToggle?.call(r),
                              );
                          // Only a row that is flashing listens to the animation; every other row is built once.
                          return flashing
                              ? AnimatedBuilder(animation: _flash, builder: (context, _) => rowWidget(_flashPulse))
                              : rowWidget(0);
                        },
                      ),
          ),
          if (showBar) _selectionBar(context, selectedRow),
        ],
      ),
    );

    if (widget.docked) {
      return widget.visible ? body : const SizedBox.shrink();
    }
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        offset: widget.visible ? Offset.zero : const Offset(-1, 0),
        child: SizedBox(width: widget.width, child: body),
      ),
    );
  }

  Color? _bracketFor(AssemblyTreeRow r, Map<String, Color> colours) {
    final p = r.path;
    if (p == null || p.isEmpty) return null;
    final set = widget.model.nodeAtPath(p)?.constraint?.rigidSet;
    return set == null ? null : colours[set];
  }

  /// One line, on a phone too: the title and four small icons (filter, grouping, expand to selection, collapse all) and Close. While the
  /// phone's filter is open the line is the field instead.
  Widget _header(BuildContext context, bool desktop) {
    final scheme = Theme.of(context).colorScheme;
    if (!desktop && _filterOpen) return _phoneFilterHeader(context);
    // 36 dp on a phone (the 48 dp default made five of them a quarter of the width); desktop keeps the compact default.
    Widget button({
      required String key,
      required String tooltip,
      required IconData icon,
      Color? colour,
      IconData? selectedIcon,
      bool selected = false,
      VoidCallback? onPressed,
    }) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: desktop ? 36 : 36, height: desktop ? 36 : 40),
          isSelected: selected,
          icon: Icon(icon, size: 20, color: colour),
          selectedIcon: selectedIcon == null ? null : Icon(selectedIcon, size: 20, color: scheme.primary),
          style: selected ? IconButton.styleFrom(backgroundColor: scheme.primaryContainer) : null,
          onPressed: onPressed,
        );
    final selectedKey = widget.model.selectedKey;
    final canExpand = !_filtering && selectedKey != null && selectedKey.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: SizedBox(
        height: desktop ? 36 : 48,
        child: Row(
          children: [
            Expanded(
              child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (!desktop)
              button(
                  key: 'tree-filter-toggle',
                  tooltip: 'Filter',
                  icon: Icons.search,
                  colour: scheme.onSurfaceVariant,
                  onPressed: _openFilter),
            // The grouping toggle is the icon itself: filled and tinted when on, outlined and grey when off (no Switch: it was far too big).
            button(
              key: 'tree-grouping-toggle',
              tooltip: widget.model.grouping ? 'Grouping repeated parts: on' : 'Grouping repeated parts: off',
              icon: Icons.layers_outlined,
              colour: scheme.onSurfaceVariant,
              selectedIcon: Icons.layers,
              selected: widget.model.grouping,
              onPressed: () {
                final v = !widget.model.grouping;
                widget.model.grouping = v;
                setState(() {});
                widget.onGroupingChanged?.call(v);
              },
            ),
            button(
              key: 'tree-expand-to-selection',
              tooltip: 'Expand to selection',
              icon: Icons.my_location,
              onPressed: canExpand ? _expandToSelection : null,
            ),
            // Both change what is open, which the filter's list does not show: off while a filter is on.
            button(key: 'tree-collapse-all', tooltip: 'Collapse all', icon: Icons.unfold_less, onPressed: _filtering ? null : _collapseAll),
            if (widget.onClose != null) button(key: 'tree-close', tooltip: 'Close', icon: Icons.close, onPressed: widget.onClose),
          ],
        ),
      ),
    );
  }

  static const String _filterHint = 'Name, or :errors :missing :hidden ...';

  TextField _filterField({required bool desktop, Widget? prefix}) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      key: const ValueKey('tree-filter-field'),
      controller: _filterText,
      focusNode: _filterFocus,
      onChanged: _setQuery,
      textInputAction: TextInputAction.search,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: desktop ? 13 : 15),
      decoration: InputDecoration(
        isDense: true,
        hintText: _filterHint,
        hintStyle: TextStyle(fontSize: desktop ? 12 : 14, color: scheme.onSurfaceVariant),
        prefixIcon: prefix ?? Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
        prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                key: const ValueKey('tree-filter-clear'),
                tooltip: 'Clear filter',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                icon: const Icon(Icons.clear, size: 18),
                onPressed: desktop
                    ? () {
                        _filterText.clear();
                        _setQuery('');
                      }
                    : _closeFilter,
              ),
        suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  /// Esc: a phone closes the field; desktop clears what is typed, and with nothing typed leaves the field.
  Widget _escapeCloses(Widget field, {required bool desktop}) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!desktop) return _closeFilter();
            if (_query.isNotEmpty) {
              _filterText.clear();
              _setQuery('');
            } else {
              _filterFocus.unfocus();
            }
          },
        },
        child: field,
      );

  Widget _phoneFilterHeader(BuildContext context) => Padding(
        key: const ValueKey('tree-filter-header'),
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              Expanded(child: SizedBox(height: 36, child: _escapeCloses(_filterField(desktop: false), desktop: false))),
              IconButton(
                key: const ValueKey('tree-filter-close'),
                tooltip: 'Close filter',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 36, height: 40),
                icon: const Icon(Icons.close, size: 20),
                onPressed: _closeFilter,
              ),
            ],
          ),
        ),
      );

  Widget _desktopFilterRow(BuildContext context) => Padding(
        key: const ValueKey('tree-filter-row'),
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: SizedBox(height: 32, child: _escapeCloses(_filterField(desktop: true), desktop: true)),
      );

  /// One quiet line under the header while a filter is on: tokens nobody knows, and what the filter cannot see yet.
  Widget _filterNotes(BuildContext context, AssemblyFilterResult filter) {
    final scheme = Theme.of(context).colorScheme;
    final model = widget.model;
    final words = _query.toLowerCase().split(RegExp(r'\s+'));
    final notes = <String>[
      if (filter.unknown.isNotEmpty) 'Unknown filter ${filter.unknown.join(' ')}',
      if (!model.statusIncluded && (words.contains(':errors') || words.contains(':warnings')))
        'Status is still loading: :errors and :warnings find only missing files and cycles for now',
      if (filter.featuresNotRead) 'Features are searched only in parts you have opened',
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(notes.join('. '),
            key: const ValueKey('tree-filter-notes'), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ),
    );
  }

  Widget _focusRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Focused on '),
                TextSpan(text: widget.focusedLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.onExitFocus != null)
            TextButton(key: const ValueKey('tree-exit-focus'), onPressed: widget.onExitFocus, child: const Text('Exit')),
        ],
      ),
    );
  }

  Widget _selectionBar(BuildContext context, AssemblyTreeRow row) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(String key, IconData icon, String label, void Function(AssemblyTreeRow)? cb) {
      if (cb == null) return const SizedBox.shrink();
      return Expanded(
        child: InkWell(
          key: ValueKey(key),
          onTap: () => cb(row),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20),
                Text(label, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      key: const ValueKey('tree-selection-bar'),
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            button('tree-bar-hide', row.hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, row.hidden ? 'Show' : 'Hide',
                widget.onHideSelected),
            button('tree-bar-isolate', Icons.filter_center_focus, 'Isolate', widget.onIsolateSelected),
            button('tree-bar-zoom', Icons.zoom_out_map, 'Zoom', widget.onZoomSelected),
            button('tree-bar-focus', Icons.center_focus_strong_outlined, 'Focus', widget.onFocusSelected),
            button('tree-bar-alone', Icons.edit_outlined, 'Alone', widget.onAloneSelected),
            button('tree-bar-more', Icons.more_horiz, 'More', widget.onMoreSelected),
          ],
        ),
      ),
    );
  }
}

/// One line. Stateful only for the desktop hover.
class _TreeRow extends StatefulWidget {
  const _TreeRow({
    super.key,
    required this.row,
    required this.height,
    required this.desktop,
    required this.selected,
    required this.multiSelect,
    required this.bracket,
    required this.canToggle,
    required this.showEye,
    required this.onToggle,
    required this.onTap,
    required this.onLongPress,
    required this.onContextMenu,
    required this.onEye,
    this.pulse = 0,
  });

  /// 0..1, the flash of a mate row (see [AssemblyTreeView.flashItemIds]).
  final double pulse;
  final AssemblyTreeRow row;
  final double height;
  final bool desktop;
  final bool selected;
  final bool multiSelect;
  final Color? bracket;
  final bool canToggle;
  final bool showEye;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<Offset>? onContextMenu;
  final VoidCallback onEye;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hover = false;

  static IconData _kindIcon(AssemblyRowKind k) => switch (k) {
        AssemblyRowKind.root => Icons.account_tree,
        AssemblyRowKind.assembly => Icons.account_tree_outlined,
        AssemblyRowKind.part => Icons.view_in_ar_outlined,
        AssemblyRowKind.missing => Icons.insert_drive_file_outlined,
        AssemblyRowKind.group => Icons.layers_outlined,
        AssemblyRowKind.feature => Icons.tune,
        AssemblyRowKind.matesFolder => Icons.link,
        AssemblyRowKind.patternsFolder => Icons.grid_view,
        AssemblyRowKind.mate => Icons.link,
        AssemblyRowKind.pattern => Icons.grid_view_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final scheme = Theme.of(context).colorScheme;
    final desktop = widget.desktop;
    final iconSize = desktop ? 16.0 : 22.0;
    final isOccurrence = r.path != null && r.path!.isNotEmpty;
    final canEye = widget.showEye && isOccurrence;
    // A group row never shows one: it has nothing to toggle (its members show their own).
    final eyeSlot = r.hidden && r.kind != AssemblyRowKind.group
        ? Icon(Icons.visibility_off_outlined, key: ValueKey('tree-eye-off:${r.key}'), size: iconSize, color: scheme.onSurfaceVariant)
        : (desktop && _hover && canEye && !widget.multiSelect)
            ? Icon(Icons.visibility_outlined, key: ValueKey('tree-eye:${r.key}'), size: iconSize, color: scheme.onSurfaceVariant)
            : null;

    final chevronWidth = desktop ? 22.0 : 36.0;
    Widget chevron;
    if (widget.canToggle) {
      chevron = GestureDetector(
        key: ValueKey('tree-chevron:${r.key}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: SizedBox(
          width: chevronWidth,
          height: widget.height,
          child: Icon(r.open ? Icons.expand_more : Icons.chevron_right, size: iconSize + 2, color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      chevron = SizedBox(width: chevronWidth);
    }

    final dim = r.suppressed ? 0.45 : (r.hidden ? 0.65 : 1.0);
    final isItem = r.itemId != null && (r.kind == AssemblyRowKind.mate || r.kind == AssemblyRowKind.pattern);
    final palette = AiPalette.of(context);
    final Color? toneColour = switch (r.tone) {
      AssemblyItemTone.error => scheme.error,
      AssemblyItemTone.warning => palette.warning,
      AssemblyItemTone.info => scheme.primary,
      null => null,
    };
    final labelStyle = TextStyle(
      fontSize: desktop ? 13 : 15,
      fontWeight: r.kind == AssemblyRowKind.root || r.match ? FontWeight.w600 : FontWeight.normal,
      // A mate or pattern a pattern edit or the backend suppressed is dimmed, not struck through (it is not a part).
      fontStyle: r.suppressed && !isItem ? FontStyle.italic : FontStyle.normal,
      decoration: r.suppressed && !isItem ? TextDecoration.lineThrough : null,
      // Only a problem colours the label (an info line colours its icon and note, not the name).
      color: r.state == AssemblyRowState.missing ? palette.danger : (r.tone == AssemblyItemTone.info ? null : toneColour),
    );
    final noteStyle = TextStyle(fontSize: desktop ? 11 : 12, color: toneColour ?? scheme.onSurfaceVariant);
    final IconData kindIcon =
        isItem && r.kind == AssemblyRowKind.mate && (r.tone == AssemblyItemTone.error || r.tone == AssemblyItemTone.warning)
            ? Icons.warning_amber_rounded
            : isItem && r.tone == AssemblyItemTone.info
                ? Icons.info_outline
                : _kindIcon(r.kind);

    Widget content = Row(
      children: [
        SizedBox(width: 6 + r.depth * (desktop ? 14.0 : 16.0)),
        chevron,
        Opacity(
          opacity: dim,
          child: widget.multiSelect && isOccurrence
              ? Icon(widget.selected ? Icons.check_circle : Icons.circle_outlined, size: iconSize, color: scheme.primary)
              : Icon(kindIcon, size: iconSize, color: toneColour ?? scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Opacity(
            // A filter's match (not the ancestors listed to show where it is): bold, on a tint.
            key: r.match ? ValueKey('tree-match:${r.key}') : null,
            opacity: dim,
            child: r.note == null
                ? Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle)
                : Tooltip(
                    message: '${r.label} - ${r.note}',
                    // Hover only: a touch long-press belongs to the row (its menu), not to the tooltip.
                    triggerMode: TooltipTriggerMode.manual,
                    child: desktop
                        // One line: the label, then the note, dimmer.
                        ? Text.rich(
                            TextSpan(children: [
                              TextSpan(text: r.label, style: labelStyle),
                              TextSpan(text: '  ${r.note}', style: noteStyle),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        // Two lines in the 48 dp phone row.
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
                              Text(r.note!,
                                  key: ValueKey('tree-note:${r.key}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: noteStyle),
                            ],
                          ),
                  ),
          ),
        ),
        if (r.count != null && (r.kind == AssemblyRowKind.matesFolder || r.kind == AssemblyRowKind.patternsFolder))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('${r.count}', style: TextStyle(fontSize: desktop ? 12 : 13, color: scheme.onSurfaceVariant)),
          ),
        if (r.bubble != null && !r.open) _bubble(context, r.bubble!),
        if (eyeSlot != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Desktop: the hover eye and the eye-off toggle. Phone: only the eye-off of a hidden row (it is state, not a button). Never in multi-select.
            onTap: canEye && !widget.multiSelect && (desktop || r.hidden) ? widget.onEye : null,
            child: SizedBox(width: desktop ? 26 : 40, height: widget.height, child: Center(child: eyeSlot)),
          ),
        Padding(padding: const EdgeInsets.only(left: 6, right: 8), child: _stateSlot(context, r, iconSize)),
      ],
    );

    if (widget.bracket != null) {
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(key: ValueKey('tree-bracket:${r.key}'), color: widget.bracket!),
          ),
        ],
      );
    }

    Widget tile = Material(
      color: widget.pulse > 0
          ? scheme.error.withValues(alpha: 0.35 * widget.pulse)
          : widget.selected
              ? scheme.secondaryContainer.withValues(alpha: 0.7)
              : r.match
                  ? scheme.tertiaryContainer.withValues(alpha: 0.5)
                  : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: SizedBox(height: widget.height, child: content),
      ),
    );
    tile = MouseContextMenuRegion(onOpen: widget.onContextMenu, child: tile);
    if (desktop) {
      tile = MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: tile,
      );
    }
    return tile;
  }

  Widget _bubble(BuildContext context, AssemblyBubble b) {
    final palette = AiPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (b.level) {
      AssemblyBubbleLevel.error => (palette.danger, Colors.white),
      AssemblyBubbleLevel.warning => (palette.warning, Colors.white),
      AssemblyBubbleLevel.unsaved => (scheme.primaryContainer, scheme.onPrimaryContainer),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        key: ValueKey('tree-bubble:${widget.row.key}'),
        constraints: const BoxConstraints(minWidth: 18),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
        child: Text('${b.count}', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }

  /// The one state slot (section 3, rule 2; spec section 5). A row whose level's status failed shows no constraint state, only a quiet hint.
  Widget _stateSlot(BuildContext context, AssemblyTreeRow r, double size) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AiPalette.of(context);
    final slotKey = ValueKey('tree-state:${r.key}:${r.state.wire}');
    final state = r.state;
    const constraintStates = {
      AssemblyRowState.broken,
      AssemblyRowState.overConstrained,
      AssemblyRowState.near,
      AssemblyRowState.underConstrained,
      AssemblyRowState.fixed,
      AssemblyRowState.fullyConstrained,
    };
    if (r.statusFailed && (constraintStates.contains(state) || state == AssemblyRowState.none)) {
      return Tooltip(
        message: 'Status unavailable',
        child: Icon(Icons.help_outline, key: ValueKey('tree-state:${r.key}:status_failed'), size: size - 4, color: scheme.outline),
      );
    }
    final dof = r.path == null ? null : _dof(context, r);
    final (IconData?, Color?, String?) look = switch (state) {
      AssemblyRowState.missing => (Icons.link_off, palette.danger, 'Missing file'),
      AssemblyRowState.cycle => (Icons.sync_problem, palette.danger, 'Contains itself'),
      AssemblyRowState.broken => (Icons.error_outline, palette.danger, 'A mate is broken'),
      AssemblyRowState.overConstrained => (Icons.warning_amber_rounded, palette.danger, 'Over-constrained - mates conflict'),
      AssemblyRowState.near => (Icons.warning_amber_rounded, palette.warning, 'Over-constrained - the mates agree to within tolerance'),
      AssemblyRowState.unsaved => (null, null, 'Unsaved changes'),
      AssemblyRowState.underConstrained => (
          Icons.lock_open,
          scheme.onSurfaceVariant,
          dof == null ? 'Under-constrained' : 'Under-constrained - $dof degree${dof == 1 ? '' : 's'} of freedom'
        ),
      AssemblyRowState.fixed => (Icons.push_pin, scheme.onSurfaceVariant, 'Fixed'),
      AssemblyRowState.fullyConstrained => (Icons.lock_outline, scheme.primary, 'Fully constrained'),
      AssemblyRowState.none => (null, null, null),
    };
    if (state == AssemblyRowState.none) return const SizedBox.shrink();
    if (state == AssemblyRowState.unsaved) {
      return Tooltip(
        message: look.$3!,
        child: Container(
          key: slotKey,
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
        ),
      );
    }
    return Tooltip(message: look.$3!, child: Icon(look.$1, key: slotKey, size: size - 2, color: look.$2));
  }

  int? _dof(BuildContext context, AssemblyTreeRow r) {
    final view = context.findAncestorStateOfType<_AssemblyTreeViewState>();
    final p = r.path;
    if (view == null || p == null || p.isEmpty) return null;
    return view.widget.model.nodeAtPath(p)?.constraint?.dof;
  }
}
