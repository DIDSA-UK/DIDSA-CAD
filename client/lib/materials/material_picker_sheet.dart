import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'material.dart';
import 'material_form_screen.dart';
import 'material_store.dart';

/// Bottom sheet for assigning a material - either a Body's own override
/// (pass [isBodyOverride]: true, offering "None (use Part default)") or the
/// Part's own default (pass false, offering plain "None"). Mirrors
/// `showBodyContextMenu`'s own bottom-sheet style. Pops with a
/// [MaterialAssignmentDto] to assign, or an explicit `null` sentinel wrapped
/// in [MaterialPickerResult] to clear the assignment - `null` alone (the
/// sheet dismissed without a choice) means "no change".
class MaterialPickerResult {
  final MaterialAssignmentDto? assignment;
  const MaterialPickerResult(this.assignment);
}

Future<MaterialPickerResult?> showMaterialPickerSheet(
  BuildContext context, {
  required bool isBodyOverride,
}) {
  return showModalBottomSheet<MaterialPickerResult>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _MaterialPickerSheet(isBodyOverride: isBodyOverride),
  );
}

class _MaterialPickerSheet extends StatefulWidget {
  final bool isBodyOverride;

  const _MaterialPickerSheet({required this.isBodyOverride});

  @override
  State<_MaterialPickerSheet> createState() => _MaterialPickerSheetState();
}

class _MaterialPickerSheetState extends State<_MaterialPickerSheet> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await MaterialStore.load();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  void _choose(Material material) {
    Navigator.of(context).pop(
      MaterialPickerResult(
        MaterialAssignmentDto(materialId: material.id, name: material.name, densityGCm3: material.densityGCm3),
      ),
    );
  }

  Future<void> _addNew() async {
    final saved = await Navigator.of(context).push<Material>(
      MaterialPageRoute(builder: (_) => const MaterialFormScreen()),
    );
    if (saved != null && mounted) _choose(saved);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    }
    final materials = MaterialStore.all;
    return SafeArea(
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Assign Material', style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(widget.isBodyOverride ? 'None (use Part default)' : 'None'),
              onTap: () => Navigator.of(context).pop(const MaterialPickerResult(null)),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add new material...'),
              onTap: _addNew,
            ),
            const Divider(height: 1),
            for (final material in materials)
              ListTile(
                title: Text(material.name),
                subtitle: Text('${material.category} · ${material.densityGCm3} g/cm³'),
                onTap: () => _choose(material),
              ),
          ],
        ),
      ),
    );
  }
}
