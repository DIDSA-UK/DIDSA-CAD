import 'dart:math' as math;

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

  /// Rebuilds the rows from the model's current state.
  void refresh() => _state?._refresh();

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
/// the host saves the grouping switch, fetches features, acts on the selection bar. It owns no data.
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
    this.onAloneSelected,
    this.onMoreSelected,
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

  /// The grouping switch changed. The model is already updated; the host saves the choice.
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
  final void Function(AssemblyTreeRow row)? onAloneSelected;
  final void Function(AssemblyTreeRow row)? onMoreSelected;

  @override
  State<AssemblyTreeView> createState() => _AssemblyTreeViewState();
}

class _AssemblyTreeViewState extends State<AssemblyTreeView> {
  final ScrollController _scroll = ScrollController();
  AssemblyTreeResponseDto? _colourTree;
  Map<String, Color> _setColours = const {};

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _requestRootFeatures();
  }

  @override
  void didUpdateWidget(AssemblyTreeView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (old.model != widget.model) _requestRootFeatures();
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _requestRootFeatures() {
    final cb = widget.onFeaturesRequested;
    final tree = widget.model.tree;
    if (cb == null || tree == null || tree.featureCount <= 0 || widget.model.hasFeatures(const [])) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.model.hasFeatures(const [])) cb(const []);
    });
  }

  void _askForFeatures(List<String>? path) {
    final cb = widget.onFeaturesRequested;
    if (cb == null || path == null || path.isEmpty) return;
    final node = widget.model.nodeAtPath(path);
    if (node == null || node.kind == 'missing' || (node.featureCount ?? 0) <= 0 || widget.model.hasFeatures(path)) return;
    cb(path);
  }

  bool _canToggle(AssemblyTreeRow r) =>
      r.expandable && r.kind != AssemblyRowKind.root && r.kind != AssemblyRowKind.matesFolder && r.kind != AssemblyRowKind.patternsFolder;

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
    final groupLike = row.kind == AssemblyRowKind.group;
    if (groupLike) {
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
    final m = widget.model;
    if (m.nodeAtPath(path) == null) return;
    m.revealAndOpen(path);
    final key = path.join('/');
    if (select) m.selectedKey = key;
    for (var i = 1; i < path.length; i++) {
      _askForFeatures(path.sublist(0, i));
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(key));
  }

  void _scrollTo(String key) {
    if (!mounted || !_scroll.hasClients) return;
    final i = widget.model.indexOf(key);
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
    const palette = <Color>[Color(0xFF1E88E5), Color(0xFFF4511E), Color(0xFF43A047), Color(0xFF8E24AA), Color(0xFFFDD835), Color(0xFF00ACC1)];
    final sorted = ids.toList()..sort();
    _setColours = {for (var i = 0; i < sorted.length; i++) sorted[i]: palette[i % palette.length]};
    return _setColours;
  }

  @override
  Widget build(BuildContext context) {
    final desktop = LayoutModeScope.isDesktop(context);
    final model = widget.model;
    final rows = model.visibleRows();
    final h = desktop ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;
    final colours = _rigidColours();
    final scheme = Theme.of(context).colorScheme;

    final selectedIndex = model.selectedKey == null ? -1 : model.indexOf(model.selectedKey!);
    final selectedRow = selectedIndex < 0 ? null : rows[selectedIndex];
    final showBar = !desktop &&
        !widget.isMultiSelectMode &&
        selectedRow != null &&
        selectedRow.path != null &&
        selectedRow.path!.isNotEmpty &&
        (widget.onHideSelected != null ||
            widget.onIsolateSelected != null ||
            widget.onFocusSelected != null ||
            widget.onAloneSelected != null ||
            widget.onMoreSelected != null);

    final body = Material(
      color: scheme.surface,
      elevation: widget.docked ? 0 : 6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.multiSelectHeader ?? _header(context, desktop),
          if (widget.editAloneLabel != null && widget.onEditAloneDone != null)
            EditAloneRow(label: widget.editAloneLabel!, onDone: widget.onEditAloneDone!),
          if (widget.focusedLabel != null) _focusRow(context),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('Nothing to show yet'))
                : ListView.builder(
                    key: const ValueKey('assembly-tree-list'),
                    controller: _scroll,
                    itemExtent: h,
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      return _TreeRow(
                        key: ValueKey('tree-row:${r.key}'),
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

  Widget _header(BuildContext context, bool desktop) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: SizedBox(
        height: desktop ? 36 : 48,
        child: Row(
          children: [
            Expanded(
              child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Tooltip(
              message: 'Group repeated parts',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_outlined, size: 18, color: scheme.onSurfaceVariant),
                  Switch(
                    key: const ValueKey('tree-grouping-switch'),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: widget.model.grouping,
                    onChanged: (v) {
                      widget.model.grouping = v;
                      setState(() {});
                      widget.onGroupingChanged?.call(v);
                    },
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('tree-collapse-all'),
              tooltip: 'Collapse all',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.unfold_less, size: 20),
              onPressed: () {
                widget.model.closeAll();
                setState(() {});
                if (_scroll.hasClients) _scroll.jumpTo(0);
              },
            ),
            if (widget.onClose != null)
              IconButton(
                key: const ValueKey('tree-close'),
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 20),
                onPressed: widget.onClose,
              ),
          ],
        ),
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
            button('tree-bar-hide', row.hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, row.hidden ? 'Show' : 'Hide', widget.onHideSelected),
            button('tree-bar-isolate', Icons.filter_center_focus, 'Isolate', widget.onIsolateSelected),
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
  });

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
      };

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final scheme = Theme.of(context).colorScheme;
    final desktop = widget.desktop;
    final iconSize = desktop ? 16.0 : 22.0;
    final isOccurrence = r.path != null && r.path!.isNotEmpty;
    final canEye = widget.showEye && isOccurrence;
    final eyeSlot = r.hidden
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
    final labelStyle = TextStyle(
      fontSize: desktop ? 13 : 15,
      fontWeight: r.kind == AssemblyRowKind.root ? FontWeight.w600 : FontWeight.normal,
      fontStyle: r.suppressed ? FontStyle.italic : FontStyle.normal,
      decoration: r.suppressed ? TextDecoration.lineThrough : null,
      color: r.state == AssemblyRowState.missing ? AiPalette.of(context).danger : null,
    );

    Widget content = Row(
      children: [
        SizedBox(width: 6 + r.depth * (desktop ? 14.0 : 16.0)),
        chevron,
        Opacity(
          opacity: dim,
          child: widget.multiSelect && isOccurrence
              ? Icon(widget.selected ? Icons.check_circle : Icons.circle_outlined, size: iconSize, color: scheme.primary)
              : Icon(_kindIcon(r.kind), size: iconSize, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Opacity(
            opacity: dim,
            child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
          ),
        ),
        if (r.count != null && (r.kind == AssemblyRowKind.matesFolder || r.kind == AssemblyRowKind.patternsFolder))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('${r.count}', style: TextStyle(fontSize: desktop ? 12 : 13, color: scheme.onSurfaceVariant)),
          ),
        if (r.bubble != null && !r.open) _bubble(context, r.bubble!),
        if (eyeSlot != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: canEye && desktop ? widget.onEye : null, child: eyeSlot),
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
      color: widget.selected ? scheme.secondaryContainer.withValues(alpha: 0.7) : Colors.transparent,
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
      AssemblyRowState.underConstrained =>
        (Icons.lock_open, scheme.onSurfaceVariant, dof == null ? 'Under-constrained' : 'Under-constrained - $dof degree${dof == 1 ? '' : 's'} of freedom'),
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
