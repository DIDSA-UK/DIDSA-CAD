import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop input D3 (`docs/desktop-input-scope.md` R3): the app's keyboard
/// shortcuts - one table ([kCadShortcuts]) that the screens bind
/// ([CadShortcutScope]), the shortcut sheet lists ([showCadShortcutSheet])
/// and tooltips quote ([withShortcut]). SOLIDWORKS is the template (view
/// keys, F, Z / Shift+Z, arrows, Ctrl+B-style chords); the Meta key and
/// Shift/Ctrl+Space are avoided (DeX and Samsung keyboards keep them).

enum CadShortcut {
  cancel,
  confirm,
  delete,
  undo,
  redo,
  save,
  saveAs,
  open,
  newDocument,
  selectAll,
  zoomToFit,
  viewFront,
  viewBack,
  viewLeft,
  viewRight,
  viewTop,
  viewBottom,
  viewIsometric,
  zoomIn,
  zoomOut,
  rotateLeft,
  rotateRight,
  rotateUp,
  rotateDown,
  rotate90Left,
  rotate90Right,
  rotate90Up,
  rotate90Down,
  panLeft,
  panRight,
  panUp,
  panDown,
  togglePerspective,
  help,
  sketchLine,
  sketchCircle,
  sketchArc,
  sketchRectangle,
  sketchDimension,
  sketchTrim,
  sketchConstruction,
}

/// One row of [kCadShortcuts].
class CadShortcutInfo {
  /// What it does, as the shortcut sheet says it.
  final String label;

  /// The keys as shown to the user ("Ctrl+S").
  final String keys;

  /// The shortcut sheet's section.
  final String group;

  final List<ShortcutActivator> activators;

  /// A key a focused text field needs for itself (letters, Enter, Delete,
  /// Backspace, arrows, Ctrl+A/Z/Y): while one has focus the shortcut steps
  /// aside and the field gets the key.
  final bool yieldsToText;

  const CadShortcutInfo({
    required this.label,
    required this.keys,
    required this.group,
    required this.activators,
    this.yieldsToText = true,
  });
}

const _general = 'General';
const _file = 'File';
const _view = 'View';
const _sketch = 'Sketch';

SingleActivator _key(LogicalKeyboardKey key, {bool control = false, bool shift = false, bool repeats = false}) =>
    SingleActivator(key, control: control, shift: shift, includeRepeats: repeats);

final Map<CadShortcut, CadShortcutInfo> kCadShortcuts = {
  CadShortcut.cancel: CadShortcutInfo(
    label: 'Cancel the tool, or clear the selection',
    keys: 'Esc',
    group: _general,
    activators: [_key(LogicalKeyboardKey.escape)],
    // Handled specially: in a text field Esc leaves the field.
    yieldsToText: false,
  ),
  CadShortcut.confirm: CadShortcutInfo(
    label: 'Confirm the tool',
    keys: 'Enter',
    group: _general,
    activators: [_key(LogicalKeyboardKey.enter), _key(LogicalKeyboardKey.numpadEnter)],
  ),
  CadShortcut.delete: CadShortcutInfo(
    label: 'Delete the selection',
    keys: 'Delete',
    group: _general,
    activators: [_key(LogicalKeyboardKey.delete), _key(LogicalKeyboardKey.backspace)],
  ),
  CadShortcut.undo: CadShortcutInfo(
    label: 'Undo',
    keys: 'Ctrl+Z',
    group: _general,
    activators: [_key(LogicalKeyboardKey.keyZ, control: true)],
  ),
  CadShortcut.redo: CadShortcutInfo(
    label: 'Redo',
    keys: 'Ctrl+Y',
    group: _general,
    activators: [_key(LogicalKeyboardKey.keyY, control: true), _key(LogicalKeyboardKey.keyZ, control: true, shift: true)],
  ),
  CadShortcut.selectAll: CadShortcutInfo(
    label: 'Select all',
    keys: 'Ctrl+A',
    group: _general,
    activators: [_key(LogicalKeyboardKey.keyA, control: true)],
  ),
  CadShortcut.help: CadShortcutInfo(
    label: 'Keyboard shortcuts',
    keys: '? or F1',
    group: _general,
    activators: [const CharacterActivator('?'), _key(LogicalKeyboardKey.f1)],
  ),
  CadShortcut.save: CadShortcutInfo(
    label: 'Save',
    keys: 'Ctrl+S',
    group: _file,
    activators: [_key(LogicalKeyboardKey.keyS, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.saveAs: CadShortcutInfo(
    label: 'Save as',
    keys: 'Ctrl+Shift+S',
    group: _file,
    activators: [_key(LogicalKeyboardKey.keyS, control: true, shift: true)],
    yieldsToText: false,
  ),
  CadShortcut.open: CadShortcutInfo(
    label: 'Open',
    keys: 'Ctrl+O',
    group: _file,
    activators: [_key(LogicalKeyboardKey.keyO, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.newDocument: CadShortcutInfo(
    label: 'New',
    keys: 'Ctrl+N',
    group: _file,
    activators: [_key(LogicalKeyboardKey.keyN, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.zoomToFit: CadShortcutInfo(
    label: 'Zoom to fit',
    keys: 'F',
    group: _view,
    activators: [_key(LogicalKeyboardKey.keyF)],
  ),
  CadShortcut.viewFront: CadShortcutInfo(
    label: 'Front',
    keys: 'Ctrl+1',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit1, control: true), _key(LogicalKeyboardKey.numpad1, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewBack: CadShortcutInfo(
    label: 'Back',
    keys: 'Ctrl+2',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit2, control: true), _key(LogicalKeyboardKey.numpad2, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewLeft: CadShortcutInfo(
    label: 'Left',
    keys: 'Ctrl+3',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit3, control: true), _key(LogicalKeyboardKey.numpad3, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewRight: CadShortcutInfo(
    label: 'Right',
    keys: 'Ctrl+4',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit4, control: true), _key(LogicalKeyboardKey.numpad4, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewTop: CadShortcutInfo(
    label: 'Top',
    keys: 'Ctrl+5',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit5, control: true), _key(LogicalKeyboardKey.numpad5, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewBottom: CadShortcutInfo(
    label: 'Bottom',
    keys: 'Ctrl+6',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit6, control: true), _key(LogicalKeyboardKey.numpad6, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.viewIsometric: CadShortcutInfo(
    label: 'Isometric',
    keys: 'Ctrl+7',
    group: _view,
    activators: [_key(LogicalKeyboardKey.digit7, control: true), _key(LogicalKeyboardKey.numpad7, control: true)],
    yieldsToText: false,
  ),
  CadShortcut.zoomIn: CadShortcutInfo(
    label: 'Zoom in',
    keys: 'Shift+Z',
    group: _view,
    activators: [_key(LogicalKeyboardKey.keyZ, shift: true, repeats: true)],
  ),
  CadShortcut.zoomOut: CadShortcutInfo(
    label: 'Zoom out',
    keys: 'Z',
    group: _view,
    activators: [_key(LogicalKeyboardKey.keyZ, repeats: true)],
  ),
  CadShortcut.rotateLeft: CadShortcutInfo(
    label: 'Rotate the view 15°',
    keys: 'Arrow keys',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowLeft, repeats: true)],
  ),
  CadShortcut.rotateRight: CadShortcutInfo(
    label: 'Rotate the view right',
    keys: '→',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowRight, repeats: true)],
  ),
  CadShortcut.rotateUp: CadShortcutInfo(
    label: 'Rotate the view up',
    keys: '↑',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowUp, repeats: true)],
  ),
  CadShortcut.rotateDown: CadShortcutInfo(
    label: 'Rotate the view down',
    keys: '↓',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowDown, repeats: true)],
  ),
  CadShortcut.rotate90Left: CadShortcutInfo(
    label: 'Rotate the view 90°',
    keys: 'Shift+arrow keys',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowLeft, shift: true)],
  ),
  CadShortcut.rotate90Right: CadShortcutInfo(
    label: 'Rotate the view 90° right',
    keys: 'Shift+→',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowRight, shift: true)],
  ),
  CadShortcut.rotate90Up: CadShortcutInfo(
    label: 'Rotate the view 90° up',
    keys: 'Shift+↑',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowUp, shift: true)],
  ),
  CadShortcut.rotate90Down: CadShortcutInfo(
    label: 'Rotate the view 90° down',
    keys: 'Shift+↓',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowDown, shift: true)],
  ),
  CadShortcut.panLeft: CadShortcutInfo(
    label: 'Pan the view',
    keys: 'Ctrl+arrow keys',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowLeft, control: true, repeats: true)],
  ),
  CadShortcut.panRight: CadShortcutInfo(
    label: 'Pan the view right',
    keys: 'Ctrl+→',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowRight, control: true, repeats: true)],
  ),
  CadShortcut.panUp: CadShortcutInfo(
    label: 'Pan the view up',
    keys: 'Ctrl+↑',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowUp, control: true, repeats: true)],
  ),
  CadShortcut.panDown: CadShortcutInfo(
    label: 'Pan the view down',
    keys: 'Ctrl+↓',
    group: _view,
    activators: [_key(LogicalKeyboardKey.arrowDown, control: true, repeats: true)],
  ),
  CadShortcut.togglePerspective: CadShortcutInfo(
    label: 'Perspective / orthographic',
    keys: 'P',
    group: _view,
    activators: [_key(LogicalKeyboardKey.keyP)],
  ),
  CadShortcut.sketchLine: CadShortcutInfo(
    label: 'Line',
    keys: 'L',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyL)],
  ),
  CadShortcut.sketchCircle: CadShortcutInfo(
    label: 'Circle',
    keys: 'C',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyC)],
  ),
  CadShortcut.sketchArc: CadShortcutInfo(
    label: 'Arc',
    keys: 'A',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyA)],
  ),
  CadShortcut.sketchRectangle: CadShortcutInfo(
    label: 'Rectangle',
    keys: 'R',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyR)],
  ),
  CadShortcut.sketchDimension: CadShortcutInfo(
    label: 'Smart dimension',
    keys: 'D',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyD)],
  ),
  CadShortcut.sketchTrim: CadShortcutInfo(
    label: 'Trim',
    keys: 'T',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyT)],
  ),
  CadShortcut.sketchConstruction: CadShortcutInfo(
    label: 'Construction on / off for the selection',
    keys: 'X',
    group: _sketch,
    activators: [_key(LogicalKeyboardKey.keyX)],
  ),
};

/// The shortcut sheet shows one row for each of these families (the
/// others in a family share its row - "Arrow keys" covers all four).
const Set<CadShortcut> _sheetFollowers = {
  CadShortcut.rotateRight,
  CadShortcut.rotateUp,
  CadShortcut.rotateDown,
  CadShortcut.rotate90Right,
  CadShortcut.rotate90Up,
  CadShortcut.rotate90Down,
  CadShortcut.panRight,
  CadShortcut.panUp,
  CadShortcut.panDown,
};

/// [tooltip] with [shortcut]'s keys after it: "Undo (Ctrl+Z)".
String withShortcut(String tooltip, CadShortcut shortcut) => '$tooltip (${kCadShortcuts[shortcut]!.keys})';

/// Whether a text field has keyboard focus (its keys come first - see
/// [CadShortcutInfo.yieldsToText]).
bool textInputHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Binds [bindings] while its screen's route is the one on top - not
/// under a dialog, sheet or menu. [bindings] is built afresh on every key
/// press, so it always reads the screen's current state (an open panel's
/// confirm enablement, the viewport). A null callback means "not available
/// here right now": the key is left alone. Esc, once bound, is always taken,
/// so Android never turns it into Back (which would leave the screen); in a
/// text field it just leaves the field.
///
/// It listens on [HardwareKeyboard] rather than holding focus: a focus node
/// of its own would take autofocus away from the text fields that ask for
/// it (Flutter only autofocuses when nothing else has focus), and keys still
/// have to arrive with nothing focused at all. A key it handles is reported
/// handled, so the platform doesn't act on it as well.
class CadShortcutScope extends StatefulWidget {
  final Map<CadShortcut, VoidCallback?> Function() bindings;
  final Widget child;

  const CadShortcutScope({super.key, required this.bindings, required this.child});

  @override
  State<CadShortcutScope> createState() => _CadShortcutScopeState();
}

class _CadShortcutScopeState extends State<CadShortcutScope> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is KeyUpEvent || !mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final keyboard = HardwareKeyboard.instance;
    final typing = textInputHasFocus();
    for (final MapEntry(key: shortcut, value: callback) in widget.bindings().entries) {
      if (callback == null) continue;
      final info = kCadShortcuts[shortcut]!;
      if (!info.activators.any((activator) => activator.accepts(event, keyboard))) continue;
      if (typing && shortcut == CadShortcut.cancel) {
        FocusManager.instance.primaryFocus?.unfocus();
        return true;
      }
      if (typing && info.yieldsToText) return false;
      callback();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows the shortcuts in [available] (those a screen binds), grouped.
Future<void> showCadShortcutSheet(BuildContext context, Iterable<CadShortcut> available) {
  final shown = [
    for (final shortcut in CadShortcut.values)
      if (available.contains(shortcut) && !_sheetFollowers.contains(shortcut)) shortcut,
  ];
  final groups = <String, List<CadShortcutInfo>>{};
  for (final shortcut in shown) {
    final info = kCadShortcuts[shortcut]!;
    groups.putIfAbsent(info.group, () => []).add(info);
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final MapEntry(key: group, value: rows) in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(group, style: Theme.of(context).textTheme.titleSmall),
              ),
              for (final info in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(width: 150, child: Text(info.keys, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(child: Text(info.label)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );
}

/// Desktop input D3: the open tool panels' Enter / Esc targets, for the
/// screen's [CadShortcutScope] - see [ToolPanelKeys]. The panel mounted most
/// recently wins.
class ToolPanelKeyRegistry {
  final List<_ToolPanelKeysState> _panels = [];

  bool get hasPanel => _panels.isNotEmpty;

  /// The top panel's confirm, or null when it has none or it's disabled.
  VoidCallback? get confirm => _panels.isEmpty ? null : _panels.last.widget.onConfirm;

  /// The top panel's cancel / close.
  VoidCallback? get cancel => _panels.isEmpty ? null : _panels.last.widget.onCancel;
}

/// Makes a [ToolPanelKeyRegistry] reachable by the [ToolPanelKeys] under it.
class ToolPanelKeyScope extends InheritedWidget {
  final ToolPanelKeyRegistry registry;

  const ToolPanelKeyScope({super.key, required this.registry, required super.child});

  static ToolPanelKeyRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToolPanelKeyScope>()?.registry;

  @override
  bool updateShouldNotify(ToolPanelKeyScope oldWidget) => registry != oldWidget.registry;
}

/// Put next to a tool panel's Confirm / Cancel buttons, with the same
/// callbacks the buttons use (including a confirm that is null while the
/// button is disabled): while the panel is on screen, Enter confirms it and
/// Esc cancels it. Draws nothing.
class ToolPanelKeys extends StatefulWidget {
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  const ToolPanelKeys({super.key, this.onConfirm, this.onCancel});

  @override
  State<ToolPanelKeys> createState() => _ToolPanelKeysState();
}

class _ToolPanelKeysState extends State<ToolPanelKeys> {
  ToolPanelKeyRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = ToolPanelKeyScope.maybeOf(context);
    if (registry == _registry) return;
    _registry?._panels.remove(this);
    _registry = registry;
    registry?._panels.add(this);
  }

  @override
  void dispose() {
    _registry?._panels.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The arrow keys' orbit step (SOLIDWORKS' default view rotation increment).
const double kKeyboardOrbitDegrees = 15;

/// Ctrl+arrow pan step, in screen pixels.
const double kKeyboardPanPixels = 40;

/// Z zooms out by this factor (Shift+Z in by its inverse) - two wheel
/// notches' worth.
const double kKeyboardZoomStep = 1.21;
