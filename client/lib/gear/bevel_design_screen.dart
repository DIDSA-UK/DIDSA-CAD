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
///
/// [crown] is not its own backend Feature type - a crown gear is exactly a
/// `BevelGearFeature` with `pitch_cone_angle_degrees` fixed at 90 (the
/// pitch cone flattens into a disc - confirmed on-device that `bevel_math`'s
/// spherical-involute formulas stay perfectly finite there, no asymptote).
/// So [crown] shares every code path [gear] does (same `createBevelGearFeature`/
/// `updateBevelGearFeature` calls) - it only changes the Pitch cone angle
/// field (fixed, hidden) and a few display strings. See `_isSingleGear`.
enum BevelMultiKind { gear, crown, pair }

const List<double> _standardModules = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
const List<double> _standardPressureAngles = [14.5, 20, 25];
const List<String> _fixedPlanes = ['XY', 'XZ', 'YZ'];

class BevelDesignScreen extends StatefulWidget {
  final DocumentApiClient? documentApi;
  final BevelMultiKind initialMode;

  /// Gear-tree UX: non-null (together with [editingFeatureId]) switches
  /// this screen from "create a new Part" into "reopen an existing
  /// BevelGearFeature/BevelPairFeature for editing" - see [GearDesignScreen]'s
  /// own identically-shaped pair of fields for the full reasoning.
  final String? editingPartId;
  final String? editingFeatureId;

  const BevelDesignScreen({
    super.key,
    this.documentApi,
    this.initialMode = BevelMultiKind.gear,
    this.editingPartId,
    this.editingFeatureId,
  });

  @override
  State<BevelDesignScreen> createState() => _BevelDesignScreenState();
}

class _BevelDesignScreenState extends State<BevelDesignScreen> {
  late final DocumentApiClient _api;
  late BevelMultiKind _mode;

  double _module = 4.0;
  double _pressureAngleDegrees = 20.0;
  String _plane = 'XY';

  // On-device feedback (bevel timeout investigation): mirrors
  // `GearDesignScreen._pointsPerFlank` - a bevel tooth's spherical-involute
  // flank is at least as expensive to build as a helical one (`app.
  // document.bevel._assemble_gear_solid`'s own `4*tooth_count + 2` face
  // sew/solid/flatten pipeline, doubled for a pair's two members), so the
  // same accuracy/build-cost tradeoff control applies here - unlike the
  // helical screen's slider, this one isn't gated behind any other field
  // since every bevel build (gear or pair) uses it.
  int _pointsPerFlank = 12;

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

  /// Auto-or-override for each member's own profile shift (`app.document.
  /// bevel_pair.resolve_member_profile_shifts` on the backend) - `true`
  /// (the default, matching `BevelPairMemberSpecSchema.profile_shift`'s
  /// own `None`-means-auto convention) sends no `profile_shift` override
  /// at all, letting the backend compute whichever value (0.0, or a
  /// negative shift) keeps this member's own tooth tip clear of the other
  /// member's material; flipping to `false` sends `_profileShift1Controller`/
  /// `_profileShift2Controller`'s own current text as an explicit value
  /// instead. While auto, the matching controller's text is driven by the
  /// live preview response's own `effectiveProfileShift` (read-only
  /// display, not user-edited) - flipping to manual keeps whatever number
  /// is showing as a sensible starting point to then adjust, rather than
  /// resetting to a bare `0`.
  bool _profileShift1Auto = true;
  bool _profileShift2Auto = true;

  Timer? _previewDebounce;
  bool _previewLoading = false;
  GearPreviewDto? _preview;
  List<String> _warnings = const [];
  String? _blockingError;

  bool _creating = false;
  String? _createError;

  bool get _isEditing => widget.editingPartId != null && widget.editingFeatureId != null;
  bool _loadingExisting = false;
  String? _loadError;

  /// Gear-tree UX: round-tripped unchanged on Save, same reasoning as
  /// `GearDesignScreen._mode`/`_targetBodyIds` - this screen has no Boss/Cut
  /// or target-Body picker UI, and `BevelPairFeature` has no Boss/Cut/
  /// target-Body concept at all.
  String _bevelGearMode = 'boss';
  List<String> _targetBodyIds = const [];

  /// True for both [BevelMultiKind.gear] and [BevelMultiKind.crown] - they
  /// share every single-gear code path (both hit `BevelGearFeature`'s own
  /// create/update/preview calls), differing only in a few display strings
  /// and whether the Pitch cone angle field is editable.
  bool get _isSingleGear => _mode != BevelMultiKind.pair;

  String _labelFor(BevelMultiKind kind) => switch (kind) {
        BevelMultiKind.gear => 'Bevel Gear',
        BevelMultiKind.crown => 'Crown Gear',
        BevelMultiKind.pair => 'Bevel Pair',
      };

  String get _modeLabel => _labelFor(_mode);

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    // A crown gear's pitch cone is fixed at 90 by definition - the field is
    // hidden (see `_buildBevelGearForm`), so this needs to be set up front
    // rather than left at the regular Bevel Gear default of 30.
    if (_mode == BevelMultiKind.crown) _pitchConeAngleController.text = '90';
    _api = widget.documentApi ?? DocumentApiClient();
    if (_isEditing) {
      _loadExistingFeature();
    } else {
      _schedulePreview();
    }
    _loadPresets();
  }

  /// Mirrors `GearDesignScreen._loadExistingFeature` exactly - see that
  /// method's own doc comment for why a no-op PATCH is used to read the
  /// Feature's current state.
  Future<void> _loadExistingFeature() async {
    setState(() => _loadingExisting = true);
    try {
      final partId = widget.editingPartId!;
      final featureId = widget.editingFeatureId!;
      final json = _isSingleGear
          ? await _api.updateBevelGearFeature(partId, featureId)
          : await _api.updateBevelPairFeature(partId, featureId);
      if (!mounted) return;
      setState(() {
        _applyExistingFeatureJson(json);
        _loadingExisting = false;
      });
      _schedulePreview();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loadingExisting = false;
      });
    }
  }

  void _applyExistingFeatureJson(Map<String, dynamic> json) {
    final planeRef =
        json['plane_ref'] == null ? null : PlaneRefDto.fromJson(json['plane_ref'] as Map<String, dynamic>);
    if (planeRef?.fixedPlane != null) _plane = planeRef!.fixedPlane!;
    _module = (json['module'] as num?)?.toDouble() ?? _module;
    _pressureAngleDegrees = (json['pressure_angle_degrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
    _pointsPerFlank = (json['points_per_flank'] as num?)?.toInt() ?? _pointsPerFlank;
    if (_isSingleGear) {
      _bevelGearMode = json['bevel_type'] as String? ?? _bevelGearMode;
      _targetBodyIds = (json['target_body_ids'] as List?)?.cast<String>() ?? _targetBodyIds;
      final toothCount = json['tooth_count'] as num?;
      if (toothCount != null) _toothCountController.text = toothCount.toInt().toString();
      final faceWidth = json['face_width'] as num?;
      if (faceWidth != null) _faceWidthController.text = faceWidth.toString();
      final pitchConeAngle = json['pitch_cone_angle_degrees'] as num?;
      if (pitchConeAngle != null) _pitchConeAngleController.text = pitchConeAngle.toString();
      final backlash = json['backlash'] as num?;
      if (backlash != null) _backlashController.text = backlash.toString();
      final profileShift = json['profile_shift'] as num?;
      if (profileShift != null) _profileShiftController.text = profileShift.toString();
      // A crown gear isn't its own Feature type on the wire - derive it
      // from the loaded pitch cone angle being (essentially) 90, same
      // "fixed by definition" threshold `_buildBevelGearForm` uses to
      // decide whether the field is editable.
      _mode = (pitchConeAngle != null && pitchConeAngle >= 89.999) ? BevelMultiKind.crown : BevelMultiKind.gear;
    } else {
      final member1 = json['member_1'] as Map<String, dynamic>?;
      final member2 = json['member_2'] as Map<String, dynamic>?;
      if (member1 != null) {
        _toothCount1Controller.text = (member1['tooth_count'] as num).toInt().toString();
        final rawShift1 = member1['profile_shift'] as num?;
        _profileShift1Auto = rawShift1 == null;
        // effective_profile_shift_1 is always present once resolved
        // (BevelPairFeatureResponse's own required field) - falls back to
        // the raw value (never null when not auto) or 0 only for a
        // malformed/older response.
        final effective1 = (json['effective_profile_shift_1'] as num?)?.toDouble();
        _profileShift1Controller.text = (rawShift1?.toDouble() ?? effective1 ?? 0.0).toString();
      }
      if (member2 != null) {
        _toothCount2Controller.text = (member2['tooth_count'] as num).toInt().toString();
        final rawShift2 = member2['profile_shift'] as num?;
        _profileShift2Auto = rawShift2 == null;
        final effective2 = (json['effective_profile_shift_2'] as num?)?.toDouble();
        _profileShift2Controller.text = (rawShift2?.toDouble() ?? effective2 ?? 0.0).toString();
      }
      final faceWidth = json['face_width'] as num?;
      if (faceWidth != null) _pairFaceWidthController.text = faceWidth.toString();
      final shaftAngle = json['shaft_angle_degrees'] as num?;
      if (shaftAngle != null) _shaftAngleController.text = shaftAngle.toString();
      final backlash = json['backlash'] as num?;
      if (backlash != null) _pairBacklashController.text = backlash.toString();
    }
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
      if (_isSingleGear) {
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
        final profileShift1 = _profileShift1Auto ? null : double.tryParse(_profileShift1Controller.text);
        final toothCount2 = int.tryParse(_toothCount2Controller.text);
        final profileShift2 = _profileShift2Auto ? null : double.tryParse(_profileShift2Controller.text);
        final faceWidth = double.tryParse(_pairFaceWidthController.text);
        final shaftAngle = double.tryParse(_shaftAngleController.text);
        final backlash = double.tryParse(_pairBacklashController.text);
        if (toothCount1 == null ||
            (!_profileShift1Auto && profileShift1 == null) ||
            toothCount2 == null ||
            (!_profileShift2Auto && profileShift2 == null) ||
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
        // While a member's own profile shift is "auto," its controller is
        // a read-only display of the live-computed value - drive it from
        // this fresh preview response rather than leave it stale
        // (`_buildBevelPairForm`'s own field is `enabled: false` in this
        // state, so the user was never editing it directly anyway).
        final members = result.bevelPair?.members;
        if (members != null) {
          for (final member in members) {
            if (member.label == 'member_1' && _profileShift1Auto) {
              _profileShift1Controller.text = member.effectiveProfileShift.toString();
            } else if (member.label == 'member_2' && _profileShift2Auto) {
              _profileShift2Controller.text = member.effectiveProfileShift.toString();
            }
          }
        }
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

  bool get _canCreate => _blockingError == null && _preview != null && !_creating && !_loadingExisting;

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final planeRef = PlaneRefDto(fixedPlane: _plane);
      if (_isEditing) {
        // Gear-tree UX: saves back onto the same Feature instead of minting
        // a new Part - mirrors GearDesignScreen._create's own editing
        // branch exactly.
        if (_isSingleGear) {
          await _api.updateBevelGearFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            bevelType: _bevelGearMode,
            module: _module,
            toothCount: int.parse(_toothCountController.text),
            faceWidth: double.parse(_faceWidthController.text),
            pitchConeAngleDegrees: double.parse(_pitchConeAngleController.text),
            pressureAngleDegrees: _pressureAngleDegrees,
            backlash: double.parse(_backlashController.text),
            profileShift: double.parse(_profileShiftController.text),
            planeRef: planeRef,
            targetBodyIds: _targetBodyIds,
            pointsPerFlank: _pointsPerFlank,
          );
        } else {
          await _api.updateBevelPairFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            module: _module,
            toothCount1: int.parse(_toothCount1Controller.text),
            profileShift1: _profileShift1Auto ? null : double.parse(_profileShift1Controller.text),
            toothCount2: int.parse(_toothCount2Controller.text),
            profileShift2: _profileShift2Auto ? null : double.parse(_profileShift2Controller.text),
            faceWidth: double.parse(_pairFaceWidthController.text),
            pressureAngleDegrees: _pressureAngleDegrees,
            shaftAngleDegrees: double.parse(_shaftAngleController.text),
            backlash: double.parse(_pairBacklashController.text),
            planeRef: planeRef,
            pointsPerFlank: _pointsPerFlank,
          );
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }

      // Bug fix (on-device feedback): this always starts a brand-new Part
      // - without resetting the session's Document first, it would just
      // pile onto whatever Document a previous tool-chooser entry already
      // created this session (see `DocumentApiClient.startNewDocument`'s
      // own doc comment). Only reached on the create-new path above (never
      // when `_isEditing`, which returns earlier) - editing in place must
      // never reset the session's Document out from under the Part being
      // edited.
      await _api.startNewDocument();
      final part = await _api.createPart('$_modeLabel Part');
      List<String> warnings = const [];
      if (_isSingleGear) {
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
          pointsPerFlank: _pointsPerFlank,
        );
        warnings = feature.warnings;
      } else {
        final feature = await _api.createBevelPairFeature(
          part.id,
          module: _module,
          toothCount1: int.parse(_toothCount1Controller.text),
          profileShift1: _profileShift1Auto ? null : double.parse(_profileShift1Controller.text),
          toothCount2: int.parse(_toothCount2Controller.text),
          profileShift2: _profileShift2Auto ? null : double.parse(_profileShift2Controller.text),
          faceWidth: double.parse(_pairFaceWidthController.text),
          pressureAngleDegrees: _pressureAngleDegrees,
          shaftAngleDegrees: double.parse(_shaftAngleController.text),
          backlash: double.parse(_pairBacklashController.text),
          planeRef: planeRef,
          pointsPerFlank: _pointsPerFlank,
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
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit $_modeLabel' : '$_modeLabel Design'),
      ),
      body: _loadingExisting
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Text(
                    'Could not load this bevel gear: $_loadError',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                )
              : LayoutBuilder(
        builder: (context, constraints) {
          final List<GearPreviewBevelMemberDto> members = _isSingleGear
              ? (_preview?.bevelGear != null ? [_preview!.bevelGear!] : const <GearPreviewBevelMemberDto>[])
              : (_preview?.bevelPair?.members ?? const <GearPreviewBevelMemberDto>[]);
          final canvas = BevelPreviewCanvas(
            members: members,
            meshPreview: _isSingleGear ? null : _preview?.bevelPair?.meshPreview,
          );
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
          // Gear-tree UX: while editing, a BevelGearFeature can't become a
          // BevelPairFeature (or vice versa) via this same Update endpoint,
          // so pair stays locked to itself - mirrors GearDesignScreen's own
          // identical restriction. Gear <-> Crown Gear *is* offered while
          // editing (unlike pair), since they're the same Feature type on
          // the wire - switching just changes pitch_cone_angle_degrees via
          // the same update call.
          segments: [
            for (final kind in _isEditing
                ? (_mode == BevelMultiKind.pair
                    ? const [BevelMultiKind.pair]
                    : const [BevelMultiKind.gear, BevelMultiKind.crown])
                : BevelMultiKind.values)
              ButtonSegment(value: kind, label: Text(_labelFor(kind))),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) {
            setState(() {
              _mode = selection.first;
              if (_mode == BevelMultiKind.crown) _pitchConeAngleController.text = '90';
            });
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
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('Tooth curve precision', style: Theme.of(context).textTheme.bodyMedium),
            ),
            fieldHelpIcon(
              'How many points each tooth flank is sampled at before fitting a smooth curve through '
              'them. Lower is faster to build (fewer points for the backend to loft/sew) but gives a '
              'more faceted tooth flank - most noticeable on a large module or low tooth count. A bevel '
              'tooth is one of the most expensive shapes this app builds, so this matters even for a '
              'plain Bevel Gear, and doubly so for a Bevel Pair (two full solids per build).',
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _pointsPerFlank.toDouble(),
                min: 4,
                max: 20,
                divisions: 16,
                label: '$_pointsPerFlank',
                onChanged: (value) => setState(() => _pointsPerFlank = value.round()),
              ),
            ),
            SizedBox(
              width: 88,
              child: Text(
                _pointsPerFlank <= 6
                    ? 'Draft ($_pointsPerFlank)'
                    : _pointsPerFlank >= 16
                        ? 'Fine ($_pointsPerFlank)'
                        : '$_pointsPerFlank pts',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_isSingleGear) ..._buildBevelGearForm() else ..._buildBevelPairForm(),
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
              : Text(_isEditing ? 'Save' : 'Create'),
        ),
        // On-device feedback (bevel timeout investigation): a bevel gear/pair
        // is a real, known-upfront-slow OCCT build (spherical-involute
        // flanks sewn into a solid, doubled for a pair's two members) -
        // shown unconditionally while `_creating`, mirroring
        // `GearDesignScreen`'s identical helical/herringbone hint.
        if (_creating)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              kComplexShapeBuildHint,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
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
      if (_mode == BevelMultiKind.crown)
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Pitch cone angle',
            suffixIcon: fieldHelpIcon(
              'A crown gear\'s pitch cone is flat by definition, so this is fixed at 90° and can\'t be '
              'edited here - switch to Bevel Gear above if you need a different angle.',
            ),
          ),
          child: const Text('90° (fixed)'),
        )
      else
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

  /// One bevel pair member's own "Profile shift" field: an auto-computed
  /// value by default (`app.document.bevel_pair.resolve_member_profile_
  /// shifts` - the smallest shift that keeps this member's own tooth tip
  /// clear of the other member's material, live-updated from the preview
  /// response's own `effectiveProfileShift` while [isAuto]), with a
  /// switch to override it with a manually-typed value instead. Unlike
  /// the standalone Bevel Gear screen's own plain `_profileShiftController`
  /// field (no meshing partner, so "auto" has no meaning there), a pair
  /// member's own default is genuinely computed against live-changing
  /// sibling-member state, so showing *both* the word "Auto" and the
  /// actual number - not just a static default - is what tells the user
  /// what's really going on, per the same on-device feedback that led to
  /// this field auto-resolving on the backend at all.
  Widget _buildProfileShiftField({
    required TextEditingController controller,
    required bool isAuto,
    required ValueChanged<bool> onAutoChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !isAuto,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: 'Profile shift',
              isDense: true,
              helperText: isAuto ? 'Auto - computed to avoid predicted mesh interference' : null,
              helperMaxLines: 2,
              suffixIcon: fieldHelpIcon(
                'Shifts this member\'s own tooth profile outward (positive) or inward (negative) from the '
                'pitch line - used to balance strength between a small pinion and a large gear, and to keep '
                'this member\'s own tooth tip clear of the other member\'s material. "Auto" computes the '
                'smallest shift that avoids predicted interference (0 if none is predicted); switch off to '
                'set your own value instead.',
              ),
            ),
            onChanged: (_) => _schedulePreview(),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(isAuto ? 'Auto' : 'Manual', style: Theme.of(context).textTheme.labelSmall),
            // On (true) = Auto, off = Manual - lit/right means "let the
            // backend decide," matching the switch's own default state
            // (Auto) starting lit.
            Switch(value: isAuto, onChanged: onAutoChanged),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildBevelPairForm() {
    return [
      const Text('Member 1 (pinion)', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(
        controller: _toothCount1Controller,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: const InputDecoration(labelText: 'Tooth count', isDense: true),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 8),
      _buildProfileShiftField(
        controller: _profileShift1Controller,
        isAuto: _profileShift1Auto,
        onAutoChanged: (auto) {
          setState(() => _profileShift1Auto = auto);
          _schedulePreview();
        },
      ),
      const SizedBox(height: 16),
      const Text('Member 2 (gear)', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(
        controller: _toothCount2Controller,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: const InputDecoration(labelText: 'Tooth count', isDense: true),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 8),
      _buildProfileShiftField(
        controller: _profileShift2Controller,
        isAuto: _profileShift2Auto,
        onAutoChanged: (auto) {
          setState(() => _profileShift2Auto = auto);
          _schedulePreview();
        },
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
        'pointsPerFlank': _pointsPerFlank,
        'plane': _plane,
        'toothCount': _toothCountController.text,
        'faceWidth': _faceWidthController.text,
        'pitchConeAngle': _pitchConeAngleController.text,
        'backlash': _backlashController.text,
        'profileShift': _profileShiftController.text,
        'toothCount1': _toothCount1Controller.text,
        'profileShift1': _profileShift1Controller.text,
        'profileShift1Auto': _profileShift1Auto,
        'toothCount2': _toothCount2Controller.text,
        'profileShift2': _profileShift2Controller.text,
        'profileShift2Auto': _profileShift2Auto,
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
      _pointsPerFlank = (fields['pointsPerFlank'] as num?)?.toInt() ?? _pointsPerFlank;
      _plane = fields['plane'] as String? ?? _plane;
      if (fields['toothCount'] is String) _toothCountController.text = fields['toothCount'] as String;
      if (fields['faceWidth'] is String) _faceWidthController.text = fields['faceWidth'] as String;
      if (fields['pitchConeAngle'] is String) _pitchConeAngleController.text = fields['pitchConeAngle'] as String;
      if (fields['backlash'] is String) _backlashController.text = fields['backlash'] as String;
      if (fields['profileShift'] is String) _profileShiftController.text = fields['profileShift'] as String;
      if (fields['toothCount1'] is String) _toothCount1Controller.text = fields['toothCount1'] as String;
      if (fields['profileShift1'] is String) _profileShift1Controller.text = fields['profileShift1'] as String;
      // Older presets (saved before profile shift could auto-resolve) have
      // no 'profileShift1Auto'/'profileShift2Auto' key at all - default to
      // manual (false) so they keep using their own saved explicit value
      // unchanged rather than silently switching to auto on load.
      _profileShift1Auto = fields['profileShift1Auto'] as bool? ?? false;
      if (fields['toothCount2'] is String) _toothCount2Controller.text = fields['toothCount2'] as String;
      if (fields['profileShift2'] is String) _profileShift2Controller.text = fields['profileShift2'] as String;
      _profileShift2Auto = fields['profileShift2Auto'] as bool? ?? false;
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
