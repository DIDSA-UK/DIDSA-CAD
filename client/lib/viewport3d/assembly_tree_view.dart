import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../ai/ai_theme.dart' show AiPalette;
import '../api/document_api_client.dart';
import '../assembly/assembly_lens.dart';
import '../assembly/assembly_lens_theme.dart';
import '../assembly/assembly_tree_model.dart';
import '../layout/layout_mode.dart';
import 'action_sheet.dart' show MouseContextMenuRegion;
import 'feature_tree_helpers.dart';
import 'assembly_context_strip.dart';
import 'assembly_tree_pin.dart';
import 'svg_icon.dart';
import 'view_preferences.dart';

/// Row height (A3, `docs/assembly-tree-overhaul-scope.md` 9.6): fixed, so the list can scroll to any row without building the ones in between.
const double kAssemblyTreeRowHeightDesktop = 30;
const double kAssemblyTreeRowHeightPhone = 48;

/// B4 (`docs/assembly-tree-overhaul-scope.md` 10.6, sections 5 and 8.2): the heights of the phone portrait sheet. **Peek** is the header and the
/// selected row with its bar; **half** half the space; **full** all of it but a strip of the viewport.
enum AssemblyTreeSheetHeight { peek, half, full }

/// The sheet's drag handle strip above the header.
const double kAssemblyTreeSheetHandleHeight = 20;

/// What of the viewport full height leaves showing above the sheet.
const double kAssemblyTreeSheetTopGap = 24;

/// B5 (section 5, "Phone, deep trees"): in the sheet a level of indent is 12 dp and the indent stops growing after 4 levels (below the title):
/// deeper rows stand where the fourth level does, and the pinned chain above them says where they are.
const double kAssemblyTreeSheetIndentStep = 12;
const int kAssemblyTreeSheetMaxIndentLevels = 4;

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

  /// Opens the tree down to the selected row and scrolls to it (the header's "Expand to selection"). Nothing without a selection, and nothing
  /// while the view is not built: the host shows the tree first and calls this after the frame.
  void expandToSelection() => _state?._expandToSelection();

  /// Rebuilds the rows from the model's current state. Also retries what was waiting for data: a [reveal] made before the tree loaded, and
  /// the root's features when the tree has just arrived.
  void refresh() => _state?._refresh();

  /// A features fetch asked for through `onFeaturesRequested` failed (or the host cleared the features): forget that it was asked, so
  /// opening the row asks again. The view otherwise asks once per path until `setFeatures`, a `merge` or a model swap.
  void forgetFeaturesRequest(List<String> path) => _state?._forgetRequest(path);

  /// C2: an items read asked for through `onFolderItemsRequested` failed or was dropped: forget it, so the open folder asks again.
  void forgetFolderRequest(String folderKey) => _state?._folderRequested.remove(folderKey);

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
    this.editAlone,
    this.onEditAloneDone,
    this.onEditAloneCrumb,
    this.focusCrumbs = const [],
    this.onFocusCrumb,
    this.onFocusHere,
    this.onClose,
    this.onRowTap,
    this.onRowLongPress,
    this.onRowEdit,
    this.onRowEditInContext,
    this.canEditInContext,
    this.onRowPick,
    this.onRowContextMenu,
    this.onVisibilityToggle,
    this.lockedEyes = false,
    this.onFeaturesRequested,
    this.onFolderItemsRequested,
    this.itemOtherLevel,
    this.onItemFocusToEdit,
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
    this.onEditSelected,
    this.onRollbackSelected,
    this.coarseEligibleFeatureIds = const {},
    this.pinnedCoarseFeatureIds = const {},
    this.onToggleCoarsePin,
    this.statusLine,
    this.statusUnavailable = false,
    this.flashItemIds = const {},
    this.flashToken = 0,
    this.sheetHeight,
    this.onSheetHeightChanged,
    this.selectionBar = true,
  });

  /// B4: phone portrait. Non-null draws the tree as a bottom sheet across the width at this height (see [AssemblyTreeSheetHeight]); the root
  /// row is the sheet's title instead of a row. A drag on the handle or the header moves it between the heights ([onSheetHeightChanged]: the
  /// host keeps the height), and opening the filter asks for full. Null is the side panel ([docked], [width]).
  final AssemblyTreeSheetHeight? sheetHeight;
  final ValueChanged<AssemblyTreeSheetHeight>? onSheetHeightChanged;

  /// Whether a phone draws the selection bar (B4: one selection surface per layout). False in phone landscape, where the component drawer is
  /// the surface and the tree shows no bar; the picker banner and the multi-select header are not the bar and stay.
  final bool selectionBar;

  final AssemblyTreeModel model;
  final AssemblyTreeController? controller;

  /// Overlay mode slides the panel off to the left when false; docked mode (desktop) is simply not drawn.
  final bool visible;

  /// Desktop layout: fills its parent (the left pane), no slide.
  final bool docked;

  /// Width of the overlay panel (ignored when [docked]).
  final double width;
  final String title;

  /// Edit Alone (B3): the tree is re-rooted on the target, and one strip above it says "Editing <label> [Done]", "in Rover > Mast" (each
  /// crumb leaves Edit Alone at that level, [onEditAloneCrumb]) and "used N x". The strip stands for the root row, which is not drawn.
  final AssemblyEditAloneInfo? editAlone;
  final VoidCallback? onEditAloneDone;
  final ValueChanged<int>? onEditAloneCrumb;

  /// Make Focus (B3): the labels of every level of the focus path, the root first, for the strip above the tree (no strip with fewer than
  /// two: nothing is focused). A crumb above the last jumps there ([onFocusCrumb] gets its depth). The strip stands for the root row, which is
  /// not drawn. The rows outside the focus are dimmed ([AssemblyTreeModel.focusPath]), and a tap on one offers [onFocusHere].
  final List<String> focusCrumbs;
  final ValueChanged<int>? onFocusCrumb;

  /// "Focus here" on a selected row outside the focus: move the focus to that row (the host pops and pushes the focus stack).
  final void Function(AssemblyTreeRow row)? onFocusHere;
  final VoidCallback? onClose;

  /// Tap on any row (the model's `selectedKey` is already set). For a row that can open, the chevron opens it; a group or folder row also
  /// opens on tap.
  final void Function(AssemblyTreeRow row)? onRowTap;
  final void Function(AssemblyTreeRow row)? onRowLongPress;

  /// Edit the row: a double-tap (touch) or a double-click (desktop) on a feature row of the live part, and only there (a tap stays select-only).
  /// Null leaves the gesture out, and with it the delay a single tap would otherwise wait for a second one.
  final void Function(AssemblyTreeRow row)? onRowEdit;

  /// C3 (#13): Edit in context on a read-only feature row (a feature of a part that is not live, spec section 7): a double-tap (touch), a
  /// double-click (desktop) and the phone bar's "Edit in context". The host focuses that part, makes it live and opens the feature. Offered only
  /// on the rows [canEditInContext] accepts (the host knows the feature's type; a row without an edit panel has none). Null leaves it out.
  final void Function(AssemblyTreeRow row)? onRowEditInContext;
  final bool Function(AssemblyTreeRow row)? canEditInContext;

  /// A row that the model's picker says is pickable (or picked, to take it back) was tapped (spec section 13's picker modes; see
  /// [AssemblyTreeModel.setPicker]). A locked row shows its reason in the banner and does not call this.
  final void Function(AssemblyTreeRow row)? onRowPick;

  /// Mouse right click; [position] is global. Not called during a multi-select.
  final void Function(AssemblyTreeRow row, Offset position)? onRowContextMenu;

  /// The desktop hover eye, and a tap on the eye-off icon of a hidden row. Null leaves the eye out.
  final void Function(AssemblyTreeRow row)? onVisibilityToggle;

  /// The sketcher's locked tree (P3): it has no selection bar, so every live feature, body, surface, curve and default-plane row shows its
  /// Hide / Show eye as a button, on a phone too; the selected row (the sketch being edited) and every other row have none. Needs
  /// [onVisibilityToggle].
  final bool lockedEyes;

  /// A part row was opened and its features are not in the model yet: fetch them and call `model.setFeatures` (then
  /// [AssemblyTreeController.refresh]). Also asked for the root, once, when it has features.
  final void Function(List<String> path)? onFeaturesRequested;

  /// C2 (spec section 14): a level's Mates or Patterns folder is open (opened, restored, or listed open by a filter) and the model has no items
  /// for it ([AssemblyTreeModel.hasFolderItems]): read that level's `/mates` and `/component-patterns` and call `model.setFolderItems` (then
  /// [AssemblyTreeController.refresh]). Asked once per folder key until the model has its items, the tree changes, the folder is closed and
  /// opened again (the host's retry of a failed read), or [AssemblyTreeController.forgetFolderRequest].
  final void Function(String folderKey)? onFolderItemsRequested;

  /// C2 (#7, answer 4): a selected mate or pattern row on a level other than the focused one is shown and highlighted, not edited. This names
  /// that level for the strip ("Coincident 1 is in Arm"), or null when the row's level is the focused one (or the row is not an item row);
  /// [onItemFocusToEdit] is the strip's "Focus here to edit" (the host moves the focus there and opens the item as a tap there does).
  final String? Function(AssemblyTreeRow row)? itemOtherLevel;
  final void Function(AssemblyTreeRow row)? onItemFocusToEdit;

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

  /// The bar of a live feature row: Edit, and Roll back to here (the feature becomes the end of the rollback). Hide / Show, Zoom and More are
  /// [onHideSelected], [onZoomSelected] and [onMoreSelected], whichever rows they apply to (the bar says: a feature has Edit, Roll back, Hide,
  /// More; a body, surface or curve Hide, Zoom, More; a default plane Show / Hide).
  final void Function(AssemblyTreeRow row)? onEditSelected;
  final void Function(AssemblyTreeRow row)? onRollbackSelected;

  /// Level-of-detail "pin to coarse": the features it applies to (by feature id), those pinned now, and the toggle. With a toggle set, the
  /// desktop header gets an icon that shows a pin column (off by default, saved in `ViewPreferences`); the same action belongs in the host's
  /// More menu on a phone. A null toggle leaves the column and the icon out.
  final Set<String> coarseEligibleFeatureIds;
  final Set<String> pinnedCoarseFeatureIds;
  final void Function(AssemblyTreeRow row)? onToggleCoarsePin;

  /// The status call failed, or the backend cannot give one: the filter says "status unavailable" instead of "still loading".
  final bool statusUnavailable;

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

  /// C2: Mates / Patterns folders whose items were asked for ([AssemblyTreeView.onFolderItemsRequested]) and are not in the model yet.
  final Set<String> _folderRequested = {};

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

  /// The desktop pin column (P1): saved in `ViewPreferences`, off by default.
  late bool _pinColumn = ViewPreferences.assemblyTreePinColumn;

  /// P2: the scroll offset of each lens (whether the model shows its live part): a lens switch lists other rows (the Assembly lens has no
  /// live rows, so its list can be much shorter and clamps the offset), and switching back puts the list where it was in that lens.
  bool? _seenLiveShown;
  final Map<bool, double> _offsetByLiveShown = {};

  /// The picker the last build saw, and the reason of the locked row last tapped under it (shown in the banner until the picker changes).
  AssemblyPicker? _seenPicker;
  String? _pickNote;

  /// B4: the sheet's height in pixels while a finger drags it (null otherwise), and the heights it snaps to, as the last build laid them out.
  double? _dragHeight;
  double _peekPixels = 0;
  double _halfPixels = 0;
  double _fullPixels = 0;
  final GlobalKey _sheetKey = GlobalKey(debugLabel: 'assembly-tree-sheet');

  /// B5: the pin arithmetic for the rows the last build listed (see [AssemblyTreePinIndex]); null outside the sheet.
  final ValueNotifier<int> _pinTick = ValueNotifier<int>(0);
  bool _pinCheckPending = false;
  List<AssemblyTreeRow>? _pinRows;
  AssemblyTreePinIndex? _pinIndex;

  bool get _sheet => widget.sheetHeight != null && !LayoutModeScope.isDesktop(context);

  /// The host holds the sheet where it is (a tool panel keeps it at peek): no drag, no handle tap, and no filter, which would want full.
  bool get _sheetLocked => _sheet && widget.onSheetHeightChanged == null;

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
      _folderRequested.clear();
      _seenTree = widget.model.tree;
    }
    // Multi-select replaces the header (and with it the filter field): a filter that kept narrowing the rows with nothing to show it would
    // be a trap, so it ends there.
    // It ends on the condition that hides the field: the header being replaced (not only the mode flag). B4 (review): the same when the host
    // starts holding the sheet (a tool panel keeps it at peek, with no list under the field and no toggle to close it).
    final becameLocked = old.sheetHeight != null && old.onSheetHeightChanged != null && widget.sheetHeight != null && widget.onSheetHeightChanged == null;
    if (((old.multiSelectHeader == null && widget.multiSelectHeader != null) || becameLocked) && (_filtering || _filterOpen)) {
      final wasFiltering = _filtering;
      _filterText.clear();
      _filterOpen = false;
      _query = '';
      // The rows are the open keys' from this build on; after it the list goes back to the top and reveals the selected row, as clearing does.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterChanged(wasFiltering);
      });
    }
    _syncModel();
    // B4: from peek (no list) to a height with the list: the list starts at the selected row.
    final sel = widget.model.selectedKey;
    if (old.sheetHeight == AssemblyTreeSheetHeight.peek && widget.sheetHeight != AssemblyTreeSheetHeight.peek && sel != null && sel.isNotEmpty) {
      _scheduleScroll(sel);
    }
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
    _pinTick.dispose();
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
      _folderRequested.clear();
    } else {
      _requested.removeWhere((_, path) => m.hasFeatures(path));
      _folderRequested.removeWhere(m.hasFolderItems);
    }
    final tree = m.tree;
    if (tree != null && tree.featureCount > 0) _askForFeatures(const [], root: true);
    _askForOpenFolders();
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

  /// C2: every Mates / Patterns folder the list shows open without items (opened, restored, revealed) asks for them, once.
  void _askForOpenFolders() {
    final cb = widget.onFolderItemsRequested;
    final m = widget.model;
    if (cb == null || m.tree == null) return;
    for (final r in m.visibleRows()) {
      if (r.open && (r.kind == AssemblyRowKind.matesFolder || r.kind == AssemblyRowKind.patternsFolder)) _askForFolder(r.key);
    }
  }

  void _askForFolder(String key) {
    final cb = widget.onFolderItemsRequested;
    if (cb == null || widget.model.hasFolderItems(key) || !_folderRequested.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _folderRequested.contains(key)) cb(key);
    });
  }

  // While a filter is on the chevrons are inert (spec section 11): what is open is not changed from a list that shows only the matches.
  bool _canToggle(AssemblyTreeRow r) => r.expandable && r.kind != AssemblyRowKind.root && !_filtering;

  void _toggle(AssemblyTreeRow row) {
    if (!_canToggle(row)) return;
    widget.model.toggle(row.key);
    setState(() {});
    if (!row.open) _askForFeatures(row.path);
    // C2: a folder closed forgets that it asked, so opening it again asks again (the host's retry of a failed read).
    if (row.open && (row.kind == AssemblyRowKind.matesFolder || row.kind == AssemblyRowKind.patternsFolder)) _folderRequested.remove(row.key);
    // C2 (review): opening a row can list folders that were open already (restored keys under a collapsed row), and opening a folder lists it.
    if (!row.open) _askForOpenFolders();
  }

  /// Whether a multi-select tap on [row] toggles it: an occurrence row, or a feature, body, surface or curve of the live part.
  bool _multiSelectable(AssemblyTreeRow row) =>
      (row.path != null && row.path!.isNotEmpty) || widget.model.multiSelectKeyOfRow(row.key) != null;

  void _tap(AssemblyTreeRow row) {
    if (widget.isMultiSelectMode) {
      if (_multiSelectable(row)) widget.onMultiSelectToggle?.call(row);
      return;
    }
    if (row.pick != AssemblyPickState.none) {
      if (row.pick == AssemblyPickState.locked) {
        setState(() => _pickNote = row.pickReason);
      } else {
        setState(() => _pickNote = null);
        widget.onRowPick?.call(row);
      }
      return;
    }
    // While a picker is open a row it does not take only opens or closes (a folder, a group); the selection is the picker's business.
    final picking = widget.model.picker != null;
    if (!picking) widget.model.selectedKey = row.key;
    final groupLike =
        row.kind == AssemblyRowKind.group ||
            row.kind == AssemblyRowKind.matesFolder ||
            row.kind == AssemblyRowKind.patternsFolder ||
            row.kind.isLiveFolder;
    if (groupLike && !_filtering) {
      widget.model.toggle(row.key);
      if (!row.open) _askForFeatures(row.path);
      if (!row.open) _askForOpenFolders();
      // C2: a folder closed forgets that it asked, so opening it again asks again (the host's retry of a failed read).
      if (row.open && (row.kind == AssemblyRowKind.matesFolder || row.kind == AssemblyRowKind.patternsFolder)) _folderRequested.remove(row.key);
    }
    setState(() {});
    if (!picking) widget.onRowTap?.call(row);
  }

  void _longPress(AssemblyTreeRow row) {
    if (widget.isMultiSelectMode) {
      if (_multiSelectable(row)) widget.onMultiSelectToggle?.call(row);
      return;
    }
    if (widget.model.picker != null) return; // a picker is its own mode: no menu, no multi-select
    widget.onRowLongPress?.call(row);
  }

  /// A double-tap / double-click: Edit, on a live feature row; Edit in context on a read-only one (C3).
  void _edit(AssemblyTreeRow row) {
    if (widget.isMultiSelectMode || widget.model.picker != null) return;
    // The double-tap wins the gesture, so the single tap never ran: select through the host first (the viewport highlight follows).
    _tap(row);
    if (row.live) {
      widget.onRowEdit?.call(row);
    } else {
      widget.onRowEditInContext?.call(row);
    }
  }

  /// C3: whether [row] is a read-only feature row that offers Edit in context.
  bool _editsInContext(AssemblyTreeRow row) =>
      !row.live &&
      row.kind == AssemblyRowKind.feature &&
      widget.onRowEditInContext != null &&
      (widget.canEditInContext?.call(row) ?? false);

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
    _askForOpenFolders();
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
    // B5: in the sheet the pinned chain covers the top of the list. A row under it (or above) goes to the first slot below the chain it would
    // have there: under its own ancestors, which pin as it arrives.
    final pin = _sheet ? _pinIndex : null;
    final maxPinned = _maxPinned(p.viewportDimension);
    final stack = pin == null ? 0 : pin.pinnedAt(p.pixels, h, maxPinned: maxPinned).length;
    final slots = pin == null || i >= pin.length ? 0 : math.min(pin.levelOf(i), maxPinned);
    double? target;
    if (top < p.pixels + stack * h) {
      target = top - slots * h;
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
      _askForOpenFolders();
      _scheduleScroll(sel);
    }
    setState(() {});
  }

  void _setQuery(String value) {
    final wasFiltering = _filtering;
    setState(() => _query = value);
    _filterChanged(wasFiltering);
  }

  void _filterChanged(bool wasFiltering) {
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
    // B4: the filter needs the rows; in the sheet it opens at full height.
    if (_sheet && widget.sheetHeight != AssemblyTreeSheetHeight.full) widget.onSheetHeightChanged?.call(AssemblyTreeSheetHeight.full);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  /// The strips above the tree that stand for the root row (B3): Edit Alone's, and the focus path's (two crumbs or more; inside Edit Alone, below
  /// its target).
  bool get _editAloneStrip => widget.editAlone != null && widget.onEditAloneDone != null;
  bool get _focusStrip => widget.focusCrumbs.length > 1;

  /// The root row is not drawn while a strip stands for it (rule 5: nothing twice), nor in the phone sheet, whose title it is (B4). The model's
  /// rows are unchanged; the list just starts after it.
  bool get _rootInStrip => _editAloneStrip || _focusStrip || _sheet;

  /// B5 (section 4, section 8 answer 3): on a phone held upright the rows outside the focus are not shown (a filter's matches are: the person
  /// asked for them, and they stay dimmed). What is left of them is the chain of
  /// ancestors the list pins, and the focused branch.
  bool get _dropOutside => _sheet && widget.model.focusPath.isNotEmpty && !_filtering;

  /// The rows the list draws, in the filter's order when one is on.
  List<AssemblyTreeRow> _displayRows(AssemblyFilterResult? filter) {
    final rows = _listedRows(filter);
    if (!_dropOutside) return rows;
    final m = widget.model;
    return [for (final r in rows) if (m.focusRoleOf(r) != AssemblyFocusRole.outside) r];
  }

  /// [_displayRows] before the rows outside the focus are taken out.
  List<AssemblyTreeRow> _listedRows(AssemblyFilterResult? filter) {
    final rows = filter?.rows ?? widget.model.visibleRows();
    return _rootInStrip && rows.isNotEmpty && rows.first.kind == AssemblyRowKind.root ? rows.sublist(1) : rows;
  }

  int _indexOfRow(String key) {
    if (_filtering || _dropOutside) {
      return _displayRows(_filtering ? widget.model.filteredRows(_query) : null).indexWhere((r) => r.key == key);
    }
    final i = widget.model.indexOf(key);
    // The root is the first row of the model's list; with a strip standing for it the list starts after it.
    return i < 0 || !_rootInStrip ? i : i - 1;
  }

  double _rowHeight() => LayoutModeScope.isDesktop(context) ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;

  // --- The phone sheet (B4) ---------------------------------------------------------------------------------------------------------------

  // --- Pinned ancestors (B5) --------------------------------------------------------------------------------------------------------------

  /// The pin arithmetic for [rows], kept while the same list is drawn.
  AssemblyTreePinIndex _pinIndexFor(List<AssemblyTreeRow> rows) {
    final known = _pinIndex;
    if (known != null && identical(_pinRows, rows)) return known;
    _pinRows = rows;
    return _pinIndex = AssemblyTreePinIndex([for (final r in rows) r.depth]);
  }

  /// How many rows the pinned chain may take of a list [viewport] px high: half of it, so the rows under the chain keep room.
  int _maxPinned(double viewport) => math.max(1, (viewport * 0.5 / _rowHeight()).floor());

  /// A tap on a pinned ancestor collapses back to it: it closes, and the list puts it where the chain's next slot is. The selection stays
  /// unless the collapse hid it, and then the ancestor is selected. Not while a filter is on (what is open is not changed from a list of
  /// matches), a picker or a multi-select (the row takes its usual tap), nor on the way down to the focus (closing it would hide the focused
  /// branch): those rows are only selected as a tap does.
  void _pinnedTap(AssemblyTreeRow row) {
    final m = widget.model;
    final role = m.focusRoleOf(row);
    final onTheWayToFocus = role == AssemblyFocusRole.ancestor || role == AssemblyFocusRole.focused;
    if (widget.isMultiSelectMode || m.picker != null || _filtering || onTheWayToFocus || !row.open) {
      _tap(row);
      return;
    }
    m.toggle(row.key);
    final sel = m.selectedKey;
    final hidden = sel != null && sel.isNotEmpty && m.indexOf(sel) < 0;
    if (hidden) m.selectedKey = row.key;
    setState(() {});
    _scheduleScroll(row.key);
    if (hidden) widget.onRowTap?.call(row);
  }

  /// The chain of pinned ancestors over the top of the list (an unbroken stack of rows, outermost first), or nothing.
  Widget _pinnedOverlay(BuildContext context, AssemblyTreePinIndex pin, List<AssemblyTreeRow> rows, double h,
      Widget Function(AssemblyTreeRow r, {bool pinned}) treeRow) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxPinned = _maxPinned(constraints.maxHeight);
      return ListenableBuilder(
        listenable: Listenable.merge([_scroll, _pinTick]),
        builder: (context, _) {
          final offset = _scroll.hasClients ? _scroll.offset : 0.0;
          // A layout that clamps the offset (a branch closed above) does not notify: look again after the frame.
          if (!_pinCheckPending) {
            _pinCheckPending = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pinCheckPending = false;
              if (mounted && _scroll.hasClients && _scroll.offset != offset) _pinTick.value++;
            });
          }
          final chain = pin.pinnedAt(offset, h, maxPinned: maxPinned);
          if (chain.isEmpty) return const SizedBox.shrink();
          final scheme = Theme.of(context).colorScheme;
          // A finger on the chain scrolls the list under it (the chain is above the list, so the list would never see it).
          return Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
            onVerticalDragUpdate: (d) {
              if (!_scroll.hasClients) return;
              final p = _scroll.position;
              _scroll.jumpTo((p.pixels - d.delta.dy).clamp(p.minScrollExtent, p.maxScrollExtent));
            },
            child: Material(
            key: const ValueKey('tree-pinned-chain'),
            color: scheme.surface,
            elevation: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final i in chain)
                  SizedBox(
                    key: ValueKey('tree-pinned:${rows[i].key}'),
                    height: h,
                    child: treeRow(rows[i], pinned: true),
                  ),
              ],
            ),
            ),
            ),
          );
        },
      );
    });
  }

  void _sheetDragStart(DragStartDetails _) {
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    // The frame's height includes the bottom inset (its SafeArea); the drag and the snap heights are the content's.
    final inset = MediaQuery.paddingOf(context).bottom;
    setState(() => _dragHeight = box == null ? _halfPixels : math.max(0.0, box.size.height - inset));
  }

  void _sheetDragUpdate(DragUpdateDetails details) {
    final h = _dragHeight;
    if (h == null) return;
    setState(() => _dragHeight = (h - details.delta.dy).clamp(_peekPixels, math.max(_peekPixels, _fullPixels)));
  }

  /// Snaps to a height: a fling goes one height up or down from where the drag let go; a slow release goes to the nearest.
  void _sheetDragEnd(DragEndDetails details) {
    final h = _dragHeight;
    if (h == null) return;
    setState(() => _dragHeight = null);
    final heights = <AssemblyTreeSheetHeight, double>{
      AssemblyTreeSheetHeight.peek: _peekPixels,
      AssemblyTreeSheetHeight.half: _halfPixels,
      AssemblyTreeSheetHeight.full: _fullPixels,
    };
    final v = details.primaryVelocity ?? 0;
    AssemblyTreeSheetHeight to;
    if (v < -700) {
      to = heights.entries.where((e) => e.value > h + 1).map((e) => e.key).firstOrNull ?? AssemblyTreeSheetHeight.full;
    } else if (v > 700) {
      to = heights.entries.where((e) => e.value < h - 1).map((e) => e.key).lastOrNull ?? AssemblyTreeSheetHeight.peek;
    } else {
      to = heights.entries.reduce((a, b) => (a.value - h).abs() <= (b.value - h).abs() ? a : b).key;
    }
    widget.onSheetHeightChanged?.call(to);
  }

  /// B5 (B4's review): whether a strip under the sheet's header names the root already (Edit Alone's "Editing NAME", the focus path's first
  /// crumb), so the title keeps its own words instead of saying it twice (rule 5). Peek draws no strip, and its title is the root.
  bool get _stripNamesRoot => (_editAloneStrip || _focusStrip) && !(widget.sheetHeight == AssemblyTreeSheetHeight.peek && _dragHeight == null);

  /// The root row's label: the sheet's title.
  String? get _rootLabel {
    final first = widget.model.visibleRows().firstOrNull;
    return first != null && first.kind == AssemblyRowKind.root ? first.label : null;
  }

  /// A tap on the handle: peek opens to half, any other height drops to peek.
  void _sheetHandleTap() => widget.onSheetHeightChanged
      ?.call(widget.sheetHeight == AssemblyTreeSheetHeight.peek ? AssemblyTreeSheetHeight.half : AssemblyTreeSheetHeight.peek);

  /// The handle strip and whatever header is on top of the sheet: both take the vertical drag.
  Widget _sheetDragArea(BuildContext context, Widget header) {
    final scheme = Theme.of(context).colorScheme;
    final locked = _sheetLocked;
    return GestureDetector(
      key: const ValueKey('tree-sheet-drag'),
      behavior: HitTestBehavior.translucent,
      // The sheet follows the finger from where it went down (the slop is not lost).
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: locked ? null : _sheetDragStart,
      onVerticalDragUpdate: locked ? null : _sheetDragUpdate,
      onVerticalDragEnd: locked ? null : _sheetDragEnd,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: const ValueKey('tree-sheet-handle'),
            behavior: HitTestBehavior.opaque,
            onTap: locked ? null : _sheetHandleTap,
            child: SizedBox(
              height: kAssemblyTreeSheetHandleHeight,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: scheme.outline.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
          ),
          header,
        ],
      ),
    );
  }

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
    final rows = _displayRows(filter);
    // A filter that listed only the root (which a strip may have taken out of the list): nothing matches.
    final noMatch = filter != null && filter.unknown.isEmpty && (_rootInStrip ? rows.isEmpty && model.tree != null : rows.length == 1);
    final h = desktop ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;
    final colours = _rigidColours();
    final scheme = Theme.of(context).colorScheme;
    if (_pendingScrollKey != null) WidgetsBinding.instance.addPostFrameCallback((_) => _flushScroll());

    final liveShown = model.livePartShown;
    final seenLiveShown = _seenLiveShown;
    if (seenLiveShown != null && liveShown != seenLiveShown) {
      // Before this build's layout, so the offset is the old lens's, not one the new rows clamped.
      if (_scroll.hasClients) _offsetByLiveShown[seenLiveShown] = _scroll.offset;
      final back = _offsetByLiveShown[liveShown];
      if (back != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || model.livePartShown != liveShown) return;
          final p = _scroll.position;
          _scroll.jumpTo(back.clamp(p.minScrollExtent, p.maxScrollExtent));
        });
      }
    }
    _seenLiveShown = liveShown;

    final selectedIndex = model.selectedKey == null ? -1 : _indexOfRow(model.selectedKey!);
    // B5: a selected row outside the focus is not listed in the sheet, but it is still the selection: its bar and "Focus here" stay.
    final selectedRow = selectedIndex >= 0
        ? rows[selectedIndex]
        : _dropOutside && model.selectedKey != null
            ? _listedRows(filter).where((r) => r.key == model.selectedKey).firstOrNull
            : null;
    final picker = model.picker;
    if (!identical(picker, _seenPicker)) {
      _seenPicker = picker;
      _pickNote = null;
    }
    final bar = picker != null || widget.isMultiSelectMode || desktop || !widget.selectionBar || selectedRow == null ? null : _barButtons(selectedRow);
    final showBar = bar != null && bar.isNotEmpty;
    final pinColumn = desktop && _pinColumn && widget.onToggleCoarsePin != null;
    // Multi-select ticks by row key, but a plane feature listed in the Planes folder and in the build order is one feature: both rows tick.
    final Set<String?> selectedMs = widget.isMultiSelectMode
        ? {
            for (final k in widget.selectedKeys)
              if (model.multiSelectKeyOfRow(k) != null) model.multiSelectKeyOfRow(k)!
          }
        : const <String>{};

    // B5: the pinned chain is worked out from the rows this build lists (the sheet's list only).
    final pin = _sheet && !(widget.sheetHeight == AssemblyTreeSheetHeight.peek && _dragHeight == null) ? _pinIndexFor(rows) : null;

    Widget treeRow(AssemblyTreeRow r, {bool pinned = false}) {
      final flashing = r.kind == AssemblyRowKind.mate && r.itemId != null && widget.flashItemIds.contains(r.itemId);
      Widget rowWidget(double pulse) => _TreeRow(
            key: ValueKey('tree-row:${r.key}'),
            pulse: pulse,
            indentShift: _sheet ? 1 : 0,
            indentStep: _sheet ? kAssemblyTreeSheetIndentStep : (desktop ? 14.0 : 16.0),
            maxIndentLevels: _sheet ? kAssemblyTreeSheetMaxIndentLevels : null,
            row: r,
            height: h,
            desktop: desktop,
            selected: widget.isMultiSelectMode
                ? widget.selectedKeys.contains(r.key) || selectedMs.contains(model.multiSelectKeyOfRow(r.key))
                : r.key == model.selectedKey,
            multiSelect: widget.isMultiSelectMode,
            selectable: _multiSelectable(r),
            pinState: pinColumn && r.featureId != null && widget.coarseEligibleFeatureIds.contains(r.featureId)
                ? widget.pinnedCoarseFeatureIds.contains(r.featureId)
                : null,
            onPin: () => widget.onToggleCoarsePin?.call(r),
            pickMulti: picker?.multi ?? false,
            onDoubleTap: picker == null &&
                    !widget.isMultiSelectMode &&
                    ((widget.onRowEdit != null && r.isLiveFeature && featureTypeHasEditPanel(r.type ?? '')) || _editsInContext(r))
                ? () => _edit(r)
                : null,
            bracket: _bracketFor(r, colours),
            focusRole: model.focusRoleOf(r),
            canToggle: _canToggle(r),
            showEye: widget.onVisibilityToggle != null,
            lockedEye: widget.lockedEyes && widget.onVisibilityToggle != null
                ? r.live && !r.kind.isLiveFolder && r.key != model.selectedKey
                : null,
            onToggle: () => _toggle(r),
            onTap: pinned ? () => _pinnedTap(r) : () => _tap(r),
            onLongPress: () => _longPress(r),
            onContextMenu: widget.isMultiSelectMode || picker != null || widget.onRowContextMenu == null
                ? null
                : (at) => widget.onRowContextMenu!(r, at),
            onEye: () => widget.onVisibilityToggle?.call(r),
          );
      // Only a row that is flashing listens to the animation; every other row is built once.
      return flashing
          ? AnimatedBuilder(animation: _flash, builder: (context, _) => rowWidget(_flashPulse))
          : rowWidget(0);
    }

    final sheet = _sheet;
    final header = widget.multiSelectHeader ?? _header(context, desktop);
    // B4: peek is the header and the selected row with its bar (or the picker's banner) and nothing else.
    final peek = sheet && widget.sheetHeight == AssemblyTreeSheetHeight.peek && _dragHeight == null;
    if (peek) {
      return _sheetFrame(
        context,
        Column(
          key: const ValueKey('tree-sheet-peek'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetDragArea(context, header),
            if (picker != null && !widget.isMultiSelectMode) _pickerBanner(context, picker),
            // B5: under Focus a selected row outside it (a viewport pick) offers to move the focus there at peek too.
            if (_focusHereRow(selectedRow) case final outside?) _focusHereBar(context, outside),
            if (_otherLevelOf(selectedRow) case final level?) _focusToEditBar(context, selectedRow!, level),
            if (selectedRow != null && !widget.isMultiSelectMode) SizedBox(height: h, child: treeRow(selectedRow)),
            if (showBar) _selectionBar(context, selectedRow!, bar),
          ],
        ),
      );
    }

    // The notes, strips and banners between the header and the rows.
    final List<Widget> chrome = <Widget>[
        if (filter != null) _filterNotes(context, filter),
        // Not while the floating tree is closed: the pill at the top of the viewport is the way out then.
        if (_editAloneStrip && (widget.visible || widget.docked))
          EditAloneStrip(
            label: widget.editAlone!.label,
            onDone: widget.onEditAloneDone!,
            inLabels: widget.editAlone!.inLabels,
            onCrumb: widget.onEditAloneCrumb,
            usedCount: widget.editAlone!.usedCount,
          ),
        if (_focusStrip) FocusBreadcrumbStrip(labels: widget.focusCrumbs, onCrumb: (i) => widget.onFocusCrumb?.call(i)),
        if (_focusHereRow(selectedRow) case final outside?) _focusHereBar(context, outside),
        if (_otherLevelOf(selectedRow) case final level?) _focusToEditBar(context, selectedRow!, level),
        if (picker != null && !widget.isMultiSelectMode) _pickerBanner(context, picker),
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
    ];

    final body = Material(
      color: scheme.surface,
      // In the sheet the frame ([_sheetFrame]) carries the elevation and the rounded top.
      elevation: widget.docked || sheet ? 0 : 6,
      child: LayoutBuilder(builder: (context, bodyConstraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (sheet) _sheetDragArea(context, header) else header,
          // Desktop: the filter box is always there; a phone has the field in the header while it is open.
          if (widget.multiSelectHeader == null && desktop) _desktopFilterRow(context),
          if (sheet)
            // B5 (B4's review): the strips and banners are the part of the column that can be taller than the sheet is while a drag from peek
            // has hardly begun. In the sheet they get what is left over (a bar's worth kept back), clipped, so nothing overflows.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: math.max(0.0, bodyConstraints.maxHeight - kAssemblyTreeSheetHandleHeight - 48 - 100)),
              child: ClipRect(
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: chrome),
                ),
              ),
            )
          else
            ...chrome,
          Expanded(
            child: noMatch
                ? Center(
                    child: Text('Nothing matches',
                        key: const ValueKey('tree-filter-empty'), style: TextStyle(color: scheme.onSurfaceVariant)))
                : rows.isEmpty
                ? const Center(child: Text('Nothing to show yet'))
                : Stack(
                        children: [
                          ListView.builder(
                            key: const ValueKey('assembly-tree-list'),
                            controller: _scroll,
                            itemExtent: h,
                            itemCount: rows.length,
                            itemBuilder: (context, i) => treeRow(rows[i]),
                          ),
                          if (pin != null) Positioned.fill(child: _pinnedOverlay(context, pin, rows, h, treeRow)),
                        ],
                      ),
          ),
          if (showBar) _selectionBar(context, selectedRow!, bar),
        ],
      )),
    );

    if (sheet) return _sheetFrame(context, body);
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

  /// B4: the sheet across the bottom of the space it is given: [content] at peek (its own height), else at half or full height (or the height a
  /// drag holds it at). Slid down out of sight while not [AssemblyTreeView.visible]. Records the heights the drag snaps to.
  Widget _sheetFrame(BuildContext context, Widget content) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : MediaQuery.sizeOf(context).height;
      final desktop = LayoutModeScope.isDesktop(context);
      final rowH = desktop ? kAssemblyTreeRowHeightDesktop : kAssemblyTreeRowHeightPhone;
      // Peek's height for the drag's snap: the handle, the header and, with a selection, its row and the bar (about 56 dp).
      final selected = widget.model.selectedKey != null && widget.model.selectedKey!.isNotEmpty;
      _peekPixels = math.min(maxH, kAssemblyTreeSheetHandleHeight + 48 + (selected ? rowH + 56 : 0));
      _fullPixels = math.max(_peekPixels, maxH - kAssemblyTreeSheetTopGap);
      _halfPixels = (maxH * 0.5).clamp(_peekPixels, _fullPixels);
      final height = _dragHeight ??
          switch (widget.sheetHeight) {
            AssemblyTreeSheetHeight.half => _halfPixels,
            AssemblyTreeSheetHeight.full => _fullPixels,
            _ => null,
          };
      final sheet = Material(
        key: _sheetKey,
        color: scheme.surface,
        elevation: 8,
        clipBehavior: Clip.antiAlias,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        // The bottom inset (a home indicator, gesture navigation): the last row or the bar is not drawn under it.
        child: SafeArea(top: false, child: height == null ? content : SizedBox(height: height, child: content)),
      );
      return Align(
        alignment: Alignment.bottomCenter,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: AnimatedSlide(
            key: const ValueKey('tree-sheet'),
            duration: const Duration(milliseconds: 180),
            offset: widget.visible ? Offset.zero : const Offset(0, 1),
            child: SizedBox(width: constraints.maxWidth, child: sheet),
          ),
        ),
      );
    });
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
              // B4: in the sheet the root row is the title (section 5: one level of indent saved).
              child: Text(_sheet && !_stripNamesRoot ? (_rootLabel ?? widget.title) : widget.title,
                  key: const ValueKey('tree-title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (!desktop && !_sheetLocked)
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
            // The pin-to-coarse column (desktop, off by default).
            if (desktop && widget.onToggleCoarsePin != null)
              button(
                key: 'tree-pin-column-toggle',
                tooltip: _pinColumn ? 'Pin column: on' : 'Pin column: off',
                icon: Icons.blur_off,
                colour: scheme.onSurfaceVariant,
                selectedIcon: Icons.blur_on,
                selected: _pinColumn,
                onPressed: () {
                  final v = !_pinColumn;
                  setState(() => _pinColumn = v);
                  unawaited(ViewPreferences.setAssemblyTreePinColumn(v));
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

  static const String _filterHint = 'Name, or :errors :missing :mates ...';

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
      if ((words.contains(':errors') || words.contains(':warnings')) && (!model.statusIncluded || model.statusIncomplete))
        widget.statusUnavailable || model.statusIncomplete
            ? 'Status unavailable: :errors and :warnings find only missing files and cycles'
            : 'Status is still loading: :errors and :warnings find only missing files and cycles for now',
      if (filter.featuresNotRead) 'Features are searched only in parts you have opened',
      // C1-1: only folders whose items were read are searched (spec section 11's hint).
      if (filter.itemsNotRead) 'Mates and patterns are searched only in folders you have opened',
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

  /// B3: a selected row outside the focus offers to move the focus there (a dimmed row is context, so a tap selects it and says so here).
  AssemblyTreeRow? _focusHereRow(AssemblyTreeRow? selected) {
    if (selected == null || widget.onFocusHere == null || widget.isMultiSelectMode || widget.model.picker != null) return null;
    if (selected.path == null || selected.path!.isEmpty) return null;
    return widget.model.focusRoleOf(selected) == AssemblyFocusRole.outside ? selected : null;
  }

  /// C2: a selected mate or pattern row on another level than the focused one: the level's name for [_focusToEditBar], else null.
  String? _otherLevelOf(AssemblyTreeRow? selected) {
    if (selected == null || selected.itemId == null || widget.onItemFocusToEdit == null || widget.isMultiSelectMode) return null;
    if (widget.model.picker != null) return null;
    return widget.itemOtherLevel?.call(selected);
  }

  Widget _focusToEditBar(BuildContext context, AssemblyTreeRow row, String level) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('tree-focus-to-edit-bar'),
      color: scheme.tertiaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text('${row.label} is in $level',
                  key: const ValueKey('tree-focus-to-edit-note'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
            TextButton(
                key: const ValueKey('tree-focus-to-edit'), onPressed: () => widget.onItemFocusToEdit!(row), child: const Text('Focus here to edit')),
          ],
        ),
      ),
    );
  }

  Widget _focusHereBar(BuildContext context, AssemblyTreeRow row) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text('${row.label} is outside the focus',
                  key: const ValueKey('tree-focus-here-note'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
            TextButton(key: const ValueKey('tree-focus-here'), onPressed: () => widget.onFocusHere!(row), child: const Text('Focus here')),
          ],
        ),
      ),
    );
  }

  /// The buttons of the phone bar for [row]: an occurrence row's (Hide, Isolate, Zoom, Focus, Alone, More), or for the live part's rows a
  /// feature's (Edit, Roll back to here, Hide / Show, More), a body, surface or curve's (Hide / Show, Zoom, More) and a default plane's
  /// (Show / Hide). A button whose callback is null is left out; null means the row has no bar.
  List<_BarButton>? _barButtons(AssemblyTreeRow row) {
    final hide = _BarButton('tree-bar-hide', row.hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, row.hidden ? 'Show' : 'Hide',
        widget.onHideSelected);
    final zoom = _BarButton('tree-bar-zoom', Icons.zoom_out_map, 'Zoom', widget.onZoomSelected);
    final more = _BarButton('tree-bar-more', Icons.more_horiz, 'More', widget.onMoreSelected);
    List<_BarButton> live(List<_BarButton> all) => [
          for (final b in all)
            if (b.onTap != null) b
        ];
    if (row.path != null && row.path!.isNotEmpty) {
      return live([
        hide,
        _BarButton('tree-bar-isolate', Icons.filter_center_focus, 'Isolate', widget.onIsolateSelected),
        zoom,
        _BarButton('tree-bar-focus', Icons.center_focus_strong_outlined, 'Focus', widget.onFocusSelected),
        _BarButton('tree-bar-alone', Icons.edit_outlined, 'Alone', widget.onAloneSelected),
        more,
      ]);
    }
    // C3: a read-only feature row (a part that is not live) has one action, Edit in context.
    if (_editsInContext(row)) {
      return [_BarButton('tree-bar-edit-in-context', Icons.edit_outlined, 'Edit in context', widget.onRowEditInContext)];
    }
    if (!row.live) return null;
    switch (row.kind) {
      case AssemblyRowKind.feature:
        return live([
          // An import or a Fill Surface has no edit panel: no Edit for it.
          _BarButton('tree-bar-edit', Icons.edit_outlined, 'Edit', featureTypeHasEditPanel(row.type ?? '') ? widget.onEditSelected : null),
          _BarButton('tree-bar-rollback', Icons.history, 'Roll back to here', widget.onRollbackSelected),
          hide,
          more,
        ]);
      case AssemblyRowKind.body:
      case AssemblyRowKind.surface:
      case AssemblyRowKind.curve:
        return live([hide, zoom, more]);
      case AssemblyRowKind.defaultPlane:
        return live([hide]);
      default:
        return null;
    }
  }

  /// What a live feature's state says, for the bar and the row's tooltip; null when it has nothing to say.
  static String? _stateText(AssemblyTreeRow row) => !row.live
      ? null
      : switch (row.state) {
        AssemblyRowState.lostReference => row.lostReason == null || row.lostReason!.isEmpty ? 'Lost reference' : 'Lost reference: ${row.lostReason}',
        AssemblyRowState.movedReference => 'Reference may have moved - open to check',
        AssemblyRowState.pendingDetail => 'Loading full detail...',
        AssemblyRowState.rolledBack => 'After the rollback point',
        _ => null,
      };

  Widget _selectionBar(BuildContext context, AssemblyTreeRow row, List<_BarButton> buttons) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AiPalette.of(context);
    final text = _stateText(row);
    final Color textColour = switch (row.state) {
      AssemblyRowState.lostReference => palette.danger,
      AssemblyRowState.movedReference => palette.warning,
      _ => scheme.onSurfaceVariant,
    };
    Widget button(_BarButton b) => Expanded(
          child: InkWell(
            key: ValueKey(b.key),
            onTap: () => b.onTap!(row),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(b.icon, size: 20),
                  Text(b.label, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        );

    return Material(
      key: const ValueKey('tree-selection-bar'),
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (text != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
                child: Text(text,
                    key: const ValueKey('tree-bar-reason'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: textColour)),
              ),
            Row(children: [for (final b in buttons) button(b)]),
          ],
        ),
      ),
    );
  }

  /// A picker's banner, in the bar's place: what is being picked, how many are ticked, and why the last locked row tapped cannot be (a lock with
  /// no banner of its own shows only that reason, once a row is tapped).
  Widget _pickerBanner(BuildContext context, AssemblyPicker picker) {
    final scheme = Theme.of(context).colorScheme;
    final banner = picker.banner;
    if (banner == null && _pickNote == null) return const SizedBox.shrink();
    final count = picker.multi ? picker.picked.length : 0;
    return Container(
      key: const ValueKey('tree-picker-banner'),
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (banner != null)
            Text(count == 0 ? banner : '$banner - $count selected',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          if (_pickNote != null)
            Text(_pickNote!,
                key: const ValueKey('tree-picker-reason'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.error, fontSize: 12)),
        ],
      ),
    );
  }
}

/// One button of the phone bar.
class _BarButton {
  final String key;
  final IconData icon;
  final String label;
  final void Function(AssemblyTreeRow row)? onTap;
  const _BarButton(this.key, this.icon, this.label, this.onTap);
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
    required this.selectable,
    required this.pinState,
    required this.onPin,
    required this.onDoubleTap,
    required this.pickMulti,
    required this.bracket,
    this.focusRole = AssemblyFocusRole.none,
    required this.canToggle,
    required this.showEye,
    this.lockedEye,
    required this.onToggle,
    required this.onTap,
    required this.onLongPress,
    required this.onContextMenu,
    required this.onEye,
    this.pulse = 0,
    this.indentShift = 0,
    this.indentStep,
    this.maxIndentLevels,
  });

  /// dp per level of indent (null: 14 on desktop, 16 on a phone), and how many levels it grows to (null: no cap). B5: the sheet's are 12 and 4.
  final double? indentStep;
  final int? maxIndentLevels;

  /// Levels of indent taken off every row: 1 in the phone sheet, whose title is the root row (B4, section 5: one level saved).
  final int indentShift;

  /// 0..1, the flash of a mate row (see [AssemblyTreeView.flashItemIds]).
  final double pulse;
  final AssemblyTreeRow row;
  final double height;
  final bool desktop;
  final bool selected;
  final bool multiSelect;

  /// A multi-select tap toggles this row (it draws a tick circle instead of its icon).
  final bool selectable;

  /// The desktop pin column: null draws nothing, else whether this feature is pinned to coarse.
  final bool? pinState;
  final VoidCallback onPin;

  /// Edit (double-tap, double-click); null leaves the gesture out.
  final VoidCallback? onDoubleTap;

  /// The model's picker ticks several rows: a pickable row draws an empty tick circle.
  final bool pickMulti;
  final Color? bracket;

  /// B3: a row outside the focus is dimmed (as the viewport fades it); the focused row and the rows below it carry the rail.
  final AssemblyFocusRole focusRole;
  final bool canToggle;
  final bool showEye;

  /// [AssemblyTreeView.lockedEyes]: true draws the eye as a button whatever the hover or the platform, false never offers one; null follows
  /// [showEye].
  final bool? lockedEye;
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
        AssemblyRowKind.bodiesFolder ||
        AssemblyRowKind.planesFolder ||
        AssemblyRowKind.surfacesFolder ||
        AssemblyRowKind.curvesFolder =>
          Icons.folder_outlined,
        // Drawn with the feature SVGs ([_liveIcon]); these are never used.
        AssemblyRowKind.body || AssemblyRowKind.surface || AssemblyRowKind.curve || AssemblyRowKind.defaultPlane => Icons.tune,
        AssemblyRowKind.feature => Icons.tune,
        AssemblyRowKind.matesFolder => Icons.link,
        AssemblyRowKind.patternsFolder => Icons.grid_view,
        AssemblyRowKind.mate => Icons.link,
        AssemblyRowKind.pattern => Icons.grid_view_outlined,
      };

  /// The levels of indent of [r]: its depth below the title, to the cap when there is one (B5).
  int _indentLevels(AssemblyTreeRow r) {
    final levels = math.max(0, r.depth - widget.indentShift);
    final cap = widget.maxIndentLevels;
    return cap == null ? levels : math.min(levels, cap);
  }

  /// The icon of a row of the live part: the existing feature glyphs, a folder, a body, a plane.
  Widget _liveIcon(AssemblyTreeRow r, double size, Color colour) {
    switch (r.kind) {
      case AssemblyRowKind.bodiesFolder:
      case AssemblyRowKind.planesFolder:
      case AssemblyRowKind.surfacesFolder:
      case AssemblyRowKind.curvesFolder:
        return Icon(Icons.folder_outlined, size: size, color: colour);
      case AssemblyRowKind.body:
        return SvgIcon('assets/icons/viewport/selection_body.svg', size: size, color: colour);
      case AssemblyRowKind.surface:
        return SvgIcon(assemblyTreeFeatureAsset('surface'), size: size, color: colour);
      case AssemblyRowKind.curve:
        return SvgIcon(assemblyTreeFeatureAsset('curve'), size: size, color: colour);
      case AssemblyRowKind.defaultPlane:
        return SvgIcon(assemblyTreeFeatureAsset('create_plane'), size: size, color: colour);
      case AssemblyRowKind.feature:
        return SvgIcon(assemblyTreeFeatureAsset(r.type ?? ''), size: size, color: colour);
      default:
        return Icon(_kindIcon(r.kind), size: size, color: colour);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final scheme = Theme.of(context).colorScheme;
    final desktop = widget.desktop;
    final iconSize = desktop ? 16.0 : 22.0;
    final isOccurrence = r.path != null && r.path!.isNotEmpty;
    final lockedEye = widget.lockedEye;
    final canEye = lockedEye ?? (widget.showEye && (isOccurrence || (r.live && !r.kind.isLiveFolder)));
    // A group row never shows one: it has nothing to toggle (its members show their own).
    final eyeSlot = lockedEye == true
        ? Tooltip(
            message: r.hidden ? 'Show' : 'Hide',
            child: Icon(r.hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                key: ValueKey(r.hidden ? 'tree-eye-off:${r.key}' : 'tree-eye:${r.key}'), size: iconSize, color: scheme.onSurfaceVariant),
          )
        : r.hidden && r.kind != AssemblyRowKind.group && !r.kind.isLiveFolder
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

    final dim = r.suppressed || r.state == AssemblyRowState.rolledBack || r.pick == AssemblyPickState.locked
        ? 0.45
        : (r.hidden ? 0.65 : 1.0);
    final isItem = r.itemId != null && (r.kind == AssemblyRowKind.mate || r.kind == AssemblyRowKind.pattern);
    final palette = AiPalette.of(context);
    // C2: an item row's colour is its state (spec section 14): red lost / broken, amber held / near; a followed reference's info line is the
    // primary colour on its icon and note only.
    final itemState = isItem ? r.itemState : null;
    final bool itemProblem = itemState != null && (itemState.isError || itemState.isWarning);
    final bool itemInfo = isItem && !itemProblem && r.followed;
    final Color? toneColour = itemState == null
        ? null
        : itemState.isError
            ? scheme.error
            : itemState.isWarning
                ? palette.warning
                : itemInfo
                    ? scheme.primary
                    : null;
    final labelStyle = TextStyle(
      fontSize: desktop ? 13 : 15,
      fontWeight: r.kind == AssemblyRowKind.root || r.match ? FontWeight.w600 : FontWeight.normal,
      // A mate or pattern a pattern edit or the backend suppressed is dimmed, not struck through (it is not a part).
      fontStyle: r.suppressed && !isItem ? FontStyle.italic : FontStyle.normal,
      decoration: r.suppressed && !isItem ? TextDecoration.lineThrough : null,
      // Only a problem colours the label (an info line colours its icon and note, not the name).
      color: r.state == AssemblyRowState.missing ? palette.danger : (itemInfo ? null : toneColour),
    );
    final noteStyle = TextStyle(fontSize: desktop ? 11 : 12, color: toneColour ?? scheme.onSurfaceVariant);
    final IconData kindIcon = isItem && r.kind == AssemblyRowKind.mate && itemProblem
        ? Icons.warning_amber_rounded
        : itemInfo
            ? Icons.info_outline
            : _kindIcon(r.kind);

    Widget content = Row(
      children: [
        SizedBox(width: 6 + _indentLevels(r) * (widget.indentStep ?? (desktop ? 14.0 : 16.0))),
        chevron,
        Opacity(
          opacity: dim,
          child: widget.multiSelect && widget.selectable
              ? Icon(widget.selected ? Icons.check_circle : Icons.circle_outlined, size: iconSize, color: scheme.primary)
              : r.pick == AssemblyPickState.picked
                  ? Icon(Icons.check_circle, key: ValueKey('tree-picked:${r.key}'), size: iconSize, color: scheme.primary)
                  : r.pick == AssemblyPickState.pickable && r.live && widget.pickMulti
                      ? Icon(Icons.circle_outlined, size: iconSize, color: scheme.primary)
                      : r.live
                          ? _liveIcon(r, iconSize, scheme.primary)
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
        if (r.count != null && (r.kind == AssemblyRowKind.matesFolder || r.kind == AssemblyRowKind.patternsFolder || r.kind.isLiveFolder))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('${r.count}', style: TextStyle(fontSize: desktop ? 12 : 13, color: scheme.onSurfaceVariant)),
          ),
        if (r.bubble != null && !r.open) _bubble(context, r.bubble!),
        if (eyeSlot != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Desktop: the hover eye and the eye-off toggle. Phone: only the eye-off of a hidden row (it is state, not a button). Never in multi-select.
            onTap: canEye && !widget.multiSelect && (desktop || r.hidden || lockedEye == true) ? widget.onEye : null,
            child: SizedBox(width: desktop ? 26 : 40, height: widget.height, child: Center(child: eyeSlot)),
          ),
        if (widget.pinState != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPin,
            child: SizedBox(
              width: 26,
              height: widget.height,
              child: Center(
                child: Tooltip(
                  message: widget.pinState! ? 'Always showing simplified geometry' : 'Always show simplified geometry',
                  child: Icon(widget.pinState! ? Icons.blur_on : Icons.blur_off,
                      key: ValueKey('tree-pin:${r.key}'), size: iconSize, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        Padding(padding: const EdgeInsets.only(left: 6, right: 8), child: _stateSlot(context, r, iconSize)),
      ],
    );

    if (widget.focusRole == AssemblyFocusRole.outside) {
      content = Opacity(key: ValueKey('tree-dimmed:${r.key}'), opacity: 0.5, child: content);
    }
    final railed = widget.focusRole == AssemblyFocusRole.focused || widget.focusRole == AssemblyFocusRole.inside;
    if (railed) {
      // The assembly lens' colour (the focus is the assembly lens' working level).
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(key: ValueKey('tree-focus-rail:${r.key}'), color: assemblyLensAccentColor(scheme, AssemblyLens.assembly)),
          ),
        ],
      );
    }
    if (widget.bracket != null) {
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: railed ? 4 : 0,
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
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: SizedBox(height: widget.height, child: content),
      ),
    );
    final tip = r.pick == AssemblyPickState.locked ? r.pickReason : _AssemblyTreeViewState._stateText(r);
    if (tip != null) tile = Tooltip(message: tip, triggerMode: TooltipTriggerMode.manual, child: tile);
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
    if (r.live) return _liveStateSlot(context, r, size);
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
      // The live part's states are drawn by [_liveStateSlot]; an occurrence row never has one.
      AssemblyRowState.lostReference ||
      AssemblyRowState.movedReference ||
      AssemblyRowState.pendingDetail ||
      AssemblyRowState.rolledBack ||
      AssemblyRowState.hidden ||
      AssemblyRowState.none =>
        (null, null, null),
    };
    if (look.$3 == null) return const SizedBox.shrink();
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

  /// The live part's one state slot (spec section 13): lost reference (red), moved reference (amber), waiting for detail, after the rollback
  /// point. `hidden` is the eye-off the row already draws; a folder, a plain row and a hidden row have no icon here.
  Widget _liveStateSlot(BuildContext context, AssemblyTreeRow r, double size) {
    final palette = AiPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final key = ValueKey('tree-state:${r.key}:${r.state.wire}');
    final text = _AssemblyTreeViewState._stateText(r);
    final (IconData?, Color?) look = switch (r.state) {
      AssemblyRowState.lostReference => (Icons.warning_rounded, palette.danger),
      AssemblyRowState.movedReference => (Icons.help_rounded, palette.warning),
      AssemblyRowState.pendingDetail => (Icons.hourglass_bottom, scheme.primary),
      AssemblyRowState.rolledBack => (Icons.history, scheme.onSurfaceVariant),
      _ => (null, null),
    };
    if (look.$1 == null) return const SizedBox.shrink();
    return Tooltip(message: text ?? '', child: Icon(look.$1, key: key, size: size - 2, color: look.$2));
  }

  int? _dof(BuildContext context, AssemblyTreeRow r) {
    final view = context.findAncestorStateOfType<_AssemblyTreeViewState>();
    final p = r.path;
    if (view == null || p == null || p.isEmpty) return null;
    return view.widget.model.nodeAtPath(p)?.constraint?.dof;
  }
}
