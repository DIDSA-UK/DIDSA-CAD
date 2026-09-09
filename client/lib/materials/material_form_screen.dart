import 'package:flutter/material.dart';

import 'material.dart';
import 'material_store.dart';

/// Add/edit form for one [CadMaterial] - shared by the Materials Manager's own
/// "+ Add Material"/edit actions and the material picker sheet's "+ Add new
/// material..." quick-add row (`material_picker_sheet.dart`), so there is
/// exactly one place this form's fields/validation live. Pops with the
/// saved [CadMaterial] on success, or `null` on cancel.
class MaterialFormScreen extends StatefulWidget {
  /// Null for "add a new material"; non-null to edit an existing one.
  final CadMaterial? existing;

  const MaterialFormScreen({super.key, this.existing});

  @override
  State<MaterialFormScreen> createState() => _MaterialFormScreenState();
}

class _MaterialFormScreenState extends State<MaterialFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _category = TextEditingController(text: widget.existing?.category ?? '');
  late final _density = TextEditingController(text: _numText(widget.existing?.densityGCm3));
  late final _elasticModulus = TextEditingController(text: _numText(widget.existing?.elasticModulusGPa));
  late final _poissonsRatio = TextEditingController(text: _numText(widget.existing?.poissonsRatio));
  late final _yieldStrength = TextEditingController(text: _numText(widget.existing?.yieldStrengthMPa));
  late final _tensileStrength = TextEditingController(text: _numText(widget.existing?.tensileStrengthMPa));
  late final _shearModulus = TextEditingController(text: _numText(widget.existing?.shearModulusGPa));
  late final _thermalExpansion = TextEditingController(text: _numText(widget.existing?.thermalExpansionPerK));
  late final _thermalConductivity = TextEditingController(text: _numText(widget.existing?.thermalConductivityWmK));
  late final _specificHeat = TextEditingController(text: _numText(widget.existing?.specificHeatJKgK));

  static String _numText(double? value) => value == null ? '' : value.toString();
  static double? _parse(String text) => text.trim().isEmpty ? null : double.tryParse(text.trim());

  @override
  void dispose() {
    for (final c in [
      _name,
      _category,
      _density,
      _elasticModulus,
      _poissonsRatio,
      _yieldStrength,
      _tensileStrength,
      _shearModulus,
      _thermalExpansion,
      _thermalConductivity,
      _specificHeat,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final density = _parse(_density.text);
    if (density == null) return; // validator already guards this

    final existing = widget.existing;
    final material = CadMaterial(
      id: existing?.id ?? '',
      name: _name.text.trim(),
      category: _category.text.trim(),
      densityGCm3: density,
      elasticModulusGPa: _parse(_elasticModulus.text),
      poissonsRatio: _parse(_poissonsRatio.text),
      yieldStrengthMPa: _parse(_yieldStrength.text),
      tensileStrengthMPa: _parse(_tensileStrength.text),
      shearModulusGPa: _parse(_shearModulus.text),
      thermalExpansionPerK: _parse(_thermalExpansion.text),
      thermalConductivityWmK: _parse(_thermalConductivity.text),
      specificHeatJKgK: _parse(_specificHeat.text),
      isBuiltIn: existing?.isBuiltIn ?? false,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );

    final saved = existing == null ? await MaterialStore.add(material) : material;
    if (existing != null) await MaterialStore.update(material);
    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  Widget _numField(TextEditingController controller, String label, {bool required = false, String? suffix}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixText: suffix),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return required ? 'Required' : null;
          return double.tryParse(text) == null ? 'Enter a number' : null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Material' : 'Add Material')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _category,
              decoration: const InputDecoration(
                labelText: 'Category',
                hintText: 'e.g. Plastic, Carbon Steel, Stainless Steel, Aluminum Alloy',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            _numField(_density, 'Density', required: true, suffix: 'g/cm³'),
            const Divider(height: 24),
            Text('Stress analysis properties (optional)', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _numField(_elasticModulus, 'Elastic (Young\'s) Modulus', suffix: 'GPa'),
            _numField(_poissonsRatio, "Poisson's Ratio"),
            _numField(_yieldStrength, 'Yield Strength', suffix: 'MPa'),
            _numField(_tensileStrength, 'Tensile Strength', suffix: 'MPa'),
            _numField(_shearModulus, 'Shear Modulus', suffix: 'GPa'),
            _numField(_thermalExpansion, 'Thermal Expansion Coefficient', suffix: '1/K'),
            _numField(_thermalConductivity, 'Thermal Conductivity', suffix: 'W/(m·K)'),
            _numField(_specificHeat, 'Specific Heat', suffix: 'J/(kg·K)'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: Text(isEdit ? 'Save Changes' : 'Add Material')),
          ],
        ),
      ),
    );
  }
}
