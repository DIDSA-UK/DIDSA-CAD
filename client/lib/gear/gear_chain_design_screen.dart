import 'dart:async';

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import '../viewport3d/part_screen.dart';
import '../viewport3d/pending_job_store.dart';
import 'field_help_icon.dart';
import 'gear_chain_preview_canvas.dart';
import 'gear_preset_controls.dart';
import 'gear_preset_store.dart';
import 'gear_validation_banner.dart';
import 'standard_value_field.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
/// bevel-pair preview" extension, the chain/planetary half - a second
/// dedicated screen alongside [GearDesignScreen] rather than folded into
/// its own `GearDesignKind` selector: `GearChainFeature`/
/// `PlanetaryGearFeature` are genuinely multi-gear (a stage list, or a
/// sun/ring/planet-count set) with a genuinely different preview shape
/// (every member's own outline + interference highlighting + ratio/
/// direction, not one outline + reference circles), so this screen owns
/// its own form/canvas pairing instead of overloading the single-gear
/// screen's widget tree. Reached from [GearDesignScreen]'s own app bar
/// action, keeping "Gear Design" as the one discovery point `08`'s own
/// gear-type selector describes.
///
/// v1 UI scope, matching `05-gear-chain-and-planetary.md`'s own "v1 UI
/// creates exactly one implicit group per chain" note: a chain has one
/// shared module/pressure-angle (one `GearGroup`, id `"g1"`) and
/// single-gear/rack stages only - no compound-station UI yet (the backend
/// already supports it; this pass just doesn't surface it, the same
/// "backend done, client UI deferred" pattern every other still-unbuilt
/// gear-type UI in this project follows).
enum GearMultiKind { chain, planetary }

enum ChainStageKind {
  external,
  internal,
  rack;

  String get apiValue => name;

  String get label => switch (this) {
        ChainStageKind.external => 'External',
        ChainStageKind.internal => 'Internal',
        ChainStageKind.rack => 'Rack',
      };
}

const List<double> _standardModules = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
const List<double> _standardPressureAngles = [14.5, 20, 25];
const List<String> _fixedPlanes = ['XY', 'XZ', 'YZ'];

/// Gear-tree UX: thrown by [_GearChainDesignScreenState._applyExistingFeatureJson]
/// for an existing Feature this screen can read but can't safely represent
/// (currently just a GearChainFeature with a compound stage - v1 UI scope,
/// see that method's own comment) - caught by [_GearChainDesignScreenState._loadExistingFeature]
/// and surfaced the same way a failed fetch itself would be, rather than
/// falling through to a mangled or silently-wrong form.
class _UnsupportedExistingFeature implements Exception {
  final String message;
  const _UnsupportedExistingFeature(this.message);
}

class _ChainStageForm {
  ChainStageKind kind;
  final TextEditingController toothCountController;
  final TextEditingController faceWidthController;
  final TextEditingController turnAngleController;
  final TextEditingController outerDiameterController;

  _ChainStageForm({
    this.kind = ChainStageKind.external,
    // 36T: comfortably clear of the ~30-34-tooth real involute tip-
    // interference threshold two similarly-sized external gears hit at
    // standard proportions (measured directly on this app's own geometry,
    // see docs/status.md) - a fresh stage should mesh cleanly by default,
    // not silently interfere the way 15T used to.
    String toothCount = '36',
    String faceWidth = '5',
    String turnAngle = '0',
    String outerDiameter = '',
  })  : toothCountController = TextEditingController(text: toothCount),
        faceWidthController = TextEditingController(text: faceWidth),
        turnAngleController = TextEditingController(text: turnAngle),
        outerDiameterController = TextEditingController(text: outerDiameter);

  void dispose() {
    toothCountController.dispose();
    faceWidthController.dispose();
    turnAngleController.dispose();
    outerDiameterController.dispose();
  }
}

class GearChainDesignScreen extends StatefulWidget {
  final DocumentApiClient? documentApi;
  final GearMultiKind initialMode;

  /// Gear-tree UX: non-null (together with [editingFeatureId]) switches
  /// this screen from "create a new Part" into "reopen an existing
  /// GearChainFeature/PlanetaryGearFeature for editing" - see
  /// [GearDesignScreen]'s own identically-shaped pair of fields for the full
  /// reasoning.
  final String? editingPartId;
  final String? editingFeatureId;

  const GearChainDesignScreen({
    super.key,
    this.documentApi,
    this.initialMode = GearMultiKind.chain,
    this.editingPartId,
    this.editingFeatureId,
  });

  @override
  State<GearChainDesignScreen> createState() => _GearChainDesignScreenState();
}

class _GearChainDesignScreenState extends State<GearChainDesignScreen> {
  late final DocumentApiClient _api;
  late GearMultiKind _mode;

  double _module = 2.0;
  double _pressureAngleDegrees = 20.0;
  String _plane = 'XY';

  // Chain mode state.
  final _startDirectionController = TextEditingController(text: '0');
  final _printClearanceController = TextEditingController(text: '0.2');
  // 36T/40T: a real, measured (BRepAlgoAPI_Common, 0.00000mm^3) meshing
  // pair, not a guess - see docs/status.md's dated entry for this default
  // change.
  final List<_ChainStageForm> _stages = [
    _ChainStageForm(toothCount: '36'),
    _ChainStageForm(toothCount: '40'),
  ];

  // Planetary mode state. 40T sun / 120T ring / 4 planets: the exact
  // combination measured at 0.000000mm^3 overlap across the sun, ring,
  // and every planet (real OCCT, see docs/status.md) - the same "reuse
  // already-proven-safe numbers" reasoning as the chain default above.
  // Assembly condition (sun+ring) % planet_count == 0 holds (160 % 4 == 0).
  final _sunToothCountController = TextEditingController(text: '40');
  final _ringToothCountController = TextEditingController(text: '120');
  final _planetCountController = TextEditingController(text: '4');
  final _planetaryFaceWidthController = TextEditingController(text: '5');
  // 260mm: at module 2.0 a 120-tooth ring's own dedendum diameter is
  // 2 * (2 * (60 + 1.25)) = 245mm - this must exceed that (server-
  // validated), so 260 preserves the old default's own ~15mm margin above
  // its ring's dedendum diameter, just scaled to the new tooth count.
  final _ringOuterDiameterController = TextEditingController(text: '260');

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

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
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
      final json = _mode == GearMultiKind.chain
          ? await _api.updateGearChainFeature(partId, featureId)
          : await _api.updatePlanetaryGearFeature(partId, featureId);
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
    } on _UnsupportedExistingFeature catch (e) {
      // v1 UI scope: a chain with a compound stage - this screen can't
      // represent or resave one (see `_applyExistingFeatureJson`'s own
      // comment), so this fails the load outright rather than silently
      // showing/saving a mangled placeholder that would corrupt the real
      // chain on Save. [_loadError] being set keeps the form (and its Save
      // button) from ever rendering at all - see `build`'s own branch.
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
    if (_mode == GearMultiKind.chain) {
      // v1 UI scope (`05-gear-chain-and-planetary.md`'s own note, see this
      // screen's top-of-file comment): exactly one implicit group, so
      // module/pressure angle are read from `groups[0]` the same way
      // [_groups] always sends exactly one group back.
      final groups = json['groups'] as List?;
      if (groups != null && groups.isNotEmpty) {
        final group0 = groups.first as Map<String, dynamic>;
        _module = (group0['module'] as num?)?.toDouble() ?? _module;
        _pressureAngleDegrees = (group0['pressure_angle_degrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
      }
      final startDirection = json['start_direction_degrees'] as num?;
      if (startDirection != null) _startDirectionController.text = startDirection.toString();
      final printClearance = json['print_clearance_margin'] as num?;
      if (printClearance != null) _printClearanceController.text = printClearance.toString();
      // Same v1 UI scope: single-member stages only - a stage this screen
      // never could have created (a compound stage) can't be safely edited
      // here at all: rebuilding [_stages] would have to drop it, and
      // resaving would then silently replace the real compound stage with
      // whatever placeholder took its place. Fails the whole load instead.
      final stagesJson = (json['stages'] as List?)?.cast<Map<String, dynamic>>();
      if (stagesJson != null && stagesJson.any((s) => s['member'] == null)) {
        throw _UnsupportedExistingFeature(
          'This chain has a compound stage, which this screen can\'t edit yet.',
        );
      }
      if (stagesJson != null && stagesJson.length >= 2) {
        for (final stage in _stages) {
          stage.dispose();
        }
        _stages.clear();
        for (final stageJson in stagesJson) {
          final member = stageJson['member'] as Map<String, dynamic>;
          final kind = ChainStageKind.values.firstWhere(
            (k) => k.apiValue == member['member_type'],
            orElse: () => ChainStageKind.external,
          );
          _stages.add(
            _ChainStageForm(
              kind: kind,
              toothCount: (member['tooth_count'] as num).toInt().toString(),
              faceWidth: (member['face_width'] as num).toString(),
              turnAngle: ((stageJson['turn_angle_degrees'] as num?) ?? 0.0).toString(),
              outerDiameter: (member['outer_diameter'] as num?)?.toString() ?? '',
            ),
          );
        }
      }
    } else {
      _module = (json['module'] as num?)?.toDouble() ?? _module;
      _pressureAngleDegrees = (json['pressure_angle_degrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
      final sunToothCount = json['sun_tooth_count'] as num?;
      if (sunToothCount != null) _sunToothCountController.text = sunToothCount.toInt().toString();
      final ringToothCount = json['ring_tooth_count'] as num?;
      if (ringToothCount != null) _ringToothCountController.text = ringToothCount.toInt().toString();
      final planetCount = json['planet_count'] as num?;
      if (planetCount != null) _planetCountController.text = planetCount.toInt().toString();
      final faceWidth = json['face_width'] as num?;
      if (faceWidth != null) _planetaryFaceWidthController.text = faceWidth.toString();
      final ringOuterDiameter = json['ring_outer_diameter'] as num?;
      if (ringOuterDiameter != null) _ringOuterDiameterController.text = ringOuterDiameter.toString();
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
    _startDirectionController.dispose();
    _printClearanceController.dispose();
    for (final stage in _stages) {
      stage.dispose();
    }
    _sunToothCountController.dispose();
    _ringToothCountController.dispose();
    _planetCountController.dispose();
    _planetaryFaceWidthController.dispose();
    _ringOuterDiameterController.dispose();
    if (widget.documentApi == null) _api.close();
    super.dispose();
  }

  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 500), _fetchPreview);
  }

  List<GearGroupInputDto> _groups() => [GearGroupInputDto(id: 'g1', module: _module, pressureAngleDegrees: _pressureAngleDegrees)];

  /// Builds every stage's wire payload - the last stage's own
  /// `turn_angle_degrees` is geometrically inert (no segment leaves the
  /// last stage - `05-gear-chain-and-planetary.md`'s own Spike 1 finding)
  /// and the backend rejects a nonzero value there outright, so this
  /// always sends `0.0` for it regardless of that row's own (disabled)
  /// text field content.
  List<GearChainStageInputDto>? _buildStages() {
    final result = <GearChainStageInputDto>[];
    for (var i = 0; i < _stages.length; i++) {
      final stage = _stages[i];
      final toothCount = int.tryParse(stage.toothCountController.text);
      final faceWidth = double.tryParse(stage.faceWidthController.text);
      if (toothCount == null || faceWidth == null) return null;
      final isLast = i == _stages.length - 1;
      final turnAngle = isLast ? 0.0 : (double.tryParse(stage.turnAngleController.text) ?? 0.0);
      double? outerDiameter;
      if (stage.kind == ChainStageKind.internal) {
        outerDiameter = double.tryParse(stage.outerDiameterController.text);
        if (outerDiameter == null) return null;
      }
      result.add(
        GearChainStageInputDto(
          turnAngleDegrees: turnAngle,
          member: GearChainMemberInputDto(
            memberType: stage.kind.apiValue,
            groupId: 'g1',
            toothCount: toothCount,
            faceWidth: faceWidth,
            outerDiameter: outerDiameter,
          ),
        ),
      );
    }
    return result;
  }

  Future<void> _fetchPreview() async {
    setState(() => _previewLoading = true);
    try {
      GearPreviewDto result;
      if (_mode == GearMultiKind.chain) {
        final stages = _buildStages();
        final startDirection = double.tryParse(_startDirectionController.text);
        final printClearance = double.tryParse(_printClearanceController.text);
        if (stages == null || stages.length < 2 || startDirection == null || printClearance == null) {
          if (!mounted) return;
          setState(() {
            _preview = null;
            _warnings = const [];
            _blockingError = 'Enter valid values for every stage (at least 2 stages required)';
            _previewLoading = false;
          });
          return;
        }
        result = await _api.previewGearChain(
          groups: _groups(),
          stages: stages,
          startDirectionDegrees: startDirection,
          printClearanceMargin: printClearance,
        );
      } else {
        final sunToothCount = int.tryParse(_sunToothCountController.text);
        final ringToothCount = int.tryParse(_ringToothCountController.text);
        final planetCount = int.tryParse(_planetCountController.text);
        final faceWidth = double.tryParse(_planetaryFaceWidthController.text);
        final ringOuterDiameter = double.tryParse(_ringOuterDiameterController.text);
        if (sunToothCount == null ||
            ringToothCount == null ||
            planetCount == null ||
            faceWidth == null ||
            ringOuterDiameter == null) {
          if (!mounted) return;
          setState(() {
            _preview = null;
            _warnings = const [];
            _blockingError = 'Enter valid values for every field';
            _previewLoading = false;
          });
          return;
        }
        result = await _api.previewGearPlanetary(
          module: _module,
          sunToothCount: sunToothCount,
          ringToothCount: ringToothCount,
          planetCount: planetCount,
          faceWidth: faceWidth,
          ringOuterDiameter: ringOuterDiameter,
          pressureAngleDegrees: _pressureAngleDegrees,
        );
      }
      if (!mounted) return;
      setState(() {
        _preview = result;
        _warnings = _warningsFor(result);
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

  /// `00-conventions.md`'s non-blocking validation banner: every
  /// interference finding (`05-gear-chain-and-planetary.md`'s own zero-
  /// tolerance-overlap/print-clearance-margin split) is a warning, never a
  /// block - a chain with genuine geometric interference is still valid
  /// preview data (the offending gears are highlighted directly on the
  /// canvas, `GearChainPreviewCanvas`'s own job), just worth flagging.
  static List<String> _warningsFor(GearPreviewDto preview) {
    final findings = preview.chain?.interferenceFindings ?? const [];
    return [
      for (final f in findings)
        'Stage ${f.stageIndexA} (${f.memberLabelA}) and stage ${f.stageIndexB} (${f.memberLabelB}) '
            '${f.kind == 'overlap' ? 'overlap' : 'come within the print-clearance margin of each other'} '
            '(gap=${f.gap.toStringAsFixed(3)}mm)',
    ];
  }

  void _addStage() {
    setState(() => _stages.add(_ChainStageForm(toothCount: '36')));
    _schedulePreview();
  }

  void _removeStage(int index) {
    if (_stages.length <= 2) return;
    setState(() {
      _stages[index].dispose();
      _stages.removeAt(index);
    });
    _schedulePreview();
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
        if (_mode == GearMultiKind.chain) {
          final stages = _buildStages()!;
          await _api.updateGearChainFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            groups: _groups(),
            stages: stages,
            startDirectionDegrees: double.parse(_startDirectionController.text),
            printClearanceMargin: double.parse(_printClearanceController.text),
            planeRef: planeRef,
          );
        } else {
          await _api.updatePlanetaryGearFeature(
            widget.editingPartId!,
            widget.editingFeatureId!,
            module: _module,
            sunToothCount: int.parse(_sunToothCountController.text),
            ringToothCount: int.parse(_ringToothCountController.text),
            planetCount: int.parse(_planetCountController.text),
            faceWidth: double.parse(_planetaryFaceWidthController.text),
            ringOuterDiameter: double.parse(_ringOuterDiameterController.text),
            pressureAngleDegrees: _pressureAngleDegrees,
            planeRef: planeRef,
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
      final part = await _api.createPart(_mode == GearMultiKind.chain ? 'Gear Chain Part' : 'Planetary Gear Part');
      List<String> warnings = const [];
      if (_mode == GearMultiKind.chain) {
        final stages = _buildStages()!;
        final feature = await _api.createGearChainFeature(
          part.id,
          groups: _groups(),
          stages: stages,
          startDirectionDegrees: double.parse(_startDirectionController.text),
          printClearanceMargin: double.parse(_printClearanceController.text),
          planeRef: planeRef,
        );
        warnings = feature.warnings;
      } else {
        // LOD Phase 2 chunk 4 (`docs/lod-strategy/02-phase2-design.md` SS6
        // item 4): job-mode create instead of the synchronous call above -
        // mirrors `BevelDesignScreen`'s own identical change exactly. A
        // large `planet_count` is `00-status.md` Finding 2's own flagged
        // genuine long tail (serial sun+ring+planet-count solid builds, no
        // upper bound) - this screen has no way to know up front whether a
        // given set crosses that threshold, so job mode applies uniformly
        // to every PlanetaryGearFeature create, same as the backend's own
        // route does.
        final payload = DocumentApiClient.planetaryGearFeatureJson(
          planeRef: planeRef,
          module: _module,
          sunToothCount: int.parse(_sunToothCountController.text),
          ringToothCount: int.parse(_ringToothCountController.text),
          planetCount: int.parse(_planetCountController.text),
          faceWidth: double.parse(_planetaryFaceWidthController.text),
          ringOuterDiameter: double.parse(_ringOuterDiameterController.text),
          pressureAngleDegrees: _pressureAngleDegrees,
        );
        final job = await _api.createPlanetaryGearFeatureJob(part.id, payload);
        await PendingJobStore.save(PendingFeatureJob(
          partId: part.id,
          jobId: job.jobId,
          featureKind: PendingFeatureJob.kindPlanetaryGear,
          coarsePreviewPayload: payload,
        ));
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
        title: Text(
          _isEditing
              ? 'Edit ${_mode == GearMultiKind.chain ? 'Gear Chain' : 'Planetary Gear'}'
              : 'Gear Chain / Planetary',
        ),
      ),
      body: _loadingExisting
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Text(
                    'Could not load this Feature: $_loadError',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                )
              : LayoutBuilder(
        builder: (context, constraints) {
          final canvas = GearChainPreviewCanvas(
            members: (_mode == GearMultiKind.chain ? _preview?.chain?.members : _preview?.planetary?.members) ??
                const [],
            interferenceFindings: _preview?.chain?.interferenceFindings ?? const [],
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
              SizedBox(width: 400, child: form),
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
        SegmentedButton<GearMultiKind>(
          // Gear-tree UX: while editing, a GearChainFeature can't become a
          // PlanetaryGearFeature (or vice versa) via this same Update
          // endpoint, so only the current mode is offered - mirrors
          // GearDesignScreen's own identical restriction.
          segments: _isEditing
              ? [
                  ButtonSegment(
                    value: _mode,
                    label: Text(_mode == GearMultiKind.chain ? 'Chain' : 'Planetary'),
                  ),
                ]
              : const [
                  ButtonSegment(value: GearMultiKind.chain, label: Text('Chain')),
                  ButtonSegment(value: GearMultiKind.planetary, label: Text('Planetary')),
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
          helpText: 'Tooth size, shared by every gear in this ${_mode == GearMultiKind.chain ? 'chain' : 'set'} - '
              'they must all share a module to mesh correctly.',
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
          helpText: 'Shared by every gear in this ${_mode == GearMultiKind.chain ? 'chain' : 'set'}.',
          onChanged: (value) {
            setState(() => _pressureAngleDegrees = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 16),
        if (_mode == GearMultiKind.chain) ..._buildChainForm() else ..._buildPlanetaryForm(),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: 'Plane',
            suffixIcon: fieldHelpIcon('Which fixed reference plane this is built on.'),
          ),
          initialValue: _plane,
          items: [for (final plane in _fixedPlanes) DropdownMenuItem(value: plane, child: Text(plane))],
          onChanged: (value) {
            if (value != null) setState(() => _plane = value);
          },
        ),
        const SizedBox(height: 12),
        GearPresetControls(
          kind: 'gear_chain_design',
          captureFields: _captureFields,
          onLoad: _applyPresetFields,
        ),
        const SizedBox(height: 12),
        if (_previewLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(),
          ),
        _buildRatioSummary(),
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
      ],
    );
  }

  List<Widget> _buildChainForm() {
    return [
      TextField(
        controller: _startDirectionController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: 'Start direction',
          suffix: const Text('°'),
          suffixIcon: fieldHelpIcon('The heading of the first segment (stage 1 to stage 2), absolute within the plane.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _printClearanceController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Print clearance margin',
          suffix: const Text('mm'),
          suffixIcon: fieldHelpIcon(
            'Non-adjacent gears closer than this (without literally overlapping) are flagged as a warning - '
            'geometrically fine isn\'t the same as printable.',
          ),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 16),
      const Text('Stages', style: TextStyle(fontWeight: FontWeight.bold)),
      for (var i = 0; i < _stages.length; i++) _buildStageRow(i),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _addStage, icon: const Icon(Icons.add), label: const Text('Add stage')),
    ];
  }

  Widget _buildStageRow(int index) {
    final stage = _stages[index];
    final isLast = index == _stages.length - 1;
    final isFirst = index == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Stage ${index + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (_stages.length > 2)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _removeStage(index),
                    tooltip: 'Remove stage',
                  ),
              ],
            ),
            DropdownButtonFormField<ChainStageKind>(
              decoration: InputDecoration(
                labelText: 'Kind',
                isDense: true,
                // Internal is only valid on the chain's last stage, and rack
                // only at the first or last (`05-gear-chain-and-planetary.
                // md`'s own restrictions) - not pre-filtered per row here
                // (every kind is always a selectable item, so a stage never
                // holds a value its own dropdown can't display, even after
                // adding/removing a stage shifts which row is "last") -
                // surfaced instead as a blocking error from the backend on
                // the next preview fetch, same as every other server-side
                // validation this screen already defers to.
                helperText: (stage.kind == ChainStageKind.internal && !isLast)
                    ? 'Internal is only valid on the last stage'
                    : (stage.kind == ChainStageKind.rack && !isFirst && !isLast)
                        ? 'Rack is only valid on the first or last stage'
                        : null,
              ),
              initialValue: stage.kind,
              items: [
                for (final kind in ChainStageKind.values) DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: (kind) {
                if (kind == null) return;
                setState(() => stage.kind = kind);
                _schedulePreview();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: stage.toothCountController,
                    keyboardType: const TextInputType.numberWithOptions(signed: false),
                    decoration: const InputDecoration(labelText: 'Tooth count', isDense: true),
                    onChanged: (_) => _schedulePreview(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: stage.faceWidthController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Face width', isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            if (stage.kind == ChainStageKind.internal) ...[
              const SizedBox(height: 8),
              TextField(
                controller: stage.outerDiameterController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Outer diameter (required)', isDense: true),
                onChanged: (_) => _schedulePreview(),
              ),
            ],
            if (!isFirst) ...[
              const SizedBox(height: 8),
              TextField(
                controller: stage.turnAngleController,
                enabled: !isLast,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: 'Turn angle',
                  suffix: const Text('°'),
                  isDense: true,
                  helperText: isLast ? 'Inert on the last stage - no segment leaves it' : null,
                ),
                onChanged: (_) => _schedulePreview(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPlanetaryForm() {
    return [
      TextField(
        controller: _sunToothCountController,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: InputDecoration(
          labelText: 'Sun tooth count',
          suffixIcon: fieldHelpIcon('The central sun gear\'s own tooth count.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _ringToothCountController,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: InputDecoration(
          labelText: 'Ring tooth count',
          suffixIcon: fieldHelpIcon(
            'The outer ring gear\'s own tooth count - must exceed the sun\'s, and (ring - sun) must be even '
            'for a valid planet tooth count to exist.',
          ),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _planetCountController,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: InputDecoration(
          labelText: 'Planet count',
          suffixIcon: fieldHelpIcon('How many planets, evenly spaced around the sun. Must be at least 3.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _planetaryFaceWidthController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Face width',
          suffixIcon: fieldHelpIcon('Shared axial width across sun, ring, and every planet.'),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _ringOuterDiameterController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Ring outer diameter (required)',
          suffixIcon: fieldHelpIcon('The ring\'s own outer rim diameter.'),
        ),
        onChanged: (_) => _schedulePreview(),
      ),
    ];
  }

  Widget _buildRatioSummary() {
    final chain = _preview?.chain;
    final planetary = _preview?.planetary;
    if (chain == null && planetary == null) return const SizedBox.shrink();

    final lines = <String>[];
    if (chain != null) {
      if (chain.overallRatio != null) {
        lines.add('Overall ratio: ${chain.overallRatio!.toStringAsFixed(3)} : 1');
      }
      for (final link in chain.links) {
        final where = link.kind == 'compound'
            ? 'Stage ${link.fromStageIndex} (compound a→b)'
            : 'Stage ${link.fromStageIndex} → ${link.toStageIndex}';
        final direction = link.reversesDirection ? 'reverses' : 'same direction';
        if (link.ratio != null) {
          lines.add('$where: ratio ${link.ratio!.toStringAsFixed(3)}, $direction');
        } else if (link.linearMmPerRevolution != null) {
          lines.add('$where: ${link.linearMmPerRevolution!.toStringAsFixed(2)}mm/rev, $direction');
        }
      }
    }
    if (planetary != null) {
      if (planetary.sunToPlanetRatio != null) {
        lines.add('Sun → planet ratio: ${planetary.sunToPlanetRatio!.toStringAsFixed(3)}');
      }
      if (planetary.planetToRingRatio != null) {
        lines.add('Planet → ring ratio: ${planetary.planetToRingRatio!.toStringAsFixed(3)}');
      }
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(lines.join('\n'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ),
    );
  }

  /// `docs/gear-design/09-presets.md`: this form's own current state
  /// (both modes' fields captured together, same "one preset, whichever
  /// fields the screen happened to have" simplicity `GearDesignScreen.
  /// _captureFields` already uses - loading a chain-mode preset back into
  /// planetary mode's own fields would just be a harmless no-op, since
  /// `_applyPresetFields` only restores the mode captured alongside them).
  Map<String, dynamic> _captureFields() => {
        'mode': _mode.name,
        'module': _module,
        'pressureAngleDegrees': _pressureAngleDegrees,
        'plane': _plane,
        'startDirection': _startDirectionController.text,
        'printClearance': _printClearanceController.text,
        'stages': [
          for (final stage in _stages)
            {
              'kind': stage.kind.name,
              'toothCount': stage.toothCountController.text,
              'faceWidth': stage.faceWidthController.text,
              'turnAngle': stage.turnAngleController.text,
              'outerDiameter': stage.outerDiameterController.text,
            },
        ],
        'sunToothCount': _sunToothCountController.text,
        'ringToothCount': _ringToothCountController.text,
        'planetCount': _planetCountController.text,
        'planetaryFaceWidth': _planetaryFaceWidthController.text,
        'ringOuterDiameter': _ringOuterDiameterController.text,
      };

  void _applyPresetFields(Map<String, dynamic> fields) {
    setState(() {
      final modeName = fields['mode'] as String?;
      if (modeName != null) {
        _mode = GearMultiKind.values.firstWhere((m) => m.name == modeName, orElse: () => _mode);
      }
      _module = (fields['module'] as num?)?.toDouble() ?? _module;
      _pressureAngleDegrees = (fields['pressureAngleDegrees'] as num?)?.toDouble() ?? _pressureAngleDegrees;
      _plane = fields['plane'] as String? ?? _plane;
      if (fields['startDirection'] is String) _startDirectionController.text = fields['startDirection'] as String;
      if (fields['printClearance'] is String) _printClearanceController.text = fields['printClearance'] as String;

      final stagesData = fields['stages'];
      if (stagesData is List && stagesData.length >= 2) {
        for (final stage in _stages) {
          stage.dispose();
        }
        _stages.clear();
        for (final raw in stagesData) {
          final map = raw as Map;
          final kind = ChainStageKind.values.firstWhere(
            (k) => k.name == map['kind'],
            orElse: () => ChainStageKind.external,
          );
          _stages.add(
            _ChainStageForm(
              kind: kind,
              toothCount: map['toothCount'] as String? ?? '20',
              faceWidth: map['faceWidth'] as String? ?? '5',
              turnAngle: map['turnAngle'] as String? ?? '0',
              outerDiameter: map['outerDiameter'] as String? ?? '',
            ),
          );
        }
      }

      if (fields['sunToothCount'] is String) _sunToothCountController.text = fields['sunToothCount'] as String;
      if (fields['ringToothCount'] is String) _ringToothCountController.text = fields['ringToothCount'] as String;
      if (fields['planetCount'] is String) _planetCountController.text = fields['planetCount'] as String;
      if (fields['planetaryFaceWidth'] is String) {
        _planetaryFaceWidthController.text = fields['planetaryFaceWidth'] as String;
      }
      if (fields['ringOuterDiameter'] is String) {
        _ringOuterDiameterController.text = fields['ringOuterDiameter'] as String;
      }
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
