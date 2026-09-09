import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import 'material_picker_sheet.dart';

/// The app's MBD (Model-Based Definition) metadata surface for the current
/// Part: Part Number/Name/Description/Revision (STEP-portable - see
/// `app.document.step_export`) plus Remarks/Supplier/Supplier Part Number
/// (DIDSA-CAD-only, never written into STEP - see `Part`'s own backend
/// docstring) and the Part-level default material. Mass is read-only,
/// computed from geometry x the resolved material via the dedicated
/// mass-properties endpoint. Structured like `AiProviderSettingsScreen`
/// (load into controllers in `initState`, a single Save action).
class PartPropertiesScreen extends StatefulWidget {
  final DocumentApiClient api;
  final PartDto part;

  const PartPropertiesScreen({super.key, required this.api, required this.part});

  @override
  State<PartPropertiesScreen> createState() => _PartPropertiesScreenState();
}

class _PartPropertiesScreenState extends State<PartPropertiesScreen> {
  late PartDto _part = widget.part;

  late final _partNumber = TextEditingController(text: _part.partNumber ?? '');
  late final _description = TextEditingController(text: _part.description ?? '');
  late final _revision = TextEditingController(text: _part.revision ?? '');
  late final _remarks = TextEditingController(text: _part.remarks ?? '');
  late final _supplier = TextEditingController(text: _part.supplier ?? '');
  late final _supplierPartNumber = TextEditingController(text: _part.supplierPartNumber ?? '');

  bool _saving = false;
  String? _error;

  MassPropertiesDto? _massProperties;
  bool _massLoading = false;

  @override
  void initState() {
    super.initState();
    _loadMassProperties();
  }

  @override
  void dispose() {
    for (final c in [_partNumber, _description, _revision, _remarks, _supplier, _supplierPartNumber]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadMassProperties() async {
    setState(() => _massLoading = true);
    try {
      final result = await widget.api.getMassProperties(_part.id);
      if (!mounted) return;
      setState(() {
        _massProperties = result;
        _massLoading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _massLoading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.api.updatePart(
        _part.id,
        partNumber: _partNumber.text.trim(),
        description: _description.text.trim(),
        revision: _revision.text.trim(),
        remarks: _remarks.text.trim(),
        supplier: _supplier.text.trim(),
        supplierPartNumber: _supplierPartNumber.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _part = updated;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Part Properties saved')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _assignDefaultMaterial() async {
    final result = await showMaterialPickerSheet(context, isBodyOverride: false);
    if (!mounted || result == null) return;
    try {
      final updated = await widget.api.setDefaultMaterial(_part.id, result.assignment);
      if (!mounted) return;
      setState(() => _part = updated);
      await _loadMassProperties();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  String get _massSummary {
    final massProps = _massProperties;
    if (massProps == null) return _massLoading ? 'Calculating...' : 'Unavailable';
    final totalBodies = massProps.bodyVolumes.length;
    final withMass = massProps.bodyMasses.length;
    final totalGrams = massProps.bodyMasses.values.fold<double>(0, (sum, g) => sum + g);
    if (totalBodies == 0) return 'No bodies';
    final formatted = totalGrams >= 1000 ? '${(totalGrams / 1000).toStringAsFixed(3)} kg' : '${totalGrams.toStringAsFixed(1)} g';
    if (withMass < totalBodies) {
      return '$formatted (partial - $withMass of $totalBodies bodies have a material assigned)';
    }
    return formatted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Part Properties'),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Text('Name', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(_part.name, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _partNumber,
            decoration: const InputDecoration(labelText: 'Part Number', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _revision,
            decoration: const InputDecoration(labelText: 'Revision', border: OutlineInputBorder()),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Material (Part default)'),
            subtitle: Text(_part.defaultMaterial?.name ?? 'None assigned'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _assignDefaultMaterial,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mass'),
            subtitle: Text(_massSummary),
            trailing: _massLoading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(icon: const Icon(Icons.refresh), onPressed: _loadMassProperties),
          ),
          const Divider(height: 32),
          Text(
            'The fields below are stored with this project only - they are not part of the STEP standard and '
            'will not be included in a STEP export.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _remarks,
            decoration: const InputDecoration(labelText: 'Remarks', border: OutlineInputBorder()),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _supplier,
            decoration: const InputDecoration(labelText: 'Supplier', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _supplierPartNumber,
            decoration: const InputDecoration(labelText: 'Supplier Part Number', border: OutlineInputBorder()),
          ),
        ],
      ),
    );
  }
}
