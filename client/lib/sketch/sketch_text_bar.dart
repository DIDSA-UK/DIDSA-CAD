import 'dart:async';

import 'package:flutter/material.dart';

import '../viewport3d/resizable_tool_panel.dart';
import 'sketch_controller.dart';

/// 3D-viewport Text tool round (`docs/text-tool-3d-viewport-scope.md`
/// §2.3): the Text tool's own configuring bar, replacing the old "Edit
/// Text" `AlertDialog` (`sketch_ribbon.dart`'s former
/// `_SetTextPropertiesDialog`) - built on the same shared
/// [ResizableToolPanel] shell `sketch_pattern_bar.dart`'s [PatternValueBar]
/// uses (per the task's own "use the pattern tool bar as a reference"
/// instruction), so it's draggable/scrollable the same way, rather than a
/// fixed-size modal. Shown whenever [SketchController.textBarTextId] is
/// non-null (set by the ribbon's "Edit Text" action;
/// [SketchController.closeTextBar] clears it) - unlike [PatternValueBar]
/// this isn't tied to a dedicated [SketchMode], since Text editing happens
/// entirely within ordinary Select mode.
///
/// Every field here applies immediately on submit (one [SketchController.
/// setTextProperties] PATCH per field), the same "no separate staged/
/// confirm step" shape the corner resize-handle's own drop-to-commit
/// already has - the height field and the resize handle are two different
/// ways to set the same `size`, deliberately allowed to "overwrite each
/// other" (the task's own words) rather than needing to be reconciled.
class TextValueBar extends StatelessWidget {
  final SketchController controller;

  const TextValueBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final textId = controller.textBarTextId;
        if (textId == null) return const SizedBox.shrink();
        final text = controller.texts[textId];
        // The Text this bar was opened for got deleted (undo of its own
        // creation, or an external change) while the bar was still open -
        // closes itself rather than showing stale/empty fields.
        if (text == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.closeTextBar();
          });
          return const SizedBox.shrink();
        }
        // Fresh State per Text id, mirroring `sketch_pattern_bar.dart`'s
        // own re-seeding key - switching to editing a *different* Text
        // (in principle, via a fresh ribbon tap while this is open) must
        // reset every field's starting value, not carry the previous
        // Text's own text-editing-controller content over.
        return _TextValueBarContent(key: ValueKey(textId), controller: controller, textId: textId);
      },
    );
  }
}

class _TextValueBarContent extends StatefulWidget {
  final SketchController controller;
  final String textId;

  const _TextValueBarContent({super.key, required this.controller, required this.textId});

  @override
  State<_TextValueBarContent> createState() => _TextValueBarContentState();
}

class _TextValueBarContentState extends State<_TextValueBarContent> {
  late final TextEditingController _contentText;
  late final TextEditingController _heightText;
  late final TextEditingController _rotationText;
  late String _font;
  bool _fontExpanded = false;
  String? _heightError;

  SketchTextView get _text => widget.controller.texts[widget.textId]!;

  @override
  void initState() {
    super.initState();
    final text = _text;
    _contentText = TextEditingController(text: text.content);
    _heightText = TextEditingController(text: text.size.toString());
    _rotationText = TextEditingController(text: text.rotationDegrees.toString());
    _font = textFontOptions.contains(text.font) ? text.font : textFontOptions.first;
  }

  @override
  void dispose() {
    _contentText.dispose();
    _heightText.dispose();
    _rotationText.dispose();
    super.dispose();
  }

  void _submitContent(String value) {
    if (value.isEmpty || value == _text.content) return;
    unawaited(widget.controller.setTextProperties(widget.textId, content: value));
  }

  void _selectFont(String font) {
    setState(() {
      _font = font;
      _fontExpanded = false;
    });
    if (font == _text.font) return;
    unawaited(widget.controller.setTextProperties(widget.textId, font: font));
  }

  void _submitHeight(String value) {
    final size = double.tryParse(value);
    setState(() => _heightError = size == null || size <= 0 ? 'Enter a positive number' : null);
    if (size == null || size <= 0 || size == _text.size) return;
    unawaited(widget.controller.setTextProperties(widget.textId, size: size));
  }

  void _submitRotation(String value) {
    final rotation = double.tryParse(value);
    if (rotation == null || rotation == _text.rotationDegrees) return;
    unawaited(widget.controller.setTextProperties(widget.textId, rotationDegrees: rotation));
  }

  void _close() {
    // Same deferral every other bar's own close/confirm action here uses
    // (see `sketch_pattern_bar.dart`'s `_confirm`/`_cancel`) - avoids
    // tearing down this widget (and its still-focused TextFields) from
    // inside the very callback one of them triggered.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.closeTextBar();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: 'Text',
      dragHandleKey: const Key('textValueBarDragHandle'),
      resizableAreaKey: const Key('textValueBarResizableArea'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _contentText,
            decoration: const InputDecoration(labelText: 'Text', border: OutlineInputBorder()),
            onSubmitted: _submitContent,
            onEditingComplete: () => _submitContent(_contentText.text),
          ),
          const SizedBox(height: 12),
          _fontPicker(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('textValueBarHeightField'),
                  controller: _heightText,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Height',
                    suffixText: 'mm',
                    errorText: _heightError,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: _submitHeight,
                  onEditingComplete: () => _submitHeight(_heightText.text),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _rotationText,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Rotation', suffixText: '°', border: OutlineInputBorder()),
                  onSubmitted: _submitRotation,
                  onEditingComplete: () => _submitRotation(_rotationText.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(onPressed: _close, child: const Text('Done')),
            ],
          ),
        ],
      ),
    );
  }

  /// Collapsed: a single tappable row naming the current font, rendered in
  /// its own face (the task's own ask: "select font can expand to show
  /// font names displayed in the font"). Expanded: every allowlisted font
  /// as its own row, each likewise rendered in its own face, so picking
  /// one is a genuine visual preview rather than a plain text dropdown -
  /// tapping any row (including the current one, to collapse without
  /// changing it) closes the list back down.
  Widget _fontPicker() {
    // A single tap target per row (the collapsed tile and every expanded
    // row alike) - deliberately *not* nesting one `InkWell` (row tap)
    // inside another (the collapsed tile's own expand tap), which
    // silently made both taps ambiguous (Flutter's gesture arena let the
    // inner one win every time, so tapping the collapsed tile actually
    // re-selected the *current* font - a no-op - instead of expanding;
    // caught by `sketch_text_bar_test.dart`'s own expand test before this
    // ever shipped). Plain content + an explicit `onTap` param instead.
    Widget fontTile(String font, {required bool selected, required bool showChevron, required VoidCallback onTap, Key? key}) =>
        InkWell(
          key: key,
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(child: Text(font, style: TextStyle(fontFamily: font, fontSize: 18))),
                if (showChevron) Icon(_fontExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
              ],
            ),
          ),
        );

    if (!_fontExpanded) {
      return fontTile(
        _font,
        selected: true,
        showChevron: true,
        key: const Key('textValueBarFontCollapsed'),
        onTap: () => setState(() => _fontExpanded = true),
      );
    }
    return Column(
      key: const Key('textValueBarFontExpanded'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final font in textFontOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: fontTile(font, selected: font == _font, showChevron: false, onTap: () => _selectFont(font)),
          ),
      ],
    );
  }
}
