import 'dart:async';

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../connection_screen.dart';
import '../didsa_logo_button.dart';
import '../sketch/sketch_controller.dart';
import '../sketch/sketch_screen.dart';
import 'add_button_menu.dart';
import 'cascade_delete_dialog.dart';
import 'extrude_panel.dart';
import 'feature_context_menu.dart';
import 'feature_picker_sheet.dart';
import 'feature_tree_panel.dart';
import 'mesh_geometry.dart';
import 'part_toolbar.dart';
import 'part_viewport.dart';
import 'plane_context_sheet.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
import 'selection_context_panel.dart';
import 'selection_hit_test.dart' show SelectionEntityRef;
import 'selection_list_drawer.dart';
import 'sketch_geometry_3d.dart';
import 'view_preferences.dart';

/// Stage 7's new screen: a Part's Feature tree alongside a 3D viewport of
/// its (placeholder, for this stage) mesh - separate from the 2D
/// [SketchScreen], which is reached by tapping a SketchFeature. A single
/// Part is created on startup, the same "always start fresh" pattern
/// [SketchController.ensureSketch] already uses for Sketches; there is no
/// "pick an existing Part" UI since the brief assumes a single Document
/// with no persistence across this stage.
class PartScreen extends StatefulWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final DocumentApiClient? documentApi;

  /// Overridable for tests - used to build the [SketchApiClient] for any
  /// SketchScreen this pushes, so a pushed screen doesn't make real network
  /// calls in a test either.
  final SketchApiClient Function()? sketchApiFactory;

  const PartScreen({super.key, this.documentApi, this.sketchApiFactory});

  @override
  State<PartScreen> createState() => _PartScreenState();
}

class _PartScreenState extends State<PartScreen> {
  late final DocumentApiClient _api;

  /// Owned by this screen (regardless of whether [PartScreen.sketchApiFactory]
  /// was supplied) just to look up an existing Feature's Sketch plane/content
  /// for the 3D viewport - separate from the per-push client
  /// [_openSketch]/[SketchController] builds for the 2D canvas itself.
  late final SketchApiClient _sketchApi;

  final GlobalKey<PartViewportState> _viewportKey = GlobalKey<PartViewportState>();

  PartDto? _part;
  List<FeatureDto> _features = [];
  MeshDto? _mesh;
  String? _selectedFeatureId;

  /// The reference plane currently tap-selected in the 3D viewport, if any -
  /// drives both [PartViewport]'s brighter highlight and [PartToolbar]'s
  /// "New Sketch on..." entry. Controlled-widget state, same pattern as
  /// [_selectedFeatureId]/[FeatureTreePanel].
  ReferencePlaneKind? _selectedPlane;

  /// Stage 10b: whether all three reference planes are globally hidden -
  /// toggled from [PartToolbar]'s "Hide/Show Reference Planes" entry,
  /// in-memory only (no persistence across app restarts, per the brief).
  bool _referencePlanesHidden = false;

  /// Stage 11: the viewport's current display mode, toggled from
  /// [PartToolbar]'s three render-mode entries. Stage 19a Item 5: now
  /// persisted via [ViewPreferences] (`view_render_mode`), the same
  /// default-then-overwrite pattern [_bgColourHex] etc. below use - was
  /// in-memory-only, always starting from [ViewportRenderMode.shaded].
  ViewportRenderMode _renderMode = ViewPreferences.defaultRenderMode;

  /// Stage 18: the 3D viewport's appearance preferences (see
  /// [ViewPreferences]) - default to the same constants [ViewPreferences]
  /// itself defaults to, then overwritten once [_loadViewPreferences]'s
  /// async `shared_preferences` read completes, so the viewport never waits
  /// on that read before its first frame.
  String _bgColourHex = ViewPreferences.defaultBgColourHex;
  String _bodyColourHex = ViewPreferences.defaultBodyColourHex;
  double _bodyOpacity = ViewPreferences.defaultBodyOpacity;

  /// A4: perspective vs orthographic toggle - false = orthographic default.
  bool _isPerspective = ViewPreferences.defaultIsPerspective;

  /// A3: manually-overridden far clip distance (mm), driven by the View menu
  /// slider and reset by the recentre auto-fit action.
  double _farClip = ViewPreferences.defaultFarClip;

  /// Stage 10b: true while the "Add" FAB's flyout's "New Sketch" entry has
  /// been tapped and the user is choosing which reference plane to sketch
  /// on - the three planes are tappable targets in this mode, and a tap on
  /// one immediately creates a SketchFeature and navigates to its canvas
  /// (see [_onPlaneTap]), unlike the plain free-tap plane-selection flow
  /// below which instead shows a toolbar confirmation step. Exited without
  /// creating anything by the Cancel button, a background tap, or the
  /// device back gesture (see [_cancelPlaneSelectionMode]).
  bool _planeSelectionMode = false;

  /// Feature ids hidden from the 3D viewport via the long-press
  /// Hide/Show action - client-side only, never sent to the backend.
  final Set<String> _hiddenFeatureIds = {};

  /// Stage 23 Item 1: whether the viewport is in Selection mode (vs the
  /// default Orbit mode) - toggled by the second FAB added below. Per Item
  /// 7, this is read by [PartViewport] only to decide which gesture-handler
  /// set to dispatch pointer events to; the existing orbit handlers
  /// themselves are never touched.
  bool _selectionMode = false;

  /// Stage 23 Item 4: the accumulated set of selected mesh entities -
  /// survives switching back and forth between Orbit and Selection mode
  /// (see [_toggleSelectionMode]); the selection-list drawer/context panel
  /// stays visible whenever this is non-empty, even in Orbit mode, and the
  /// cursor is removed/restored separately, gated on [_selectionMode]
  /// itself.
  ///
  /// Reassigned (never mutated in place) on every change, rather than
  /// `final` - [PartViewport.selectedEntities]'s `didUpdateWidget` check is
  /// `widget.selectedEntities != oldWidget.selectedEntities`, and `Set` has
  /// no value-based `==`, so an in-place `.add()`/`.remove()`/`.clear()`
  /// would leave both sides pointing at the identical object and silently
  /// skip re-syncing the selected-entity highlight nodes.
  Set<SelectionEntityRef> _selectedEntities = {};

  /// The second FAB's callback (Item 1) - just toggles which gesture set
  /// the viewport dispatches to; the selection itself is preserved across
  /// the switch so returning to Selection mode picks up where it left off.
  void _toggleSelectionMode() {
    setState(() => _selectionMode = !_selectionMode);
  }

  /// Item 4: "Unselected entity tap -> add; already-selected -> remove
  /// (toggle)" - passed to [PartViewport.onSelectionToggle], fired by a tap
  /// (Fix 4) when the cursor's hover hit is non-null.
  void _toggleSelectedEntity(SelectionEntityRef entity) {
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (!next.remove(entity)) next.add(entity);
      _selectedEntities = next;
    });
  }

  /// Item 4: "Empty space tap -> clears entire selection set" - passed to
  /// [PartViewport.onClearSelection], fired by a tap (Fix 4) when the
  /// cursor's hover hit is null.
  void _clearSelectedEntities() {
    setState(() => _selectedEntities = {});
  }

  /// Every Feature's 3D Sketch geometry, keyed by Feature id, regardless of
  /// [_hiddenFeatureIds] - [_visibleSketchGeometries] is the
  /// hidden-filtered view of this actually passed to [PartViewport].
  Map<String, SketchGeometry3D> _allSketchGeometries = {};
  Map<String, SketchGeometry3D> _visibleSketchGeometries = {};

  bool _busy = false;
  String? _errorMessage;

  /// The Feature tree is hidden by default so the 3D viewport gets full
  /// space - revealed via [_toolbarOpen]'s "Show Feature Tree" action.
  bool _featureTreeVisible = false;
  bool _toolbarOpen = false;

  /// Prompt D: true while the Feature tree is acting as a Sketch picker for
  /// a pending Extrude - entered by [_extrudeSelectedFeature] when no
  /// eligible Sketch is already selected, exited by [_onSketchPicked] (a
  /// valid pick) or [_cancelSketchPicker] (dismissal). Threaded into
  /// [FeatureTreePanel] as a plain bool rather than mirrored in its own
  /// state, per the project convention of keeping that widget reusable/dumb.
  bool _sketchPickerActive = false;

  /// While [_sketchPickerActive], the Sketch Feature ids [_refreshPickableSketchIds]
  /// most recently found to have a closed profile - drives which rows
  /// [FeatureTreePanel] dims. Purely a visual aid; [_onSketchPicked]
  /// re-checks the tapped Sketch itself.
  Set<String> _pickableSketchIds = {};

  /// The SketchFeature currently being extruded via [ExtrudePanel], or null
  /// when the panel is closed - set by the long-press "Extrude" context-menu
  /// action, cleared on Confirm/Cancel.
  FeatureDto? _extrudeSketchFeature;

  /// The ExtrudeFeature created by the panel's first live-preview update, so
  /// later preview updates PATCH it instead of creating another one - and
  /// Cancel knows what to delete. Null until the first preview update lands.
  String? _previewExtrudeFeatureId;

  /// [_mesh]'s value from just before the panel opened, restored by Cancel.
  MeshDto? _meshBeforeExtrude;

  ExtrudeType _extrudeType = ExtrudeType.boss;
  double _extrudeStartDistance = 0.0;
  double _extrudeEndDistance = 10.0;

  /// Debounces the panel's live-preview PATCH/POST + mesh refresh by 500ms
  /// after the last field change, per the brief - cancelled outright by
  /// Confirm/Cancel/dispose so a stale preview update never fires after the
  /// panel has already closed.
  Timer? _extrudeDebounce;

  /// True while [ExtrudePanel] is open (i.e. [_extrudeSketchFeature] is
  /// non-null) - the Feature tree auto-hides (slides left, via
  /// [FeatureTreePanel]'s own [AnimatedSlide]) while this is true, per Stage
  /// 16 item 8, so the bottom-sheet-style panel never has the tree sitting
  /// on top of it; restores on Confirm/Cancel since those null out
  /// [_extrudeSketchFeature] without otherwise touching [_featureTreeVisible].
  bool get _extrudeActive => _extrudeSketchFeature != null;

  @override
  void initState() {
    super.initState();
    _api = widget.documentApi ?? DocumentApiClient();
    _sketchApi = widget.sketchApiFactory?.call() ?? SketchApiClient();
    _loadPart();
    _loadViewPreferences();
  }

  /// Loads [ViewPreferences] in the background, not awaited from
  /// [initState] - the viewport renders with the in-memory defaults already
  /// set above immediately, then repaints with whatever was actually stored
  /// once this completes.
  Future<void> _loadViewPreferences() async {
    await ViewPreferences.load();
    if (!mounted) return;
    setState(() {
      _bgColourHex = ViewPreferences.bgColourHex;
      _bodyColourHex = ViewPreferences.bodyColourHex;
      _bodyOpacity = ViewPreferences.bodyOpacity;
      _renderMode = ViewPreferences.renderMode;
      _isPerspective = ViewPreferences.isPerspective;
      _farClip = ViewPreferences.farClip;
    });
  }

  Future<void> _onBgColourChanged(String hex) async {
    setState(() => _bgColourHex = hex);
    await ViewPreferences.setBgColourHex(hex);
  }

  Future<void> _onBodyColourChanged(String hex) async {
    setState(() => _bodyColourHex = hex);
    await ViewPreferences.setBodyColourHex(hex);
  }

  Future<void> _onBodyOpacityChanged(double opacity) async {
    setState(() => _bodyOpacity = opacity);
    await ViewPreferences.setBodyOpacity(opacity);
  }

  /// A4: toggles perspective/orthographic projection.
  Future<void> _onPerspectiveChanged(bool value) async {
    setState(() => _isPerspective = value);
    await ViewPreferences.setIsPerspective(value);
  }

  /// A3: updates far clip from the View menu slider or from the recentre
  /// auto-fit result - both paths write through to [ViewPreferences].
  Future<void> _onFarClipChanged(double value) async {
    setState(() => _farClip = value);
    await ViewPreferences.setFarClip(value);
  }

  /// Opens [ConnectionScreen] from the File menu's "Connection Settings"
  /// entry - [ConnectionScreen.isSettingsRevisit] tells it to pop back here
  /// on success rather than pushing a brand new [PartScreen].
  Future<void> _openConnectionSettings() async {
    setState(() => _toolbarOpen = false);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const ConnectionScreen(isSettingsRevisit: true)),
    );
  }

  @override
  void dispose() {
    _extrudeDebounce?.cancel();
    if (widget.documentApi == null) {
      _api.close();
    }
    _sketchApi.close();
    super.dispose();
  }

  Future<void> _loadPart() async {
    await _runGuarded(() async {
      debugPrint('[PartScreen] createPart...');
      final part = await _api.createPart('Part 1');
      debugPrint('[PartScreen] createPart done: ${part.id}');
      _part = part;
      debugPrint('[PartScreen] getPartMesh...');
      await _refreshMesh();
      debugPrint('[PartScreen] getPartMesh done: ${_mesh?.vertices.length ?? 0} vertices');
      await _refreshFeatures();
      await _refreshSketchGeometries();
      debugPrint('[PartScreen] refreshFeatures done');
    });
  }

  Future<void> _refreshFeatures() async {
    final part = _part;
    if (part == null) return;
    _features = await _api.listFeatures(part.id);
  }

  /// Re-fetches the Part's mesh with [_hiddenFeatureIds] sent along, so a
  /// hidden ExtrudeFeature's contribution to the displayed solid (and so to
  /// the camera target/zoom bounds [PartViewport] derives from it) drops
  /// out immediately - called after anything that can change either the
  /// Part's geometry (extrude preview/confirm/cancel, cascade delete) or
  /// [_hiddenFeatureIds] itself (Hide/Show).
  ///
  /// Discards the response entirely when its `source` is `"placeholder"`
  /// (see `backend/app/document/router.py`'s `BRepPrimAPI_MakeBox(10,10,10)`
  /// fallback for a Part with no ExtrudeFeature yet) rather than rendering
  /// it - that placeholder box is a backend implementation detail to keep
  /// the mesh endpoint's response shape uniform, not real geometry the user
  /// created, and showing it as a stray cube in an otherwise-empty viewport
  /// was confusing on-device.
  Future<void> _refreshMesh() async {
    final part = _part;
    if (part == null) return;
    final response = await _api.getPartMesh(part.id, hiddenFeatureIds: _hiddenFeatureIds.toList());
    _mesh = response.source == 'placeholder' ? null : response.mesh;
  }

  /// Re-fetches every Feature's Sketch content (points/lines/circles) and
  /// rebuilds [_allSketchGeometries]/[_visibleSketchGeometries] from it, so
  /// the 3D viewport's rendered Sketch geometry always matches the latest
  /// backend state. A single Feature's fetch failing (e.g. a test fixture
  /// that only stubs `GET /sketch/sketches/{id}`, or a transient network
  /// issue) only drops that Feature's geometry, not the whole viewport.
  Future<void> _refreshSketchGeometries() async {
    final updated = <String, SketchGeometry3D>{};
    for (final feature in _features) {
      final sketchId = feature.sketchId;
      if (sketchId == null) continue; // An ExtrudeFeature - no Sketch of its own.
      try {
        final sketch = await _sketchApi.getSketch(sketchId);
        final plane = referencePlaneKindFromApiValue(sketch.plane);
        if (plane == null) continue;
        final points = await _sketchApi.listPoints(sketchId);
        final lines = await _sketchApi.listLines(sketchId);
        final circles = await _sketchApi.listCircles(sketchId);
        final geometry =
            sketchGeometry3DFrom(plane: plane, points: points, lines: lines, circles: circles);
        if (!geometry.isEmpty) updated[feature.id] = geometry;
      } catch (_) {
        // Swallow - see doc comment above.
      }
    }
    _allSketchGeometries = updated;
    _recomputeVisibleSketchGeometries();
  }

  /// Filters [_allSketchGeometries] down to [_visibleSketchGeometries] by
  /// [_hiddenFeatureIds] - the only place that builds a new Map instance for
  /// [PartViewport.sketchGeometries], so its `didUpdateWidget` `!=` check
  /// only fires on a genuine content/visibility change.
  void _recomputeVisibleSketchGeometries() {
    _visibleSketchGeometries = {
      for (final entry in _allSketchGeometries.entries)
        if (!_hiddenFeatureIds.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Creates a SketchFeature on [plane] and navigates straight to its
  /// SketchScreen - called from both the free-tap fly-up sheet flow
  /// ([_showPlaneContextSheet]) and the FAB's flyout-driven
  /// plane-selection mode ([_onPlaneTap]).
  Future<void> _addSketchFeature({ReferencePlaneKind plane = ReferencePlaneKind.xy}) async {
    final part = _part;
    if (part == null || _busy) return;

    FeatureDto? created;
    await _runGuarded(() async {
      created = await _api.createSketchFeature(part.id, plane: plane.apiValue);
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });

    final feature = created;
    if (feature != null && mounted) {
      await _viewportKey.currentState?.animateToPlane(plane);
      if (!mounted) return;
      await _openSketch(feature, plane: plane);
    }
  }

  /// A tap that landed on a reference plane rectangle in the 3D viewport.
  ///
  /// During [_planeSelectionMode] (entered via the "Add" FAB's flyout - see
  /// [_onAddPressed]), this immediately creates a SketchFeature on the
  /// tapped plane and navigates to its canvas, exiting the mode - per the
  /// Stage 10b brief, that flow has no separate confirmation step. Otherwise
  /// it's the pre-existing free-tap flow: selects the plane (brighter
  /// highlight) and opens [showPlaneContextSheet]'s fly-up with its
  /// contextual action - Stage 19b Item 2 moved that out of the hamburger
  /// drawer, which must no longer open on a selection tap.
  void _onPlaneTap(ReferencePlaneKind plane) {
    if (_planeSelectionMode) {
      setState(() => _planeSelectionMode = false);
      _addSketchFeature(plane: plane);
      return;
    }
    setState(() {
      _selectedPlane = plane;
      _featureTreeVisible = false;
    });
    _showPlaneContextSheet(plane);
  }

  /// Awaits [showPlaneContextSheet] and acts on whatever it returns, clearing
  /// the plane highlight once it's dismissed either way (action taken or
  /// just swiped away) - the highlight is only meant to last while the sheet
  /// is open.
  Future<void> _showPlaneContextSheet(ReferencePlaneKind plane) async {
    final action = await showPlaneContextSheet(context, plane: plane);
    if (!mounted) return;
    setState(() => _selectedPlane = null);
    if (action == PlaneContextSheetAction.newSketch) {
      await _addSketchFeature(plane: plane);
    }
  }

  /// A tap that missed every reference plane - dismisses the toolbar and
  /// clears the selection, mirroring a tap on empty space elsewhere in the
  /// app deselecting whatever was selected; also exits [_planeSelectionMode]
  /// without creating anything, since a background tap during that mode is
  /// as much a "never mind" gesture as the Cancel button is.
  void _onViewportBackgroundTap() {
    setState(() {
      _selectedPlane = null;
      _toolbarOpen = false;
      _planeSelectionMode = false;
    });
    // Prompt D: a background tap is as much a "never mind" gesture for the
    // Sketch picker as it already is for plane-selection mode above.
    if (_sketchPickerActive) _cancelSketchPicker();
  }

  /// Opens the "Add" FAB's flyout. "New Sketch" enters [_planeSelectionMode]
  /// rather than acting directly (Stage 10b); Stage 19b Item 3's "Feature"
  /// opens the second-level Feature picker instead.
  Future<void> _onAddPressed() async {
    if (_busy) return;
    final action = await showAddButtonMenu(context);
    if (!mounted || action == null) return;
    switch (action) {
      case AddButtonMenuAction.newSketch:
        setState(() {
          _planeSelectionMode = true;
          _selectedPlane = null;
          _toolbarOpen = false;
          _featureTreeVisible = false;
        });
      case AddButtonMenuAction.feature:
        await _onFeaturePressed();
    }
  }

  /// The "Add" FAB's "Feature" entry - shows the second-level picker and
  /// acts on whichever (enabled) entry was tapped. Only Extrude is wired up
  /// per the Stage 19b brief; the rest render disabled in the sheet itself
  /// and so never produce an action here.
  Future<void> _onFeaturePressed() async {
    final action = await showFeaturePickerSheet(context);
    if (!mounted || action == null) return;
    switch (action) {
      case FeaturePickerAction.extrude:
        await _extrudeSelectedFeature();
    }
  }

  /// Extrudes the Feature currently selected in the tree, opened from the
  /// "Add" FAB's Feature picker rather than a Feature's own long-press menu.
  /// Prompt D: when there's no eligible Sketch already selected (the common
  /// case - there usually isn't a prior selection at all), this opens the
  /// Feature tree as a guided picker ([_startSketchPicker]) instead of just
  /// surfacing a snack bar; a pre-selected, already-eligible Sketch skips
  /// the picker entirely and goes straight to the panel, unchanged from
  /// before Prompt D.
  Future<void> _extrudeSelectedFeature() async {
    final featureId = _selectedFeatureId;
    final feature = featureId == null ? null : _featureById(featureId);
    if (feature != null && feature.type == 'sketch') {
      final reason = await _checkExtrudeEligibility(feature);
      if (!mounted) return;
      if (reason == null) {
        _openExtrudePanel(feature);
        return;
      }
    }
    _startSketchPicker();
  }

  /// Prompt D: opens the Feature tree in Sketch-picker mode for a pending
  /// Extrude - closes the toolbar/plane-selection overlays it'd otherwise
  /// collide with, then kicks off [_refreshPickableSketchIds] in the
  /// background so the tree can start dimming ineligible Sketches once that
  /// resolves.
  void _startSketchPicker() {
    setState(() {
      _sketchPickerActive = true;
      _featureTreeVisible = true;
      _toolbarOpen = false;
      _planeSelectionMode = false;
      _pickableSketchIds = {};
    });
    _refreshPickableSketchIds();
  }

  /// Checks every Sketch Feature's closed-profile eligibility (in parallel)
  /// and stores the eligible ids for [FeatureTreePanel]'s dimming - purely a
  /// visual aid, since [_onSketchPicked] re-checks the tapped Sketch itself
  /// rather than trusting this set, so a stale or still-in-flight result
  /// here can never let an ineligible Sketch through.
  Future<void> _refreshPickableSketchIds() async {
    final sketchFeatures = _features.where((f) => f.type == 'sketch').toList();
    final results = await Future.wait(sketchFeatures.map((feature) async {
      final reason = await _checkExtrudeEligibility(feature);
      return MapEntry(feature.id, reason == null);
    }));
    if (!mounted || !_sketchPickerActive) return;
    setState(() {
      _pickableSketchIds = {for (final entry in results) if (entry.value) entry.key};
    });
  }

  /// [FeatureTreePanel.onSketchPicked] - Prompt D's picker-mode tap handler.
  /// Re-validates the tapped Sketch's profile itself (rather than trusting
  /// [_pickableSketchIds], which is only a best-effort visual aid) before
  /// proceeding; an ineligible Sketch stays in picker mode with an
  /// explanatory SnackBar instead.
  Future<void> _onSketchPicked(FeatureDto feature) async {
    final reason = await _checkExtrudeEligibility(feature);
    if (!mounted || !_sketchPickerActive) return;
    if (reason != null) {
      _showSnack('This sketch has no closed profile — add more lines or close the loop first');
      return;
    }
    setState(() {
      _sketchPickerActive = false;
      _featureTreeVisible = false;
      _selectedFeatureId = feature.id;
      _pickableSketchIds = {};
    });
    _openExtrudePanel(feature);
  }

  /// Exits picker mode without creating an Extrude - the Feature tree's own
  /// close button and the device back gesture (see [build]'s `PopScope`)
  /// both lead here, per Prompt D's "dismissing the picker cancels the
  /// pending Extrude" rule.
  void _cancelSketchPicker() {
    setState(() {
      _sketchPickerActive = false;
      _featureTreeVisible = false;
      _pickableSketchIds = {};
    });
  }

  FeatureDto? _featureById(String id) {
    for (final feature in _features) {
      if (feature.id == id) return feature;
    }
    return null;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Exits [_planeSelectionMode] without creating anything - wired to both
  /// the mode's Cancel button and the device back gesture (see [build]'s
  /// `PopScope`).
  void _cancelPlaneSelectionMode() {
    setState(() => _planeSelectionMode = false);
  }

  /// Toggles [_referencePlanesHidden] (Stage 10b) - the toolbar's
  /// "Hide/Show Reference Planes" entry.
  void _onToggleReferencePlanes() {
    setState(() => _referencePlanesHidden = !_referencePlanesHidden);
  }

  /// Stage 11: the toolbar's render-mode entries - sets [_renderMode]
  /// directly to whichever entry was tapped (unlike
  /// [_onToggleReferencePlanes]'s two-state flip, there are three discrete
  /// choices here, not one "next state"). Stage 19a Item 5: now also
  /// persisted, the same async-but-`void`-typed-callback pattern
  /// [_onBgColourChanged] etc. use - `PartToolbar.onRenderModeChanged` is
  /// declared `void Function(ViewportRenderMode)`, so this `await`s inside
  /// its own body rather than the call site awaiting it.
  Future<void> _onRenderModeChanged(ViewportRenderMode mode) async {
    setState(() => _renderMode = mode);
    await ViewPreferences.setRenderMode(mode);
  }

  /// A tap always selects/highlights the Feature; only an editable (not
  /// locked) Feature also opens its Sketch - tapping a locked Feature to
  /// re-edit it is explicitly out of scope for this stage.
  void _onFeatureTap(FeatureDto feature) {
    setState(() => _selectedFeatureId = feature.id);
    if (!feature.locked && feature.type == 'sketch') {
      _openSketchWithAnimation(feature);
    }
  }

  /// Animates the 3D camera to face this Feature's Sketch plane (per the
  /// brief's "camera animation when entering a sketch") before navigating to
  /// its 2D canvas - skips straight to navigation if the plane can't be
  /// resolved (e.g. a fetch failure), rather than blocking the open.
  Future<void> _openSketchWithAnimation(FeatureDto feature) async {
    final plane = await _planeOfFeature(feature);
    if (!mounted) return;
    if (plane != null) {
      await _viewportKey.currentState?.animateToPlane(plane);
      if (!mounted) return;
    }
    await _openSketch(feature, plane: plane);
  }

  Future<ReferencePlaneKind?> _planeOfFeature(FeatureDto feature) async {
    final sketchId = feature.sketchId;
    if (sketchId == null) return null;
    try {
      final sketch = await _sketchApi.getSketch(sketchId);
      return referencePlaneKindFromApiValue(sketch.plane);
    } catch (_) {
      return null;
    }
  }

  /// A long-press on any Feature (locked or not) opens a context menu of
  /// actions for it, rather than triggering anything directly - the menu
  /// is what lets later stages add actions (rename, edit, ...) alongside
  /// Delete without reworking this entry point. Stage 9 adds Extrude,
  /// gated on a closed-profile check run once here (on menu open), not on
  /// every render - only a SketchFeature even offers the entry at all.
  Future<void> _onFeatureLongPress(FeatureDto feature) async {
    if (_busy) return;

    final isSketchFeature = feature.type == 'sketch';
    final extrudeDisabledReason = isSketchFeature ? await _checkExtrudeEligibility(feature) : null;
    final canExtrude = isSketchFeature && extrudeDisabledReason == null;
    if (!mounted) return;

    final action = await showFeatureContextMenu(
      context,
      isHidden: _hiddenFeatureIds.contains(feature.id),
      showExtrude: isSketchFeature,
      canExtrude: canExtrude,
      extrudeDisabledReason: extrudeDisabledReason,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case FeatureContextMenuAction.extrude:
        _openExtrudePanel(feature);
      case FeatureContextMenuAction.toggleVisibility:
        await _toggleFeatureVisibility(feature);
      case FeatureContextMenuAction.delete:
        await _cascadeDeleteFeature(feature);
    }
  }

  /// Runs the closed-profile check an Extrude action requires - shared by
  /// [_onFeatureLongPress] (Stage 9's original entry point) and Stage 19b's
  /// [_extrudeSelectedFeature] (the "Add" FAB's Feature picker), so the two
  /// don't drift out of sync on what makes a Sketch extrude-eligible.
  /// Returns null when eligible, otherwise the reason to show the caller.
  Future<String?> _checkExtrudeEligibility(FeatureDto feature) async {
    try {
      final profile = await _sketchApi.getProfile(feature.sketchId!);
      return profile.isExtrudable ? null : 'Sketch does not contain a closed profile';
    } catch (_) {
      return 'Sketch does not contain a closed profile';
    }
  }

  /// Opens [ExtrudePanel] for [sketchFeature], resetting every preview-flow
  /// field back to its default - in particular [_meshBeforeExtrude], which
  /// Cancel restores to.
  void _openExtrudePanel(FeatureDto sketchFeature) {
    setState(() {
      _extrudeSketchFeature = sketchFeature;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = _mesh;
      _extrudeType = ExtrudeType.boss;
      _extrudeStartDistance = 0.0;
      _extrudeEndDistance = 10.0;
    });
  }

  /// Creates the preview ExtrudeFeature on the first call, or PATCHes the
  /// one already created by an earlier call, then refetches the mesh -
  /// shared by the debounced live-preview path and [_confirmExtrude] (which
  /// calls this directly, bypassing the debounce, if the user confirms
  /// before any field change ever fired one).
  Future<void> _ensureExtrudeFeatureExists(ExtrudeType type, double start, double end) async {
    final part = _part;
    final sketchFeature = _extrudeSketchFeature;
    if (part == null || sketchFeature == null) return;

    final existingId = _previewExtrudeFeatureId;
    if (existingId == null) {
      final created = await _api.createExtrudeFeature(
        part.id,
        sketchFeatureId: sketchFeature.id,
        extrudeType: type.apiValue,
        startDistance: start,
        endDistance: end,
      );
      _previewExtrudeFeatureId = created.id;
    } else {
      await _api.updateExtrudeFeature(
        part.id,
        existingId,
        extrudeType: type.apiValue,
        startDistance: start,
        endDistance: end,
      );
    }
    await _refreshMesh();
  }

  /// [ExtrudePanel.onChanged] - records the latest values immediately (so
  /// [_confirmExtrude] always has them, even mid-debounce) and (re)starts
  /// the 500ms debounce before actually hitting the backend.
  void _onExtrudeValuesChanged(ExtrudeType type, double start, double end) {
    _extrudeType = type;
    _extrudeStartDistance = start;
    _extrudeEndDistance = end;
    _extrudeDebounce?.cancel();
    _extrudeDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(() => _ensureExtrudeFeatureExists(type, start, end));
    });
  }

  /// Closes the panel, leaving the ExtrudeFeature the preview flow already
  /// created/updated in place - per the brief, Confirm has nothing left to
  /// do beyond that except refresh the Feature tree and mesh, except in the
  /// edge case where the user confirms before any preview update ever
  /// fired (no field touched), in which case the Feature doesn't exist yet
  /// and this creates it with the panel's still-default values first.
  ///
  /// Stage 19b extra: also auto-hides [_extrudeSketchFeature] itself from the
  /// 3D viewport - once a Sketch has been consumed by a Feature, its own
  /// profile drawing is visual clutter on top of the resulting solid, and
  /// the user otherwise had to remember to hide it manually from the tree.
  ///
  /// Prompt D follow-up: also clears [_selectedFeatureId] when it's the
  /// just-consumed Sketch, so a later "Add" FAB > Feature > Extrude doesn't
  /// take [_extrudeSelectedFeature]'s back-compat shortcut straight back to
  /// this same Sketch (skipping the picker) - including after the resulting
  /// ExtrudeFeature is later deleted, since deleting it doesn't otherwise
  /// touch this stale selection.
  Future<void> _confirmExtrude() async {
    _extrudeDebounce?.cancel();
    final sketchFeature = _extrudeSketchFeature;
    await _runGuarded(() async {
      await _ensureExtrudeFeatureExists(_extrudeType, _extrudeStartDistance, _extrudeEndDistance);
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });
    if (!mounted) return;
    setState(() {
      if (sketchFeature != null) _hiddenFeatureIds.add(sketchFeature.id);
      _recomputeVisibleSketchGeometries();
      _extrudeSketchFeature = null;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = null;
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
  }

  /// Deletes the preview ExtrudeFeature (if one was ever created) and
  /// restores the mesh to its pre-extrude state, closing the panel either
  /// way - mirrors [_confirmExtrude]'s structure but undoes rather than
  /// keeps the preview's backend-side effects.
  ///
  /// Prompt D follow-up: also clears [_selectedFeatureId] when it's this
  /// Sketch, for the same reason [_confirmExtrude] does - a cancelled pick
  /// shouldn't leave behind a stale selection that silently skips the
  /// picker next time either.
  Future<void> _cancelExtrude() async {
    _extrudeDebounce?.cancel();
    final part = _part;
    final sketchFeature = _extrudeSketchFeature;
    final previewId = _previewExtrudeFeatureId;
    final meshBefore = _meshBeforeExtrude;
    setState(() {
      _extrudeSketchFeature = null;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = null;
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    if (part == null || previewId == null) return;
    await _runGuarded(() async {
      await _api.deleteFeature(part.id, previewId);
      if (meshBefore != null) {
        _mesh = meshBefore;
      } else {
        await _refreshMesh();
      }
      await _refreshFeatures();
    });
  }

  /// Client-side-only Hide/Show for a Feature - [_hiddenFeatureIds] itself
  /// is never sent to the backend, but it *is* re-sent as the mesh
  /// endpoint's `hidden_feature_ids` query param (see [_refreshMesh]), so
  /// hiding an ExtrudeFeature also drops its volume from the displayed
  /// solid, not just its own Sketch geometry from [_visibleSketchGeometries]
  /// (a SketchFeature has no solid of its own to drop).
  Future<void> _toggleFeatureVisibility(FeatureDto feature) async {
    setState(() {
      if (_hiddenFeatureIds.contains(feature.id)) {
        _hiddenFeatureIds.remove(feature.id);
      } else {
        _hiddenFeatureIds.add(feature.id);
      }
      _recomputeVisibleSketchGeometries();
    });
    await _runGuarded(_refreshMesh);
  }

  /// Cascade-deletes [feature] and every Feature after it, once the user
  /// confirms exactly which ones will go. The Feature tree is already in
  /// creation order, so the Features at and after [feature]'s index are
  /// precisely the ones the backend's cascade-delete will remove.
  Future<void> _cascadeDeleteFeature(FeatureDto feature) async {
    final part = _part;
    if (part == null || _busy) return;

    final index = _features.indexWhere((f) => f.id == feature.id);
    if (index == -1) return;
    final namesToDelete = [
      for (var i = index; i < _features.length; i++) featureDisplayName(_features, i),
    ];

    final confirmed = await showCascadeDeleteDialog(context, namesToDelete);
    if (!confirmed || !mounted) return;

    await _runGuarded(() async {
      await _api.cascadeDeleteFeature(part.id, feature.id);
      // Re-fetch rather than trim local state, so the tree always reflects
      // genuine backend state rather than an assumption about what the
      // cascade just did.
      await _refreshFeatures();
      await _refreshSketchGeometries();
      if (_selectedFeatureId != null && !_features.any((f) => f.id == _selectedFeatureId)) {
        _selectedFeatureId = null;
      }
      _hiddenFeatureIds.removeWhere((id) => !_features.any((f) => f.id == id));
      // Bug-fix: deleting the ExtrudeFeature that consumed a Sketch (see
      // _confirmExtrude's auto-hide) used to leave that Sketch stuck in
      // _hiddenFeatureIds forever, since it never stopped existing - only
      // stopped being locked - so the tree kept showing it dimmed/hidden
      // even once it was editable again. The Sketch was only ever hidden
      // because something depended on it; once the new last Feature is
      // unlocked again, there's nothing left to make it redundant clutter.
      if (_features.isNotEmpty && !_features.last.locked) {
        _hiddenFeatureIds.remove(_features.last.id);
      }
      _recomputeVisibleSketchGeometries();
      await _refreshMesh();
    });
  }

  /// Stage 19b Item 1's dedicated FAB - toggles the Feature tree panel
  /// open/closed (the FAB itself is hidden while it's open, same as the
  /// hamburger toggle below, since [FeatureTreePanel] has its own close
  /// button once open).
  void _toggleFeatureTree() {
    setState(() {
      _featureTreeVisible = !_featureTreeVisible;
      if (_featureTreeVisible) _toolbarOpen = false;
    });
  }

  /// Pushes the Sketch screen and, once it returns (back button or the
  /// ribbon's Exit Sketch action - both just pop this route), re-fetches
  /// Features and their Sketch content: whatever was drawn during this
  /// visit must show up back in the 3D viewport, not only on the next
  /// unrelated Feature-creation refresh.
  Future<void> _openSketch(FeatureDto feature, {ReferencePlaneKind? plane}) async {
    final mesh = _mesh;
    final ghostSegments = (plane != null && mesh != null)
        ? projectMeshEdgesOntoPlane(plane, edgeSegmentsFromMesh(mesh))
        : const <((double, double), (double, double))>[];

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SketchScreen(
          controller: SketchController(api: widget.sketchApiFactory?.call()),
          adoptSketchId: feature.sketchId,
          referenceGhostSegments: ghostSegments,
        ),
      ),
    );
    if (!mounted) return;
    await _runGuarded(() async {
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });
  }

  Future<void> _runGuarded(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await body();
    } on ApiException catch (e) {
      _errorMessage = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // While choosing a plane for a new Sketch (Stage 10b) or a Sketch to
      // extrude (Prompt D), the device back gesture cancels that mode
      // instead of popping this screen - canPop: false intercepts it; any
      // other time, popping proceeds normally.
      canPop: !_planeSelectionMode && !_sketchPickerActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_sketchPickerActive) {
          _cancelSketchPicker();
        } else {
          _cancelPlaneSelectionMode();
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const DidsaLogoButton(),
        leadingWidth: 100,
        centerTitle: false,
        title: Text(_part?.name ?? 'Part', textAlign: TextAlign.right),
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade900)),
            ),
          Expanded(
            child: Stack(
              children: [
                // Full-space by default - the tree/toolbar below are
                // overlays, not siblings in a Row, so the viewport never
                // loses space to a hidden panel.
                PartViewport(
                  key: _viewportKey,
                  mesh: _mesh,
                  selectedPlane: _selectedPlane,
                  sketchGeometries: _visibleSketchGeometries,
                  onPlaneTap: _onPlaneTap,
                  onBackgroundTap: _onViewportBackgroundTap,
                  isPreviewMesh: _extrudeSketchFeature != null,
                  referencePlanesHidden: _referencePlanesHidden,
                  renderMode: _renderMode,
                  bgColourHex: _bgColourHex,
                  bodyColourHex: _bodyColourHex,
                  bodyOpacity: _bodyOpacity,
                  selectionMode: _selectionMode,
                  selectedEntities: _selectedEntities,
                  onSelectionToggle: _toggleSelectedEntity,
                  onClearSelection: _clearSelectedEntities,
                  isPerspective: _isPerspective,
                  farClip: _farClip,
                  onFarClipChanged: _onFarClipChanged,
                ),
                // Stage 23 Item 1: a subtle tinted border around the
                // viewport while in Selection mode - an overlay rather than
                // a decoration on PartViewport itself, so its own layout
                // (and the orbit gesture handling underneath) stays
                // untouched.
                if (_selectionMode)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Stage 23 Items 5/6, Fix 5: the context action panel is
                // passed into the drawer as its [SelectionListDrawer.header]
                // (rendered above the entity list, inside the same draggable
                // sheet) so the two stay visually stacked panel-above-list
                // with no separate height bookkeeping between two
                // independently-positioned widgets. [Positioned.fill] (not a
                // bottom-anchored Positioned) is required here because
                // [DraggableScrollableSheet] sizes itself as a fraction of
                // its parent's height, which only a bounded/full-height
                // ancestor can provide. The Stage 23 mode-toggle FAB lives in
                // Scaffold's own floatingActionButton slot, which Flutter
                // always paints above this body Stack, so this never needs
                // special-cased margin to avoid obscuring it.
                Positioned.fill(
                  child: SelectionListDrawer(
                    selectedEntities: _selectedEntities,
                    onRemove: _toggleSelectedEntity,
                    header: SelectionContextPanel(selectedEntities: _selectedEntities),
                  ),
                ),
                Positioned.fill(
                  child: FeatureTreePanel(
                    visible: _featureTreeVisible && !_extrudeActive,
                    features: _features,
                    selectedFeatureId: _selectedFeatureId,
                    hiddenFeatureIds: _hiddenFeatureIds,
                    onFeatureTap: _onFeatureTap,
                    onFeatureLongPress: _onFeatureLongPress,
                    onClose: () {
                      if (_sketchPickerActive) {
                        _cancelSketchPicker();
                      } else {
                        setState(() => _featureTreeVisible = false);
                      }
                    },
                    isSketchPickerMode: _sketchPickerActive,
                    pickableSketchIds: _pickableSketchIds,
                    onSketchPicked: _onSketchPicked,
                  ),
                ),
                Positioned.fill(
                  child: PartToolbar(
                    visible: _toolbarOpen,
                    referencePlanesHidden: _referencePlanesHidden,
                    onToggleReferencePlanes: _onToggleReferencePlanes,
                    renderMode: _renderMode,
                    onRenderModeChanged: _onRenderModeChanged,
                    onOpenConnectionSettings: _openConnectionSettings,
                    bgColourHex: _bgColourHex,
                    bodyColourHex: _bodyColourHex,
                    bodyOpacity: _bodyOpacity,
                    onBgColourChanged: _onBgColourChanged,
                    onBodyColourChanged: _onBodyColourChanged,
                    onBodyOpacityChanged: _onBodyOpacityChanged,
                    isPerspective: _isPerspective,
                    onPerspectiveChanged: _onPerspectiveChanged,
                    farClip: _farClip,
                    onFarClipChanged: _onFarClipChanged,
                  ),
                ),
                if (_extrudeSketchFeature != null)
                  Positioned.fill(
                    child: ExtrudePanel(
                      key: ValueKey(_extrudeSketchFeature!.id),
                      initialType: _extrudeType,
                      initialStartDistance: _extrudeStartDistance,
                      initialEndDistance: _extrudeEndDistance,
                      onChanged: _onExtrudeValuesChanged,
                      onConfirm: _confirmExtrude,
                      onCancel: _cancelExtrude,
                    ),
                  ),
                // Always on top (last in the Stack) so it stays tappable
                // regardless of whether the toolbar underneath is open -
                // but hidden while the Feature tree is open since it sits
                // right on top of the tree's header text otherwise; the
                // tree's own X button is the way to dismiss it instead.
                // Also hidden during plane-selection mode (Stage 10b), since
                // its own banner below sits in the same top-left corner.
                if (!_featureTreeVisible && !_planeSelectionMode)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Fix 7: was an IconButton.filled, now a FAB above
                          // 'feature-tree-fab' in this same Column, matching
                          // how every other toolbar/viewport toggle here is a
                          // FAB. Stage 22's _extrudeSketchFeature/_toolbarOpen
                          // hiding rule applies for the extrude-panel case
                          // specifically, but never while _toolbarOpen is
                          // true - the hamburger is the only way to close the
                          // toolbar once it's open, so it must stay visible
                          // then regardless of anything else.
                          if (_toolbarOpen || _extrudeSketchFeature == null)
                            FloatingActionButton.small(
                              heroTag: 'hamburger-fab',
                              tooltip: _toolbarOpen ? 'Close toolbar' : 'Open toolbar',
                              onPressed: () => setState(() => _toolbarOpen = !_toolbarOpen),
                              child: Icon(_toolbarOpen ? Icons.close : Icons.menu),
                            ),
                          const SizedBox(height: 8),
                          // Stage 19b Item 1: dedicated secondary FAB,
                          // replacing the hamburger drawer's old "Show
                          // Feature Tree" entry.
                          //
                          // Stage 22 item 3: hidden while the toolbar is
                          // open, since it otherwise paints on top of the
                          // toolbar panel (this FAB sits later in this
                          // Stack than [PartToolbar], so it would always
                          // win paint order) - it isn't usable while the
                          // toolbar is open anyway.
                          if (!_toolbarOpen)
                            FloatingActionButton.small(
                              heroTag: 'feature-tree-fab',
                              tooltip: 'Feature tree',
                              onPressed: _toggleFeatureTree,
                              child: const Icon(Icons.account_tree_outlined),
                            ),
                        ],
                      ),
                    ),
                  ),
                // Stage 10b: shown only while choosing a plane for a new
                // Sketch via the "Add" FAB's flyout - names the mode and
                // offers an explicit Cancel alongside the back-gesture
                // handling in [build].
                if (_planeSelectionMode)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Center(
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(24),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Tap a reference plane for the new sketch'),
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: _cancelPlaneSelectionMode,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      // Stage 10b: hidden while the Extrude panel is open, so its bottom-
      // aligned content never has the FAB sitting on top of it.
      //
      // Stage 22 item 3: also hidden while the toolbar is open - Scaffold
      // always paints floatingActionButton after the entire body
      // (including the body Stack's PartToolbar entry), so it would
      // otherwise sit on top of the open toolbar panel regardless of the
      // body Stack's own child order.
      //
      // Stage 23 Item 1: the mode-toggle FAB sits above the "Add" FAB,
      // hidden under the exact same conditions - it follows the same Stage
      // 22 z-order rules as every other FAB here.
      floatingActionButton: (_extrudeSketchFeature != null || _toolbarOpen)
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'selection-mode-fab',
                  tooltip: _selectionMode ? 'Switch to orbit mode' : 'Switch to selection mode',
                  backgroundColor:
                      _selectionMode ? Theme.of(context).colorScheme.primaryContainer : null,
                  onPressed: _busy ? null : _toggleSelectionMode,
                  // The icon shows the mode a tap will switch *into*: a
                  // cursor/pointer while in (default) Orbit mode, an
                  // orbit/rotate glyph while in Selection mode.
                  child: Icon(_selectionMode ? Icons.threed_rotation : Icons.touch_app),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'add-fab',
                  tooltip: 'Add',
                  onPressed: _busy ? null : _onAddPressed,
                  child: const Icon(Icons.add),
                ),
              ],
            ),
    );
  }
}
