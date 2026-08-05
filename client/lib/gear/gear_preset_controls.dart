import 'package:flutter/material.dart';

import 'gear_preset_store.dart';

/// `docs/gear-design/09-presets.md`'s own UI: a "Save as preset" action
/// capturing the current form state under a user-given name, and a
/// picklist/gallery to load one back in - shared by every Gear Design
/// screen ([GearDesignScreen]/[GearChainDesignScreen]/[BevelDesignScreen])
/// rather than each screen re-implementing the same two dialogs, since
/// [GearPresetStore] itself is already generic across screens (kind-
/// scoped, opaque `fields` map).
class GearPresetControls extends StatelessWidget {
  /// Which screen/gear-type family this control belongs to - only presets
  /// saved under the same [kind] are offered back (`GearPresetStore.
  /// forKind`), since a chain preset's own field shape has nothing
  /// meaningful to offer an external-gear form and vice versa.
  final String kind;

  /// Captures the calling screen's current form state on demand - called
  /// only when the user actually taps "Save as preset", not on every
  /// rebuild.
  final Map<String, dynamic> Function() captureFields;

  /// Applies a loaded preset's own field map back into the calling
  /// screen's form state (setState + re-schedule preview is the caller's
  /// own job, not this widget's).
  final void Function(Map<String, dynamic> fields) onLoad;

  const GearPresetControls({super.key, required this.kind, required this.captureFields, required this.onLoad});

  Future<void> _showSaveDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Deferred to a post-frame callback rather than disposed immediately:
    // `showDialog`'s Future resolves as soon as the route is popped, but the
    // dialog's exit transition is still animating the TextField out at that
    // point - disposing its controller synchronously here raced the
    // framework's own teardown of the still-attached EditableText ("attached:
    // is not true" / "Tried to build dirty widget in the wrong build scope").
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null || name.isEmpty) return;
    await GearPresetStore.save(name, kind, captureFields());
  }

  Future<void> _showLoadDialog(BuildContext context) async {
    final presets = GearPresetStore.forKind(kind);
    final selected = await showDialog<GearPreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Load preset'),
        content: SizedBox(
          width: 360,
          child: presets.isEmpty
              ? const Text('No presets saved yet.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: presets.length,
                  itemBuilder: (context, index) {
                    final preset = presets[index];
                    return ListTile(
                      title: Text(preset.name),
                      onTap: () => Navigator.of(context).pop(preset),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete preset',
                        onPressed: () async {
                          await GearPresetStore.delete(preset.id);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ],
      ),
    );
    if (selected != null) onLoad(selected.fields);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showSaveDialog(context),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save as preset'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showLoadDialog(context),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Load preset'),
          ),
        ),
      ],
    );
  }
}
