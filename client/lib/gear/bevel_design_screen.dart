import 'dart:async';

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import '../viewport3d/part_screen.dart';
import 'bevel_preview_canvas.dart';
import 'field_help_icon.dart';
import 'gear_preset_controls.dart';
import 'gear_preset_store.dart';
import 'gear_validation_banner.dart';
import 'standard_value_field.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
/// bevel-pair preview" extension, the bevel half - a third dedicated
/// screen alongside [GearDesignScreen]/`GearChainDesignScreen`, reached
/// from [GearDesignScreen]'s own app bar, per that same "one discovery
/// point, several dedicated screens for genuinely different data/preview
/// shapes" pattern the chain/planetary screen already established.
///
/// Bevel gear teeth have no flat 2D cut profile at all (`10-bevel-gear.md`'s
/// own "structurally unlike every other gear type" framing) - the preview
/// this screen shows is the standard bevel-drafting axial cross-section
/// envelope (`BevelPreviewCanvas`'s own doc comment), not a tooth outline.
enum BevelMultiKind { gear, pair }

const List<double> _standardModules = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
const List<double> _standardPressureAngles = [14.5, 20, 25];
const List<String> _fixedPlanes = ['XY', 'XZ', 'YZ'];

class BevelDesignScreen extends StatefulWidget {
  final DocumentApiClient? documentApi;
  final BevelMultiKind initialMode;

  const BevelDesignScreen({super.key, this.documentApi, this.initialMode = BevelMultiKind.gear});

  @override
  State<BevelDesignScreen> createState() => _BevelDesignScreenState();
}

class _BevelDesignScreenState extends State<BevelDesignScreen> {
  late final DocumentApiClient _api;
  late BevelMultiKind _mode;

  double _module = 4.0;
  double _pressureAngleDegrees = 20.0;
  String _plane = 'XY';

  // Single bevel gear mode.
  final _toothCountController = TextEditingController(text: '20');
  final _faceWidthController = TextEditingController(text: '15');
  final _pitchConeAngleController = TextEditingController(text: '30');
  final _backlashController = TextEditingController(text: '0');
  final _profileShiftController = TextEditingController(text: '0');

  // Bevel pair mode.
  final _toothCount1Controller = TextEditingController(text: '20');
  final _profileShift1Controller = TextEditingController(text: '0');
  final _toothCount2Controller = TextEditingController(text: '40');
  final _profileShift2Controller = TextEditingController(text: '0');
  final _pairFaceWidthController = TextEditingController(text: '15');
  final _shaftAngleController = TextEditingController(text: '90');
  final _pairBacklashController = TextEditingController(text: '0');

  Timer? _previewDebounce;
  bool _previewLoading = false;
  GearPreviewDto? _preview;
  List<String> _warnings = const [];
  String? _blockingError;

  bool _creating = false;
  String? _createError;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _api = widget.documentApi ?? DocumentApiClient();
    _schedulePreview();
    _loadPresets();
  }

  /// Mirrors `GearDesignScreen._loadPresets`'s own fire-and-forget warm-up.
  Future<void> _loadPresets() async {
    await GearPresetStore.load();
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _toothCountController.dispose();
    _faceWidthController.dispose();
    _pitchConeAngleController.dispose();
    _backlashController.dispose();
    _profileShiftController.dispose();
    _toothCount1Controller.dispose();
    _profileShift1Controller.dispose();
    _toothCount2Controller.dispose();
    _profileShift2Controller.dispose();
    _pairFaceWidthController.dispose();
    _shaftAngleController.dispose();
    _pairBacklashController.dispose();
    if (widget.documentApi == null) _api.close();
    super.dispose();
  }

  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 500), _fetchPreview);
  }

  Future<void> _fetchPreview() async {
    setState(() => _previewLoading = true);
    try {
      GearPreviewDto result;
      if (_mode == BevelMultiKind.gear) {
        final toothCount = int.tryParse(_toothCountController.text);
        final faceWidth = double.tryParse(_faceWidthController.text);
        final pitchConeAngle = double.tryParse(_pitchConeAngleController.text);
        final backlash = double.tryParse(_backlashController.text);
        final profileShift = double.tryParse(_profileShiftController.text);
        if (toothCount == null ||
            faceWidth == null ||
            pitchConeAngle == null ||
            backlash == null ||
            profileShift == null) {
          if (!mounted) return;
          setState(() {
            _preview = null;
            _warnings = const [];
            _blockingError = 'Enter valid values for every field';
            _previewLoading = false;
          });
          return;
        }
        result = await _api.previewGearBevelGear(
          module: _module,
          toothCount: toothCount,
          faceWidth: faceWidth,
          pitchConeAngleDegrees: pitchConeAngle,
          pressureAngleDegrees: _pressureAngleDegrees,
          backlash: backlash,
          profileShift: profileShift,
        );
      } else {
        final toothCount1 = int.tryParse(_toothCount1Controller.text);
        final profileShift1 = double.tryParse(_profileShift1Controller.text);
        final toothCount2 = int.tryParse(_toothCount2Controller.text);
        final profileShift2 = double.tryParse(_profileShift2Controller.text);
        final faceWidth = double.tryParse(_pairFaceWidthController.text);
        final shaftAngle = double.tryParse(_shaftAngleController.text);
        final backlash = double.tryParse(_pairBacklashController.text);
        if (toothCount1 == null ||
            profileShift1 == null ||
            toothCount2 == null ||
            profileShift2 == null ||
            faceWidth == null ||
            shaftAngle == null ||
            backlash == null) {
          if (!mounted) return;
          setState(() {
            _preview = null;
            _warnings = const [];
            _blockingError = 'Enter valid values for every field';
            _previewLoading = false;
          });
          return;
        }
        result = await _api.previewGearBevelPair(
          module: _module,
          toothCount1: toothCount1,
          profileShift1: profileShift1,
          toothCount2: toothCount2,
          profileShift2: profileShift2,
          faceWidth: faceWidth,
          pressureAngleDegrees: _pressureAngleDegrees,
          shaftAngleDegrees: shaftAngle,
          backlash: backlash,
        );
      }
      if (!mounted) return;
      setState(() {
        _preview = result;
        _warnings = result.warnings;
        _blockingError = null;
        _previewLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _warnings = const [];
        _blockingError = e.message;
        _previewLoading = false;
      });
    }
  }

  bool get _canCreate => _blockingError == null && _preview != null && !_creating;

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      // Bug fix (on-device feedback): this always starts a brand-new Part
      // - without resetting the session's Document first, it would just
      // pile onto whatever Document a previous tool-chooser entry already
      // created this session (see `DocumentApiClient.startNewDocument`'s
      // own doc comment).
      await _api.startNewDocument();
      final part = await _api.createPart(_mode == BevelMultiKind.gear ? 'Bevel Gear Part' : 'Bevel Pair Part');
      final planeRef = PlaneRefDto(fixedPlane: _plane);
      List<String> warnings = const [];
      if (_mode == BevelMultiKind.gear) {
        final feature = await _api.createBevelGearFeature(
          part.id,
          bevelType: 'boss',
          module: _module,
          toothCount: int.parse(_toothCountController.text),
          faceWidth: double.parse(_faceWidthController.text),
          pitchConeAngleDegrees: double.parse(_pitchConeAngleController.text),
          pressureAngleDegrees: _pressureAngleDegrees,
          backlash: double.parse(_backlashController.text),
          profileShift: double.parse(_profileShiftController.text),
          planeRef: planeRef,
        );
        warnings = feature.warnings;
      } else {
        final feature = await _api.createBevelPairFeature(
          part.id,
          module: _module,
          toothCount1: int.parse(_toothCount1Controller.text),
          profileShift1: double.parse(_profileShift1Controller.text),
          toothCount2: int.parse(_toothCount2Controller.text),
          profileShift2: double.parse(_profileShift2Controller.text),
          faceWidth: double.parse(_pairFaceWidthController.text),
          pressureAngleDegrees: _pressureAngleDegrees,
          shaftAngleDegrees: double.parse(_shaftAngleController.text),
          backlash: double.parse(_pairBacklashController.text),
          planeRef: planeRef,
        );
        warnings = feature.warnings;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PartScreen(initialPartId: part.id, initialWarnings: warnings)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _createError = e.message;
        _creating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bevel Gear Design')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final List<GearPreviewBevelMemberDto> members = _mode == BevelMultiKind.gear
              ? (_preview?.bevelGear != null ? [_preview!.bevelGear!] : const <GearPreviewBevelMemberDto>[])
              : (_preview?.bevelPair?.members ?? const <GearPreviewBevelMemberDto>[]);
          final canvas = BevelPreviewCanvas(members: members);
          final form = SingleChildScrollView(padding: const EdgeInsets.all(16), child: _buildForm());
          if (constraints.maxWidth < 700) {
            return Column(
              children: [
                SizedBox(height: constraints.maxHeight * 0.4, child: canvas),
                Expanded(child: form),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: canvas),
              SizedBox(width: 380, child: form),
            ],
          );
        },
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<BevelMultiKind>(
          segments: const [
            ButtonSegment(value: BevelMultiKind.gear, label: Text('Bevel Gear')),
            ButtonSegment(value: BevelMultiKind.pair, label: Text('Bevel Pair')),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) {
            setState(() => _mode = selection.first);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 16),
        StandardValueField(
          label: 'Module',
          standardValues: _standardModules,
          value: _module,
          helpText: 'Tooth size, measured at the outer (large, back-cone) end.',
          onChanged: (value) {
            setState(() => _module = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 12),
        StandardValueField(
          label: 'Pressure angle',
          standardValues: _standardPressureAngles,
          value: _pressureAngleDegrees,
          suffix: '°',
          onChanged: (value) {
            setState(() => _pressureAngleDegrees = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 16),
        if (_mode == BevelMultiKind.gear) ..._buildBevelGearForm() else ..._buildBevelPairForm(),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: 'Plane',
            suffixIcon: fieldHelpIcon(
              'The apex sits at this plane\'s origin; the primary shaft axis is its normal.',
            ),
          ),
          initialValue: _plane,
          items: [for (final plane in _fixedPlanes) DropdownMenuItem(value: plane, child: Text(plane))],
          onChanged: (value) {
            if (value != null) setState(() => _plane = value);
          },
        ),
        const SizedBox(height: 12),
        GearPresetControls(kind: 'bevel_design', captureFields: _captureFields, onLoad: _applyPresetFields),
        const SizedBox(height: 12),
        if (_previewLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(),
          ),
        _buildValidationBanner(),
        if (_createError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_createError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _canCreate ? _create : null,
          child: _creating
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
      ],
    );
  }

  List<Widget> _buildBevelGearForm() {
    return [
      TextField(
        controller: _toothCountController,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: InputDecoration(
          labelText: 'Tooth count',
          suffixIcon: fieldHelpIcon('How many teeth this bevel gear has.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _faceWidthController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Face width',
          suffixIcon: fieldHelpIcon('How far the tooth runs along the cone, from the outer (back) end inward.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pitchConeAngleController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Pitch cone angle',
          suffix: const Text('°'),
          suffixIcon: fieldHelpIcon(
            'The angle between the pitch cone\'s own surface and the shaft axis. A standalone bevel gear has no '
            'meshing partner to derive this from automatically - use Bevel Pair instead if you want it '
            'auto-derived from both gears\' tooth counts.',
          ),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _profileShiftController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: const InputDecoration(labelText: 'Profile shift'),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _backlashController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Backlash'),
        onChanged: (_) => _schedulePreview(),
      ),
    ];
  }

  List<Widget> _buildBevelPairForm() {
    return [
      const Text('Member 1 (pinion)', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _toothCount1Controller,
              keyboardType: const TextInputType.numberWithOptions(signed: false),
              decoration: const InputDecoration(labelText: 'Tooth count', isDense: true),
              onChanged: (_) => _schedulePreview(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _profileShift1Controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Profile shift', isDense: true),
              onChanged: (_) => _schedulePreview(),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      const Text('Member 2 (gear)', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _toothCount2Controller,
              keyboardType: const TextInputType.numberWithOptions(signed: false),
              decoration: const InputDecoration(labelText: 'Tooth count', isDense: true),
              onChanged: (_) => _schedulePreview(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _profileShift2Controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Profile shift', isDense: true),
              onChanged: (_) => _schedulePreview(),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _pairFaceWidthController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Face width',
          suffixIcon: fieldHelpIcon('Shared by both members - they physically share one axial band/mesh.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _shaftAngleController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Shaft angle',
          suffix: const Text('°'),
          suffixIcon: fieldHelpIcon(
            'The angle between the two members\' own shaft axes. 90° (the default) covers right-angle drives '
            'and miter gears - the overwhelming majority of real designs - but any angle is supported.',
          ),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pairBacklashController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Backlash'),
        onChanged: (_) => _schedulePreview(),
      ),
    ];
  }

  /// `docs/gear-design/09-presets.md`: both modes' fields captured
  /// together, same simplicity `GearChainDesignScreen._captureFields`
  /// already uses.
  Map<String, dynamic> _captureFields() => {
        'mode': _mode.name,
        'module': _module,
        'pressureAngleDegrees': _pressureAngleDegrees,
        'plane': _plane,
        'toothCount': _toothCountController.text,
        'faceWidth': _faceWidthController.text,
        'pitchConeAngle': _pitchConeAngleController.text,
        'backlash': _backlashController.text,
        'profileShift': _profileShiftController.text,
        'toothCount1': _toothCount1Controller.text,
        'profileShift1': _profileShift1Controller.text,
        'toothCount2': _toothCount2Controller.text,
        'profileShift2': _profileShift2Controller.text,
        'pairFaceWidth': _pairFaceWidthController.text,
        'shaftAngle': _shaftAngleController.text,
        'pairBacklash': _pairBacklashController.text,
      };

  void _applyPresetFields(Map<String, dynamic> fields) {
    setState(() {
      final modeName = fields['mode'] as String?;
      if (modeName != null) {
        _mode = BevelMultiKind.values.firstWhere((m) => m.name == modeName, orElse: () => _mode);
      }
      _module = (fields['module'] as num?)?.toDouble() ?? _module;
      _pressureAngleDegrees = (fields['pressureAngleDegrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
      _plane = fields['plane'] as String? ?? _plane;
      if (fields['toothCount'] is String) _toothCountController.text = fields['toothCount'] as String;
      if (fields['faceWidth'] is String) _faceWidthController.text = fields['faceWidth'] as String;
      if (fields['pitchConeAngle'] is String) _pitchConeAngleController.text = fields['pitchConeAngle'] as String;
      if (fields['backlash'] is String) _backlashController.text = fields['backlash'] as String;
      if (fields['profileShift'] is String) _profileShiftController.text = fields['profileShift'] as String;
      if (fields['toothCount1'] is String) _toothCount1Controller.text = fields['toothCount1'] as String;
      if (fields['profileShift1'] is String) _profileShift1Controller.text = fields['profileShift1'] as String;
      if (fields['toothCount2'] is String) _toothCount2Controller.text = fields['toothCount2'] as String;
      if (fields['profileShift2'] is String) _profileShift2Controller.text = fields['profileShift2'] as String;
      if (fields['pairFaceWidth'] is String) _pairFaceWidthController.text = fields['pairFaceWidth'] as String;
      if (fields['shaftAngle'] is String) _shaftAngleController.text = fields['shaftAngle'] as String;
      if (fields['pairBacklash'] is String) _pairBacklashController.text = fields['pairBacklash'] as String;
    });
    _schedulePreview();
  }

  Widget _buildValidationBanner() {
    final blockingError = _blockingError;
    if (blockingError != null) {
      return GearValidationBanner(color: Colors.red, icon: Icons.error_outline, text: blockingError);
    }
    if (_warnings.isNotEmpty) {
      return GearValidationBanner(color: Colors.amber, icon: Icons.warning_amber, text: _warnings.join('\n'));
    }
    return const SizedBox.shrink();
  }
}
