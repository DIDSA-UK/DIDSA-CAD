import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'material.dart';
import 'material_csv.dart';
import 'material_form_screen.dart';
import 'material_store.dart';

/// Settings > Materials > Materials Manager: CRUD list over the client-local
/// material library ([MaterialStore]), plus CSV export/import - structured
/// like `AiProviderSettingsScreen` (`Scaffold(appBar + ListView)`, load in
/// `initState`).
class MaterialsManagerScreen extends StatefulWidget {
  const MaterialsManagerScreen({super.key});

  @override
  State<MaterialsManagerScreen> createState() => _MaterialsManagerScreenState();
}

class _MaterialsManagerScreenState extends State<MaterialsManagerScreen> {
  bool _loaded = false;
  String? _statusMessage;

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

  Future<void> _addMaterial() async {
    final saved = await Navigator.of(context).push<Material>(
      MaterialPageRoute(builder: (_) => const MaterialFormScreen()),
    );
    if (saved != null && mounted) setState(() {});
  }

  Future<void> _editMaterial(Material material) async {
    final saved = await Navigator.of(context).push<Material>(
      MaterialPageRoute(builder: (_) => MaterialFormScreen(existing: material)),
    );
    if (saved != null && mounted) setState(() {});
  }

  Future<void> _deleteMaterial(Material material) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete material?'),
        content: Text('Remove "${material.name}" from the material library?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await MaterialStore.delete(material.id);
    if (mounted) setState(() {});
  }

  Future<void> _resetToDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset built-in materials?'),
        content: const Text(
          'Every built-in material is restored to its shipped values. Materials you added yourself are '
          'left untouched.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    await MaterialStore.resetToDefaults();
    if (mounted) setState(() => _statusMessage = 'Built-in materials reset to defaults.');
  }

  Future<void> _exportCsv() async {
    final csv = materialsToCsv(MaterialStore.all);
    final bytes = Uint8List.fromList(utf8.encode(csv));
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Material Library',
      fileName: 'materials.csv',
      bytes: bytes,
    );
    if (savedPath == null) return;
    // Mirrors PartScreen._saveNativeFileViaDialog's own desktop write
    // workaround - file_picker's own desktop saveFile only runs the native
    // dialog and never actually writes `bytes` there.
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(savedPath).writeAsBytes(bytes);
    }
    if (mounted) setState(() => _statusMessage = 'Exported ${MaterialStore.all.length} materials.');
  }

  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;

    final parsed = materialsFromCsv(utf8.decode(bytes));
    for (final material in parsed.imported) {
      await MaterialStore.add(material);
    }
    if (!mounted) return;
    setState(() {
      _statusMessage = parsed.skipped > 0
          ? 'Imported ${parsed.imported.length} materials, skipped ${parsed.skipped} invalid row(s).'
          : 'Imported ${parsed.imported.length} materials.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final materials = MaterialStore.all;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Materials Manager'),
        actions: [
          IconButton(icon: const Icon(Icons.upload_file), tooltip: 'Export CSV', onPressed: _exportCsv),
          IconButton(icon: const Icon(Icons.download), tooltip: 'Import CSV', onPressed: _importCsv),
          IconButton(icon: const Icon(Icons.restore), tooltip: 'Reset built-in materials', onPressed: _resetToDefaults),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMaterial,
        icon: const Icon(Icons.add),
        label: const Text('Add Material'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_statusMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                Expanded(
                  child: materials.isEmpty
                      ? const Center(child: Text('No materials yet'))
                      : ListView.separated(
                          itemCount: materials.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final m = materials[index];
                            return ListTile(
                              title: Text(m.name),
                              subtitle: Text('${m.category} · ${m.densityGCm3} g/cm³${m.isBuiltIn ? ' · built-in' : ''}'),
                              onTap: () => _editMaterial(m),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _editMaterial(m)),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _deleteMaterial(m),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
