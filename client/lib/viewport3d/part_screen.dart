import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, LineDto, SketchApiClient;
import '../connection_screen.dart';
import '../didsa_logo_button.dart';
import '../sketch/sketch_controller.dart';
import '../sketch/sketch_screen.dart';
import 'add_button_menu.dart';
import 'body_naming.dart';
import 'cascade_delete_dialog.dart';
import 'create_plane_context_sheet.dart';
import 'create_plane_geometry_3d.dart';
import 'create_plane_panel.dart';
import 'extrude_panel.dart';
import 'feature_context_menu.dart';
import 'feature_picker_sheet.dart';
import 'feature_tree_panel.dart';
import 'mesh_geometry.dart';
import 'override_stack.dart';
import 'part_toolbar.dart';
import 'part_viewport.dart';
import 'plane_context_sheet.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
import 'rollback.dart';
import 'selection_context_panel.dart';
import 'selection_filter.dart';
import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;
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

  /// Prompt A3: one entry per independently-tessellated Body (Prompt A1's
  /// `/mesh` array) - was a single `MeshDto? _mesh` before this. Empty
  /// (not the placeholder box) whenever the Part has no ExtrudeFeature yet
  /// or every current Body is hidden - see [_refreshMesh].
  List<BodyMeshDto> _bodies = [];
  String? _selectedFeatureId;

  /// B3 revision: the Part's real, currently-computed Body ids - excludes
  /// the dev-time placeholder box (`source: "placeholder"`), which is never
  /// a real Body and shouldn't appear in the Build Tree's Bodies section or
  /// [SelectionListDrawer]'s naming.
  List<String> get _computedBodyIds =>
      _bodies.where((b) => b.source == 'computed').map((b) => b.bodyId).toList();

  /// Stable "Body 1"/"Body 2"... names shared between the Build Tree's
  /// Bodies section and [SelectionListDrawer] - see `body_naming.dart`.
  /// Recomputed on every build; cheap (a handful of Bodies/Features at
  /// most) and always needs to reflect the latest [_features]/[_bodies].
  Map<String, String> get _bodyNames => bodyDisplayNames(_features, _computedBodyIds);

  /// The reference plane currently tap-selected in the 3D viewport, if any -
  /// drives both [PartViewport]'s brighter highlight and [PartToolbar]'s
  /// "New Sketch on..." entry. Controlled-widget state, same pattern as
  /// [_selectedFeatureId]/[FeatureTreePanel].
  ReferencePlaneKind? _selectedPlane;

  /// C3: the created Plane (by Feature id) currently tap-selected in the 3D
  /// viewport, if any - mirrors [_selectedPlane]'s own controlled-widget
  /// pattern for [PartViewport]'s brighter highlight, just for a
  /// `CreatePlaneFeature` instead of one of the three fixed planes.
  String? _selectedCreatePlaneFeatureId;

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
  ///
  /// Prompt A2: backed by [OverrideStack] rather than a plain field - this
  /// mode has always only ever had one level (push once on entry, pop once
  /// on exit), so migrating it is a real-world correctness check on the new
  /// primitive (see `OverrideStack`'s doc comment) with no behaviour change:
  /// [_planeSelectionMode] itself stays a read-only `bool` getter, so every
  /// existing read site (`if (_planeSelectionMode)` etc.) is untouched.
  final OverrideStack<bool> _planeSelectionModeStack = OverrideStack<bool>();
  bool get _planeSelectionMode => _planeSelectionModeStack.isActive;

  /// Prompt A2: which entity kinds the 3D viewport's Selection mode
  /// hit-testing considers - the View submenu's four toggles write this.
  /// Session-only, no persistence - same convention as [SketchScreen]'s
  /// Canvas Colour/Transparency toggles, not [ViewPreferences]'s
  /// `shared_preferences`-backed one.
  SelectionFilterState _selectionFilterBase = SelectionFilterState.defaults;

  /// Prompt A2: a stack of temporary [SelectionFilterState] overrides any
  /// modal flow can push directly via `.push(state)`/`.pop()` (e.g. a future
  /// Boss/Cut target-body picker in Prompt A4 pushing "bodies only,
  /// everything else off"), the same way [_planeSelectionModeStack] above is
  /// driven - nothing pushes onto this yet in this prompt, which only builds
  /// and exercises the primitive itself (see `override_stack_test.dart`).
  /// [_selectionFilter] is always what hit-testing/the View submenu should
  /// actually show: the top of this stack if active, else
  /// [_selectionFilterBase].
  final OverrideStack<SelectionFilterState> _selectionFilterOverrides =
      OverrideStack<SelectionFilterState>();
  SelectionFilterState get _selectionFilter =>
      _selectionFilterOverrides.current ?? _selectionFilterBase;

  void _setVertexFilter(bool value) {
    setState(() => _selectionFilterBase = _selectionFilterBase.copyWith(vertex: value));
  }

  void _setEdgeFilter(bool value) {
    setState(() => _selectionFilterBase = _selectionFilterBase.copyWith(edge: value));
  }

  void _setFaceFilter(bool value) {
    setState(() => _selectionFilterBase = _selectionFilterBase.copyWith(face: value));
  }

  void _setSketchPointFilter(bool value) {
    setState(() => _selectionFilterBase = _selectionFilterBase.copyWith(sketchPoint: value));
  }

  void _setSketchLineFilter(bool value) {
    setState(() => _selectionFilterBase = _selectionFilterBase.copyWith(sketchLine: value));
  }

  /// Body is exclusive against vertex/edge/face, not merely additive: there
  /// is no click that lands "on the body" without also landing on one of its
  /// faces/edges/vertices, and [hitTestBodies] tries vertex/edge before body
  /// (see `selection_hit_test.dart`), so with all four enabled a body could
  /// never actually be picked wherever a vertex/edge is in range - precisely
  /// where users naturally click. Turning Body on therefore forces the other
  /// three off (and the toolbar greys them out, see [PartToolbar]); turning
  /// it back off restores them to their default on-state. Prompt C1: also
  /// excludes Sketch Point/Line, which tie with Body Vertex/Edge at the top
  /// of the hit-test priority order - without this, "Body only" would still
  /// let a Sketch entity win the pick.
  void _setBodyFilter(bool value) {
    setState(() {
      _selectionFilterBase = value
          ? const SelectionFilterState(
              vertex: false,
              edge: false,
              face: false,
              body: true,
              sketchPoint: false,
              sketchLine: false,
            )
          : _selectionFilterBase.copyWith(
              vertex: true,
              edge: true,
              face: true,
              body: false,
              sketchPoint: true,
              sketchLine: true,
            );
    });
  }

  /// Feature ids hidden from the 3D viewport via the long-press
  /// Hide/Show action - client-side only, never sent to the backend.
  final Set<String> _hiddenFeatureIds = {};

  /// Prompt C1: the subset of [_hiddenFeatureIds] hidden purely because
  /// [_confirmExtrude]'s auto-hide-the-consumed-Sketch bookkeeping put them
  /// there - never because the user explicitly hid them, and never one of
  /// B4's rollback-suppressed later Features (see [_beginRollback], which
  /// deliberately does not add to this set). [_recomputeVisibleSketchGeometries]
  /// uses this to keep a merely-auto-hidden Sketch's geometry rendered and
  /// pickable (dimmed - see `sketch_geometry_3d.dart`'s `sketchLineDimmedColor`)
  /// even though it's still "hidden" for every other purpose (the feature
  /// tree's greyed display, `_refreshMesh`'s `hidden_feature_ids`, which is
  /// a no-op for a Sketch anyway since it never contributes solid geometry) -
  /// this is exactly Prompt C1's own motivating case, Create Plane
  /// referencing the profile Sketch of an already-built Boss. A real user
  /// Hide (via [_toggleFeatureVisibility]) or a rollback suppression both
  /// leave a Feature out of this set, so both still fully exclude its
  /// Sketch geometry from the 3D viewport, same as before this prompt.
  final Set<String> _autoHiddenSketchFeatureIds = {};

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
  ///
  /// Prompt A4: while [_extrudeActive], [_selectedEntities] *is* the
  /// target-body picker's selection (see [_openExtrudePanel]), so a tap here
  /// is a body pick - reschedules the debounced live-preview re-solve so it
  /// picks up the new `target_body_ids`, same as any other field change.
  void _toggleSelectedEntity(SelectionEntityRef entity) {
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (!next.remove(entity)) next.add(entity);
      _selectedEntities = next;
    });
    if (_extrudeActive) _scheduleExtrudePreview();
  }

  /// Item 4: "Empty space tap -> clears entire selection set" - passed to
  /// [PartViewport.onClearSelection], fired by a tap (Fix 4) when the
  /// cursor's hover hit is null. See [_toggleSelectedEntity]'s doc comment
  /// for why this also reschedules the preview during [_extrudeActive].
  void _clearSelectedEntities() {
    setState(() => _selectedEntities = {});
    if (_extrudeActive) _scheduleExtrudePreview();
  }

  /// Every Feature's 3D Sketch geometry, keyed by Feature id, regardless of
  /// [_hiddenFeatureIds] - [_visibleSketchGeometries] is the
  /// hidden-filtered view of this actually passed to [PartViewport].
  Map<String, SketchGeometry3D> _allSketchGeometries = {};
  Map<String, SketchGeometry3D> _visibleSketchGeometries = {};

  /// C2: raw `LineDto`s per Sketch Feature, populated alongside
  /// [_allSketchGeometries] (see [_refreshSketchGeometries]) - unlike
  /// [SketchGeometry3D] (world-space render geometry only), this keeps each
  /// Line's own `startPointId`/`endPointId`, which [_isPointOnLine] needs to
  /// tell a Line's real endpoint apart from an unrelated Point elsewhere in
  /// the same Sketch.
  Map<String, List<LineDto>> _linesByFeatureId = {};

  /// Prompt C1: which entries of [_visibleSketchGeometries] should render
  /// dimmed (see [_recomputeVisibleSketchGeometries]) - always a subset of
  /// [_visibleSketchGeometries]'s keys.
  Set<String> _dimmedSketchFeatureIds = {};

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

  /// [_bodies]' value from just before the panel opened, restored by
  /// Cancel. Null (as opposed to empty) means "never captured yet" -
  /// [_cancelExtrude] falls back to [_refreshMesh] in that case, the same
  /// distinction it made when this was a single nullable `MeshDto?`.
  List<BodyMeshDto>? _meshBeforeExtrude;

  /// Prompt A4: [_selectedEntities]' value from just before the panel
  /// opened. While the panel is open, [_selectedEntities] is dedicated
  /// entirely to target-body picking (see [_openExtrudePanel], which also
  /// forces [_selectionFilterOverrides] to bodies-only) rather than the
  /// general Stage 23 selection it normally holds, so whatever the user had
  /// already selected there isn't silently lost. Restored by both
  /// [_confirmExtrude] and [_cancelExtrude]. Null (as opposed to empty)
  /// means "never captured yet" - same distinction [_meshBeforeExtrude]
  /// makes just above.
  Set<SelectionEntityRef>? _entitiesBeforeExtrude;

  /// B4: non-null while [ExtrudePanel] is editing an *existing*
  /// ExtrudeFeature (as opposed to [_openExtrudePanel]'s "create a brand-new
  /// one from a Sketch" flow) - set upfront to that Feature's own id in
  /// [_openExtrudePanelForEdit], which is what makes every subsequent
  /// [_ensureExtrudeFeatureExists] call (the live-preview debounce
  /// included) PATCH it directly rather than ever creating a new Feature.
  String? _editingExtrudeFeatureId;

  /// B4: the edited Feature's own stored values from just before editing
  /// started - [_cancelExtrude] PATCHes these back verbatim when
  /// [_editingExtrudeFeatureId] is set, since (unlike the "create new"
  /// flow, where Cancel deletes the just-created preview Feature) an
  /// already-existing Feature must never be deleted just because its edit
  /// was cancelled.
  ({ExtrudeType type, double start, double end, List<String> targetBodyIds})? _extrudeEditSnapshot;

  /// B4: [_hiddenFeatureIds]' value from just before true-rollback editing
  /// began (see [_beginRollback]/[_endRollback]) - null whenever rollback
  /// isn't currently active (e.g. editing the last Feature, which has
  /// nothing after it to suppress in the first place).
  Set<String>? _hiddenFeatureIdsBeforeRollback;

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

  // --- C2: Create Plane -----------------------------------------------------

  /// Non-null while [CreatePlanePanel] is open - which of the two v1 flows
  /// (see `create_plane_panel.dart`'s `CreatePlaneMode`) is showing. Set by
  /// [_onCreatePlaneTapped]/[_openCreatePlanePanelForEdit], cleared by
  /// [_confirmCreatePlane]/[_cancelCreatePlane].
  CreatePlaneMode? _createPlaneMode;

  /// The CreatePlaneFeature created (or, in edit mode, already existing) for
  /// the panel session - mirrors [_previewExtrudeFeatureId]'s "create
  /// eagerly on open, PATCH on every field edit, Confirm just closes,
  /// Cancel deletes-or-reverts" pattern, since unlike Extrude there is no
  /// separate "not yet a real Feature" preview state to speak of: Create
  /// Plane produces no mesh, so there's no expensive-to-discard geometry
  /// riding on the distinction. Null only while creation is still in
  /// flight, or if it failed outright (see [_openCreatePlanePanel]'s own
  /// handling of that case).
  String? _previewCreatePlaneFeatureId;

  /// B4: non-null while [CreatePlanePanel] is editing an *existing*
  /// CreatePlaneFeature (as opposed to [_onCreatePlaneTapped]'s "create a
  /// brand-new one from the current selection" flow) - same purpose as
  /// [_editingExtrudeFeatureId].
  String? _editingCreatePlaneFeatureId;

  /// B4: the edited Feature's own stored values from just before editing
  /// started - [_cancelCreatePlane] PATCHes these back verbatim when
  /// [_editingCreatePlaneFeatureId] is set, same reason
  /// [_extrudeEditSnapshot] exists.
  ({List<SubShapeRefDto> faceRefs, double? offset, SketchEntityRefDto? lineRef, SketchEntityRefDto? pointRef})?
      _createPlaneEditSnapshot;

  /// [_selectedEntities]' value from just before the panel opened - restored
  /// by both [_confirmCreatePlane] and [_cancelCreatePlane], same purpose
  /// [_entitiesBeforeExtrude] serves for target-body picking.
  Set<SelectionEntityRef>? _entitiesBeforeCreatePlane;

  /// Only meaningful (and only ever read) while [_createPlaneMode] is
  /// [CreatePlaneMode.offsetFace] - the panel's live offset field value,
  /// debounced into a PATCH the same way [_extrudeStartDistance] etc. are.
  double _createPlaneOffset = 0.0;

  Timer? _createPlaneDebounce;

  bool get _createPlaneActive => _createPlaneMode != null;

  /// C2: per-Feature resolved plane geometry for [PartViewport.createPlanes] -
  /// recomputed from [_features] directly (no extra network call - the
  /// resolved `origin`/`normal` already ride along on every
  /// `GET .../features` response, see `_create_plane_feature_response`),
  /// so this is refreshed unconditionally at the end of every
  /// [_refreshFeatures] call rather than needing its own explicit refresh
  /// call threaded through every call site the way [_refreshSketchGeometries]
  /// needs (that one needs its own separate network calls per Sketch).
  Map<String, ResolvedPlaneGeometry> _createPlaneGeometries = {};

  void _recomputeCreatePlaneGeometries() {
    _createPlaneGeometries = {
      for (final feature in _features)
        if (feature.type == 'create_plane' &&
            feature.origin != null &&
            feature.normal != null &&
            feature.xAxis != null &&
            feature.yAxis != null)
          feature.id: ResolvedPlaneGeometry(
            origin: vm.Vector3(feature.origin![0], feature.origin![1], feature.origin![2]),
            normal: vm.Vector3(feature.normal![0], feature.normal![1], feature.normal![2]),
            xAxis: vm.Vector3(feature.xAxis![0], feature.xAxis![1], feature.xAxis![2]),
            yAxis: vm.Vector3(feature.yAxis![0], feature.yAxis![1], feature.yAxis![2]),
          ),
    };
  }

  /// C3: [feature]'s own resolved basis, converted to [SketchPlaneBasis] for
  /// a Sketch anchored to it (see `sketch_geometry_3d.dart`) - null if
  /// [feature] isn't a currently-resolvable `create_plane` Feature (a stale
  /// reference, or [_recomputeCreatePlaneGeometries] hasn't run yet).
  SketchPlaneBasis? _customPlaneBasis(String planeFeatureId) {
    final geometry = _createPlaneGeometries[planeFeatureId];
    if (geometry == null) return null;
    return SketchPlaneBasis(
      origin: geometry.origin,
      xAxis: geometry.xAxis,
      yAxis: geometry.yAxis,
      normal: geometry.normal,
    );
  }

  /// C3: [feature]'s own Sketch-embedding basis - a custom plane's (via
  /// [feature.planeFeatureId]) or one of the three fixed reference planes'
  /// (via [ReferencePlaneKind], fetched from the standalone Sketch API the
  /// same way this always worked before C3). Returns null when neither
  /// resolves (a stale/broken reference, or a fetch failure) - callers treat
  /// that the same way an unresolvable [ReferencePlaneKind] already was
  /// (skip rendering/animation, never crash).
  Future<SketchPlaneBasis?> _sketchPlaneBasisFor(FeatureDto feature) async {
    final planeFeatureId = feature.planeFeatureId;
    if (planeFeatureId != null) return _customPlaneBasis(planeFeatureId);
    final sketchId = feature.sketchId;
    if (sketchId == null) return null;
    final sketch = await _sketchApi.getSketch(sketchId);
    final plane = referencePlaneKindFromApiValue(sketch.plane);
    return plane == null ? null : SketchPlaneBasis.fixed(plane);
  }

  /// C2: resolves a `SelectionEntityRef.sketchFeatureId` (a Feature id) back
  /// to the real `app.sketch.models.Sketch` id the backend's
  /// `SketchEntityRef.sketch_id` needs - see `SketchEntityRefDto`'s own doc
  /// comment for why those two ids differ. Null if no such Feature exists
  /// (defensive only - every sketchLine/sketchPoint selection is always
  /// tagged with a real, currently-loaded Feature id).
  String? _sketchIdForFeatureId(String featureId) => _featureById(featureId)?.sketchId;

  /// C2: whether [pointEntityId] is one of [lineEntityId]'s own two endpoint
  /// ids, within the Sketch Feature [sketchFeatureId] - the real lookup
  /// `selection_actions.dart`'s `PointOnLineChecker` needs, backed by
  /// [_linesByFeatureId] (populated alongside [_allSketchGeometries] - see
  /// [_refreshSketchGeometries]).
  bool _isPointOnLine(String sketchFeatureId, String lineEntityId, String pointEntityId) {
    final lines = _linesByFeatureId[sketchFeatureId];
    if (lines == null) return false;
    for (final line in lines) {
      if (line.id == lineEntityId) {
        return line.startPointId == pointEntityId || line.endPointId == pointEntityId;
      }
    }
    return false;
  }

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
      debugPrint('[PartScreen] getPartMesh done: ${_bodies.length} body/bodies');
      await _refreshFeatures();
      await _refreshSketchGeometries();
      debugPrint('[PartScreen] refreshFeatures done');
    });
  }

  Future<void> _refreshFeatures() async {
    final part = _part;
    if (part == null) return;
    _features = await _api.listFeatures(part.id);
    _recomputeCreatePlaneGeometries();
  }

  /// Re-fetches the Part's mesh with [_hiddenFeatureIds] sent along, so a
  /// hidden ExtrudeFeature's contribution to the displayed solid (and so to
  /// the camera target/zoom bounds [PartViewport] derives from it) drops
  /// out immediately - called after anything that can change either the
  /// Part's geometry (extrude preview/confirm/cancel, cascade delete) or
  /// [_hiddenFeatureIds] itself (Hide/Show).
  ///
  /// Discards the response entirely when it's the placeholder box (Prompt
  /// A1: a single-entry array, `body_id: "placeholder"`, `source:
  /// "placeholder"` - see `backend/app/document/router.py`'s
  /// `BRepPrimAPI_MakeBox(10,10,10)` fallback for a Part with no
  /// ExtrudeFeature yet) rather than rendering it - that placeholder box is
  /// a backend implementation detail to keep the mesh endpoint's response
  /// shape uniform, not real geometry the user created, and showing it as a
  /// stray cube in an otherwise-empty viewport was confusing on-device.
  Future<void> _refreshMesh() async {
    final part = _part;
    if (part == null) return;
    final response = await _api.getPartMesh(part.id, hiddenFeatureIds: _hiddenFeatureIds.toList());
    final isPlaceholder = response.length == 1 && response.first.source == 'placeholder';
    _bodies = isPlaceholder ? [] : response;
  }

  /// Re-fetches every Feature's Sketch content (points/lines/circles) and
  /// rebuilds [_allSketchGeometries]/[_visibleSketchGeometries] from it, so
  /// the 3D viewport's rendered Sketch geometry always matches the latest
  /// backend state. A single Feature's fetch failing (e.g. a test fixture
  /// that only stubs `GET /sketch/sketches/{id}`, or a transient network
  /// issue) only drops that Feature's geometry, not the whole viewport.
  Future<void> _refreshSketchGeometries() async {
    final updated = <String, SketchGeometry3D>{};
    final updatedLines = <String, List<LineDto>>{};
    for (final feature in _features) {
      final sketchId = feature.sketchId;
      if (sketchId == null) continue; // An ExtrudeFeature - no Sketch of its own.
      try {
        final basis = await _sketchPlaneBasisFor(feature);
        if (basis == null) continue;
        final points = await _sketchApi.listPoints(sketchId);
        final lines = await _sketchApi.listLines(sketchId);
        final circles = await _sketchApi.listCircles(sketchId);
        updatedLines[feature.id] = lines;
        final geometry =
            sketchGeometry3DFrom(basis: basis, points: points, lines: lines, circles: circles);
        if (!geometry.isEmpty) updated[feature.id] = geometry;
      } catch (_) {
        // Swallow - see doc comment above.
      }
    }
    _allSketchGeometries = updated;
    _linesByFeatureId = updatedLines;
    _recomputeVisibleSketchGeometries();
  }

  /// Filters [_allSketchGeometries] down to [_visibleSketchGeometries] by
  /// [_hiddenFeatureIds] - the only place that builds a new Map/Set instance
  /// for [PartViewport.sketchGeometries]/[PartViewport.dimmedSketchFeatureIds],
  /// so their `didUpdateWidget` `!=` checks only fire on a genuine
  /// content/visibility change.
  ///
  /// Prompt C1: a Feature hidden *only* via [_autoHiddenSketchFeatureIds]
  /// (auto-hidden because it's consumed, not a real user Hide - see that
  /// field's own doc comment) stays in [_visibleSketchGeometries] rather
  /// than being excluded, and is also added to [_dimmedSketchFeatureIds] so
  /// [PartViewport] renders it with `sketch_geometry_3d.dart`'s dimmed
  /// style - visually distinct from an active Sketch, but still pickable,
  /// which is this prompt's whole point.
  ///
  /// This exception is suspended entirely while [_hiddenFeatureIdsBeforeRollback]
  /// is non-null (a B4 rollback edit is in progress): [_beginRollback] never
  /// touches [_autoHiddenSketchFeatureIds], so a Sketch that was already
  /// auto-hidden *before* the rollback session began (its own Extrude sits
  /// somewhere in the range now being suppressed) would otherwise wrongly
  /// stay visible/pickable during the edit, defeating B4's "suppress
  /// everything after the Feature being edited" invariant. Outside of an
  /// active rollback, this gate is always true and has no effect.
  void _recomputeVisibleSketchGeometries() {
    final rollbackActive = _hiddenFeatureIdsBeforeRollback != null;
    _visibleSketchGeometries = {
      for (final entry in _allSketchGeometries.entries)
        if (!_hiddenFeatureIds.contains(entry.key) ||
            (!rollbackActive && _autoHiddenSketchFeatureIds.contains(entry.key)))
          entry.key: entry.value,
    };
    _dimmedSketchFeatureIds = {
      for (final entry in _allSketchGeometries.entries)
        if (!rollbackActive &&
            _hiddenFeatureIds.contains(entry.key) &&
            _autoHiddenSketchFeatureIds.contains(entry.key))
          entry.key,
    };
  }

  /// Creates a SketchFeature on [plane] (default) or, since C3, anchored to
  /// an existing created Plane ([planeFeatureId] - never both) and navigates
  /// straight to its SketchScreen - called from the free-tap fly-up sheet
  /// flow ([_showPlaneContextSheet]), the FAB's flyout-driven plane-selection
  /// mode ([_onPlaneTap]), and (C3) a created Plane's own context sheet's
  /// "Create Sketch on Plane" action ([_onCreatePlaneContextAction]).
  ///
  /// C3: a custom-plane Sketch has no [ReferencePlaneKind] to animate the
  /// camera toward (see [_openSketchWithAnimation]'s own doc comment) - skips
  /// the animation for that case, same graceful degradation.
  Future<void> _addSketchFeature({ReferencePlaneKind? plane, String? planeFeatureId}) async {
    final part = _part;
    if (part == null || _busy) return;
    final fixedPlane = planeFeatureId == null ? (plane ?? ReferencePlaneKind.xy) : null;

    FeatureDto? created;
    await _runGuarded(() async {
      created = await _api.createSketchFeature(
        part.id,
        plane: fixedPlane?.apiValue,
        planeFeatureId: planeFeatureId,
      );
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });

    final feature = created;
    if (feature != null && mounted) {
      SketchPlaneBasis? basis;
      if (fixedPlane != null) {
        await _viewportKey.currentState?.animateToPlane(fixedPlane);
        if (!mounted) return;
        basis = SketchPlaneBasis.fixed(fixedPlane);
      } else if (planeFeatureId != null) {
        basis = _customPlaneBasis(planeFeatureId);
      }
      await _openSketch(feature, basis: basis);
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
      setState(() => _planeSelectionModeStack.pop());
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

  /// C3: a tap that landed on a created Plane's rendered quad - selects it
  /// (brighter highlight, mirroring [_onPlaneTap]'s own for the three fixed
  /// planes) and opens [showCreatePlaneContextSheet]'s fly-up.
  void _onCreatePlaneFeatureTap(String featureId) {
    setState(() {
      _selectedCreatePlaneFeatureId = featureId;
      _featureTreeVisible = false;
    });
    _showCreatePlaneContextSheet(featureId);
  }

  /// Awaits [showCreatePlaneContextSheet] and acts on whatever it returns,
  /// clearing the highlight once it's dismissed either way - mirrors
  /// [_showPlaneContextSheet] exactly. "Create Sketch on Plane" reuses
  /// [_addSketchFeature]'s [planeFeatureId] path; "Delete Plane" reuses the
  /// same cascade-delete flow ([_cascadeDeleteFeature]) every other Feature's
  /// long-press menu already offers, since a created Plane is just another
  /// Feature that may have Sketches (and their own downstream Extrudes)
  /// depending on it.
  Future<void> _showCreatePlaneContextSheet(String featureId) async {
    final action = await showCreatePlaneContextSheet(context, featureId: featureId);
    if (!mounted) return;
    setState(() => _selectedCreatePlaneFeatureId = null);
    if (action == CreatePlaneContextSheetAction.newSketch) {
      await _addSketchFeature(planeFeatureId: featureId);
    } else if (action == CreatePlaneContextSheetAction.delete) {
      final feature = _featureById(featureId);
      if (feature != null) await _cascadeDeleteFeature(feature);
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
      _selectedCreatePlaneFeatureId = null;
      _toolbarOpen = false;
      _planeSelectionModeStack.pop();
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
          _planeSelectionModeStack.push(true);
          _selectedPlane = null;
          _toolbarOpen = false;
          _featureTreeVisible = false;
        });
      case AddButtonMenuAction.feature:
        await _onFeaturePressed();
    }
  }

  /// The "Add" FAB's "Feature" entry - shows the second-level picker and
  /// acts on whichever (enabled) entry was tapped. Extrude and (C3) Plane
  /// are wired up; the rest render disabled in the sheet itself and so
  /// never produce an action here.
  Future<void> _onFeaturePressed() async {
    final action = await showFeaturePickerSheet(context);
    if (!mounted || action == null) return;
    switch (action) {
      case FeaturePickerAction.extrude:
        await _extrudeSelectedFeature();
      case FeaturePickerAction.plane:
        _startPlanePicker();
    }
  }

  /// C3: the "Add" FAB's Feature picker's "Plane" entry - clears the current
  /// selection and hints what to pick next, then relies entirely on the
  /// pre-existing ambient selection machinery ([SelectionContextPanel]/
  /// `contextActionsFor`/[_onCreatePlaneTapped]) to actually open
  /// [CreatePlanePanel] once a valid combo (one Face, two Faces, or a Line
  /// plus the Point that's its own endpoint) is selected. Unlike
  /// [_startSketchPicker], there is no separate guided-picker mode to enter -
  /// Create Plane's selection flow already worked this way for every other
  /// entry point (a free tap on a Face/Line/Point in the viewport already
  /// offered "Create Plane" before this menu entry existed), so this just
  /// clears the deck and points the user at it.
  void _startPlanePicker() {
    setState(() {
      _selectedEntities = {};
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _planeSelectionModeStack.pop();
    });
    _showSnack('Select a face, two faces, or a line and its endpoint to create a plane');
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
      _planeSelectionModeStack.pop();
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
    setState(() => _planeSelectionModeStack.pop());
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

  /// B4: a tap always selects/highlights the Feature and now opens it for
  /// editing regardless of lock state - true SolidWorks-style rollback
  /// (see [_beginRollback]) engages first whenever the tapped Feature isn't
  /// already the last one, so its edit panel/Sketch never shows stale
  /// downstream geometry behind it. A Sketch opens the 2D canvas (as
  /// before B4, just no longer gated on `!feature.locked`); an Extrude
  /// reopens [ExtrudePanel] prefilled with its own current stored values
  /// (see [_openExtrudePanelForEdit]) rather than doing nothing, which is
  /// what an Extrude-Feature tap did pre-B4.
  Future<void> _onFeatureTap(FeatureDto feature) async {
    setState(() => _selectedFeatureId = feature.id);
    final rollbackIds = featureIdsAfter(_features, feature.id);
    if (rollbackIds.isNotEmpty) await _beginRollback(rollbackIds);
    if (!mounted) return;
    if (feature.type == 'sketch') {
      await _openSketchWithAnimation(feature);
      if (!mounted) return;
      await _endRollback();
    } else if (feature.type == 'extrude') {
      // Rollback is ended by _confirmExtrude/_cancelExtrude instead, once
      // the panel actually closes - it must stay engaged for the panel's
      // whole lifetime, not just until it opens. If the panel couldn't
      // actually open (defensive only - a real ExtrudeFeature always
      // resolves its own Sketch), roll forward immediately rather than
      // leaving rollback stuck engaged with nothing to end it.
      final opened = _openExtrudePanelForEdit(feature);
      if (!opened) await _endRollback();
    } else if (feature.type == 'create_plane') {
      // C2: rollback is ended by _confirmCreatePlane/_cancelCreatePlane
      // instead, same "stays engaged for the panel's whole lifetime"
      // reasoning as the extrude branch above.
      _openCreatePlanePanelForEdit(feature);
    } else {
      // Defensive: no known editable panel for this Feature type yet
      // (every type today is handled above) - never leave rollback
      // engaged with nothing that will ever end it.
      await _endRollback();
    }
  }

  /// B4: engages true rollback - hides [rollbackIds] on top of whatever the
  /// user already had hidden manually (Hide/Show, unrelated to this),
  /// stashing the pre-rollback set so [_endRollback] can restore it
  /// exactly. Reuses the pre-existing [_hiddenFeatureIds]/
  /// `hidden_feature_ids` mechanism (A1) - a Feature named there is already
  /// excluded entirely from backend recompute, not just hidden visually -
  /// rather than inventing a second, parallel suppression concept.
  Future<void> _beginRollback(Set<String> rollbackIds) async {
    _hiddenFeatureIdsBeforeRollback = Set.of(_hiddenFeatureIds);
    setState(() => _hiddenFeatureIds.addAll(rollbackIds));
    await _runGuarded(_refreshMesh);
  }

  /// B4: undoes [_beginRollback] - restores exactly the hidden set from
  /// before rollback began, discarding the rollback-only additions (a real
  /// manual Hide/Show made *during* the edit is also discarded here, same
  /// as every other "restore to before this flow started" stash in this
  /// file, e.g. [_meshBeforeExtrude]/[_entitiesBeforeExtrude]). A safe no-op
  /// if rollback was never engaged for this edit (editing the last
  /// Feature).
  Future<void> _endRollback() async {
    final before = _hiddenFeatureIdsBeforeRollback;
    if (before == null) return;
    setState(() {
      _hiddenFeatureIds
        ..clear()
        ..addAll(before);
      // Prompt C1: without this, [_visibleSketchGeometries]/
      // [_dimmedSketchFeatureIds] would stay computed against the
      // mid-rollback hidden set (and its rollback-active auto-hidden
      // suspension) until some unrelated later refresh happened to
      // recompute them.
      _hiddenFeatureIdsBeforeRollback = null;
      _recomputeVisibleSketchGeometries();
    });
    await _runGuarded(_refreshMesh);
  }

  /// B3 revision: tapping a Body row in the Build Tree's Bodies section -
  /// toggles it in [_selectedEntities] exactly like tapping that Body
  /// directly in the 3D viewport already does (`_toggleSelectedEntity`),
  /// rather than a separate one-off "always select" action - the same
  /// selection set drives [SelectionListDrawer] either way, so the two
  /// selection paths (tree row, viewport tap) stay fully interchangeable.
  void _onBodyTap(String bodyId) {
    _toggleSelectedEntity(SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bodyId));
  }

  /// Animates the 3D camera to face this Feature's Sketch plane (per the
  /// brief's "camera animation when entering a sketch") before navigating to
  /// its 2D canvas - skips straight to navigation if the plane can't be
  /// resolved (e.g. a fetch failure), rather than blocking the open.
  Future<void> _openSketchWithAnimation(FeatureDto feature) async {
    final planeFeatureId = feature.planeFeatureId;
    if (planeFeatureId != null) {
      // C3: a custom-plane Sketch has no ReferencePlaneKind to animate the
      // camera to (orientationFacingPlane only covers the three fixed
      // planes) - skips the animation, the same graceful "can't resolve,
      // just navigate" fallback this method already used for a fetch
      // failure, and still passes along the real basis for the ghost
      // overlay below.
      await _openSketch(feature, basis: _customPlaneBasis(planeFeatureId));
      return;
    }
    final plane = await _planeOfFeature(feature);
    if (!mounted) return;
    if (plane != null) {
      await _viewportKey.currentState?.animateToPlane(plane);
      if (!mounted) return;
    }
    await _openSketch(feature, basis: plane == null ? null : SketchPlaneBasis.fixed(plane));
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
  ///
  /// Prompt A4: also enters target-body picking mode for the duration of the
  /// panel - stashes whatever was already in [_selectedEntities] (restored
  /// by [_confirmExtrude]/[_cancelExtrude]) so it can be reused directly as
  /// the picker's own selection, and pushes a bodies-only
  /// [_selectionFilterOverrides] override so every viewport tap while the
  /// panel is open can only ever produce a [SelectionEntityKind.body] hit
  /// (see `selection_hit_test.dart`'s `hitTestBodies`).
  void _openExtrudePanel(FeatureDto sketchFeature) {
    setState(() {
      _extrudeSketchFeature = sketchFeature;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = _bodies;
      _extrudeType = ExtrudeType.boss;
      _extrudeStartDistance = 0.0;
      _extrudeEndDistance = 10.0;
      _entitiesBeforeExtrude = _selectedEntities;
      _selectedEntities = {};
      _selectionFilterOverrides.push(
        const SelectionFilterState(
          vertex: false,
          edge: false,
          face: false,
          body: true,
          sketchPoint: false,
          sketchLine: false,
        ),
      );
    });
  }

  /// B4: opens [ExtrudePanel] to edit an *already-existing* ExtrudeFeature -
  /// unlike [_openExtrudePanel] (always a brand-new Feature from a Sketch),
  /// every field (including `target_body_ids`, via [_selectedEntities]) is
  /// prefilled from [feature]'s own current stored values, and
  /// [_previewExtrudeFeatureId] is set to [feature]'s own id upfront - this
  /// is what makes every [_ensureExtrudeFeatureExists] call (the
  /// live-preview debounce included) PATCH it directly, so Confirm "PATCHes
  /// the existing feature, never creates a new one" by construction rather
  /// than a special Confirm-time branch. Returns false (and does nothing
  /// else) if [feature]'s own Sketch can't be resolved (defensive only -
  /// every real Extrude Feature always names a real SketchFeature, enforced
  /// at create time) - the caller ends true-rollback immediately in that
  /// case, since nothing will otherwise ever do so.
  bool _openExtrudePanelForEdit(FeatureDto feature) {
    final sketchFeatureId = feature.sketchFeatureId;
    final sketchFeature = sketchFeatureId == null ? null : _featureById(sketchFeatureId);
    if (sketchFeature == null) return false;

    final type = ExtrudeType.fromApiValue(feature.extrudeType ?? 'boss');
    final start = feature.startDistance ?? 0.0;
    final end = feature.endDistance ?? 10.0;
    final targetBodyIds = feature.targetBodyIds;

    setState(() {
      _extrudeSketchFeature = sketchFeature;
      _editingExtrudeFeatureId = feature.id;
      _previewExtrudeFeatureId = feature.id;
      _extrudeEditSnapshot = (type: type, start: start, end: end, targetBodyIds: targetBodyIds);
      _meshBeforeExtrude = _bodies;
      _extrudeType = type;
      _extrudeStartDistance = start;
      _extrudeEndDistance = end;
      _entitiesBeforeExtrude = _selectedEntities;
      _selectedEntities = {
        for (final bodyId in targetBodyIds)
          SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bodyId),
      };
      _selectionFilterOverrides.push(
        const SelectionFilterState(
          vertex: false,
          edge: false,
          face: false,
          body: true,
          sketchPoint: false,
          sketchLine: false,
        ),
      );
    });
    return true;
  }

  /// Creates the preview ExtrudeFeature on the first call, or PATCHes the
  /// one already created by an earlier call, then refetches the mesh -
  /// shared by the debounced live-preview path and [_confirmExtrude] (which
  /// calls this directly, bypassing the debounce, if the user confirms
  /// before any field change ever fired one).
  ///
  /// Prompt A4: [targetBodyIds] is always the *current* picks (see
  /// [_currentTargetBodyIds]) at the moment this actually runs, not a
  /// snapshot from when it was scheduled - both callers pass a freshly
  /// computed value right before calling this.
  Future<void> _ensureExtrudeFeatureExists(
    ExtrudeType type,
    double start,
    double end,
    List<String> targetBodyIds,
  ) async {
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
        targetBodyIds: targetBodyIds,
      );
      _previewExtrudeFeatureId = created.id;
    } else {
      await _api.updateExtrudeFeature(
        part.id,
        existingId,
        extrudeType: type.apiValue,
        startDistance: start,
        endDistance: end,
        targetBodyIds: targetBodyIds,
      );
    }
    await _refreshMesh();
  }

  /// Prompt A4: [_selectedEntities]' bodyIds while [_extrudeActive] - always
  /// [SelectionEntityKind.body] entries only, since [_openExtrudePanel]
  /// forces the bodies-only filter override for the panel's whole lifetime.
  /// A `Set` first (not just `.toList()`) since a single Body can appear
  /// more than once in [_selectedEntities] in principle - `hitTestBodies`
  /// only ever adds one [SelectionEntityRef] per body id, but de-duplicating
  /// here costs nothing and guards against ever sending a repeated id.
  List<String> _currentTargetBodyIds() =>
      _selectedEntities.map((e) => e.bodyId).toSet().toList();

  /// [ExtrudePanel.onChanged] - records the latest values immediately (so
  /// [_confirmExtrude] always has them, even mid-debounce) and (re)starts
  /// the 500ms debounce before actually hitting the backend.
  void _onExtrudeValuesChanged(ExtrudeType type, double start, double end) {
    _extrudeType = type;
    _extrudeStartDistance = start;
    _extrudeEndDistance = end;
    _scheduleExtrudePreview();
  }

  /// Prompt A4: shared by [_onExtrudeValuesChanged] (a distance/type field
  /// changed) and [_toggleSelectedEntity]/[_clearSelectedEntities] (a
  /// target-body pick changed) - either kind of change should debounce the
  /// same live-preview re-solve, using whatever the *other* kind's latest
  /// value currently is (e.g. picking a body re-solves with the panel's
  /// current distances, and vice versa).
  void _scheduleExtrudePreview() {
    _extrudeDebounce?.cancel();
    _extrudeDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(() => _ensureExtrudeFeatureExists(
            _extrudeType,
            _extrudeStartDistance,
            _extrudeEndDistance,
            _currentTargetBodyIds(),
          ));
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
  ///
  /// Prompt A4: also exits target-body picking mode - restores
  /// [_selectedEntities] to whatever it held before the panel opened (see
  /// [_openExtrudePanel]) and pops the bodies-only filter override, both
  /// unconditionally (not gated on whether any bodies were actually picked),
  /// so this can never leave stale picker state behind for the *next*
  /// Extrude - the same class of bug the Prompt D follow-up above guards
  /// against for [_selectedFeatureId].
  ///
  /// B4: when [_editingExtrudeFeatureId] is set (editing an already-existing
  /// Feature rather than creating one), the auto-hide-the-Sketch behaviour
  /// above is skipped - that only makes sense the *first* time a Sketch is
  /// consumed by a brand-new Extrude, not every time an already-consumed one
  /// is re-edited - and true rollback is rolled forward ([_endRollback])
  /// once the panel's own state has been torn down, so the now-current
  /// downstream Features are visible again with this edit's changes
  /// actually reflected in them.
  Future<void> _confirmExtrude() async {
    _extrudeDebounce?.cancel();
    final sketchFeature = _extrudeSketchFeature;
    final wasEditing = _editingExtrudeFeatureId != null;
    final targetBodyIds = _currentTargetBodyIds();
    await _runGuarded(() async {
      await _ensureExtrudeFeatureExists(
        _extrudeType,
        _extrudeStartDistance,
        _extrudeEndDistance,
        targetBodyIds,
      );
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });
    if (!mounted) return;
    setState(() {
      if (sketchFeature != null && !wasEditing) {
        _hiddenFeatureIds.add(sketchFeature.id);
        // Prompt C1: this is *the* auto-hide-on-consume case
        // [_autoHiddenSketchFeatureIds] exists for - mark it so its Sketch
        // geometry stays visible/pickable (dimmed) in the 3D viewport.
        _autoHiddenSketchFeatureIds.add(sketchFeature.id);
      }
      _recomputeVisibleSketchGeometries();
      _extrudeSketchFeature = null;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = null;
      _editingExtrudeFeatureId = null;
      _extrudeEditSnapshot = null;
      _selectedEntities = _entitiesBeforeExtrude ?? {};
      _entitiesBeforeExtrude = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    await _endRollback();
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
  ///
  /// Prompt A4: also unconditionally restores [_selectedEntities]/pops the
  /// filter override, same as [_confirmExtrude] - see that method's doc
  /// comment for why this must happen regardless of whether anything was
  /// actually picked.
  ///
  /// B4: when [_editingExtrudeFeatureId] is set, [previewId] refers to a
  /// Feature that already existed *before* this edit session - deleting it
  /// (the "create new" flow's undo) would destroy real, pre-existing work
  /// just because an edit was cancelled. Instead this PATCHes
  /// [_extrudeEditSnapshot]'s stashed original values back, undoing
  /// whatever the live-preview debounce may have already written, then
  /// rolls true rollback forward ([_endRollback]) - "no changes" (per this
  /// prompt's own Confirm/Cancel requirement) for an edit session means the
  /// Feature ends up exactly as it was, not merely "not deleted".
  Future<void> _cancelExtrude() async {
    _extrudeDebounce?.cancel();
    final part = _part;
    final sketchFeature = _extrudeSketchFeature;
    final previewId = _previewExtrudeFeatureId;
    final meshBefore = _meshBeforeExtrude;
    final wasEditing = _editingExtrudeFeatureId != null;
    final editSnapshot = _extrudeEditSnapshot;
    setState(() {
      _extrudeSketchFeature = null;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = null;
      _editingExtrudeFeatureId = null;
      _extrudeEditSnapshot = null;
      _selectedEntities = _entitiesBeforeExtrude ?? {};
      _entitiesBeforeExtrude = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateExtrudeFeature(
            part.id,
            previewId,
            extrudeType: editSnapshot.type.apiValue,
            startDistance: editSnapshot.start,
            endDistance: editSnapshot.end,
            targetBodyIds: editSnapshot.targetBodyIds,
          );
          await _refreshFeatures();
        });
      } else {
        await _runGuarded(() async {
          await _api.deleteFeature(part.id, previewId);
          if (meshBefore != null) {
            _bodies = meshBefore;
          } else {
            await _refreshMesh();
          }
          await _refreshFeatures();
        });
      }
    }
    await _endRollback();
  }

  // --- C2: Create Plane -----------------------------------------------------

  /// [SelectionContextPanel.onCreatePlane]'s callback - re-derives which of
  /// the three flows applies from [_selectedEntities]' current shape, the
  /// same check `selection_actions.dart`'s `contextActionsFor` already used
  /// to decide the button should be enabled in the first place (so this is
  /// never reached for any other selection shape).
  void _onCreatePlaneTapped() {
    final faces = _selectedEntities.where((e) => e.kind == SelectionEntityKind.face).toList();
    if (faces.length == 1 && _selectedEntities.length == 1) {
      _openCreatePlanePanel(mode: CreatePlaneMode.offsetFace, faceEntities: faces);
      return;
    }
    if (faces.length == 2 && _selectedEntities.length == 2) {
      _openCreatePlanePanel(mode: CreatePlaneMode.midplane, faceEntities: faces);
      return;
    }
    final points = _selectedEntities.where((e) => e.kind == SelectionEntityKind.sketchPoint).toList();
    final lines = _selectedEntities.where((e) => e.kind == SelectionEntityKind.sketchLine).toList();
    if (points.length == 1 && lines.length == 1) {
      _openCreatePlanePanel(
        mode: CreatePlaneMode.normalToLineAtPoint,
        lineEntity: lines.single,
        pointEntity: points.single,
      );
    }
  }

  /// Creates the CreatePlaneFeature eagerly (mirrors [_ensureExtrudeFeatureExists]'s
  /// "create on open" pattern) from whichever refs [_onCreatePlaneTapped]
  /// resolved. Stashes/clears [_selectedEntities] the same way
  /// [_openExtrudePanel] does for target-body picking, since the
  /// face(s)/line/point that triggered this is baked into the created
  /// Feature, not something the user keeps adjusting in the viewport
  /// afterward. [faceEntities] has exactly one entry for [CreatePlaneMode.
  /// offsetFace] or exactly two for [CreatePlaneMode.midplane] (C3).
  Future<void> _openCreatePlanePanel({
    required CreatePlaneMode mode,
    List<SelectionEntityRef> faceEntities = const [],
    SelectionEntityRef? lineEntity,
    SelectionEntityRef? pointEntity,
  }) async {
    final part = _part;
    if (part == null) return;
    setState(() {
      _createPlaneMode = mode;
      _entitiesBeforeCreatePlane = _selectedEntities;
      _selectedEntities = {};
      if (mode == CreatePlaneMode.offsetFace) _createPlaneOffset = 0.0;
    });
    await _runGuarded(() async {
      final FeatureDto feature;
      if (mode == CreatePlaneMode.offsetFace || mode == CreatePlaneMode.midplane) {
        final faceRefs = [
          for (final faceEntity in faceEntities)
            SubShapeRefDto(bodyId: faceEntity.bodyId, shapeType: 'face', index: faceEntity.id),
        ];
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: mode == CreatePlaneMode.offsetFace ? 'offset_face' : 'midplane',
          faceRefs: faceRefs,
          offset: mode == CreatePlaneMode.offsetFace ? _createPlaneOffset : null,
        );
      } else {
        final sketchId = _sketchIdForFeatureId(lineEntity!.sketchFeatureId);
        if (sketchId == null) return; // Defensive - see _sketchIdForFeatureId's own doc comment.
        final lineRef = SketchEntityRefDto(
          sketchId: sketchId,
          entityType: 'line',
          entityId: lineEntity.sketchEntityId,
        );
        final pointRef = SketchEntityRefDto(
          sketchId: sketchId,
          entityType: 'point',
          entityId: pointEntity!.sketchEntityId,
        );
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: 'normal_to_line_at_point',
          lineRef: lineRef,
          pointRef: pointRef,
        );
      }
      _previewCreatePlaneFeatureId = feature.id;
      await _refreshFeatures();
    });
    if (_previewCreatePlaneFeatureId == null && mounted) {
      // Creation failed (e.g. non_planar_reference/point_not_on_line/
      // faces_not_parallel - _errorMessage is already set by _runGuarded) -
      // nothing to edit, so close the panel back out rather than leaving it
      // stuck open with no real Feature behind it.
      setState(() {
        _createPlaneMode = null;
        _selectedEntities = _entitiesBeforeCreatePlane ?? {};
        _entitiesBeforeCreatePlane = null;
      });
    }
  }

  /// B4: opens [CreatePlanePanel] to edit an *already-existing*
  /// CreatePlaneFeature - mirrors [_openExtrudePanelForEdit] exactly,
  /// including the "no zero-argument reconstruction" snapshot stash for
  /// [_cancelCreatePlane] to PATCH back verbatim.
  void _openCreatePlanePanelForEdit(FeatureDto feature) {
    final mode = switch (feature.planeType) {
      'offset_face' => CreatePlaneMode.offsetFace,
      'midplane' => CreatePlaneMode.midplane,
      _ => CreatePlaneMode.normalToLineAtPoint,
    };
    setState(() {
      _createPlaneMode = mode;
      _editingCreatePlaneFeatureId = feature.id;
      _previewCreatePlaneFeatureId = feature.id;
      _createPlaneOffset = feature.offset ?? 0.0;
      _createPlaneEditSnapshot = (
        faceRefs: feature.faceRefs,
        offset: feature.offset,
        lineRef: feature.lineRef,
        pointRef: feature.pointRef,
      );
      _entitiesBeforeCreatePlane = _selectedEntities;
      _selectedEntities = {};
    });
  }

  /// Debounces the panel's offset-field edits into a PATCH + Feature refresh,
  /// same 500ms-after-last-change pattern [_scheduleExtrudePreview] uses.
  /// Only ever called while [_createPlaneMode] is [CreatePlaneMode.offsetFace] -
  /// [CreatePlaneMode.normalToLineAtPoint] has no field to debounce.
  void _onCreatePlaneOffsetChanged(double offset) {
    _createPlaneOffset = offset;
    _createPlaneDebounce?.cancel();
    _createPlaneDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(_ensureCreatePlaneOffsetUpdated);
    });
  }

  Future<void> _ensureCreatePlaneOffsetUpdated() async {
    final part = _part;
    final featureId = _previewCreatePlaneFeatureId;
    if (part == null || featureId == null) return;
    await _api.updateCreatePlaneFeature(part.id, featureId, offset: _createPlaneOffset);
    await _refreshFeatures();
  }

  /// Keeps the just-created/edited Feature (it's already fully persisted -
  /// unlike Extrude, there's no separate "not yet real" preview state to
  /// promote), restores whatever was selected before the panel opened, and
  /// rolls B4 rollback forward.
  Future<void> _confirmCreatePlane() async {
    _createPlaneDebounce?.cancel();
    setState(() {
      _createPlaneMode = null;
      _selectedEntities = _entitiesBeforeCreatePlane ?? {};
      _entitiesBeforeCreatePlane = null;
      _previewCreatePlaneFeatureId = null;
      _editingCreatePlaneFeatureId = null;
      _createPlaneEditSnapshot = null;
    });
    await _endRollback();
  }

  /// Deletes the just-created preview Feature (new-Plane flow) or PATCHes
  /// [_createPlaneEditSnapshot]'s stashed original values back (edit flow) -
  /// mirrors [_cancelExtrude]'s structure exactly.
  Future<void> _cancelCreatePlane() async {
    _createPlaneDebounce?.cancel();
    final part = _part;
    final previewId = _previewCreatePlaneFeatureId;
    final wasEditing = _editingCreatePlaneFeatureId != null;
    final editSnapshot = _createPlaneEditSnapshot;
    setState(() {
      _createPlaneMode = null;
      _selectedEntities = _entitiesBeforeCreatePlane ?? {};
      _entitiesBeforeCreatePlane = null;
      _previewCreatePlaneFeatureId = null;
      _editingCreatePlaneFeatureId = null;
      _createPlaneEditSnapshot = null;
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateCreatePlaneFeature(
            part.id,
            previewId,
            faceRefs: editSnapshot.faceRefs,
            offset: editSnapshot.offset,
            lineRef: editSnapshot.lineRef,
            pointRef: editSnapshot.pointRef,
          );
          await _refreshFeatures();
        });
      } else {
        await _runGuarded(() async {
          await _api.deleteFeature(part.id, previewId);
          await _refreshFeatures();
        });
      }
    }
    await _endRollback();
  }

  /// Prompt A4: the top banner's text while [_extrudeActive] - Cut's wording
  /// differs from Boss's since Cut requires 1+ picks (mirrors
  /// [ExtrudePanel]'s own Confirm-disable rule, `_canConfirm`) while Boss
  /// explicitly allows confirming with nothing picked to start a new Body.
  String _targetBodyPickerBannerText() {
    final count = _selectedEntities.length;
    if (_extrudeType == ExtrudeType.cut) {
      return count == 0
          ? 'Select at least one body to cut'
          : 'Select bodies to cut ($count selected)';
    }
    return count == 0
        ? 'Select bodies to merge into (optional)'
        : 'Select bodies to merge into ($count selected)';
  }

  /// Client-side-only Hide/Show for a Feature - [_hiddenFeatureIds] itself
  /// is never sent to the backend, but it *is* re-sent as the mesh
  /// endpoint's `hidden_feature_ids` query param (see [_refreshMesh]), so
  /// hiding an ExtrudeFeature also drops its volume from the displayed
  /// solid, not just its own Sketch geometry from [_visibleSketchGeometries]
  /// (a SketchFeature has no solid of its own to drop).
  ///
  /// Prompt C1: an explicit Hide here always removes [feature.id] from
  /// [_autoHiddenSketchFeatureIds] too (a no-op unless it was already
  /// auto-hidden) - once the user has explicitly acted on a Feature's
  /// visibility, its hidden state means what it says for every purpose,
  /// including 3D-viewport pickability, not just the auto-hide-on-consume
  /// exception.
  Future<void> _toggleFeatureVisibility(FeatureDto feature) async {
    setState(() {
      if (_hiddenFeatureIds.contains(feature.id)) {
        _hiddenFeatureIds.remove(feature.id);
      } else {
        _hiddenFeatureIds.add(feature.id);
      }
      _autoHiddenSketchFeatureIds.remove(feature.id);
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
      _autoHiddenSketchFeatureIds.removeWhere((id) => !_features.any((f) => f.id == id));
      // Bug-fix: deleting the ExtrudeFeature that consumed a Sketch (see
      // _confirmExtrude's auto-hide) used to leave that Sketch stuck in
      // _hiddenFeatureIds forever, since it never stopped existing - only
      // stopped being locked - so the tree kept showing it dimmed/hidden
      // even once it was editable again. The Sketch was only ever hidden
      // because something depended on it; once the new last Feature is
      // unlocked again, there's nothing left to make it redundant clutter.
      if (_features.isNotEmpty && !_features.last.locked) {
        _hiddenFeatureIds.remove(_features.last.id);
        _autoHiddenSketchFeatureIds.remove(_features.last.id);
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
  ///
  /// B4: also re-fetches the mesh - pre-B4, a Sketch could only ever be
  /// opened here while it was still the last Feature in its Part (nothing
  /// downstream yet to recompute), so this was never needed before.
  /// Editing an *earlier* Sketch with a downstream Extrude (B4's own new
  /// capability, reached via true rollback - see [_onFeatureTap]) makes
  /// this reachable for the first time: the Extrude that consumes this
  /// Sketch's profile needs to recompute against whatever changed, and
  /// still-hidden rollback siblings correctly stay excluded from this
  /// refresh regardless (the caller only calls [_endRollback], which
  /// refreshes again, once *this* method has already returned).
  Future<void> _openSketch(FeatureDto feature, {SketchPlaneBasis? basis}) async {
    // Prompt A3: merges every Body's edges into one flat list - the ghost
    // outline doesn't care which Body an edge came from, only where it
    // projects onto the new Sketch's plane.
    final allEdgeSegments = [for (final body in _bodies) ...edgeSegmentsFromMesh(body.mesh)];
    final ghostSegments = basis != null
        ? projectMeshEdgesOntoPlane(basis, allEdgeSegments)
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
      await _refreshMesh();
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
                  bodies: _bodies,
                  selectedPlane: _selectedPlane,
                  sketchGeometries: _visibleSketchGeometries,
                  dimmedSketchFeatureIds: _dimmedSketchFeatureIds,
                  createPlanes: _createPlaneGeometries,
                  onCreatePlaneTap: _onCreatePlaneFeatureTap,
                  selectedCreatePlaneFeatureId: _selectedCreatePlaneFeatureId,
                  onPlaneTap: _onPlaneTap,
                  onBackgroundTap: _onViewportBackgroundTap,
                  isPreviewMesh: _extrudeSketchFeature != null,
                  referencePlanesHidden: _referencePlanesHidden,
                  renderMode: _renderMode,
                  bgColourHex: _bgColourHex,
                  bodyColourHex: _bodyColourHex,
                  bodyOpacity: _bodyOpacity,
                  // Prompt A4: forced on for the duration of the Extrude
                  // panel regardless of the Stage 23 mode-toggle FAB's own
                  // state (hidden while the panel is open anyway - see
                  // floatingActionButton below) - target-body picking always
                  // needs live hit-testing/cursor, the same as the general
                  // Selection mode does.
                  selectionMode: _extrudeActive ? true : _selectionMode,
                  selectedEntities: _selectedEntities,
                  onSelectionToggle: _toggleSelectedEntity,
                  onClearSelection: _clearSelectedEntities,
                  selectionFilter: _selectionFilter,
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
                // Prompt A4: hidden while the Extrude panel is open -
                // [_selectedEntities] is the target-body picker's selection
                // then (see [_openExtrudePanel]), already surfaced by the
                // top banner's count and the viewport's own highlights, and
                // this drawer is bottom-docked (a DraggableScrollableSheet)
                // exactly where [ExtrudePanel]'s own Confirm/Cancel controls
                // live - showing both at once would visually collide.
                // C2: also hidden while CreatePlanePanel is open - same
                // bottom-docked-panel visual-collision reasoning as the
                // Extrude case above (in practice [_selectedEntities] is
                // already empty for the panel's whole session - see
                // [_openCreatePlanePanel] - so [SelectionListDrawer]'s own
                // empty-selection gate would already hide this too, but this
                // stays explicit rather than relying on that as an implicit
                // side effect).
                if (!_extrudeActive && !_createPlaneActive)
                  Positioned.fill(
                    child: SelectionListDrawer(
                      selectedEntities: _selectedEntities,
                      onRemove: _toggleSelectedEntity,
                      header: SelectionContextPanel(
                        selectedEntities: _selectedEntities,
                        isPointOnLine: _isPointOnLine,
                        onCreatePlane: _onCreatePlaneTapped,
                      ),
                      bodyNames: _bodyNames,
                    ),
                  ),
                Positioned.fill(
                  child: FeatureTreePanel(
                    visible: _featureTreeVisible && !_extrudeActive && !_createPlaneActive,
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
                    bodyIds: _computedBodyIds,
                    bodyNames: _bodyNames,
                    onBodyTap: _onBodyTap,
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
                    selectionFilter: _selectionFilter,
                    onVertexFilterChanged: _setVertexFilter,
                    onEdgeFilterChanged: _setEdgeFilter,
                    onFaceFilterChanged: _setFaceFilter,
                    onBodyFilterChanged: _setBodyFilter,
                    onSketchPointFilterChanged: _setSketchPointFilter,
                    onSketchLineFilterChanged: _setSketchLineFilter,
                  ),
                ),
                if (_extrudeSketchFeature != null)
                  Positioned.fill(
                    child: ExtrudePanel(
                      key: ValueKey(_editingExtrudeFeatureId ?? _extrudeSketchFeature!.id),
                      title: _editingExtrudeFeatureId != null ? 'Edit Extrude' : 'Extrude',
                      initialType: _extrudeType,
                      initialStartDistance: _extrudeStartDistance,
                      initialEndDistance: _extrudeEndDistance,
                      targetBodyCount: _selectedEntities.length,
                      onChanged: _onExtrudeValuesChanged,
                      onConfirm: _confirmExtrude,
                      onCancel: _cancelExtrude,
                    ),
                  ),
                if (_createPlaneMode != null)
                  Positioned.fill(
                    child: CreatePlanePanel(
                      key: ValueKey(_editingCreatePlaneFeatureId ?? _previewCreatePlaneFeatureId),
                      title: _editingCreatePlaneFeatureId != null ? 'Edit Plane' : 'Create Plane',
                      mode: _createPlaneMode!,
                      initialOffset: _createPlaneOffset,
                      onOffsetChanged: _onCreatePlaneOffsetChanged,
                      onConfirm: _confirmCreatePlane,
                      onCancel: _cancelCreatePlane,
                    ),
                  ),
                // Prompt A4: names the target-body picking mode live for the
                // whole time the Extrude panel is open - same top-center
                // pill convention as the plane-selection-mode banner below,
                // since both are "pick something in the viewport, Cancel to
                // back out" modes; unlike that one this doesn't need to
                // check `!_featureTreeVisible`, since the tree is already
                // forced hidden while the panel is open (see
                // `FeatureTreePanel.visible` above). Bug fix: the text is
                // long enough to overflow a plain unconstrained `Row` (the
                // plane-selection banner's short fixed string never hit
                // this) - `ConstrainedBox` caps the pill to the available
                // width and `Flexible` lets the text wrap onto a second
                // line instead of running off the right edge.
                if (_extrudeActive)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width - 32,
                          ),
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(24),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _targetBodyPickerBannerText(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _cancelExtrude,
                                    child: const Text('Cancel'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Always on top (last in the Stack) so it stays tappable
                // regardless of whether the toolbar underneath is open -
                // but hidden while the Feature tree is open since it sits
                // right on top of the tree's header text otherwise; the
                // tree's own X button is the way to dismiss it instead.
                // Also hidden during plane-selection mode (Stage 10b) and
                // Prompt A4's target-body picking, since each has its own
                // banner in the same top-left corner - without this, the
                // feature-tree FAB specifically (unlike the hamburger just
                // below, which already has its own extrude-aware check) sat
                // underneath/overlapping A4's banner.
                if (!_featureTreeVisible && !_planeSelectionMode && !_extrudeActive && !_createPlaneActive)
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
      floatingActionButton: (_extrudeSketchFeature != null || _createPlaneActive || _toolbarOpen)
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
