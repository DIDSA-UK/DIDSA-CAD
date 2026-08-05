import 'dart:async';

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import '../viewport3d/part_screen.dart';
import 'field_help_icon.dart';
import 'gear_chain_design_screen.dart';
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
/// Chain/planetary/bevel/bevel-pair (Workstreams 5/10/11's own Feature
/// types) still have no client UI - out of scope for this pass, tracked
/// separately (see `docs/gear-design/README.md`'s workstream table).
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

  const GearDesignScreen({super.key, this.documentApi});

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

  @override
  void initState() {
    super.initState();
    _api = widget.documentApi ?? DocumentApiClient();
    _schedulePreview();
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
      _blockingError == null && _preview != null && !_creating && double.tryParse(_faceWidthController.text) != null;

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
      final part = await _api.createPart('Gear Part');
      final planeRef = PlaneRefDto(fixedPlane: _plane);
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
        title: const Text('Gear Design'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GearChainDesignScreen()),
            ),
            child: const Text('Chain / Planetary'),
          ),
        ],
      ),
      body: LayoutBuilder(
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
          segments: [
            for (final kind in GearDesignKind.values) ButtonSegment(value: kind, label: Text(kind.label)),
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
              : const Text('Create'),
        ),
      ],
    );
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
