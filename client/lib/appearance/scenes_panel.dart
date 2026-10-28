/// The flat app's Scenes panel (`docs/scenes-scope.md` S3, section 7): the assembly's scenes and the scene mode's actions.
/// A scene is a named arrangement (parts moved, hidden or painted, section planes, a viewpoint) that changes nothing in
/// the model. Showing one is a mode with one way out, Back to default; while it shows, the gizmo, Hide / Show, the
/// Appearance panel and sections change what is on screen only, and Update scene / Save as new keep it.
library;

import 'package:flutter/material.dart';

import '../viewport3d/resizable_tool_panel.dart';
import 'appearance_rule.dart';
import '../viewport3d/keyboard_shortcuts.dart';

/// What leaving a scene with unsaved changes does (D7): keep them in the scene first, drop them, or stay.
enum SceneLeaveChoice { update, discard, stay }

/// Asks Update / Discard / Stay. A dismissed dialog stays.
Future<SceneLeaveChoice> askSceneLeave(BuildContext context, {required bool canUpdate}) async {
  final choice = await showDialog<SceneLeaveChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Unsaved scene changes'),
      content: Text(canUpdate
          ? 'What is on screen differs from the scene. Keep it in the scene first?'
          : 'This new scene has not been saved. Leave it?'),
      actions: [
        TextButton(key: const ValueKey('scene-leave-stay'), onPressed: () => Navigator.of(ctx).pop(SceneLeaveChoice.stay), child: const Text('Stay')),
        TextButton(key: const ValueKey('scene-leave-discard'), onPressed: () => Navigator.of(ctx).pop(SceneLeaveChoice.discard), child: const Text('Discard')),
        if (canUpdate)
          FilledButton(key: const ValueKey('scene-leave-update'), onPressed: () => Navigator.of(ctx).pop(SceneLeaveChoice.update), child: const Text('Update')),
      ],
    ),
  );
  return choice ?? SceneLeaveChoice.stay;
}

/// Asks for a name ([initial] filled in) under [title]. Null when cancelled or empty. (Also the Appearance panel's
/// "Save brush...".)
Future<String?> askSceneName(BuildContext context, {required String title, String initial = '', String fieldKey = 'scene-name'}) async {
  final name = await showDialog<String>(context: context, builder: (_) => NameDialog(title: title, initial: initial, fieldKey: fieldKey));
  return name == null || name.trim().isEmpty ? null : name.trim();
}

/// A one-field name dialog that owns its text controller (disposed with the dialog, after its closing animation).
class NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String fieldKey;

  const NameDialog({super.key, required this.title, this.initial = '', this.fieldKey = 'scene-name'});

  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: ValueKey('${widget.fieldKey}-field'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(key: ValueKey('${widget.fieldKey}-ok'), onPressed: () => Navigator.of(context).pop(_controller.text), child: const Text('Save')),
        ],
      );
}

class ScenesPanel extends StatelessWidget {
  final List<Json> scenes;

  /// The scene showing (its id), `''` for a new one not saved yet, null in the default.
  final String? shownId;
  final bool dirty;
  final bool useViewpoint;
  final bool saveView;
  final bool busy;
  final String? notice;
  final ValueChanged<Json> onShow;
  final VoidCallback onNewScene;
  final VoidCallback onUpdate;
  final VoidCallback onSaveAsNew;
  final VoidCallback onBackToDefault;
  final ValueChanged<Json> onRename;
  final ValueChanged<Json> onDelete;
  final ValueChanged<bool> onUseViewpointChanged;
  final ValueChanged<bool> onSaveViewChanged;
  final VoidCallback onClose;

  const ScenesPanel({
    super.key,
    required this.scenes,
    required this.shownId,
    required this.dirty,
    required this.useViewpoint,
    required this.saveView,
    this.busy = false,
    this.notice,
    required this.onShow,
    required this.onNewScene,
    required this.onUpdate,
    required this.onSaveAsNew,
    required this.onBackToDefault,
    required this.onRename,
    required this.onDelete,
    required this.onUseViewpointChanged,
    required this.onSaveViewChanged,
    required this.onClose,
  });

  String _status() {
    if (shownId == null) return 'Showing the default (the real model).';
    if (shownId!.isEmpty) return 'New scene from the default${dirty ? ' (changed)' : ''}: move, hide, paint, then Save as new.';
    final shown = scenes.where((s) => s['id'] == shownId);
    final name = shown.isEmpty ? 'a scene' : '"${shown.first['name']}"';
    return 'Showing $name${dirty ? ' (changed since shown)' : ''}. Moves, hiding and paint are on screen only until you Update it.';
  }

  @override
  Widget build(BuildContext context) {
    final inScene = shownId != null;
    return ResizableToolPanel(
      title: 'Scenes',
      tooltip: inScene ? 'Mates are not enforced while a scene shows' : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_status(), key: const ValueKey('scenes-status'))),
              ToolPanelKeys(onCancel: onClose),
              IconButton(key: const ValueKey('scenes-close'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: onClose),
            ],
          ),
          if (notice != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(notice!, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!inScene)
                FilledButton.icon(key: const ValueKey('scenes-new'), onPressed: busy ? null : onNewScene, icon: const Icon(Icons.add), label: const Text('New scene')),
              if (inScene && shownId!.isNotEmpty)
                FilledButton(key: const ValueKey('scenes-update'), onPressed: busy ? null : onUpdate, child: const Text('Update scene')),
              if (inScene)
                OutlinedButton(key: const ValueKey('scenes-save-new'), onPressed: busy ? null : onSaveAsNew, child: const Text('Save as new...')),
              if (inScene)
                OutlinedButton(key: const ValueKey('scenes-back'), onPressed: busy ? null : onBackToDefault, child: const Text('Back to default')),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('scenes-use-viewpoint'),
            dense: true,
            title: const Text('Show takes the scene\'s viewpoint'),
            value: useViewpoint,
            onChanged: onUseViewpointChanged,
          ),
          SwitchListTile(
            key: const ValueKey('scenes-save-view'),
            dense: true,
            title: const Text('Save my view with the scene'),
            value: saveView,
            onChanged: onSaveViewChanged,
          ),
          const Divider(),
          if (scenes.isEmpty) const Text('No scenes in this assembly yet.'),
          for (final scene in scenes)
            ListTile(
              key: ValueKey('scene-row-${scene['id']}'),
              dense: true,
              selected: scene['id'] == shownId,
              leading: Icon(scene['id'] == shownId ? Icons.visibility : Icons.photo_camera_back_outlined),
              title: Text('${scene['name']}'),
              subtitle: ((scene['unresolved'] as List?) ?? const []).isEmpty
                  ? null
                  : Text('${(scene['unresolved'] as List).length} change(s) no longer match the assembly'),
              onTap: busy ? null : () => onShow(scene),
              trailing: PopupMenuButton<String>(
                key: ValueKey('scene-menu-${scene['id']}'),
                onSelected: (action) => action == 'rename' ? onRename(scene) : onDelete(scene),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
