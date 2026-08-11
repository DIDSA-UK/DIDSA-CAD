import 'dart:async';

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import '../viewport3d/part_screen.dart';
import 'bevel_design_screen.dart';
import 'field_help_icon.dart';
import 'gear_chain_design_screen.dart';
import 'gear_preset_controls.dart';
import 'gear_preset_store.dart';
import 'gear_preview_canvas.dart';
import 'gear_validation_banner.dart';
import 'standard_value_field.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s gear-type selector -
/// covers the two Feature types `GearFeature` (external/internal spur
/// gears, now including helical/herringbone teeth - Workstream 4a's
/// `helix_angle_degrees`/`herringbone` fields sit directly on the
/// External/Internal form, not as separate `GearDesignKind` values, since
/// they're orthogonal modifiers on the same Feature type rather than a
/// distinct one) and `RackFeature` (standalone rack, no helix concept).
/// Chain/planetary (`GearChainFeature`/`PlanetaryGearFeature`) and bevel/
/// bevel-pair (`BevelGearFeature`/`BevelPairFeature`) each get their own
/// dedicated screen instead of a `GearDesignKind` value - reached via this
/// screen's own app bar actions (`GearChainDesignScreen`, `BevelDesignScreen`)
/// - both are genuinely multi-gear/differently-shaped previews, not a
/// single-gear form variant (see those screens' own top-of-file comments).
enum GearDesignKind {
  external,
  internal,
  rack;

  String get apiValue => name;

  String get label => switch (this) {
        GearDesignKind.external => 'External',
        GearDesignKind.internal => 'Internal',
        GearDesignKind.rack => 'Rack',
      };
}

/// `00-conventions.md`'s field input style: module's own standard-value
/// table.
const List<double> _standardModules = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];

/// `00-conventions.md`'s field input style: pressure angle's own
/// standard-value table.
const List<double> _standardPressureAngles = [14.5, 20, 25];

const List<String> _fixedPlanes = ['XY', 'XZ', 'YZ'];

/// New `ToolChooserScreen` tile -> this dedicated screen (closer in shape
/// to `SketchScreen` than a compact `ResizableToolPanel`, since it needs a
/// 2D canvas alongside a form): a gear-type selector, a parameter form per
/// type, a live 2D preview canvas hitting `/gear/preview` on debounce
/// (same 500ms rhythm every other panel's live-PATCH already uses - see
/// `PartScreen`'s own `Timer`-based debounce fields), and a toggleable
/// reference-circle overlay. "Create" posts the real Feature via the
/// existing `gear-features`/`rack-features` endpoints and hands off to the
/// normal `PartScreen` 3D-viewport flow.
///
/// Positioning (`00-conventions.md`'s `plane_ref`/`PlaneRef` convention):
/// this screen is always reached fresh from `ToolChooserScreen`, before any
/// Part exists - there is no Body face or existing `CreatePlaneFeature` to
/// offer yet, so the full `PlaneRef` picker Mirror/Create Plane use (which
/// needs real Part geometry to pick a face from) has nothing to pick from
/// here. The plane field is scoped down to the three fixed reference planes
/// (XY/XZ/YZ) instead - still a full, always-visible, never-silently-
/// defaulted choice (pre-filled to XY), just without the Body-face/Plane-
/// feature options a Part-less entry point can't meaningfully offer.
class GearDesignScreen extends StatefulWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final DocumentApiClient? documentApi;

  /// Gear-tree UX: which kind this screen opens on - the free create flow
  /// always starts at [GearDesignKind.external] (unchanged), but a Build
  /// Tree tap re-entering this screen to edit an existing GearFeature/
  /// RackFeature already knows which one it is (`FeatureDto.type`) and
  /// passes it here so the form doesn't open on the wrong kind for a beat
  /// before [_loadExistingFeature] corrects it.
  final GearDesignKind initialKind;

  /// Gear-tree UX: non-null (together with [editingFeatureId]) switches
  /// this screen from "create a new Part with a fresh gear" into "reopen an
  /// existing GearFeature/RackFeature for editing" - see [_isEditing].
  final String? editingPartId;
  final String? editingFeatureId;

  const GearDesignScreen({
    super.key,
    this.documentApi,
    this.initialKind = GearDesignKind.external,
    this.editingPartId,
    this.editingFeatureId,
  });

  @override
  State<GearDesignScreen> createState() => _GearDesignScreenState();
}

class _GearDesignScreenState extends State<GearDesignScreen> {
  late final DocumentApiClient _api;

  GearDesignKind _kind = GearDesignKind.external;
  double _module = 2.0;
  double _pressureAngleDegrees = 20.0;
  double _profileShift = 0.0;
  double _backlash = 0.0;
  double _rootFilletRadius = 0.0;
  double _helixAngleDegrees = 0.0;
  bool _herringbone = false;
  String _plane = 'XY';
  bool _showReferenceOverlay = true;

  final _toothCountController = TextEditingController(text: '20');
  final _faceWidthController = TextEditingController(text: '5');
  final _outerDiameterController = TextEditingController();
  final _backingHeightController = TextEditingController();

  Timer? _previewDebounce;
  bool _previewLoading = false;
  GearPreviewDto? _preview;
  List<String> _warnings = const [];
  String? _blockingError;

  bool _creating = false;
  String? _createError;

  /// Gear-tree UX: true once [widget.editingPartId]/[widget.editingFeatureId]
  /// are both set - see those fields' own doc comments.
  bool get _isEditing => widget.editingPartId != null && widget.editingFeatureId != null;

  bool _loadingExisting = false;
  String? _loadError;

  /// Gear-tree UX: the existing Feature's own `gear_type`/`rack_type`
  /// (Boss/Cut) and `target_body_ids`, round-tripped unchanged on Save -
  /// this screen has no Boss/Cut or target-Body picker UI at all (a brand
  /// new gear/rack it creates is always `'boss'` with no targets), so
  /// editing must never silently downgrade an existing Cut gear (or one
  /// fused into specific Bodies) back to a targetless Boss.
  String _mode = 'boss';
  List<String> _targetBodyIds = const [];

  @override
  void initState() {
    super.initState();
    _api = widget.documentApi ?? DocumentApiClient();
    _kind = widget.initialKind;
    if (_isEditing) {
      _loadExistingFeature();
    } else {
      _schedulePreview();
    }
    _loadPresets();
  }

  /// Gear-tree UX: reads the Feature's current full parameter set via a
  /// no-op PATCH (every gear-family Update endpoint always returns its
  /// complete post-update state, so calling it with every field omitted is
  /// a harmless way to read the current one back - see
  /// `DocumentApiClient.updateGearFeature`'s own doc comment), then
  /// populates every form field from it exactly as if the user had entered
  /// them, mirroring [_applyPresetFields]'s own "repopulate the form"
  /// shape.
  Future<void> _loadExistingFeature() async {
    setState(() => _loadingExisting = true);
    try {
      final partId = widget.editingPartId!;
      final featureId = widget.editingFeatureId!;
      final json = _kind == GearDesignKind.rack
          ? await _api.updateRackFeature(partId, featureId)
          : await _api.updateGearFeature(partId, featureId);
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
    final planeRef = json['plane_ref'] == null
        ? null
        : PlaneRefDto.fromJson(json['plane_ref'] as Map<String, dynamic>);
    if (planeRef?.fixedPlane != null) _plane = planeRef!.fixedPlane!;
    _module = (json['module'] as num?)?.toDouble() ?? _module;
    _pressureAngleDegrees = (json['pressure_angle_degrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
    final toothCount = json['tooth_count'] as num?;
    if (toothCount != null) _toothCountController.text = toothCount.toInt().toString();
    final faceWidth = json['face_width'] as num?;
    if (faceWidth != null) _faceWidthController.text = _formatDouble(faceWidth.toDouble());
    _backlash = (json['backlash'] as num?)?.toDouble() ?? _backlash;
    _targetBodyIds = (json['target_body_ids'] as List?)?.cast<String>() ?? _targetBodyIds;
    if (_kind == GearDesignKind.rack) {
      _mode = json['rack_type'] as String? ?? _mode;
      final backingHeight = json['backing_height'] as num?;
      if (backingHeight != null) _backingHeightController.text = _formatDouble(backingHeight.toDouble());
    } else {
      _mode = json['gear_type'] as String? ?? _mode;
      _kind = (json['is_internal'] as bool? ?? false) ? GearDesignKind.internal : GearDesignKind.external;
      _profileShift = (json['profile_shift'] as num?)?.toDouble() ?? _profileShift;
      _rootFilletRadius = (json['root_fillet_radius'] as num?)?.toDouble() ?? _rootFilletRadius;
      _helixAngleDegrees = (json['helix_angle_degrees'] as num?)?.toDouble() ?? _helixAngleDegrees;
      _herringbone = json['herringbone'] as bool? ?? _herringbone;
      final outerDiameter = json['outer_diameter'] as num?;
      if (outerDiameter != null) _outerDiameterController.text = _formatDouble(outerDiameter.toDouble());
    }
  }

  /// Mirrors `MeshViewerScreen._loadScenePrefs`'s own "don't block the
  /// first frame on a shared_preferences read" pattern - not awaited from
  /// [initState]. Presets are only actually read once "Load preset" is
  /// tapped (`GearPresetControls`), so this just warms the in-memory cache
  /// early rather than gating anything on it.
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
    _outerDiameterController.dispose();
    _backingHeightController.dispose();
    if (widget.documentApi == null) _api.close();
    super.dispose();
  }

  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 500), _fetchPreview);
  }

  Future<void> _fetchPreview() async {
    final toothCount = int.tryParse(_toothCountController.text);
    if (toothCount == null) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _warnings = const [];
        _blockingError = 'Enter a valid tooth count';
      });
      return;
    }

    double? outerDiameter;
    if (_kind == GearDesignKind.internal) {
      outerDiameter = double.tryParse(_outerDiameterController.text);
      if (outerDiameter == null) {
        if (!mounted) return;
        setState(() {
          _preview = null;
          _warnings = const [];
          _blockingError = 'Enter an outer diameter for an internal gear';
        });
        return;
      }
    }

    final backingHeight =
        _kind == GearDesignKind.rack ? double.tryParse(_backingHeightController.text) : null;

    setState(() => _previewLoading = true);
    try {
      final result = await _api.previewGear(
        gearKind: _kind.apiValue,
        module: _module,
        toothCount: toothCount,
        pressureAngleDegrees: _pressureAngleDegrees,
        profileShift: _kind == GearDesignKind.rack ? 0.0 : _profileShift,
        backlash: _backlash,
        outerDiameter: outerDiameter,
        backingHeight: backingHeight,
      );
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

  void _onKindChanged(GearDesignKind kind) {
    setState(() {
      _kind = kind;
      if (kind == GearDesignKind.internal) {
        // On-device feedback: an internal gear's addendum points *inward*
        // (`spur_gear_geometry`'s `is_internal` sign flip) - at this
        // screen's own default module/pressure angle, a 20-tooth internal
        // gear's addendum radius already sits inside its base circle,
        // which `gear_math.sample_involute_flank` can't sample (raises,
        // surfaced here as a blocking "invalid_gear_preview_parameters"
        // 422 - correct behaviour per `00-conventions.md`'s no-valid-
        // geometry exception, but a bad first impression to walk a user
        // into via this screen's *own* default the instant they pick
        // Internal). Bumped to a tooth count confirmed clear of that
        // (module 2/20°: 34 is the first that clears it, 40 used for
        // headroom) only while still this screen's own untouched default -
        // never overwrites a tooth count the user deliberately chose.
        if (_toothCountController.text == '20') {
          _toothCountController.text = '40';
        }
        // Seed a sensible starting outer diameter the first time Internal
        // is picked, so the form isn't left permanently blocked on an
        // empty required field the user hasn't touched yet - comfortably
        // clear of the tooth profile's own addendum reach, not a value
        // meant to be kept as-is.
        if (_outerDiameterController.text.isEmpty) {
          final toothCount = int.tryParse(_toothCountController.text) ?? 40;
          _outerDiameterController.text = _formatDouble(_module * (toothCount + 8));
        }
      }
    });
    _schedulePreview();
  }

  static String _formatDouble(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canCreate =>
      _blockingError == null &&
      _preview != null &&
      !_creating &&
      !_loadingExisting &&
      double.tryParse(_faceWidthController.text) != null;

  Future<void> _create() async {
    if (!_canCreate) return;
    final toothCount = int.tryParse(_toothCountController.text);
    final faceWidth = double.tryParse(_faceWidthController.text);
    if (toothCount == null || faceWidth == null) return;

    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final planeRef = PlaneRefDto(fixedPlane: _plane);
      if (_isEditing) {
        // Gear-tree UX: saves back onto the same Feature instead of minting
        // a new Part - the Build Tree tap that opened this screen already
        // engaged rollback around every Feature after this one
        // (`PartScreen._onFeatureTap`), so it (and the Part it belongs to)
        // is still exactly where it was; there's nothing to navigate to but
        // back.
        if (_kind == GearDesignKind.rack) {
          await _api.updateRackFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            rackType: _mode,
            module: _module,
            toothCount: toothCount,
            faceWidth: faceWidth,
            pressureAngleDegrees: _pressureAngleDegrees,
            backlash: _backlash,
            backingHeight: double.tryParse(_backingHeightController.text),
            planeRef: planeRef,
            targetBodyIds: _targetBodyIds,
          );
        } else {
          await _api.updateGearFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            gearType: _mode,
            isInternal: _kind == GearDesignKind.internal,
            module: _module,
            toothCount: toothCount,
            faceWidth: faceWidth,
            pressureAngleDegrees: _pressureAngleDegrees,
            profileShift: _profileShift,
            backlash: _backlash,
            rootFilletRadius: _rootFilletRadius,
            outerDiameter: _kind == GearDesignKind.internal ? double.tryParse(_outerDiameterController.text) : null,
            planeRef: planeRef,
            targetBodyIds: _targetBodyIds,
            helixAngleDegrees: _helixAngleDegrees,
            herringbone: _herringbone,
          );
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }

      final part = await _api.createPart('Gear Part');
      List<String> warnings = const [];
      if (_kind == GearDesignKind.rack) {
        await _api.createRackFeature(
          part.id,
          rackType: 'boss',
          module: _module,
          toothCount: toothCount,
          faceWidth: faceWidth,
          pressureAngleDegrees: _pressureAngleDegrees,
          backlash: _backlash,
          backingHeight: double.tryParse(_backingHeightController.text),
          planeRef: planeRef,
        );
      } else {
        final feature = await _api.createGearFeature(
          part.id,
          gearType: 'boss',
          isInternal: _kind == GearDesignKind.internal,
          module: _module,
          toothCount: toothCount,
          faceWidth: faceWidth,
          pressureAngleDegrees: _pressureAngleDegrees,
          profileShift: _profileShift,
          backlash: _backlash,
          rootFilletRadius: _rootFilletRadius,
          outerDiameter: _kind == GearDesignKind.internal ? double.tryParse(_outerDiameterController.text) : null,
          planeRef: planeRef,
          helixAngleDegrees: _helixAngleDegrees,
          herringbone: _herringbone,
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
        title: Text(_isEditing ? 'Edit ${_kind == GearDesignKind.rack ? 'Rack' : 'Gear'}' : 'Gear Design'),
        // Gear-tree UX: the "discover a different gear-family screen"
        // actions only make sense from the free-create entry point - while
        // editing an existing Feature there is nowhere else to go but back
        // to this same one.
        actions: _isEditing
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GearChainDesignScreen()),
                  ),
                  child: const Text('Chain / Planetary'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BevelDesignScreen()),
                  ),
                  child: const Text('Bevel'),
                ),
              ],
      ),
      body: _loadingExisting
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Text(
                    'Could not load this gear: $_loadError',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                )
              : LayoutBuilder(
        builder: (context, constraints) {
          final canvas = GearPreviewCanvas(preview: _preview, showReferenceOverlay: _showReferenceOverlay);
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
              SizedBox(width: 360, child: form),
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
        SegmentedButton<GearDesignKind>(
          // Gear-tree UX: while editing, only offer the kinds the current
          // Feature type could actually become - a RackFeature has no
          // internal/external concept and a GearFeature can't turn into a
          // standalone RackFeature via this same Update endpoint, so
          // switching families mid-edit isn't offered (only External <->
          // Internal, both still real `is_internal` toggles on the same
          // GearFeature).
          segments: [
            for (final kind in _isEditing
                ? (_kind == GearDesignKind.rack
                    ? const [GearDesignKind.rack]
                    : const [GearDesignKind.external, GearDesignKind.internal])
                : GearDesignKind.values)
              ButtonSegment(value: kind, label: Text(kind.label)),
          ],
          selected: {_kind},
          onSelectionChanged: (selection) => _onKindChanged(selection.first),
        ),
        const SizedBox(height: 16),
        StandardValueField(
          label: 'Module',
          standardValues: _standardModules,
          value: _module,
          helpText: 'Tooth size - pitch diameter divided by tooth count. Larger module means larger, '
              'stronger teeth for the same tooth count.',
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
          helpText: 'The angle between a tooth\'s profile and a line perpendicular to the pitch circle. '
              '20° is the modern standard; 14.5° is an older standard kept for compatibility.',
          onChanged: (value) {
            setState(() => _pressureAngleDegrees = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _toothCountController,
          keyboardType: const TextInputType.numberWithOptions(signed: false),
          decoration: InputDecoration(
            labelText: 'Tooth count',
            suffixIcon: fieldHelpIcon('How many teeth this gear has, evenly spaced around it.'),
          ),
          onChanged: (_) => _schedulePreview(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _faceWidthController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Face width',
            suffixIcon: fieldHelpIcon('How far the gear is extruded along its own axis - its thickness.'),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_kind != GearDesignKind.rack) ...[
          const SizedBox(height: 12),
          TextField(
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: 'Profile shift',
              suffixIcon: fieldHelpIcon(
                'Shifts the tooth profile outward (positive) or inward (negative) from standard - '
                'changes tooth thickness and can help avoid undercut on low tooth counts.',
              ),
            ),
            onChanged: (text) {
              final value = double.tryParse(text);
              if (value != null) {
                setState(() => _profileShift = value);
                _schedulePreview();
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Root fillet radius',
              // On-device feedback: /gear/preview genuinely can't reflect
              // this (cosmetic-only at OCCT-construction time, gear_math
              // never reads it - see the backend router's own docstring),
              // so without this note a user has no way to tell that's
              // intentional rather than the field silently not working.
              helperText: 'Not shown in the preview above - visible after Create',
              suffixIcon: fieldHelpIcon(
                'Rounds the corner at the base of each tooth for strength. 0 leaves a sharp corner.',
              ),
            ),
            onChanged: (text) {
              final value = double.tryParse(text);
              if (value != null) setState(() => _rootFilletRadius = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: 'Helix angle',
              suffix: const Text('°'),
              // Same reasoning as root fillet's identical helper text above:
              // `04-helical-herringbone-loft.md`'s own spike found a
              // helical tooth's flat 2D outline is identical to the
              // equivalent spur profile - the twist is a 3D-only effect
              // `/gear/preview`'s response has no way to represent.
              helperText: 'Not shown in the preview above - visible after Create',
              suffixIcon: fieldHelpIcon(
                'Angles the teeth relative to the gear\'s own axis, for quieter, smoother meshing. '
                '0° is a plain straight-tooth (spur) gear.',
              ),
            ),
            onChanged: (text) {
              final value = double.tryParse(text);
              if (value != null) {
                setState(() {
                  _helixAngleDegrees = value;
                  if (value == 0.0) _herringbone = false;
                });
              }
            },
          ),
          if (_helixAngleDegrees != 0.0) ...[
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Herringbone'),
              subtitle: const Text('Two mirrored helical halves meeting at the mid-plane, instead of one twist '
                  'the full face width - cancels the axial thrust a plain helical gear produces.'),
              value: _herringbone,
              onChanged: (value) => setState(() => _herringbone = value),
            ),
          ],
        ],
        const SizedBox(height: 12),
        TextField(
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Backlash',
            suffixIcon: fieldHelpIcon(
              'Extra clearance subtracted from tooth thickness, so mating teeth don\'t jam.',
            ),
          ),
          onChanged: (text) {
            final value = double.tryParse(text);
            if (value != null) {
              setState(() => _backlash = value);
              _schedulePreview();
            }
          },
        ),
        if (_kind == GearDesignKind.internal) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _outerDiameterController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Outer diameter (required)',
              suffixIcon: fieldHelpIcon(
                'The ring\'s own outer rim diameter - must be larger than the tooth profile\'s own '
                'reach, or there\'s no rim material left.',
              ),
            ),
            onChanged: (_) => _schedulePreview(),
          ),
        ],
        if (_kind == GearDesignKind.rack) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _backingHeightController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Backing height',
              hintText: 'Default: 2 × module',
              suffixIcon: fieldHelpIcon(
                'Solid material thickness below the tooth root. Leave blank for a sensible default '
                '(2 × module).',
              ),
            ),
            onChanged: (_) => _schedulePreview(),
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: 'Plane',
            suffixIcon: fieldHelpIcon('Which fixed reference plane the gear is built on.'),
          ),
          initialValue: _plane,
          items: [for (final plane in _fixedPlanes) DropdownMenuItem(value: plane, child: Text(plane))],
          onChanged: (value) {
            if (value != null) setState(() => _plane = value);
          },
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show reference circles'),
          value: _showReferenceOverlay,
          onChanged: (value) => setState(() => _showReferenceOverlay = value),
        ),
        const SizedBox(height: 12),
        GearPresetControls(kind: 'gear_design', captureFields: _captureFields, onLoad: _applyPresetFields),
        const SizedBox(height: 8),
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
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEditing ? 'Save' : 'Create'),
        ),
      ],
    );
  }

  /// `docs/gear-design/09-presets.md`: this form's own current state,
  /// captured as a plain map - controller text is snapshotted as-is
  /// (rather than the parsed number) so an in-progress/blank field round-
  /// trips exactly, matching what the user actually typed.
  Map<String, dynamic> _captureFields() => {
        'kind': _kind.name,
        'module': _module,
        'pressureAngleDegrees': _pressureAngleDegrees,
        'toothCount': _toothCountController.text,
        'faceWidth': _faceWidthController.text,
        'profileShift': _profileShift,
        'backlash': _backlash,
        'rootFilletRadius': _rootFilletRadius,
        'helixAngleDegrees': _helixAngleDegrees,
        'herringbone': _herringbone,
        'outerDiameter': _outerDiameterController.text,
        'backingHeight': _backingHeightController.text,
        'plane': _plane,
      };

  /// The inverse of [_captureFields] - loading a preset re-populates the
  /// form exactly as if the user had typed/selected every value
  /// themselves, then re-fetches the preview (`09-presets.md`'s own "a
  /// convenience for re-populating the form" framing - no ongoing link to
  /// the preset afterward).
  void _applyPresetFields(Map<String, dynamic> fields) {
    setState(() {
      final kindName = fields['kind'] as String?;
      if (kindName != null) {
        _kind = GearDesignKind.values.firstWhere((k) => k.name == kindName, orElse: () => _kind);
      }
      _module = (fields['module'] as num?)?.toDouble() ?? _module;
      _pressureAngleDegrees = (fields['pressureAngleDegrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
      if (fields['toothCount'] is String) _toothCountController.text = fields['toothCount'] as String;
      if (fields['faceWidth'] is String) _faceWidthController.text = fields['faceWidth'] as String;
      _profileShift = (fields['profileShift'] as num?)?.toDouble() ?? _profileShift;
      _backlash = (fields['backlash'] as num?)?.toDouble() ?? _backlash;
      _rootFilletRadius = (fields['rootFilletRadius'] as num?)?.toDouble() ?? _rootFilletRadius;
      _helixAngleDegrees = (fields['helixAngleDegrees'] as num?)?.toDouble() ?? _helixAngleDegrees;
      _herringbone = fields['herringbone'] as bool? ?? _herringbone;
      if (fields['outerDiameter'] is String) _outerDiameterController.text = fields['outerDiameter'] as String;
      if (fields['backingHeight'] is String) _backingHeightController.text = fields['backingHeight'] as String;
      _plane = fields['plane'] as String? ?? _plane;
    });
    _schedulePreview();
  }

  /// `00-conventions.md`'s non-blocking validation banner: a `gear_math`
  /// validation with no valid geometry at all ([_blockingError], from a 422)
  /// blocks Create outright ([_canCreate]); anything else worth surfacing
  /// (currently just undercut risk, [_warnings]) is shown but never blocks.
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
