import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart'
    show ApiException, LineDto, ProfileDetectionDto, ProfileLoopDto, SketchApiClient;
import '../connection_screen.dart';
import '../didsa_logo_button.dart';
import '../sketch/sketch_controller.dart';
import '../sketch/sketch_screen.dart';
import 'add_button_menu.dart';
import 'body_naming.dart';
import 'cascade_delete_dialog.dart';
import 'chamfer_panel.dart';
import 'create_plane_context_sheet.dart';
import 'create_plane_geometry_3d.dart';
import 'create_plane_panel.dart';
import 'extrude_panel.dart';
import 'feature_context_menu.dart';
import 'feature_picker_sheet.dart';
import 'feature_tree_panel.dart';
import 'fillet_panel.dart';
import 'mesh_geometry.dart';
import 'override_stack.dart';
import 'part_toolbar.dart';
import 'part_viewport.dart';
import 'plane_context_sheet.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
import 'revolve_panel.dart';
import 'rollback.dart';
import 'selection_context_panel.dart';
import 'selection_filter.dart';
import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;
import 'selection_list_drawer.dart';
import 'sketch_geometry_3d.dart';
import 'sketch_orientation_indicator.dart';
import 'sweep_panel.dart';
import 'svg_icon.dart';
import 'scene_preferences.dart';
import 'view_preferences.dart';

/// Prompt G: which Feature type the profile picker (see [_PartScreenState]'s
/// own "Prompt G: profile picking" state section) is gathering picks for -
/// decides whether confirming opens [ExtrudePanel] or [RevolvePanel].
enum _ProfilePickerTarget { extrude, revolve, sweep }

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

  /// Native Load: when set, [_loadPart] opens this existing Part (via
  /// [DocumentApiClient.getPart]) instead of the default "always start
  /// fresh" `createPart` call - set by [_PartScreenState._openNativeFile]
  /// when it pushes a brand-new [PartScreen] onto whichever Part a native
  /// file import just replaced the backend's Document with. A fresh
  /// [PartScreen]/State pair (rather than mutating the current one in
  /// place) is deliberate: it's the simplest way to guarantee every one of
  /// this screen's many transient fields (selection, hidden/rollback sets,
  /// in-progress picker/panel state) starts clean against Feature/Body ids
  /// that belong to the newly-opened Part, not the one that was open a
  /// moment ago.
  final String? initialPartId;

  /// Native Load: the Hide/Show feature-id set a native file's own
  /// `hidden_feature_ids` entry carried (see [_PartScreenState._saveNativeFile]/
  /// [_PartScreenState._openNativeFile]) - restored into the fresh screen's
  /// [_PartScreenState._hiddenFeatureIds] at [_PartScreenState.initState],
  /// same reasoning as [initialPartId] for why this is a constructor param
  /// on a brand-new screen rather than mutated in place. Empty by default,
  /// matching a Part that opened with nothing hidden.
  final List<String> initialHiddenFeatureIds;

  /// Native Load/Save: the filename Open just read this Part from (see
  /// [_PartScreenState._openNativeFile]), or null for a brand-new (never
  /// Opened) Part - remembered as [_PartScreenState._lastSavedFileName]'s
  /// own starting point, so a subsequent plain Save on the fresh screen
  /// re-suggests the same file instead of falling back to a generic
  /// "&lt;Part name&gt;.DIDSAprt" default.
  final String? initialFileName;

  const PartScreen({
    super.key,
    this.documentApi,
    this.sketchApiFactory,
    this.initialPartId,
    this.initialHiddenFeatureIds = const [],
    this.initialFileName,
  });

  @override
  State<PartScreen> createState() => _PartScreenState();
}

/// A Sketch's plane plus its own stored orientation (flip/rotation) - bundled
/// together so callers that resolve a Feature's Sketch can't accidentally
/// drop the orientation and fall back to the raw, unoriented plane basis.
class _SketchOrientation {
  const _SketchOrientation({required this.plane, required this.flip, required this.rotationQuarterTurns});

  final ReferencePlaneKind plane;
  final bool flip;
  final int rotationQuarterTurns;
}

/// Which flow the orientation confirm step's shared UI (see
/// `_confirmingSketchOrientation` and friends) is currently running:
/// [newSketch] (via [_PartScreenState._addSketchFeature] - Cancel discards
/// the still-empty Feature) or [redefine] (via [_PartScreenState.
/// _redefineSketchOrientation], reached from a Sketch's long-press context
/// menu - Cancel reverts the already-live-PATCHed orientation instead,
/// since the Feature has real content).
enum _PendingOrientationMode { newSketch, redefine }

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
  /// (not the placeholder box) whenever the Part has no ExtrudeFeature yet -
  /// see [_refreshMesh]. On-device follow-up: unlike its original A3 shape,
  /// this now includes hidden Bodies too (`BodyMeshDto.hidden`, echoing
  /// `hidden_feature_ids` back rather than dropping the entry - see
  /// `app.document.router.get_part_mesh`'s own docstring) so the Build
  /// Tree's Bodies section can keep listing one; use [_visibleBodies], not
  /// this directly, for anything that actually renders/hit-tests geometry.
  List<BodyMeshDto> _bodies = [];
  String? _selectedFeatureId;

  /// B3 revision: the Part's real, currently-computed Body ids, hidden or
  /// not - excludes only the dev-time placeholder box (`source:
  /// "placeholder"`), which is never a real Body and shouldn't appear in
  /// the Build Tree's Bodies section or [SelectionListDrawer]'s naming. Not
  /// filtered by [BodyMeshDto.hidden] - the Build Tree needs to keep
  /// listing a hidden Body so Show can be reached again from its own row.
  List<String> get _computedBodyIds =>
      _bodies.where((b) => b.source == 'computed').map((b) => b.bodyId).toList();

  /// Memoization for [_visibleBodies] - `identical(_visibleBodiesCacheSource,
  /// _bodies)` tells us the last computed [_visibleBodiesCache] is still
  /// valid, so unrelated rebuilds (toggling selection mode, picking an
  /// entity, anything that calls `setState` without touching [_bodies]
  /// itself) don't hand `PartViewport` a freshly-allocated `List` each time.
  List<BodyMeshDto>? _visibleBodiesCache;
  List<BodyMeshDto>? _visibleBodiesCacheSource;

  /// [_bodies] filtered down to what should actually render/hit-test in the
  /// 3D viewport - everything that isn't [BodyMeshDto.hidden]. Use this
  /// (never [_bodies] directly) for [PartViewport.bodies] and anything else
  /// that projects/derives from real Body geometry (e.g. the ghost-edge
  /// reference in [_openSketch]) - [_computedBodyIds]/[_bodyNames] are the
  /// deliberate exception, since the Build Tree wants the unfiltered list.
  ///
  /// On-device feedback: this used to be a plain `.where(...).toList()`
  /// getter, building a brand-new `List` instance on *every* access - since
  /// [PartViewport.bodies]'s own doc comment requires a new instance only
  /// when the content actually changes (so [PartViewport.didUpdateWidget]
  /// can tell "unrelated rebuild" from "the mesh changed"), that meant every
  /// unrelated `setState` in this widget (selection-mode toggle, picking an
  /// entity, etc.) looked like a body change to `PartViewport`, which
  /// re-ran `_syncMeshNode` and snapped the camera's target back to the
  /// mesh bounds' centre - discarding any pan the user had done. Caching
  /// against [_bodies]' own identity (only reassigned where [_bodies] itself
  /// is, i.e. on a genuine mesh refetch) restores the contract.
  List<BodyMeshDto> get _visibleBodies {
    if (!identical(_visibleBodiesCacheSource, _bodies)) {
      _visibleBodiesCacheSource = _bodies;
      _visibleBodiesCache = _bodies.where((b) => !b.hidden).toList();
    }
    return _visibleBodiesCache!;
  }

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

  /// On-device feedback: the reference planes are a placement aid for an
  /// empty Part - once the first real Body exists, they're clutter, so
  /// [_refreshMesh] auto-hides them the first time [_bodies] goes from
  /// empty to non-empty. Guards against firing more than once per screen
  /// lifetime (mirrors [PartViewportState._hasFramedCamera]'s own "one-time
  /// auto-behaviour" pattern) - deleting every Body later and creating a new
  /// one shouldn't fight a user who explicitly re-showed the planes in the
  /// meantime.
  bool _hasAutoHiddenReferencePlanes = false;

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

  /// The `PhysicallyBasedMaterial`/lighting upgrade's own controls - see
  /// [ScenePreferences], loaded/persisted the same way as the block above.
  double _sceneRoughness = ScenePreferences.defaultRoughness;
  double _sceneLightIntensity = ScenePreferences.defaultLightIntensity;
  double _sceneEmissiveIntensity = ScenePreferences.defaultEmissiveIntensity;

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
              sketchCircle: false,
            )
          : _selectionFilterBase.copyWith(
              vertex: true,
              edge: true,
              face: true,
              body: false,
              sketchPoint: true,
              sketchLine: true,
              sketchCircle: true,
            );
    });
  }

  /// Feature ids hidden from the 3D viewport via the long-press Hide/Show
  /// action (plus [_confirmExtrude]'s auto-hide-the-consumed-Sketch
  /// bookkeeping, see [_autoHiddenSketchFeatureIds] below) - client-side
  /// only, and (bug fix, post-C4) now purely cosmetic server-side too, sent
  /// as `hidden_feature_ids`: every Body is still fully computed against
  /// the Part's real, unmodified history, so a Plane anchored to a hidden
  /// Body's face (and anything built on that Plane) keeps resolving
  /// normally - a hidden Body is only dropped from the mesh response
  /// afterward. See `app.document.router.get_part_mesh`'s own docstring for
  /// the full incident writeup of why this and [_rollbackExcludedFeatureIds]
  /// used to be the same set, and why that broke Create Plane.
  ///
  /// On-device feedback: purely client-side state means a native Save/Load
  /// round-trip lost it entirely (the backend never sees it outside a
  /// single `/mesh` request's query param) - [_saveNativeFile]/
  /// [_openNativeFile] now carry it through the file's own JSON as a
  /// `hidden_feature_ids` array the backend's own `export_native`/
  /// `import_native` know nothing about and simply pass through unexamined.
  final Set<String> _hiddenFeatureIds = {};

  /// Native Save/Load: the filename most recently Opened-from or Saved-to
  /// this session (see [PartScreen.initialFileName]'s own doc comment for
  /// why a fresh Open-triggered screen starts with one already) - the
  /// default [_saveNativeFile] suggests, so a quick re-save doesn't fall
  /// back to a generic "&lt;Part name&gt;.DIDSAprt" name every time.
  /// [_saveAsNativeFile] always ignores this for its own initial suggestion
  /// (a deliberate fresh prompt), but still updates it from whatever the
  /// user actually saves to, same as a plain Save does.
  String? _lastSavedFileName;

  /// B4 true-rollback's own "pretend these Features (and hence everything
  /// depending on them) don't exist yet" state (see [_beginRollback]/
  /// [_endRollback]) - sent to the backend as `rollback_excluded_feature_ids`,
  /// genuinely excluded from recompute there (unlike [_hiddenFeatureIds]
  /// above). Kept as a wholly separate set/query-param rather than merged
  /// into [_hiddenFeatureIds] the way it was before this bug fix - see
  /// [_hiddenFeatureIds]'s own doc comment for why that broke Create Plane.
  /// Always empty outside an active rollback edit.
  final Set<String> _rollbackExcludedFeatureIds = {};

  /// Every Feature id that should be invisible/unpickable in the 3D
  /// viewport right now, for either reason - [_hiddenFeatureIds] (Hide/Show,
  /// cosmetic) or [_rollbackExcludedFeatureIds] (true-rollback, the
  /// Feature genuinely isn't part of the model being previewed). The
  /// viewport itself (unlike the backend's `/mesh` computation) has no
  /// reason to tell the two apart - either way, nothing of that Feature's
  /// should render or be tappable right now.
  Set<String> get _viewportHiddenFeatureIds => {..._hiddenFeatureIds, ..._rollbackExcludedFeatureIds};

  /// The subset of [_hiddenFeatureIds] hidden purely because
  /// [_confirmExtrude]'s auto-hide-the-consumed-Sketch bookkeeping put them
  /// there - never because the user explicitly hid them, and never one of
  /// B4's rollback-suppressed later Features (those live in
  /// [_rollbackExcludedFeatureIds] instead, never here). A consumed Sketch is
  /// fully excluded from the 3D viewport (rendering and pickability alike)
  /// exactly like a manually-hidden Feature - this set exists purely so a
  /// later event that makes the Sketch stop being consumed (deleting its
  /// ExtrudeFeature - see the cascade-delete cleanup in
  /// [_cascadeDeleteFeature] - or explicitly toggling visibility, see
  /// [_toggleFeatureVisibility]) can tell "hidden because auto-consumed,
  /// safe to auto-restore" apart from "hidden because the user explicitly
  /// hid it, leave it alone".
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
  ///
  /// On-device feedback: while [_filletActive] (the panel now opens
  /// immediately, whether from the "Add" FAB with zero edges yet or from an
  /// existing edge selection - see [_openFilletPanel]), a Face tap is
  /// special-cased to [_toggleFilletFaceEdges] instead of toggling the face
  /// itself - the filter allows Faces through purely as a "select this
  /// face's whole edge loop" convenience (see [_filletSelectionFilter]'s
  /// own doc comment), never as a real Fillet reference. Also reschedules
  /// the debounced live-preview re-solve while [_filletActive], same
  /// reasoning as the [_extrudeActive] case just above.
  void _toggleSelectedEntity(SelectionEntityRef entity) {
    if (_filletActive && entity.kind == SelectionEntityKind.face) {
      _toggleFilletFaceEdges(entity);
      return;
    }
    if (_chamferActive && entity.kind == SelectionEntityKind.face) {
      _toggleChamferFaceEdges(entity);
      return;
    }
    // Prompt G: a sketchLine/sketchCircle tap while the profile picker is
    // open toggles its whole containing loop, not just the one tapped
    // entity - see [_toggleProfileLoop]. Checked before the Revolve axis
    // special-case below since the two modes are never active at the same
    // time, but this ordering costs nothing either way.
    if (_profilePickerActive &&
        (entity.kind == SelectionEntityKind.sketchLine ||
            entity.kind == SelectionEntityKind.sketchCircle)) {
      _toggleProfileLoop(entity);
      return;
    }
    // A sketchLine tap while the path picker is open extends/undoes the
    // Sweep path being built - see [_togglePathPick]. Checked before the
    // Revolve axis special-case below for the same reason the profile-picker
    // check above is - the two modes are never active at the same time.
    if (_pathPickerActive && entity.kind == SelectionEntityKind.sketchLine) {
      _togglePathPick(entity);
      return;
    }
    // Prompt F: a sketchLine tap while the Revolve panel is open sets (or
    // clears, if it's the already-picked one) the axis - a single reference,
    // replaced rather than accumulated the way target-body picks are - see
    // [_setRevolveAxis]. A body tap falls through to the ordinary toggle
    // below, same as Extrude's own target-body picking.
    if (_revolveActive && entity.kind == SelectionEntityKind.sketchLine) {
      _setRevolveAxis(entity);
      return;
    }
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (!next.remove(entity)) next.add(entity);
      _selectedEntities = next;
    });
    if (_extrudeActive) _scheduleExtrudePreview();
    if (_filletActive) _scheduleFilletPreview();
    if (_chamferActive) _scheduleChamferPreview();
    if (_revolveActive) _scheduleRevolvePreview();
    if (_sweepActive) _scheduleSweepPreview();
  }

  /// Prompt F: [_toggleSelectedEntity]'s sketchLine special-case for the
  /// Revolve flow - replaces whatever `sketchLine` entity (if any) is
  /// currently in [_selectedEntities] with [axisEntity], unless [axisEntity]
  /// was already the one picked, in which case it's cleared instead (tap the
  /// current axis again to deselect it). Never touches any `body` entities
  /// already in the set - those are a completely independent pick (see
  /// [_revolveSelectionFilter]'s own doc comment).
  void _setRevolveAxis(SelectionEntityRef axisEntity) {
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      final alreadyPicked = next.contains(axisEntity);
      next.removeWhere((e) => e.kind == SelectionEntityKind.sketchLine);
      if (!alreadyPicked) next.add(axisEntity);
      _selectedEntities = next;
    });
    _scheduleRevolvePreview();
  }

  /// Item 4: "Empty space tap -> clears entire selection set" - passed to
  /// [PartViewport.onClearSelection], fired by a tap (Fix 4) when the
  /// cursor's hover hit is null. See [_toggleSelectedEntity]'s doc comment
  /// for why this also reschedules the preview during [_extrudeActive]/
  /// [_filletActive]/[_chamferActive].
  void _clearSelectedEntities() {
    setState(() => _selectedEntities = {});
    if (_extrudeActive) _scheduleExtrudePreview();
    if (_filletActive) _scheduleFilletPreview();
    if (_chamferActive) _scheduleChamferPreview();
    if (_revolveActive) _scheduleRevolvePreview();
    if (_sweepActive) _scheduleSweepPreview();
  }

  /// On-device feedback: [_toggleSelectedEntity]'s Face special-case for the
  /// Fillet flow - resolves [faceEntity]'s Body/face id to that face's whole
  /// boundary loop (`BodyMeshDto.mesh.faceEdgeIds`, backend
  /// `app.document.mesh._extract_face_edge_ids`) and toggles the *whole
  /// loop* as one unit: if every edge in it is already selected, all are
  /// removed; otherwise every edge not yet selected is added (a partial
  /// loop is grown to complete, never left half-toggled). A no-op if the
  /// face's body/index can't be resolved (stale hit against mesh data
  /// that's since changed) or the face borders no edges at all (never
  /// happens for a real solid, but there's nothing to toggle either way).
  void _toggleFilletFaceEdges(SelectionEntityRef faceEntity) {
    BodyMeshDto? body;
    for (final candidate in _bodies) {
      if (candidate.bodyId == faceEntity.bodyId) {
        body = candidate;
        break;
      }
    }
    final faceEdgeIds = body?.mesh.faceEdgeIds;
    if (faceEdgeIds == null || faceEntity.id < 0 || faceEntity.id >= faceEdgeIds.length) return;
    final loopEdgeIds = faceEdgeIds[faceEntity.id];
    if (loopEdgeIds.isEmpty) return;

    final loopEntities = [
      for (final edgeId in loopEdgeIds)
        SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: faceEntity.bodyId, id: edgeId),
    ];
    final allSelected = loopEntities.every(_selectedEntities.contains);
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (allSelected) {
        next.removeAll(loopEntities);
      } else {
        next.addAll(loopEntities);
      }
      _selectedEntities = next;
    });
    if (_filletActive) _scheduleFilletPreview();
  }

  /// Mirrors [_toggleFilletFaceEdges] exactly for the Chamfer flow - see
  /// that method's own doc comment for the full reasoning.
  void _toggleChamferFaceEdges(SelectionEntityRef faceEntity) {
    BodyMeshDto? body;
    for (final candidate in _bodies) {
      if (candidate.bodyId == faceEntity.bodyId) {
        body = candidate;
        break;
      }
    }
    final faceEdgeIds = body?.mesh.faceEdgeIds;
    if (faceEdgeIds == null || faceEntity.id < 0 || faceEntity.id >= faceEdgeIds.length) return;
    final loopEdgeIds = faceEdgeIds[faceEntity.id];
    if (loopEdgeIds.isEmpty) return;

    final loopEntities = [
      for (final edgeId in loopEdgeIds)
        SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: faceEntity.bodyId, id: edgeId),
    ];
    final allSelected = loopEntities.every(_selectedEntities.contains);
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (allSelected) {
        next.removeAll(loopEntities);
      } else {
        next.addAll(loopEntities);
      }
      _selectedEntities = next;
    });
    if (_chamferActive) _scheduleChamferPreview();
  }

  /// Every Feature's 3D Sketch geometry, keyed by Feature id, regardless of
  /// [_viewportHiddenFeatureIds] - [_visibleSketchGeometries] is the
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
  ({
    ExtrudeType type,
    double start,
    double end,
    List<String> targetBodyIds,
    List<SketchEntityRefDto> profileRefs,
  })? _extrudeEditSnapshot;

  /// Prompt G: which outer profile(s) of [_extrudeSketchFeature] to use -
  /// set once, either to `[]` (no profile picker shown - a single-loop
  /// Sketch) or to whatever [_confirmProfilePicker] resolved, and never
  /// changed again for the rest of this create/edit session (create-time-
  /// only picking - see `_ProfilePickerTarget`'s own doc comment for why
  /// re-picking mid-edit is out of scope for this pass). Threaded into
  /// every [_ensureExtrudeFeatureExists] call the same way
  /// [_extrudeStartDistance] etc. are, so a live-preview re-solve never
  /// silently reverts it to "every profile".
  List<SketchEntityRefDto> _extrudeProfileRefs = [];

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
  ({
    List<PlaneRefDto> faceRefs,
    double? offset,
    SketchEntityRefDto? lineRef,
    SketchEntityRefDto? pointRef,
    SubShapeRefDto? edgeRef,
    SubShapeRefDto? vertexRef,
    List<PointRefDto> pointRefs,
  })? _createPlaneEditSnapshot;

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

  /// Prompt D: true while [FilletPanel] is open - unlike [_createPlaneMode]
  /// (one of six construction methods), Fillet has only the one flow, so
  /// there's no mode enum to be non-null instead; this is the direct
  /// equivalent, set synchronously by [_openFilletPanel]/[_openFilletPanelForEdit]
  /// so the panel shows immediately, even during the brief async gap before
  /// [_previewFilletFeatureId] itself is set (mirrors [_createPlaneMode]'s
  /// own reason for being a separate flag from [_previewCreatePlaneFeatureId]).
  bool _filletActive = false;

  /// The FilletFeature created (or, in edit mode, already existing) for the
  /// panel session - mirrors [_previewCreatePlaneFeatureId]'s "create
  /// eagerly on open, PATCH on every field edit, Confirm just closes,
  /// Cancel deletes-or-reverts" pattern.
  String? _previewFilletFeatureId;

  /// B4: non-null while [FilletPanel] is editing an *existing* FilletFeature
  /// (as opposed to [_onFilletTapped]'s "create a brand-new one from the
  /// current selection" flow) - same purpose as [_editingCreatePlaneFeatureId].
  String? _editingFilletFeatureId;

  /// B4: the edited Feature's own stored values from just before editing
  /// started - [_cancelFillet] PATCHes these back verbatim when
  /// [_editingFilletFeatureId] is set, same reason [_createPlaneEditSnapshot]
  /// exists.
  ({List<SubShapeRefDto> edgeRefs, double radius})? _filletEditSnapshot;

  /// [_selectedEntities]' value from just before the panel opened - restored
  /// by both [_confirmFillet] and [_cancelFillet], same purpose
  /// [_entitiesBeforeCreatePlane] serves.
  Set<SelectionEntityRef>? _entitiesBeforeFillet;

  /// The panel's live radius field value, debounced into a PATCH the same
  /// way [_createPlaneOffset] is.
  double _filletRadius = 1.0;

  Timer? _filletDebounce;

  /// On-device feedback: the Body id the live rounded-corner visual preview
  /// targets (see [_refreshFilletPreviewMesh]) - null whenever there's no
  /// Fillet Feature yet or no edge is currently selected to derive it from.
  /// Passed straight through to [PartViewport.previewOverlayBodyId].
  String? _filletPreviewBodyId;

  /// On-device feedback: the *actual current effect* of the in-progress
  /// Fillet (radius/edges as last successfully PATCHed), fetched
  /// separately from [_bodies] (which must stay the stable, pre-Fillet
  /// mesh for the whole live-edit session - see [_ensureFilletFeatureExists]'s
  /// own doc comment on why) purely so there's something to actually *see*
  /// while adjusting the radius/edge selection. Passed straight through to
  /// [PartViewport.previewOverlayMesh], which renders it (translucent-
  /// tinted, same as an Extrude preview) in place of the stable mesh for
  /// just the one Body [_filletPreviewBodyId] names - [_bodies] itself,
  /// and therefore hit-testing/edge-picking, is completely unaffected.
  /// Prompt E's own Chamfer flow mirrors this exact mechanism with its own
  /// separate fields ([_chamferPreviewBodyId]/[_chamferPreviewMesh]) - the
  /// "stable body for picking, separate overlay for the visual" split
  /// applies identically to both operations, but each keeps its own state
  /// rather than sharing (see the Chamfer state section's own header
  /// comment for why).
  MeshDto? _filletPreviewMesh;

  /// On-device feedback: locks [_selectionFilterOverrides] to edges/faces
  /// only for the *whole* Fillet flow (from the moment [_openFilletPanel]/
  /// [_openFilletPanelForEdit] opens the panel, whether or not any edges
  /// are picked yet) - so a stray vertex/Body tap can never end up in
  /// [_selectedEntities] mid-flow. `face: true` is not "faces are
  /// themselves fillet-able" (only edges ever go into `edge_refs`) - it's
  /// so [_toggleSelectedEntity]'s face branch (see [_toggleFilletFaceEdges])
  /// can offer "tap a face to select its whole boundary loop" as a
  /// convenience for reliably building a vertex-complete edge selection.
  ///
  /// Bug fix (on-device feedback): `plane: false` too - reference/created
  /// Planes stayed selectable through this whole flow despite every other
  /// kind being turned off, since `SelectionFilterState` had no `plane`
  /// field at all until this fix (`part_viewport.dart`'s
  /// `_hoverHitTestPlanes` now checks it).
  static const _filletSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: true,
    face: true,
    body: false,
    sketchPoint: false,
    sketchLine: false,
    sketchCircle: false,
    plane: false,
  );

  // --- Prompt E: Chamfer state --------------------------------------------
  // Mirrors every one of the Fillet fields directly above, field for field -
  // deliberately its own separate set (not shared/generalized with Fillet's)
  // since only one of _extrudeActive/_createPlaneActive/_filletActive/
  // _chamferActive is ever true at a time, but generalizing now would mean
  // touching Fillet's own working code for no functional gain - see
  // `docs/live-preview-pattern.md`'s own note that this is a call to make
  // when it's actually needed, not speculatively.

  /// Prompt E: true while [ChamferPanel] is open - mirrors [_filletActive]
  /// exactly.
  bool _chamferActive = false;

  /// The ChamferFeature created (or, in edit mode, already existing) for the
  /// panel session - mirrors [_previewFilletFeatureId].
  String? _previewChamferFeatureId;

  /// B4: non-null while [ChamferPanel] is editing an *existing*
  /// ChamferFeature - mirrors [_editingFilletFeatureId].
  String? _editingChamferFeatureId;

  /// B4: the edited Feature's own stored values from just before editing
  /// started - mirrors [_filletEditSnapshot].
  ({List<SubShapeRefDto> edgeRefs, double distance})? _chamferEditSnapshot;

  /// [_selectedEntities]' value from just before the panel opened - mirrors
  /// [_entitiesBeforeFillet].
  Set<SelectionEntityRef>? _entitiesBeforeChamfer;

  /// The panel's live distance field value - mirrors [_filletRadius].
  double _chamferDistance = 1.0;

  Timer? _chamferDebounce;

  /// Mirrors [_filletPreviewBodyId] - see [_refreshChamferPreviewMesh].
  String? _chamferPreviewBodyId;

  /// Mirrors [_filletPreviewMesh] - see [_ensureChamferFeatureExists]'s own
  /// doc comment (identical reasoning to [_ensureFilletFeatureExists]'s).
  MeshDto? _chamferPreviewMesh;

  /// Mirrors [_filletSelectionFilter] exactly - same edge/face-only, plane-
  /// off filter, kept as Chamfer's own separate constant rather than
  /// reusing Fillet's (see this section's own header comment on why).
  static const _chamferSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: true,
    face: true,
    body: false,
    sketchPoint: false,
    sketchLine: false,
    sketchCircle: false,
    plane: false,
  );

  // --- Prompt F: Revolve state ---------------------------------------------
  // A full separate mirror of the Extrude state block above, per this
  // project's established separate-not-shared convention - Revolve is
  // Boss/Cut-shaped like Extrude (simple `isPreviewMesh` live preview, no
  // dual-mesh overlay - see docs/live-preview-pattern.md's decision tree:
  // target_body_ids are Body-level picks, stable across re-solves, exactly
  // like Extrude's own), just consuming a Sketch Line axis pick alongside
  // Extrude's own target-body picking rather than instead of it.

  /// Prompt F: true while the Feature tree is acting as a Sketch picker for
  /// a pending Revolve - mirrors [_sketchPickerActive] exactly, entered by
  /// [_revolveSelectedFeature] when no eligible Sketch is already selected.
  bool _revolveSketchPickerActive = false;

  /// Mirrors [_pickableSketchIds] exactly, for the Revolve picker.
  Set<String> _pickableRevolveSketchIds = {};

  /// The SketchFeature currently being revolved via [RevolvePanel], or null
  /// when the panel is closed - mirrors [_extrudeSketchFeature].
  FeatureDto? _revolveSketchFeature;

  /// The RevolveFeature created by the panel's first live-preview update -
  /// mirrors [_previewExtrudeFeatureId].
  String? _previewRevolveFeatureId;

  /// Mirrors [_meshBeforeExtrude].
  List<BodyMeshDto>? _meshBeforeRevolve;

  /// Mirrors [_entitiesBeforeExtrude] - while the panel is open,
  /// [_selectedEntities] is dedicated to axis-Line + target-body picking
  /// (see [_openRevolvePanel]) instead of the general Stage 23 selection.
  Set<SelectionEntityRef>? _entitiesBeforeRevolve;

  /// B4: non-null while [RevolvePanel] is editing an *existing*
  /// RevolveFeature - mirrors [_editingExtrudeFeatureId].
  String? _editingRevolveFeatureId;

  /// B4: the edited Feature's own stored values from just before editing
  /// started - mirrors [_extrudeEditSnapshot].
  ({
    RevolveMode mode,
    double angle,
    SketchEntityRefDto axisRef,
    List<String> targetBodyIds,
    List<SketchEntityRefDto> profileRefs,
  })? _revolveEditSnapshot;

  RevolveMode _revolveMode = RevolveMode.boss;
  double _revolveAngle = 180.0;

  /// Prompt G: mirrors [_extrudeProfileRefs] exactly - which outer
  /// profile(s) of [_revolveSketchFeature] to use.
  List<SketchEntityRefDto> _revolveProfileRefs = [];

  /// Debounces the panel's live-preview PATCH/POST + mesh refresh - mirrors
  /// [_extrudeDebounce].
  Timer? _revolveDebounce;

  /// Mirrors [_extrudeActive].
  bool get _revolveActive => _revolveSketchFeature != null;

  /// Prompt F: the axis-Line-picking + target-body-picking filter for the
  /// whole Revolve flow - unlike Extrude's bodies-only override
  /// ([_openExtrudePanel]), this allows *both* `sketchLine` (the axis) and
  /// `body` (Boss/Cut targets) hits simultaneously, since a Revolve session
  /// needs to pick one of each rather than only ever one kind - no separate
  /// "picking mode" toggle is needed because [_selectedEntities] already
  /// holds entities of both kinds side by side (a [SelectionEntityRef]'s own
  /// `kind` tells them apart), and [_toggleSelectedEntity]'s Revolve
  /// special-case (below) routes a `sketchLine` tap to axis-replacement while
  /// a `body` tap falls through to the ordinary toggle-add/remove Extrude
  /// itself already uses.
  static const _revolveSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: false,
    face: false,
    body: true,
    sketchPoint: false,
    sketchLine: true,
    // On-device feedback: a Circle is never a valid Revolve axis (no
    // meaningful "axis direction" - see this project's already-resolved
    // Prompt F decision that the axis stays a Line reference), so this
    // stays off even though sketchLine (axis picking) is on.
    sketchCircle: false,
    plane: false,
  );

  // --- Prompt G: profile picking -------------------------------------------
  // Lets the user choose which closed profile(s) of a Sketch to extrude/
  // revolve, instead of always using every one detected (or erroring on a
  // mix of open/closed profiles - see app.sketch.profile.detect_profile's
  // own Prompt G relaxation). Entered from _extrudeSelectedFeature/
  // _onSketchPicked/_revolveSelectedFeature/_onRevolveSketchPicked once an
  // eligible Sketch is chosen and turns out to have 2+ usable closed loops -
  // a single-loop Sketch skips straight to the panel exactly as before this
  // prompt, so the common case gets zero added friction. Create-time-only:
  // editing an already-existing Extrude/Revolve keeps whatever profile_refs
  // it already has for the whole edit session (no re-picking UI yet - see
  // _openExtrudePanelForEdit/_openRevolvePanelForEdit, which just prefill
  // _extrudeProfileRefs/_revolveProfileRefs from the stored Feature and
  // never change them again).

  /// True while the profile picker is open.
  bool _profilePickerActive = false;

  /// Which Feature type the picker is gathering picks for - decides what
  /// [_confirmProfilePicker] opens once the checkmark FAB is tapped.
  _ProfilePickerTarget? _profilePickerTarget;

  /// The SketchFeature being picked from.
  FeatureDto? _profilePickerSketchFeature;

  /// Every outer profile loop `detect_profile` currently reports for
  /// [_profilePickerSketchFeature] (fetched once, when picking starts, via
  /// `SketchApiClient.getProfile`) - each entry is one loop's own set of
  /// Line/Circle entity ids. Used both to resolve "which loop does this
  /// tapped/hovered Line belong to" ([_profileLoopIndexFor], driving
  /// [_toggleProfileLoop] and [PartViewport.sketchLineLoopGroup]) and to
  /// build the anchor [SketchEntityRefDto] list once the user confirms (one
  /// anchor per picked loop, any member of it - see [_confirmProfilePicker]).
  List<Set<String>> _profilePickerLoops = [];

  /// [_selectedEntities]' value from just before picking started - restored
  /// on confirm/cancel, same purpose every other picker's own
  /// entitiesBeforeX field serves.
  Set<SelectionEntityRef>? _entitiesBeforeProfilePicker;

  /// Restricts the picker session to `sketchLine`/`sketchCircle` hits only -
  /// a tap on either toggles that entity's whole containing loop (see
  /// [_toggleProfileLoop]), a Circle-only loop being a single-entity "loop"
  /// of exactly one Circle (see `app.sketch.profile._circle_profile`).
  static const _profilePickerSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: false,
    face: false,
    body: false,
    sketchPoint: false,
    sketchLine: true,
    sketchCircle: true,
    plane: false,
  );

  /// The loop index in [_profilePickerLoops] containing [sketchEntityId], or
  /// null if it belongs to none (shouldn't happen for a real hit against a
  /// Sketch this picker fetched its loops from, but stays defensive against
  /// stale data the same way every other by-id lookup in this file does).
  int? _profileLoopIndexFor(String sketchEntityId) {
    for (var i = 0; i < _profilePickerLoops.length; i++) {
      if (_profilePickerLoops[i].contains(sketchEntityId)) return i;
    }
    return null;
  }

  /// [PartViewport.sketchLineLoopGroup] - see that field's own doc comment.
  /// Only ever returns non-null while [_profilePickerActive] and for the
  /// specific Sketch Feature being picked from - every other hover in this
  /// file falls back to the single-entity default.
  Set<String>? _sketchLineLoopGroup(String sketchFeatureId, String sketchEntityId) {
    if (!_profilePickerActive || _profilePickerSketchFeature?.id != sketchFeatureId) return null;
    final index = _profileLoopIndexFor(sketchEntityId);
    return index == null ? null : _profilePickerLoops[index];
  }

  /// Shared by every "a Sketch was just chosen for Extrude/Revolve" entry
  /// point ([_extrudeSelectedFeature]/[_onSketchPicked]/
  /// [_revolveSelectedFeature]/[_onRevolveSketchPicked]) - fetches the
  /// Sketch's current Profile detection and either opens the target panel
  /// directly with no profile selection (0 or 1 usable loop - nothing to
  /// disambiguate, exactly the pre-Prompt-G behaviour) or enters the picker
  /// (2+ loops).
  Future<void> _proceedToSketchConsumingFeature(
    FeatureDto sketchFeature,
    _ProfilePickerTarget target,
  ) async {
    final sketchId = sketchFeature.sketchId;
    if (sketchId == null) {
      _openPanelForTarget(sketchFeature, target, const []);
      return;
    }
    ProfileDetectionDto? profile;
    try {
      profile = await _sketchApi.getProfile(sketchId);
    } catch (_) {
      // Defensive - the caller's own eligibility check already confirmed
      // this Sketch resolves; fall back to "no picking, just proceed"
      // rather than getting stuck on a transient fetch failure.
    }
    if (!mounted) return;
    final loops = [
      for (final loop in profile?.fillableLoops ?? const <ProfileLoopDto>[]) loop.lineIds.toSet(),
    ];
    if (loops.length <= 1) {
      _openPanelForTarget(sketchFeature, target, const []);
      return;
    }
    _startProfilePicker(sketchFeature, target, loops);
  }

  void _openPanelForTarget(
    FeatureDto sketchFeature,
    _ProfilePickerTarget target,
    List<SketchEntityRefDto> profileRefs,
  ) {
    switch (target) {
      case _ProfilePickerTarget.extrude:
        _openExtrudePanel(sketchFeature, profileRefs: profileRefs);
      case _ProfilePickerTarget.revolve:
        _openRevolvePanel(sketchFeature, profileRefs: profileRefs);
      case _ProfilePickerTarget.sweep:
        // Unlike Extrude/Revolve, a Sweep's path is mandatory and picked
        // once, up front - never live while its own panel is open (see
        // the path-picking flow below) - so this enters that flow instead
        // of opening SweepPanel directly; SweepPanel only ever opens once
        // a path has actually been confirmed (see [_confirmPathPicker]).
        _startPathPicker(sketchFeature, profileRefs);
    }
  }

  void _startProfilePicker(
    FeatureDto sketchFeature,
    _ProfilePickerTarget target,
    List<Set<String>> loops,
  ) {
    setState(() {
      _profilePickerActive = true;
      _profilePickerTarget = target;
      _profilePickerSketchFeature = sketchFeature;
      _profilePickerLoops = loops;
      _entitiesBeforeProfilePicker = _selectedEntities;
      _selectedEntities = {};
      _selectionMode = true;
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _planeSelectionModeStack.pop();
      _selectionFilterOverrides.push(_profilePickerSelectionFilter);
    });
  }

  /// Whether [entityId] (one of [_profilePickerLoops]' member ids, for
  /// [sketchFeatureId]) is a Circle rather than a Line - a Circle-only loop
  /// is exactly one Circle id (see `app.sketch.profile._circle_profile`),
  /// so this is what tells [_toggleProfileLoop]/[_confirmProfilePicker]
  /// which [SelectionEntityKind]/`SketchEntityRefDto.entityType` to build
  /// for a given member id, instead of assuming every member is a Line.
  bool _isProfileCircleEntity(String sketchFeatureId, String entityId) =>
      _allSketchGeometries[sketchFeatureId]?.circleIds.contains(entityId) ?? false;

  /// [_toggleSelectedEntity]'s profile-picker special-case - toggles every
  /// entity in [tappedEntity]'s whole containing loop in/out of
  /// [_selectedEntities] as one unit, mirroring [_toggleFilletFaceEdges]'s
  /// own "grow a partial pick to the complete loop, or clear a complete one"
  /// convenience. A no-op if [tappedEntity] doesn't resolve to any of
  /// [_profilePickerLoops] (stale hit against data that's since changed).
  void _toggleProfileLoop(SelectionEntityRef tappedEntity) {
    final index = _profileLoopIndexFor(tappedEntity.sketchEntityId);
    if (index == null) return;
    final loopEntities = {
      for (final entityId in _profilePickerLoops[index])
        SelectionEntityRef(
          kind: _isProfileCircleEntity(tappedEntity.sketchFeatureId, entityId)
              ? SelectionEntityKind.sketchCircle
              : SelectionEntityKind.sketchLine,
          sketchFeatureId: tappedEntity.sketchFeatureId,
          sketchEntityId: entityId,
        ),
    };
    final allSelected = loopEntities.every(_selectedEntities.contains);
    setState(() {
      final next = Set<SelectionEntityRef>.of(_selectedEntities);
      if (allSelected) {
        next.removeAll(loopEntities);
      } else {
        next.addAll(loopEntities);
      }
      _selectedEntities = next;
    });
  }

  /// How many distinct loops are currently picked - the top banner's own
  /// live count, derived from [_selectedEntities] the same way
  /// [_confirmProfilePicker] itself resolves the final pick.
  int _profilePickedCount() {
    final pickedLoopIndices = <int>{};
    for (final entity in _selectedEntities) {
      if (entity.kind != SelectionEntityKind.sketchLine &&
          entity.kind != SelectionEntityKind.sketchCircle) {
        continue;
      }
      final index = _profileLoopIndexFor(entity.sketchEntityId);
      if (index != null) pickedLoopIndices.add(index);
    }
    return pickedLoopIndices.length;
  }

  /// The checkmark FAB - resolves every currently-picked loop (derived from
  /// [_selectedEntities], not a separately-tracked index set, since the
  /// selection set is already the single source of truth for "which loops
  /// are picked") into one anchor [SketchEntityRefDto] per loop (any member
  /// entity id - `select_profiles` on the backend only needs *a* member, not
  /// a specific one), then closes the picker and opens the target panel.
  /// Picking nothing is valid and simply means "use every profile" (an
  /// empty `profile_refs` list) - the backend's own default, so no special-
  /// casing is needed for a zero-pick confirm.
  void _confirmProfilePicker() {
    final sketchFeature = _profilePickerSketchFeature;
    final target = _profilePickerTarget;
    if (sketchFeature == null || target == null) return;

    final pickedLoopIndices = <int>{};
    for (final entity in _selectedEntities) {
      if (entity.kind != SelectionEntityKind.sketchLine &&
          entity.kind != SelectionEntityKind.sketchCircle) {
        continue;
      }
      final index = _profileLoopIndexFor(entity.sketchEntityId);
      if (index != null) pickedLoopIndices.add(index);
    }
    final sketchId = sketchFeature.sketchId!;
    // On-device feedback: `entityType` used to be hardcoded to `'line'`,
    // which broke the moment a picked loop's anchor member was actually a
    // Circle's own id (a Circle-only loop, per `_circle_profile`) - the
    // backend's `resolve_sketch_entity` validates `entity_type` against the
    // real entity's type (`isinstance(entity, expected_type)`) and 422s a
    // mismatch, so this now reports whichever type the anchor id really is.
    final profileRefs = [
      for (final index in pickedLoopIndices)
        SketchEntityRefDto(
          sketchId: sketchId,
          entityType: _isProfileCircleEntity(sketchFeature.id, _profilePickerLoops[index].first)
              ? 'circle'
              : 'line',
          entityId: _profilePickerLoops[index].first,
        ),
    ];

    setState(() {
      _profilePickerActive = false;
      _profilePickerTarget = null;
      _profilePickerSketchFeature = null;
      _profilePickerLoops = [];
      _selectedEntities = _entitiesBeforeProfilePicker ?? {};
      _entitiesBeforeProfilePicker = null;
      _selectionFilterOverrides.pop();
    });
    _openPanelForTarget(sketchFeature, target, profileRefs);
  }

  /// Exits the picker without opening anything - the picker's own Cancel
  /// button and the device back gesture (see [build]'s `PopScope`) both
  /// lead here, mirroring every other guided picker's "dismissing cancels
  /// the pending operation" rule.
  void _cancelProfilePicker() {
    setState(() {
      _profilePickerActive = false;
      _profilePickerTarget = null;
      _profilePickerSketchFeature = null;
      _profilePickerLoops = [];
      _selectedEntities = _entitiesBeforeProfilePicker ?? {};
      _entitiesBeforeProfilePicker = null;
      _selectionFilterOverrides.pop();
    });
  }

  // --- Sweep: path picking -------------------------------------------------
  // Sweep's own second picking step, entered automatically right after the
  // profile step (see [_openPanelForTarget]'s `sweep` case) - unlike
  // Revolve's axis (a single Line, picked live while its own panel is open),
  // a Sweep's path is an *ordered*, possibly-multi-segment, possibly-cross-
  // Sketch chain of Lines (confirmed decisions - see the backend's
  // `SweepFeature` docstring), so it gets its own dedicated picking mode
  // instead: tap Lines one at a time, in order, to build the chain; tap the
  // most recently picked Line again to undo it; a checkmark FAB confirms
  // once at least one segment is picked and opens [SweepPanel].

  /// True while the path picker is open.
  bool _pathPickerActive = false;

  /// The Profile's own SketchFeature - carried through to [SweepPanel] once
  /// picking confirms.
  FeatureDto? _pathPickerSketchFeature;

  /// [_profilePickerLoops]' Sweep counterpart - the Profile's own
  /// profile_refs, resolved by the profile-picking step that ran just
  /// before this one started (empty if that step was skipped, meaning
  /// "every profile" - same convention every other profile_refs consumer in
  /// this file already follows). Carried through to [SweepPanel] unchanged;
  /// this picker never touches it.
  List<SketchEntityRefDto> _pathPickerProfileRefs = [];

  /// The path picked so far, in pick order - the single source of truth
  /// this whole picker is built around; [_selectedEntities] is derived from
  /// it (see [_togglePathPick]), not the other way around, so the two can
  /// never drift out of sync.
  List<SketchEntityRefDto> _pathPickerRefs = [];

  /// [_selectedEntities]' value from just before picking started - restored
  /// on confirm/cancel, same purpose every other picker's own
  /// entitiesBeforeX field serves.
  Set<SelectionEntityRef>? _entitiesBeforePathPicker;

  /// Restricts the picker session to `sketchLine` hits only - a path
  /// segment must be a Line (mirrors Revolve's own axis restriction;
  /// Point/Circle are never valid path segments), and unlike the profile
  /// picker's own filter, `body` stays off too - target-body picking only
  /// happens later, once [SweepPanel] itself is open.
  static const _pathPickerSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: false,
    face: false,
    body: false,
    sketchPoint: false,
    sketchLine: true,
    sketchCircle: false,
    plane: false,
  );

  void _startPathPicker(FeatureDto sketchFeature, List<SketchEntityRefDto> profileRefs) {
    setState(() {
      _pathPickerActive = true;
      _pathPickerSketchFeature = sketchFeature;
      _pathPickerProfileRefs = profileRefs;
      _pathPickerRefs = [];
      _entitiesBeforePathPicker = _selectedEntities;
      _selectedEntities = {};
      _selectionMode = true;
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _planeSelectionModeStack.pop();
      _selectionFilterOverrides.push(_pathPickerSelectionFilter);
    });
  }

  /// World-space distance within which two points are treated as the same -
  /// mirrors the backend's own `app.document.sweep._PATH_POINT_TOLERANCE`
  /// exactly. Purely a client-side pre-check for immediate tap feedback;
  /// the backend re-validates independently (and is the actual source of
  /// truth) once the path is confirmed.
  static const double _pathPointTolerance = 1e-4;

  static bool _pathPointsCoincide(vm.Vector3 a, vm.Vector3 b) => (a - b).length < _pathPointTolerance;

  /// World-space `(start, end)` for the Sketch Line named by
  /// [sketchFeatureId]/[sketchEntityId] - looked up in
  /// [_allSketchGeometries] (not [_visibleSketchGeometries], so an already-
  /// picked segment's own endpoints stay resolvable even if its Sketch gets
  /// hidden mid-pick) - null if that Sketch/Line can no longer be resolved.
  (vm.Vector3, vm.Vector3)? _lineWorldSegment(String sketchFeatureId, String sketchEntityId) {
    final geometry = _allSketchGeometries[sketchFeatureId];
    if (geometry == null) return null;
    final index = geometry.lineIds.indexOf(sketchEntityId);
    if (index == -1) return null;
    return geometry.lineSegments[index];
  }

  /// Traces [refs] (an ordered list of path picks) into its actual ordered
  /// world-space point chain - mirrors the backend's own `app.document.
  /// sweep._resolve_path_wire` tracing logic exactly (each ref's own
  /// endpoint pair is resolved independently, then chained by matching
  /// position against *either* end of the chain built so far - its front
  /// ([points.first]) or its back ([points.last]), not just the back, since
  /// the very first pick has no "correct" direction fixed yet: the second
  /// pick may connect to either of its two endpoints - since cross-Sketch
  /// entries have no shared Point id to chain by instead). Returns null if
  /// any ref's Line can no longer be resolved, or if two consecutive refs
  /// don't actually connect - shouldn't happen for anything
  /// [_togglePathPick] itself built, but stays defensive against stale data
  /// the same way [_profileLoopIndexFor] already does.
  List<vm.Vector3>? _tracePathPoints(List<SketchEntityRefDto> refs) {
    final points = <vm.Vector3>[];
    for (final ref in refs) {
      final sketchFeatureId = _sketchFeatureIdForSketchId(ref.sketchId);
      final segment = sketchFeatureId == null ? null : _lineWorldSegment(sketchFeatureId, ref.entityId);
      if (segment == null) return null;
      final (start, end) = segment;
      if (points.isEmpty) {
        points.add(start);
        points.add(end);
        continue;
      }
      final front = points.first;
      final back = points.last;
      if (_pathPointsCoincide(back, start)) {
        points.add(end);
      } else if (_pathPointsCoincide(back, end)) {
        points.add(start);
      } else if (_pathPointsCoincide(front, start)) {
        points.insert(0, end);
      } else if (_pathPointsCoincide(front, end)) {
        points.insert(0, start);
      } else {
        return null;
      }
    }
    return points;
  }

  /// [_toggleSelectedEntity]'s path-picker special-case - a sketchLine tap
  /// while the path picker is open either extends [_pathPickerRefs] (starting
  /// a brand-new chain if none is picked yet, or appending to whichever end
  /// of the current chain the tapped Line's own endpoint coincides with), or
  /// - if the tapped Line is the *most recently* picked one - undoes it (tap
  /// the last pick again to remove it, mirroring this app's "tap again to
  /// deselect" convention elsewhere). A tap that neither connects to the
  /// chain nor targets the last pick gets an explanatory SnackBar rather
  /// than [_toggleProfileLoop]'s own silent "stale hit" ignore - unlike a
  /// stale profile-loop hit, a disconnected path tap is an expected, regular
  /// occurrence during normal picking, not just stale data, so it needs real
  /// feedback. [_selectedEntities] is rebuilt from [_pathPickerRefs] on every
  /// change (rather than toggled independently) so the two can never drift
  /// out of sync.
  void _togglePathPick(SelectionEntityRef lineEntity) {
    final sketchId = _sketchIdForFeatureId(lineEntity.sketchFeatureId);
    if (sketchId == null) return;
    final ref = SketchEntityRefDto(sketchId: sketchId, entityType: 'line', entityId: lineEntity.sketchEntityId);

    List<SketchEntityRefDto> nextRefs;
    if (_pathPickerRefs.isNotEmpty &&
        _pathPickerRefs.last.sketchId == ref.sketchId &&
        _pathPickerRefs.last.entityId == ref.entityId) {
      nextRefs = _pathPickerRefs.sublist(0, _pathPickerRefs.length - 1);
    } else if (_pathPickerRefs.any((r) => r.sketchId == ref.sketchId && r.entityId == ref.entityId)) {
      _showSnack('That line is already part of the path');
      return;
    } else if (_pathPickerRefs.isEmpty) {
      nextRefs = [ref];
    } else {
      final points = _tracePathPoints(_pathPickerRefs);
      final segment = _lineWorldSegment(lineEntity.sketchFeatureId, lineEntity.sketchEntityId);
      if (points == null || segment == null) return;
      final (start, end) = segment;
      // Checked against both ends of the chain built so far, not just its
      // back - the very first pick has no "correct" direction fixed yet, so
      // a second pick connecting to its *other* endpoint is just as valid
      // (see [_tracePathPoints]'s own doc comment).
      if (_pathPointsCoincide(points.last, start) ||
          _pathPointsCoincide(points.last, end) ||
          _pathPointsCoincide(points.first, start) ||
          _pathPointsCoincide(points.first, end)) {
        nextRefs = [..._pathPickerRefs, ref];
      } else {
        _showSnack("That line doesn't connect to the current path - tap one touching either end");
        return;
      }
    }

    setState(() {
      _pathPickerRefs = nextRefs;
      _selectedEntities = {
        for (final r in nextRefs)
          SelectionEntityRef(
            kind: SelectionEntityKind.sketchLine,
            sketchFeatureId: _sketchFeatureIdForSketchId(r.sketchId) ?? '',
            sketchEntityId: r.entityId,
          ),
      };
    });
  }

  /// Whether [refs] (an ordered list of path picks) traces a closed
  /// (looping) path - its first and last points coincide - or an open one.
  /// Shared by [_pathPickerBannerText] (the live picker banner) and
  /// [SweepPanel]'s own `pathIsClosed` (via [_sweepPathIsClosed]) so the two
  /// never disagree about the same path.
  bool _pathIsClosed(List<SketchEntityRefDto> refs) {
    final points = _tracePathPoints(refs);
    return points != null && points.length > 2 && _pathPointsCoincide(points.first, points.last);
  }

  /// [SweepPanel.pathIsClosed] for the currently-open panel session's own
  /// (already-confirmed, fixed) [_sweepPathRefs].
  bool _sweepPathIsClosed() => _pathIsClosed(_sweepPathRefs);

  /// The top banner's live status text - segment count plus open/closed,
  /// mirroring [SweepPanel]'s own path summary line.
  String _pathPickerBannerText() {
    if (_pathPickerRefs.isEmpty) return 'Tap a line to start the path';
    final isClosed = _pathIsClosed(_pathPickerRefs);
    final count = _pathPickerRefs.length;
    return '$count segment${count == 1 ? '' : 's'} picked'
        '${isClosed ? ' (closed)' : ''} - tap checkmark to confirm';
  }

  /// The checkmark FAB - closes the picker and opens [SweepPanel] with the
  /// confirmed path. Requires at least one segment (mirrors Cut's own
  /// "at least one" rules elsewhere) - disabled otherwise, see the FAB's own
  /// `onPressed` gating.
  void _confirmPathPicker() {
    final sketchFeature = _pathPickerSketchFeature;
    if (sketchFeature == null || _pathPickerRefs.isEmpty) return;
    final profileRefs = _pathPickerProfileRefs;
    final pathRefs = _pathPickerRefs;

    setState(() {
      _pathPickerActive = false;
      _pathPickerSketchFeature = null;
      _pathPickerProfileRefs = [];
      _pathPickerRefs = [];
      _selectedEntities = _entitiesBeforePathPicker ?? {};
      _entitiesBeforePathPicker = null;
      _selectionFilterOverrides.pop();
    });
    _openSweepPanel(sketchFeature, pathRefs, profileRefs: profileRefs);
  }

  /// Exits the path picker without creating a Sweep - mirrors
  /// [_cancelProfilePicker] exactly.
  void _cancelPathPicker() {
    setState(() {
      _pathPickerActive = false;
      _pathPickerSketchFeature = null;
      _pathPickerProfileRefs = [];
      _pathPickerRefs = [];
      _selectedEntities = _entitiesBeforePathPicker ?? {};
      _entitiesBeforePathPicker = null;
      _selectionFilterOverrides.pop();
    });
  }

  // --- Prompt F-mirror: Sweep state ----------------------------------------
  // A full separate mirror of the Revolve state block, per this project's
  // established separate-not-shared convention - Sweep is Boss/Cut-shaped
  // like Extrude/Revolve, just consuming an ordered path of Sketch Lines
  // (picked once, up front - see the path-picking flow above) instead of a
  // live-picked single axis Line.

  /// True while the Feature tree is acting as a Sketch picker for a pending
  /// Sweep - mirrors [_revolveSketchPickerActive] exactly, entered by
  /// [_sweepSelectedFeature] when no eligible Sketch is already selected.
  bool _sweepSketchPickerActive = false;

  /// Mirrors [_pickableRevolveSketchIds] exactly, for the Sweep picker.
  Set<String> _pickableSweepSketchIds = {};

  /// The SketchFeature currently being swept via [SweepPanel], or null when
  /// the panel is closed - mirrors [_revolveSketchFeature].
  FeatureDto? _sweepSketchFeature;

  /// The SweepFeature created by the panel's first live-preview update -
  /// mirrors [_previewRevolveFeatureId].
  String? _previewSweepFeatureId;

  /// Mirrors [_meshBeforeRevolve].
  List<BodyMeshDto>? _meshBeforeSweep;

  /// Mirrors [_entitiesBeforeRevolve] - while the panel is open,
  /// [_selectedEntities] is dedicated entirely to target-body picking (the
  /// path is already fixed by the time this panel opens, unlike Revolve's
  /// own live axis pick - see [_openSweepPanel]).
  Set<SelectionEntityRef>? _entitiesBeforeSweep;

  /// B4-style: non-null while [SweepPanel] is editing an *existing*
  /// SweepFeature - mirrors [_editingRevolveFeatureId].
  String? _editingSweepFeatureId;

  /// The edited Feature's own stored values from just before editing
  /// started - mirrors [_revolveEditSnapshot].
  ({
    SweepMode mode,
    List<SketchEntityRefDto> pathRefs,
    List<String> targetBodyIds,
    List<SketchEntityRefDto> profileRefs,
  })? _sweepEditSnapshot;

  SweepMode _sweepMode = SweepMode.boss;

  /// The path this session sweeps along - fixed once [SweepPanel] opens
  /// (set by [_openSweepPanel]/[_openSweepPanelForEdit]) and never changed
  /// again for the rest of the create/edit session, mirroring
  /// [_extrudeProfileRefs]/[_revolveProfileRefs]'s own create-time-only
  /// picking precedent - just applied to the path instead of the profile.
  List<SketchEntityRefDto> _sweepPathRefs = [];

  /// Mirrors [_revolveProfileRefs] exactly - which outer profile(s) of
  /// [_sweepSketchFeature] to use.
  List<SketchEntityRefDto> _sweepProfileRefs = [];

  /// Debounces the panel's live-preview PATCH/POST + mesh refresh - mirrors
  /// [_revolveDebounce].
  Timer? _sweepDebounce;

  /// Mirrors [_revolveActive].
  bool get _sweepActive => _sweepSketchFeature != null;

  /// The target-body-picking filter for the whole Sweep panel session -
  /// unlike Revolve's own combined sketchLine+body filter (its axis is
  /// picked live while the panel is open), a Sweep's path is already fixed
  /// by the time this panel shows, so this only ever needs bodies, exactly
  /// like Extrude's own bodies-only override.
  static const _sweepSelectionFilter = SelectionFilterState(
    vertex: false,
    edge: false,
    face: false,
    body: true,
    sketchPoint: false,
    sketchLine: false,
    sketchCircle: false,
    plane: false,
  );

  /// Mirrors [_currentRevolveTargetBodyIds] exactly.
  List<String> _currentSweepTargetBodyIds() => _selectedEntities
      .where((e) => e.kind == SelectionEntityKind.body)
      .map((e) => e.bodyId)
      .toSet()
      .toList();

  /// Prompt F-mirror: opens [SweepPanel] for [sketchFeature] with [pathRefs]
  /// already confirmed (see [_confirmPathPicker]) - mirrors
  /// [_openRevolvePanel] exactly, substituting the fixed [pathRefs] for a
  /// live axis pick.
  void _openSweepPanel(
    FeatureDto sketchFeature,
    List<SketchEntityRefDto> pathRefs, {
    List<SketchEntityRefDto> profileRefs = const [],
  }) {
    setState(() {
      _sweepSketchFeature = sketchFeature;
      _previewSweepFeatureId = null;
      _meshBeforeSweep = _bodies;
      _sweepMode = SweepMode.boss;
      _sweepPathRefs = pathRefs;
      _sweepProfileRefs = profileRefs;
      _entitiesBeforeSweep = _selectedEntities;
      _selectedEntities = {};
      _selectionMode = true;
      _selectionFilterOverrides.push(_sweepSelectionFilter);
    });
  }

  /// Mirrors [_openRevolvePanelForEdit] exactly, substituting [_sweepPathRefs]
  /// for the reconstructed axis entity - a SweepFeature's own `path_refs`
  /// round-trips directly (no reverse Feature-id lookup needed the axis
  /// reconstruction does), so [_selectedEntities] only ever needs prefilling
  /// with the target-body entities here.
  bool _openSweepPanelForEdit(FeatureDto feature) {
    final sketchFeatureId = feature.sketchFeatureId;
    final sketchFeature = sketchFeatureId == null ? null : _featureById(sketchFeatureId);
    if (sketchFeature == null) return false;

    final mode = SweepMode.fromApiValue(feature.mode ?? 'boss');
    final targetBodyIds = feature.targetBodyIds;
    final profileRefs = feature.profileRefs;
    final pathRefs = feature.pathRefs;

    setState(() {
      _sweepSketchFeature = sketchFeature;
      _editingSweepFeatureId = feature.id;
      _previewSweepFeatureId = feature.id;
      _sweepEditSnapshot = (
        mode: mode,
        pathRefs: pathRefs,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
      _meshBeforeSweep = _bodies;
      _sweepMode = mode;
      _sweepPathRefs = pathRefs;
      _sweepProfileRefs = profileRefs;
      _entitiesBeforeSweep = _selectedEntities;
      _selectedEntities = {
        for (final bodyId in targetBodyIds)
          SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bodyId),
      };
      _selectionMode = true;
      _selectionFilterOverrides.push(_sweepSelectionFilter);
    });
    return true;
  }

  /// Mirrors [_ensureRevolveFeatureExists] exactly, substituting the fixed
  /// [pathRefs] for a live axis pick.
  Future<void> _ensureSweepFeatureExists(
    SweepMode mode,
    List<SketchEntityRefDto> pathRefs,
    List<String> targetBodyIds,
    List<SketchEntityRefDto> profileRefs,
  ) async {
    final part = _part;
    final sketchFeature = _sweepSketchFeature;
    if (part == null || sketchFeature == null) return;

    final existingId = _previewSweepFeatureId;
    if (existingId == null) {
      final created = await _api.createSweepFeature(
        part.id,
        sketchFeatureId: sketchFeature.id,
        pathRefs: pathRefs,
        mode: mode.apiValue,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
      _previewSweepFeatureId = created.id;
    } else {
      await _api.updateSweepFeature(
        part.id,
        existingId,
        pathRefs: pathRefs,
        mode: mode.apiValue,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
    }
    await _refreshMesh();
  }

  /// [SweepPanel.onChanged] - mirrors [_onRevolveValuesChanged], minus the
  /// angle field Sweep has no equivalent of.
  void _onSweepValuesChanged(SweepMode mode) {
    _sweepMode = mode;
    _scheduleSweepPreview();
  }

  /// Mirrors [_scheduleRevolvePreview], minus the "nothing to solve without
  /// an axis" guard - a Sweep's path is always already valid by the time
  /// this could ever fire (fixed at panel-open time), so there is nothing
  /// equivalent to gate on here.
  void _scheduleSweepPreview() {
    _sweepDebounce?.cancel();
    _sweepDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(() => _ensureSweepFeatureExists(
            _sweepMode,
            _sweepPathRefs,
            _currentSweepTargetBodyIds(),
            _sweepProfileRefs,
          ));
    });
  }

  /// Mirrors [_confirmRevolve] exactly, minus the "only if an axis is
  /// picked" guard [_ensureSweepFeatureExists] call needs (unconditional
  /// here - a Sweep's path is always already valid, unlike Revolve's axis,
  /// which might never get picked at all).
  Future<void> _confirmSweep() async {
    _sweepDebounce?.cancel();
    final sketchFeature = _sweepSketchFeature;
    final wasEditing = _editingSweepFeatureId != null;
    final targetBodyIds = _currentSweepTargetBodyIds();
    await _runGuarded(() async {
      await _ensureSweepFeatureExists(_sweepMode, _sweepPathRefs, targetBodyIds, _sweepProfileRefs);
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });
    if (!mounted) return;
    setState(() {
      if (sketchFeature != null && !wasEditing) {
        _hiddenFeatureIds.add(sketchFeature.id);
        _autoHiddenSketchFeatureIds.add(sketchFeature.id);
      }
      _recomputeVisibleSketchGeometries();
      _sweepSketchFeature = null;
      _previewSweepFeatureId = null;
      _meshBeforeSweep = null;
      _editingSweepFeatureId = null;
      _sweepEditSnapshot = null;
      _sweepPathRefs = [];
      _sweepProfileRefs = [];
      _selectedEntities = _entitiesBeforeSweep ?? {};
      _entitiesBeforeSweep = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    await _endRollback();
  }

  /// Mirrors [_cancelRevolve] exactly.
  Future<void> _cancelSweep() async {
    _sweepDebounce?.cancel();
    final part = _part;
    final sketchFeature = _sweepSketchFeature;
    final previewId = _previewSweepFeatureId;
    final meshBefore = _meshBeforeSweep;
    final wasEditing = _editingSweepFeatureId != null;
    final editSnapshot = _sweepEditSnapshot;
    setState(() {
      _sweepSketchFeature = null;
      _previewSweepFeatureId = null;
      _meshBeforeSweep = null;
      _editingSweepFeatureId = null;
      _sweepEditSnapshot = null;
      _sweepPathRefs = [];
      _sweepProfileRefs = [];
      _selectedEntities = _entitiesBeforeSweep ?? {};
      _entitiesBeforeSweep = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateSweepFeature(
            part.id,
            previewId,
            pathRefs: editSnapshot.pathRefs,
            mode: editSnapshot.mode.apiValue,
            targetBodyIds: editSnapshot.targetBodyIds,
            profileRefs: editSnapshot.profileRefs,
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

  /// Mirrors [_targetBodyPickerBannerText] - Sweep's panel-session banner
  /// only ever reports target-body status (the path is already fixed by
  /// the time this panel shows, unlike Revolve's own two-part banner).
  String _sweepPickerBannerText() {
    final count = _currentSweepTargetBodyIds().length;
    return _sweepMode == SweepMode.cut
        ? (count == 0 ? 'select a target body' : '$count target body/bodies selected')
        : (count == 0 ? 'tap bodies to merge into (optional)' : '$count target body/bodies selected');
  }

  /// Mirrors [_revolveSelectedFeature] exactly, substituting Sweep's own
  /// state/picker/panel.
  Future<void> _sweepSelectedFeature() async {
    final featureId = _selectedFeatureId;
    final feature = featureId == null ? null : _featureById(featureId);
    if (feature != null && feature.type == 'sketch') {
      final reason = await _checkExtrudeEligibility(feature);
      if (!mounted) return;
      if (reason == null) {
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.sweep);
        return;
      }
    }
    _startSweepSketchPicker();
  }

  /// Mirrors [_startRevolveSketchPicker] exactly, for the Sweep picker.
  void _startSweepSketchPicker() {
    setState(() {
      _sweepSketchPickerActive = true;
      _featureTreeVisible = true;
      _toolbarOpen = false;
      _planeSelectionModeStack.pop();
      _pickableSweepSketchIds = {};
    });
    _refreshPickableSweepSketchIds();
  }

  /// Mirrors [_refreshPickableRevolveSketchIds] exactly, for the Sweep
  /// picker.
  Future<void> _refreshPickableSweepSketchIds() async {
    final sketchFeatures = _features.where((f) => f.type == 'sketch').toList();
    final results = await Future.wait(sketchFeatures.map((feature) async {
      final reason = await _checkExtrudeEligibility(feature);
      return MapEntry(feature.id, reason == null);
    }));
    if (!mounted || !_sweepSketchPickerActive) return;
    setState(() {
      _pickableSweepSketchIds = {for (final entry in results) if (entry.value) entry.key};
    });
  }

  /// Mirrors [_onRevolveSketchPicked] exactly, for the Sweep picker.
  Future<void> _onSweepSketchPicked(FeatureDto feature) async {
    final reason = await _checkExtrudeEligibility(feature);
    if (!mounted || !_sweepSketchPickerActive) return;
    if (reason != null) {
      _showSnack('This sketch has no closed profile — add more lines or close the loop first');
      return;
    }
    setState(() {
      _sweepSketchPickerActive = false;
      _featureTreeVisible = false;
      _selectedFeatureId = feature.id;
      _pickableSweepSketchIds = {};
    });
    await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.sweep);
  }

  /// Mirrors [_cancelRevolveSketchPicker] exactly, for the Sweep picker.
  void _cancelSweepSketchPicker() {
    setState(() {
      _sweepSketchPickerActive = false;
      _featureTreeVisible = false;
      _pickableSweepSketchIds = {};
    });
  }

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

  /// C3: [feature]'s own Sketch-embedding basis, fully oriented - a custom
  /// plane's (via [feature.planeFeatureId]) or one of the three fixed
  /// reference planes' (via [ReferencePlaneKind]) - either way with this
  /// Sketch's own `flip`/`rotationQuarterTurns` applied (fetched from the
  /// standalone Sketch API). Returns null when neither resolves (a stale/
  /// broken reference, or a fetch failure) - callers treat that the same
  /// way an unresolvable [ReferencePlaneKind] already was (skip rendering/
  /// animation, never crash).
  ///
  /// Bug fix: the custom-plane branch used to return [_customPlaneBasis]'s
  /// *raw* (unoriented) basis directly, silently dropping the Sketch's own
  /// flip/rotation - the same "camera/backdrop faces the wrong way" class of
  /// bug [orientationFacingPlane]'s own doc comment already warns about for
  /// the fixed-plane case, just never fixed here for the custom one. Both
  /// branches now fetch the Sketch's own orientation and apply it the same
  /// way.
  Future<SketchPlaneBasis?> _sketchPlaneBasisFor(FeatureDto feature) async {
    final sketchId = feature.sketchId;
    if (sketchId == null) return null;
    final sketch = await _sketchApi.getSketch(sketchId);
    final planeFeatureId = feature.planeFeatureId;
    if (planeFeatureId != null) {
      final raw = _customPlaneBasis(planeFeatureId);
      return raw?.withOrientation(flip: sketch.flip, rotationQuarterTurns: sketch.rotationQuarterTurns);
    }
    final plane = referencePlaneKindFromApiValue(sketch.plane);
    return plane == null
        ? null
        : SketchPlaneBasis.oriented(plane, flip: sketch.flip, rotationQuarterTurns: sketch.rotationQuarterTurns);
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
    // Native Load: restores whichever Features a just-opened file's own
    // `hidden_feature_ids` named - see [PartScreen.initialHiddenFeatureIds]'s
    // own doc comment. A no-op (empty) for every non-native-Load launch.
    _hiddenFeatureIds.addAll(widget.initialHiddenFeatureIds);
    _lastSavedFileName = widget.initialFileName;
    _loadPart();
    _loadViewPreferences();
  }

  /// Loads [ViewPreferences] in the background, not awaited from
  /// [initState] - the viewport renders with the in-memory defaults already
  /// set above immediately, then repaints with whatever was actually stored
  /// once this completes.
  Future<void> _loadViewPreferences() async {
    await ViewPreferences.load();
    await ScenePreferences.load();
    if (!mounted) return;
    setState(() {
      _bgColourHex = ViewPreferences.bgColourHex;
      _bodyColourHex = ViewPreferences.bodyColourHex;
      _bodyOpacity = ViewPreferences.bodyOpacity;
      _renderMode = ViewPreferences.renderMode;
      _isPerspective = ViewPreferences.isPerspective;
      _farClip = ViewPreferences.farClip;
      _sceneRoughness = ScenePreferences.roughness;
      _sceneLightIntensity = ScenePreferences.lightIntensity;
      _sceneEmissiveIntensity = ScenePreferences.emissiveIntensity;
    });
  }

  Future<void> _onBgColourChanged(String hex) async {
    setState(() => _bgColourHex = hex);
    await ViewPreferences.setBgColourHex(hex);
  }

  Future<void> _onSceneRoughnessChanged(double value) async {
    setState(() => _sceneRoughness = value);
    await ScenePreferences.setRoughness(value);
  }

  Future<void> _onSceneLightIntensityChanged(double value) async {
    setState(() => _sceneLightIntensity = value);
    await ScenePreferences.setLightIntensity(value);
  }

  Future<void> _onSceneEmissiveIntensityChanged(double value) async {
    setState(() => _sceneEmissiveIntensity = value);
    await ScenePreferences.setEmissiveIntensity(value);
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

  /// File > Exit: abandons the current Part and returns all the way back to
  /// the first splash/[ConnectionScreen] - a fresh, non-revisit instance
  /// (so its "View a mesh file" entry is present, same as cold launch),
  /// with [Navigator.pushAndRemoveUntil] clearing this and every other
  /// route underneath so there's no way back to the abandoned [PartScreen]
  /// via the system back gesture. Confirms first, mirroring
  /// [_startNewPart]'s identical "unsaved work would be lost" dialog -
  /// exiting is just as destructive to unsaved changes as starting new.
  Future<void> _exitToConnectionScreen() async {
    setState(() => _toolbarOpen = false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit this project?'),
        content: const Text(
          'Any changes since your last Save will be lost. This does not delete the current '
          'project - it will still be there if you open it again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const ConnectionScreen()),
      (route) => false,
    );
  }

  /// Shared by [_saveNativeFile]/[_saveAsNativeFile]: exports the whole
  /// Document (every Part's ordered Feature list, plus every Sketch it
  /// references - no cached mesh/geometry) as this app's own native
  /// project file format, and hands the bytes to the platform's save-file
  /// dialog under [suggestedFileName]. Client-owned files (locked-in
  /// scope): the backend has no project storage of its own, this is this
  /// app's one point of contact with the device's actual filesystem for
  /// Save/Save As. Remembers whatever filename the user actually saved to
  /// (the dialog lets them rename even the suggestion) as
  /// [_lastSavedFileName], so a later plain Save reuses it.
  Future<void> _exportAndSaveNativeFile(String suggestedFileName) async {
    await _runGuarded(() async {
      final data = await _api.exportNative();
      // On-device feedback: the backend's own export knows nothing about
      // Hide/Show (purely client-side, see [_hiddenFeatureIds]'s own doc
      // comment) - stash it directly into the same JSON object under a key
      // the backend's `import_native` simply ignores, so opening this file
      // elsewhere restores it too instead of silently losing it.
      data['hidden_feature_ids'] = _hiddenFeatureIds.toList();
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Project',
        fileName: suggestedFileName,
        bytes: bytes,
      );
      if (savedPath != null) {
        _lastSavedFileName = savedPath.split('/').last;
      }
    });
  }

  /// Native Save: re-suggests [_lastSavedFileName] (whatever this session
  /// last Opened-from or Saved-to) as the dialog's default, so a quick
  /// re-save doesn't fall back to a generic name every time - see
  /// [_lastSavedFileName]'s own doc comment for why this can't be a truly
  /// silent overwrite (Android's Storage Access Framework has no such
  /// concept without deeper persisted-URI-permission integration; every
  /// save, Save or Save As alike, goes through the same platform dialog).
  Future<void> _saveNativeFile() async {
    setState(() => _toolbarOpen = false);
    await _exportAndSaveNativeFile(_lastSavedFileName ?? '${_part?.name ?? 'part'}.DIDSAprt');
  }

  /// Native Save As: always suggests a fresh, generic name (never
  /// [_lastSavedFileName]) - the deliberate difference from plain Save,
  /// given both otherwise go through the identical save-file dialog (see
  /// [_saveNativeFile]'s own doc comment).
  Future<void> _saveAsNativeFile() async {
    setState(() => _toolbarOpen = false);
    await _exportAndSaveNativeFile('${_part?.name ?? 'part'}.DIDSAprt');
  }

  /// File > New: starts a brand-new, blank Part - the same "always start
  /// fresh" pattern this app already uses at first launch (see
  /// [PartScreen]'s own doc comment) - after confirming, since whatever is
  /// currently open (if not yet saved) would otherwise be lost with no way
  /// back. Pushes a fresh [PartScreen]/State pair with no `initialPartId`/
  /// `initialHiddenFeatureIds`/`initialFileName` rather than resetting this
  /// screen's own state in place - see [PartScreen.initialPartId]'s own
  /// doc comment for why that's deliberate.
  Future<void> _startNewPart() async {
    setState(() => _toolbarOpen = false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new project?'),
        content: const Text(
          'Any changes since your last Save will be lost. This does not delete the current '
          'project - it will still be there if you open it again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('New Project'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PartScreen(
          documentApi: widget.documentApi,
          sketchApiFactory: widget.sketchApiFactory,
        ),
      ),
    );
  }

  /// Native Load: reads a native project file the user picks and imports it
  /// - a full replace of the backend's whole Document/Sketch store (see
  /// [DocumentApiClient.importNative]'s own docstring) - then pushes a
  /// brand-new [PartScreen] pointed at whichever Part the import returned
  /// (this app has no "pick an existing Part" UI, see [PartScreen]'s own
  /// doc comment, so the first one is simply which Part opens). Pushing a
  /// fresh screen rather than reloading in place is deliberate - see
  /// [PartScreen.initialPartId]'s own doc comment for why.
  Future<void> _openNativeFile() async {
    setState(() => _toolbarOpen = false);
    // On-device feedback: `FileType.custom` + `allowedExtensions` filters by
    // OS-guessed MIME type - Android has no MIME mapping for a made-up
    // extension like `.didsacad`, so a saved file shows up greyed out/
    // unselectable in the picker even though it's visible. `FileType.any`
    // sidesteps that entirely; content is already validated just below
    // (JSON decode, then the backend's own schema_version check), so the
    // extension filter was a UX nicety only, never load-bearing.
    final result = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    if (result == null || result.files.isEmpty || !mounted) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      setState(() => _errorMessage = 'Not a valid native project file');
      return;
    }

    // On-device feedback: the file's own Hide/Show state (see
    // [_saveNativeFile]) - the backend's `import_native` doesn't know this
    // key exists and simply ignores it, so it's read back here instead.
    final hiddenFeatureIds = (decoded['hidden_feature_ids'] as List?)?.cast<String>() ?? const [];

    NativeImportResultDto? imported;
    await _runGuarded(() async {
      imported = await _api.importNative(decoded);
    });
    if (imported == null || imported!.partIds.isEmpty || !mounted) return;

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PartScreen(
          documentApi: widget.documentApi,
          sketchApiFactory: widget.sketchApiFactory,
          initialPartId: imported!.partIds.first,
          initialHiddenFeatureIds: hiddenFeatureIds,
          initialFileName: result.files.single.name,
        ),
      ),
    );
  }

  /// Import: brings an external STEP/STL/OBJ/glTF file in as a fixed,
  /// non-parametric Body (locked-in scope - see the backend's
  /// `app.document.models.ImportFeature` own docstring) via
  /// [DocumentApiClient.createImportFeature]. `type: FileType.any` for the
  /// same reason [_openNativeFile] uses it, not an extension allow-list -
  /// see that method's own doc comment for the Android MIME-type-filtering
  /// bug this sidesteps.
  static const Map<String, String> _importSourceFormatByExtension = {
    'step': 'step',
    'stp': 'step',
    'stl': 'stl',
    'obj': 'obj',
    'gltf': 'gltf',
    'glb': 'gltf',
  };

  Future<void> _importGeometry() async {
    setState(() => _toolbarOpen = false);
    final part = _part;
    if (part == null) return;

    final result = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    if (result == null || result.files.isEmpty || !mounted) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) return;

    final extension = (picked.extension ?? picked.name.split('.').last).toLowerCase();
    final sourceFormat = _importSourceFormatByExtension[extension];
    if (sourceFormat == null) {
      setState(() => _errorMessage = 'Unrecognized file type: .$extension (expected STEP/STL/OBJ/glTF)');
      return;
    }

    await _runGuarded(() async {
      await _api.createImportFeature(part.id, sourceFormat: sourceFormat, bytes: bytes);
      await _refreshFeatures();
      await _refreshMesh();
    });
  }

  /// Export: writes the current Part's geometry out to one of four
  /// interchange formats (`format` is `'step'`/`'stl'`/`'obj'`/`'glb'`,
  /// matching both the backend endpoint's own path segment and the saved
  /// file's extension) via [DocumentApiClient.exportPart]. The backend 400s
  /// (surfaced as [_errorMessage] by [_runGuarded]) if the Part has no
  /// solid geometry yet - there is nothing to export before a first Boss.
  Future<void> _exportPart(String format) async {
    setState(() => _toolbarOpen = false);
    final part = _part;
    if (part == null) return;
    await _runGuarded(() async {
      final bytes = await _api.exportPart(part.id, format);
      await FilePicker.platform.saveFile(
        dialogTitle: 'Export Part',
        fileName: '${part.name}.$format',
        bytes: bytes,
      );
    });
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
      final PartDto part;
      if (widget.initialPartId != null) {
        debugPrint('[PartScreen] getPart(${widget.initialPartId})...');
        part = await _api.getPart(widget.initialPartId!);
        debugPrint('[PartScreen] getPart done: ${part.id}');
      } else {
        debugPrint('[PartScreen] createPart...');
        part = await _api.createPart('Part 1');
        debugPrint('[PartScreen] createPart done: ${part.id}');
      }
      _part = part;
      debugPrint('[PartScreen] getPartMesh...');
      await _refreshMesh();
      debugPrint('[PartScreen] getPartMesh done: ${_bodies.length} body/bodies');
      await _refreshFeatures();
      await _refreshSketchGeometries();
      debugPrint('[PartScreen] refreshFeatures done');
    });
  }

  ///
  /// Bug fix (on-device feedback): the fetch itself used to mutate
  /// [_features] directly, with no `setState` of its own - relying entirely
  /// on whatever the *caller* happened to `setState` afterward (often
  /// [_runGuarded]'s own bookkeeping `_busy` flip) to actually trigger a
  /// repaint. That's exactly backwards for a Flutter `State` object: a field
  /// read by `build` must be mutated inside `setState` at the point it
  /// changes, not left to some unrelated later call to coincidentally flush
  /// it - when the timing lined up this was invisible, but it made the
  /// screen only ever "catch up" on the *next* unrelated `setState` (see
  /// [_refreshMesh]'s own matching fix for the reported symptom this
  /// caused).
  Future<void> _refreshFeatures() async {
    final part = _part;
    if (part == null) return;
    final features = await _api.listFeatures(part.id);
    if (!mounted) return;
    setState(() {
      _features = features;
      _recomputeCreatePlaneGeometries();
    });
  }

  /// Re-fetches the Part's mesh with [_hiddenFeatureIds]/
  /// [_rollbackExcludedFeatureIds] sent along (as two separate params - see
  /// [_hiddenFeatureIds]'s own doc comment for why they must never be
  /// merged), so a hidden/rolled-back-past ExtrudeFeature's contribution to
  /// the displayed solid (and so to the camera target/zoom bounds
  /// [PartViewport] derives from it) drops out immediately - called after
  /// anything that can change the Part's geometry (extrude preview/confirm/
  /// cancel, cascade delete) or either of those two sets.
  ///
  /// Discards the response entirely when it's the placeholder box (Prompt
  /// A1: a single-entry array, `body_id: "placeholder"`, `source:
  /// "placeholder"` - see `backend/app/document/router.py`'s
  /// `BRepPrimAPI_MakeBox(10,10,10)` fallback for a Part with no
  /// ExtrudeFeature yet) rather than rendering it - that placeholder box is
  /// a backend implementation detail to keep the mesh endpoint's response
  /// shape uniform, not real geometry the user created, and showing it as a
  /// stray cube in an otherwise-empty viewport was confusing on-device.
  ///
  /// Bug fix (on-device feedback): creating a Fillet on a Body that already
  /// had a Chamfer left the viewport showing the pre-Fillet shape until an
  /// unrelated later action (e.g. adding a second Chamfer) happened to
  /// trigger some *other* `setState` call - hover hit-testing already
  /// reflected the new Fillet topology (it reads [_bodies] directly, not
  /// through `build`'s last-painted frame), proving the fetch itself
  /// succeeded and [_bodies] held the right value; only the repaint never
  /// happened. Root cause: this method mutated [_bodies] with no `setState`
  /// of its own, relying entirely on whichever caller happened to
  /// `setState` afterward (most callers go through [_runGuarded], whose own
  /// `_busy` bookkeeping `setState` in its `finally` block was doing this
  /// job by accident) - fragile the moment that incidental timing didn't
  /// line up. Now self-contained: every real change to [_bodies] happens
  /// inside its own `setState`, so a repaint is never left to chance.
  Future<void> _refreshMesh() async {
    final part = _part;
    if (part == null) return;
    final response = await _api.getPartMesh(
      part.id,
      hiddenFeatureIds: _hiddenFeatureIds.toList(),
      rollbackExcludedFeatureIds: _rollbackExcludedFeatureIds.toList(),
    );
    if (!mounted) return;
    final isPlaceholder = response.length == 1 && response.first.source == 'placeholder';
    final newBodies = isPlaceholder ? <BodyMeshDto>[] : response;
    final justGotFirstBody = _bodies.isEmpty && newBodies.isNotEmpty && !_hasAutoHiddenReferencePlanes;
    setState(() {
      _bodies = newBodies;
      if (justGotFirstBody) {
        _referencePlanesHidden = true;
        _hasAutoHiddenReferencePlanes = true;
      }
    });
  }

  /// Re-fetches every Feature's Sketch content (points/lines/circles) and
  /// rebuilds [_allSketchGeometries]/[_visibleSketchGeometries] from it, so
  /// the 3D viewport's rendered Sketch geometry always matches the latest
  /// backend state. A single Feature's fetch failing (e.g. a test fixture
  /// that only stubs `GET /sketch/sketches/{id}`, or a transient network
  /// issue) only drops that Feature's geometry, not the whole viewport.
  ///
  /// Bug fix (on-device feedback): mirrors [_refreshMesh]'s own fix - the
  /// rebuilt maps used to be assigned with no `setState` of their own.
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
        final arcs = await _sketchApi.listArcs(sketchId);
        final ellipses = await _sketchApi.listEllipses(sketchId);
        final splines = await _sketchApi.listSplines(sketchId);
        updatedLines[feature.id] = lines;
        final geometry = sketchGeometry3DFrom(
          basis: basis,
          points: points,
          lines: lines,
          circles: circles,
          arcs: arcs,
          ellipses: ellipses,
          splines: splines,
        );
        if (!geometry.isEmpty) updated[feature.id] = geometry;
      } catch (_) {
        // Swallow - see doc comment above.
      }
    }
    if (!mounted) return;
    setState(() {
      _allSketchGeometries = updated;
      _linesByFeatureId = updatedLines;
      _recomputeVisibleSketchGeometries();
    });
  }

  /// Filters [_allSketchGeometries] down to [_visibleSketchGeometries] by
  /// [_viewportHiddenFeatureIds] (Hide/Show *and* true-rollback alike - the
  /// viewport doesn't care which of the two reasons applies) - the only
  /// place that builds a new `Map` instance for [PartViewport.
  /// sketchGeometries], so its `didUpdateWidget` `!=` check only fires on a
  /// genuine content/visibility change.
  ///
  /// A Feature auto-hidden because it's consumed by a downstream Extrude
  /// (see [_autoHiddenSketchFeatureIds]) is excluded here exactly like a
  /// manually-hidden one - fully invisible and unpickable in the 3D
  /// viewport, not merely dimmed. Referencing a consumed Sketch's own
  /// geometry (e.g. for Create Plane's "normal to line at point") requires
  /// explicitly un-hiding it first via [_toggleFeatureVisibility].
  void _recomputeVisibleSketchGeometries() {
    final hidden = _viewportHiddenFeatureIds;
    _visibleSketchGeometries = {
      for (final entry in _allSketchGeometries.entries)
        if (!hidden.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// On-device feedback: the default (flip, rotationQuarterTurns) offered
  /// for a brand new fixed-plane Sketch's own orientation-confirm step - a
  /// custom (Feature-anchored) plane has no "which fixed plane" concept to
  /// key off, so it always gets the identity `(false, 0)`. Computed via a
  /// full calibration round (every flip x rotation combination, checked
  /// programmatically against three independently on-device-captured
  /// targets, one per fixed plane, *after* fixing `orientationFacingBasis`'s
  /// own left-handed-basis bug - see that function's own doc comment for the
  /// full story) rather than guessed: YZ needed no change at all
  /// (`false, 0` was already an exact match); XY and XZ both needed a
  /// genuinely different orientation than any single `flip` toggle alone
  /// could reach, which is exactly why guessing only `flip` kept moving the
  /// target on every previous round.
  (bool, int) _defaultPendingOrientationFor(ReferencePlaneKind? fixedPlane) => switch (fixedPlane) {
        ReferencePlaneKind.xy => (true, 1),
        ReferencePlaneKind.xz => (true, 0),
        ReferencePlaneKind.yz => (false, 0),
        null => (false, 0),
      };

  /// Creates a SketchFeature on [plane] (default) or, since C3, anchored to
  /// an existing created Plane ([planeFeatureId] - never both) and navigates
  /// straight to its SketchScreen - called from the free-tap fly-up sheet
  /// flow ([_showPlaneContextSheet]), the FAB's flyout-driven plane-selection
  /// mode ([_onPlaneTap]), and (C3) a created Plane's own context sheet's
  /// "Create Sketch on Plane" action ([_onCreatePlaneContextAction]).
  ///
  /// Bug fix: a custom-plane Sketch used to skip the orientation confirm
  /// step entirely and open immediately - [SketchPlaneBasis.withOrientation]
  /// now applies flip/rotation to any resolved basis, not just a fixed
  /// [ReferencePlaneKind]'s, so both cases go through the same step. The
  /// camera-fly-to-plane animation still only runs for a fixed plane (no
  /// [PartViewport] API animates toward an arbitrary custom basis) - a
  /// separate, orthogonal nicety from the step actually appearing.
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
    if (feature == null || !mounted) return;
    final rawBasis =
        fixedPlane != null ? SketchPlaneBasis.fixed(fixedPlane) : _customPlaneBasis(planeFeatureId!);
    if (rawBasis == null) {
      // Defensive fallback (unresolved custom-plane geometry) - same
      // graceful "can't resolve, just open" degradation every other
      // basis-dependent call site in this file already uses.
      await _openSketch(feature, basis: null);
      return;
    }
    // On-device feedback: orientation had no visual feedback and no
    // creation-time entry point at all - only a hamburger-menu sheet
    // reachable from inside the 2D editor, after already committing to a
    // plane. This step lets the user see + adjust it, live, in the 3D
    // viewport, before the sketch is ever opened - see
    // _confirmPendingOrientation/_cancelPendingOrientation.
    //
    // New camera sequence: animates to the plane-independent isometric
    // preset first (rather than straight to the plane's own face-on view,
    // the old behaviour), since defining orientation is easiest from an
    // angle that shows all three axes at once - the face-on view the user
    // is actually choosing only gets its own animation once they confirm
    // (see _confirmPendingOrientation). Unlike the old plane-specific
    // animation, this runs for a custom (Feature-anchored) plane too - it
    // was never possible before since there was no orientationFacingPlane
    // equivalent for an arbitrary basis, but isometric doesn't need one.
    await _viewportKey.currentState?.animateToIsometric();
    if (!mounted) return;
    // On-device feedback + a full numeric calibration round: see
    // _defaultPendingOrientationFor's own doc comment - this used to only
    // vary [flip] (never rotation) and, before orientationFacingBasis's own
    // left-handed-basis bug was found and fixed, couldn't have landed on a
    // stable answer no matter which flip was guessed.
    final (defaultFlip, defaultRotation) = _defaultPendingOrientationFor(fixedPlane);
    setState(() {
      _pendingOrientationFeature = feature;
      _pendingOrientationRawBasis = rawBasis;
      _pendingOrientationFlip = defaultFlip;
      _pendingOrientationRotation = defaultRotation;
      _pendingOrientationMode = _PendingOrientationMode.newSketch;
      _pendingOrientationFixedPlaneKind = fixedPlane;
      // On-device feedback: judging a pending orientation needs free orbit
      // gestures (PartViewport routes every tap/drag to its selection
      // pipeline instead while selectionMode is true, per _onPlaneTap's own
      // doc comment below) - force orbit mode for the duration of this
      // step, remembering cursor mode so it comes back once the step ends
      // (see _confirmPendingOrientation/_cancelPendingOrientation).
      _pendingOrientationPreviousSelectionMode = _selectionMode;
      _selectionMode = false;
    });
  }

  /// Sketcher-roadmap feedback round: reopens the orientation confirm step
  /// for an *existing* Sketch Feature, from its long-press context menu
  /// entry - the 2D-only hamburger-menu sheet this used to be the only way
  /// to reach (no 3D reference for the user to judge flip/rotate against)
  /// is gone; this is the sole remaining entry point, reusing the exact
  /// same 3D-viewport step [_addSketchFeature] shows for a brand new
  /// Sketch. Preloads the Sketch's own current flip/rotation (rather than
  /// resetting to the default) and records them in
  /// [_pendingOrientationOriginalFlip]/[_pendingOrientationOriginalRotation]
  /// so Cancel can revert the live PATCHes [_adjustPendingOrientation]
  /// already makes - unlike a brand new Sketch, this Feature already has
  /// real content, so Cancel must never delete it (see
  /// [_cancelPendingOrientation]'s own doc comment).
  Future<void> _redefineSketchOrientation(FeatureDto feature) async {
    if (_busy) return;
    final planeFeatureId = feature.planeFeatureId;
    SketchPlaneBasis? rawBasis;
    bool currentFlip = false;
    int currentRotation = 0;
    _SketchOrientation? orientation;
    if (planeFeatureId != null) {
      rawBasis = _customPlaneBasis(planeFeatureId);
    } else {
      orientation = await _planeOfFeature(feature);
      if (orientation != null) {
        rawBasis = SketchPlaneBasis.fixed(orientation.plane);
        currentFlip = orientation.flip;
        currentRotation = orientation.rotationQuarterTurns;
      }
    }
    if (rawBasis == null || !mounted) return;
    if (orientation != null) {
      await _viewportKey.currentState?.animateToPlane(
        orientation.plane,
        flip: currentFlip,
        rotationQuarterTurns: currentRotation,
      );
      if (!mounted) return;
    }
    setState(() {
      _pendingOrientationFeature = feature;
      _pendingOrientationRawBasis = rawBasis;
      _pendingOrientationFlip = currentFlip;
      _pendingOrientationRotation = currentRotation;
      _pendingOrientationOriginalFlip = currentFlip;
      _pendingOrientationOriginalRotation = currentRotation;
      _pendingOrientationMode = _PendingOrientationMode.redefine;
      // Irrelevant to redefine (only _addSketchFeature's new-sketch camera
      // sequence reads this) - cleared rather than left stale from a
      // possibly-earlier new-sketch step.
      _pendingOrientationFixedPlaneKind = null;
      // On-device feedback: same as _addSketchFeature's own - force orbit
      // mode for the duration of the step, remembering cursor mode so it
      // comes back once the step ends.
      _pendingOrientationPreviousSelectionMode = _selectionMode;
      _selectionMode = false;
    });
  }

  FeatureDto? _pendingOrientationFeature;
  SketchPlaneBasis? _pendingOrientationRawBasis;
  bool _pendingOrientationFlip = false;
  int _pendingOrientationRotation = 0;
  _PendingOrientationMode _pendingOrientationMode = _PendingOrientationMode.newSketch;
  bool _pendingOrientationOriginalFlip = false;
  int _pendingOrientationOriginalRotation = 0;

  /// On-device feedback: whether cursor/select mode was active right before
  /// entering the sketch-orientation-confirm step - both entry points
  /// (`_addSketchFeature`/`_redefineSketchOrientation`) force `_selectionMode`
  /// off for the step's own duration (it needs free orbit gestures) and save
  /// it here; both exit points (`_confirmPendingOrientation`/
  /// `_cancelPendingOrientation`) restore it.
  bool _pendingOrientationPreviousSelectionMode = false;

  /// New sketch-start camera sequence: the fixed plane [_addSketchFeature]
  /// resolved (null for a custom, Feature-anchored plane - no
  /// [orientationFacingPlane] equivalent exists for an arbitrary basis yet)
  /// - stashed so [_confirmPendingOrientation] can animate the camera to
  /// this plane's own face-on view (at whatever flip/rotation was just
  /// confirmed) once the user commits to an orientation, rather than only
  /// ever having shown the isometric preset this step started with.
  ReferencePlaneKind? _pendingOrientationFixedPlaneKind;

  bool get _confirmingSketchOrientation => _pendingOrientationFeature != null;

  /// [SketchOrientationIndicator]'s own live basis, reflecting whatever
  /// flip/rotation the user has tapped so far this step - null outside
  /// [_confirmingSketchOrientation].
  SketchPlaneBasis? get _pendingOrientationBasis {
    final raw = _pendingOrientationRawBasis;
    if (raw == null) return null;
    return raw.withOrientation(
      flip: _pendingOrientationFlip,
      rotationQuarterTurns: _pendingOrientationRotation,
    );
  }

  /// Applies [flip]/[rotationDelta] and PATCHes the pending Sketch's real
  /// orientation right away (not deferred to confirm) - so
  /// [SketchOrientationIndicator] and the eventual [_openSketch] can never
  /// disagree, and so the same backend endpoint [SketchController.
  /// setOrientation] already uses stays the single source of truth rather
  /// than this screen re-deriving/duplicating what "confirm" should send.
  Future<void> _adjustPendingOrientation({bool? flip, int rotationDelta = 0}) async {
    final feature = _pendingOrientationFeature;
    if (feature?.sketchId == null || _busy) return;
    final nextFlip = flip ?? _pendingOrientationFlip;
    final nextRotation = (_pendingOrientationRotation + rotationDelta) % 4;
    await _runGuarded(() async {
      await _sketchApi.updateSketchOrientation(
        feature!.sketchId!,
        flip: nextFlip,
        rotationQuarterTurns: nextRotation,
      );
    });
    if (!mounted) return;
    setState(() {
      _pendingOrientationFlip = nextFlip;
      _pendingOrientationRotation = nextRotation;
    });
  }

  /// [_PendingOrientationMode.newSketch]: new camera sequence - animates to
  /// the just-confirmed orientation's own face-on view (the plane
  /// [_addSketchFeature] resolved, at whatever flip/rotation was just
  /// confirmed) before opening the just-created Sketch, so the isometric
  /// preset this step started on ends by settling into the exact view the
  /// sketcher itself opens into, rather than cutting straight there. Only
  /// possible for a fixed plane - a custom (Feature-anchored) plane has no
  /// [orientationFacingPlane] equivalent yet, so it opens directly, same as
  /// before this sequence existed. [_PendingOrientationMode.redefine] just
  /// closes the step and refreshes this Feature's rendered geometry in the
  /// main 3D viewport - the orientation was already PATCHed live by
  /// [_adjustPendingOrientation], and there's an existing 2D canvas the
  /// user didn't ask to be dropped into (and the camera is already facing
  /// it - see [_redefineSketchOrientation]'s own animation).
  Future<void> _confirmPendingOrientation() async {
    final feature = _pendingOrientationFeature;
    if (feature == null) return;
    final basis = _pendingOrientationBasis;
    final mode = _pendingOrientationMode;
    final fixedPlaneKind = _pendingOrientationFixedPlaneKind;
    final flip = _pendingOrientationFlip;
    final rotation = _pendingOrientationRotation;
    setState(() {
      _pendingOrientationFeature = null;
      _pendingOrientationRawBasis = null;
      _pendingOrientationFixedPlaneKind = null;
      _selectionMode = _pendingOrientationPreviousSelectionMode;
    });
    if (mode == _PendingOrientationMode.newSketch) {
      if (fixedPlaneKind != null) {
        await _viewportKey.currentState?.animateToPlane(
          fixedPlaneKind,
          flip: flip,
          rotationQuarterTurns: rotation,
        );
        if (!mounted) return;
      }
      // Bug fix: createSketchFeature always creates flip=false/rotation=0
      // server-side (it takes no orientation params) - if the user confirms
      // without ever touching the flip/rotate controls, the backend's own
      // stored orientation never learned about a non-default starting flip
      // (now a real case - see _addSketchFeature's own XY/XZ default). Only
      // sends the PATCH when it would actually change anything, since a
      // plain false/0 confirm already matches creation's own default.
      if (feature.sketchId != null && (flip || rotation != 0)) {
        await _runGuarded(() async {
          await _sketchApi.updateSketchOrientation(feature.sketchId!, flip: flip, rotationQuarterTurns: rotation);
        });
        if (!mounted) return;
      }
      await _openSketch(feature, basis: basis);
    } else {
      await _refreshSketchGeometries();
    }
  }

  /// [_PendingOrientationMode.newSketch]: discards the just-created
  /// (still-empty) SketchFeature outright, same as the preview-cleanup
  /// pattern used elsewhere in this file (e.g. the Extrude-preview Cancel
  /// path) - safe because nothing was ever drawn into it, unlike deleting
  /// an existing Sketch a user has actually worked in.
  ///
  /// [_PendingOrientationMode.redefine]: the Feature already has real
  /// content, so Cancel must never delete it - instead reverts the live
  /// PATCHes [_adjustPendingOrientation] already made back to whatever the
  /// orientation was before this step started
  /// ([_pendingOrientationOriginalFlip]/[_pendingOrientationOriginalRotation]).
  Future<void> _cancelPendingOrientation() async {
    final feature = _pendingOrientationFeature;
    final part = _part;
    final mode = _pendingOrientationMode;
    final originalFlip = _pendingOrientationOriginalFlip;
    final originalRotation = _pendingOrientationOriginalRotation;
    setState(() {
      _pendingOrientationFeature = null;
      _pendingOrientationRawBasis = null;
      _pendingOrientationFixedPlaneKind = null;
      _selectionMode = _pendingOrientationPreviousSelectionMode;
    });
    if (feature == null) return;
    if (mode == _PendingOrientationMode.newSketch) {
      if (part == null) return;
      await _runGuarded(() async {
        await _api.deleteFeature(part.id, feature.id);
        await _refreshFeatures();
        await _refreshSketchGeometries();
      });
    } else {
      if (feature.sketchId == null) return;
      await _runGuarded(() async {
        await _sketchApi.updateSketchOrientation(
          feature.sketchId!,
          flip: originalFlip,
          rotationQuarterTurns: originalRotation,
        );
        await _refreshSketchGeometries();
      });
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
  ///
  /// C5: only ever reached in Orbit mode - [PartViewport]'s own pointer
  /// dispatch ([PartViewport._onPointerEnd]) routes every tap in Selection
  /// mode to its cursor/hover/commit pipeline instead ([PartViewport.
  /// _commitSelection] -> [onSelectionToggle]/[_toggleSelectedEntity]), which
  /// is how a plane tap actually joins [_selectedEntities] now (see
  /// [PartViewport._hoverHitTestPlanes]) - this callback is simply never
  /// invoked while [_selectionMode] is true, so it needs no gating of its
  /// own here.
  void _onPlaneTap(ReferencePlaneKind plane) {
    if (_planeSelectionMode) {
      setState(() => _planeSelectionModeStack.pop());
      _addSketchFeature(plane: plane);
      return;
    }
    // Confirm/Cancel are the only way out of the orientation confirm step
    // (see _confirmingSketchOrientation's own doc comment) - a stray plane
    // tap underneath its banner shouldn't pop open an unrelated context
    // sheet mid-flow.
    if (_confirmingSketchOrientation) return;
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
  ///
  /// C5: mirrors [_onPlaneTap]'s own doc comment - only ever reached in
  /// Orbit mode, so it needs no Selection-mode gating of its own either.
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
      case FeaturePickerAction.fillet:
        _startFilletPicker();
      case FeaturePickerAction.chamfer:
        _startChamferPicker();
      case FeaturePickerAction.revolve:
        await _revolveSelectedFeature();
      case FeaturePickerAction.sweep:
        await _sweepSelectedFeature();
    }
  }

  /// C3/C4/C5: the "Add" FAB's Feature picker's "Plane" entry - clears the
  /// current selection, switches to Selection mode (a bare tap in Orbit mode
  /// does nothing - this used to leave the user in whichever mode they were
  /// already in, silently stranding anyone who opened this from Orbit mode
  /// with a hint but no way to act on it), and hints what to pick next, then
  /// relies entirely on the pre-existing ambient selection machinery
  /// ([SelectionContextPanel]/`contextActionsFor`/[_onCreatePlaneTapped]) to
  /// actually open [CreatePlanePanel] once a valid combo is selected. Unlike
  /// [_startSketchPicker], there is no separate guided-picker mode to enter -
  /// Create Plane's selection flow already worked this way for every other
  /// entry point (a free tap on a Face/Line/Point/plane in the viewport
  /// already offers "Create Plane" before this menu entry is even used), so
  /// this just clears the deck, ensures taps do something, and points the
  /// user at it.
  void _startPlanePicker() {
    setState(() {
      _selectedEntities = {};
      _selectionMode = true;
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _planeSelectionModeStack.pop();
    });
    _showSnack('Select a face or plane (or two, for a midplane) to create a plane');
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
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.extrude);
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
    await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.extrude);
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

  /// Prompt F: mirrors [_extrudeSelectedFeature] exactly, substituting
  /// Revolve's own state/picker/panel - see that method's own doc comment
  /// for the full reasoning. Reuses [_checkExtrudeEligibility] directly
  /// (not a duplicate check) since a Revolve's Profile needs exactly the
  /// same closed-profile eligibility an Extrude's does - that helper has no
  /// Extrude-specific behaviour of its own, it just asks the Sketch API for
  /// the Sketch's Profile.
  Future<void> _revolveSelectedFeature() async {
    final featureId = _selectedFeatureId;
    final feature = featureId == null ? null : _featureById(featureId);
    if (feature != null && feature.type == 'sketch') {
      final reason = await _checkExtrudeEligibility(feature);
      if (!mounted) return;
      if (reason == null) {
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.revolve);
        return;
      }
    }
    _startRevolveSketchPicker();
  }

  /// Mirrors [_startSketchPicker] exactly, for the Revolve picker.
  void _startRevolveSketchPicker() {
    setState(() {
      _revolveSketchPickerActive = true;
      _featureTreeVisible = true;
      _toolbarOpen = false;
      _planeSelectionModeStack.pop();
      _pickableRevolveSketchIds = {};
    });
    _refreshPickableRevolveSketchIds();
  }

  /// Mirrors [_refreshPickableSketchIds] exactly, for the Revolve picker.
  Future<void> _refreshPickableRevolveSketchIds() async {
    final sketchFeatures = _features.where((f) => f.type == 'sketch').toList();
    final results = await Future.wait(sketchFeatures.map((feature) async {
      final reason = await _checkExtrudeEligibility(feature);
      return MapEntry(feature.id, reason == null);
    }));
    if (!mounted || !_revolveSketchPickerActive) return;
    setState(() {
      _pickableRevolveSketchIds = {for (final entry in results) if (entry.value) entry.key};
    });
  }

  /// Mirrors [_onSketchPicked] exactly, for the Revolve picker.
  Future<void> _onRevolveSketchPicked(FeatureDto feature) async {
    final reason = await _checkExtrudeEligibility(feature);
    if (!mounted || !_revolveSketchPickerActive) return;
    if (reason != null) {
      _showSnack('This sketch has no closed profile — add more lines or close the loop first');
      return;
    }
    setState(() {
      _revolveSketchPickerActive = false;
      _featureTreeVisible = false;
      _selectedFeatureId = feature.id;
      _pickableRevolveSketchIds = {};
    });
    await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.revolve);
  }

  /// Mirrors [_cancelSketchPicker] exactly, for the Revolve picker.
  void _cancelRevolveSketchPicker() {
    setState(() {
      _revolveSketchPickerActive = false;
      _featureTreeVisible = false;
      _pickableRevolveSketchIds = {};
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
    } else if (feature.type == 'fillet') {
      // Prompt D: rollback is ended by _confirmFillet/_cancelFillet
      // instead, same "stays engaged for the panel's whole lifetime"
      // reasoning as the extrude/create_plane branches above.
      await _openFilletPanelForEdit(feature);
    } else if (feature.type == 'chamfer') {
      // Prompt E: mirrors the fillet branch above exactly.
      await _openChamferPanelForEdit(feature);
    } else if (feature.type == 'revolve') {
      // Prompt F: rollback is ended by _confirmRevolve/_cancelRevolve
      // instead, same "stays engaged for the panel's whole lifetime"
      // reasoning as the extrude branch above - mirrors that branch exactly,
      // including the defensive "couldn't open, roll forward immediately"
      // fallback.
      final opened = _openRevolvePanelForEdit(feature);
      if (!opened) await _endRollback();
    } else if (feature.type == 'sweep') {
      // Rollback is ended by _confirmSweep/_cancelSweep instead - mirrors
      // the revolve branch above exactly.
      final opened = _openSweepPanelForEdit(feature);
      if (!opened) await _endRollback();
    } else {
      // Defensive: no known editable panel for this Feature type yet
      // (every type today is handled above) - never leave rollback
      // engaged with nothing that will ever end it.
      await _endRollback();
    }
  }

  /// B4: engages true rollback - adds [rollbackIds] to
  /// [_rollbackExcludedFeatureIds], entirely separate from whatever the user
  /// already had hidden manually via [_hiddenFeatureIds] (Hide/Show,
  /// unrelated to this). Bug fix (post-C4): used to reuse [_hiddenFeatureIds]
  /// itself for this (stashing/restoring it around the edit) on the theory
  /// that "rolled back" and "hidden" meant the same thing to the backend -
  /// see [_hiddenFeatureIds]'s own doc comment for why that broke Create
  /// Plane once a Plane could depend on a hidden Body's face. No stash/
  /// restore needed anymore: [_rollbackExcludedFeatureIds] starts and ends
  /// every rollback empty, untouched by anything else.
  Future<void> _beginRollback(Set<String> rollbackIds) async {
    setState(() => _rollbackExcludedFeatureIds.addAll(rollbackIds));
    await _runGuarded(_refreshMesh);
  }

  /// B4: undoes [_beginRollback] - clears [_rollbackExcludedFeatureIds]
  /// entirely (it only ever holds rollback-only ids, nothing to preserve).
  /// A safe no-op if rollback was never engaged for this edit (editing the
  /// last Feature).
  Future<void> _endRollback() async {
    if (_rollbackExcludedFeatureIds.isEmpty) return;
    setState(() {
      _rollbackExcludedFeatureIds.clear();
      // Without this, [_visibleSketchGeometries] would stay computed
      // against the mid-rollback hidden set until some unrelated later
      // refresh happened to recompute it.
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

  /// On-device feedback: long-pressing a Body row used to directly toggle
  /// its Hide/Show state; it now opens a context menu instead, matching the
  /// same bottom-sheet style a Feature row's long-press already shows (see
  /// [showFeatureContextMenu]) - resolves [bodyId] back to the Feature that
  /// produced it via [baseFeatureId] (`body_naming.dart`) since Hide/Show is
  /// always Feature-scoped. Defensive no-op if that Feature can no longer be
  /// found (a stale [bodyId] from a mesh response that's since changed).
  Future<void> _onBodyLongPress(String bodyId) async {
    if (_busy) return;
    final feature = _featureById(baseFeatureId(bodyId));
    if (feature == null) return;

    final action = await showBodyContextMenu(
      context,
      isHidden: _hiddenFeatureIds.contains(feature.id),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case BodyContextMenuAction.toggleVisibility:
        await _toggleFeatureVisibility(feature);
    }
  }

  /// Animates the 3D camera to face this Feature's Sketch plane (per the
  /// brief's "camera animation when entering a sketch") before navigating to
  /// its 2D canvas - skips straight to navigation if the plane can't be
  /// resolved (e.g. a fetch failure), rather than blocking the open.
  Future<void> _openSketchWithAnimation(FeatureDto feature) async {
    // Bug fix: used to only animate the camera for a fixed-plane Sketch
    // (orientationFacingPlane's own ReferencePlaneKind-only signature) and
    // skip it outright for a custom one - [_sketchPlaneBasisFor]/
    // [PartViewportState.animateToBasis] now cover both the same way, so
    // this single path replaces the old plane-vs-custom branch entirely.
    // Same "can't resolve, just navigate" graceful fallback as before on a
    // fetch failure.
    SketchPlaneBasis? basis;
    try {
      basis = await _sketchPlaneBasisFor(feature);
    } catch (_) {
      basis = null;
    }
    if (!mounted) return;
    if (basis != null) {
      await _viewportKey.currentState?.animateToBasis(basis);
      if (!mounted) return;
    }
    await _openSketch(feature, basis: basis);
  }

  Future<_SketchOrientation?> _planeOfFeature(FeatureDto feature) async {
    final sketchId = feature.sketchId;
    if (sketchId == null) return null;
    try {
      final sketch = await _sketchApi.getSketch(sketchId);
      final plane = referencePlaneKindFromApiValue(sketch.plane);
      if (plane == null) return null;
      return _SketchOrientation(plane: plane, flip: sketch.flip, rotationQuarterTurns: sketch.rotationQuarterTurns);
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
    // Prompt F: Revolve's own eligibility check is the identical
    // closed-profile check Extrude's own uses (see _checkExtrudeEligibility's
    // doc comment) - reused directly rather than re-run separately. Sweep's
    // own Profile eligibility mirrors both the same way (its path is
    // checked live during path-picking, not here).
    final canRevolve = canExtrude;
    final canSweep = canExtrude;
    if (!mounted) return;

    final action = await showFeatureContextMenu(
      context,
      isHidden: _hiddenFeatureIds.contains(feature.id),
      showExtrude: isSketchFeature,
      canExtrude: canExtrude,
      extrudeDisabledReason: extrudeDisabledReason,
      showRevolve: isSketchFeature,
      canRevolve: canRevolve,
      revolveDisabledReason: extrudeDisabledReason,
      showSweep: isSketchFeature,
      canSweep: canSweep,
      sweepDisabledReason: extrudeDisabledReason,
      showRedefineOrientation: isSketchFeature,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case FeatureContextMenuAction.extrude:
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.extrude);
      case FeatureContextMenuAction.revolve:
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.revolve);
      case FeatureContextMenuAction.sweep:
        await _proceedToSketchConsumingFeature(feature, _ProfilePickerTarget.sweep);
      case FeatureContextMenuAction.redefineOrientation:
        await _redefineSketchOrientation(feature);
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
      // Bug fix: used to always show the same generic reason regardless of
      // *why* - the backend's own `detail` (e.g. "N point(s) are used by
      // more than two entities" for a branch/T-junction) is what actually
      // tells the user what to go fix, so surface it instead of discarding
      // it - see ProfileDetectionDto.detail's own doc comment.
      return profile.isExtrudable ? null : 'Sketch does not contain a closed profile: ${profile.detail}';
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
  void _openExtrudePanel(FeatureDto sketchFeature, {List<SketchEntityRefDto> profileRefs = const []}) {
    setState(() {
      _extrudeSketchFeature = sketchFeature;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = _bodies;
      _extrudeType = ExtrudeType.boss;
      _extrudeStartDistance = 0.0;
      _extrudeEndDistance = 10.0;
      _extrudeProfileRefs = profileRefs;
      _entitiesBeforeExtrude = _selectedEntities;
      _selectedEntities = {};
      // On-device feedback: a one-time default rather than the permanent
      // forced-true override this used to be (see the removed ternary at
      // this widget's own `PartViewport.selectionMode` call site) - target-
      // body picking needs Selection mode to start with, but the user must
      // still be able to toggle back to Orbit mode via the FAB (now visible
      // throughout this panel's lifetime) to look around before picking.
      _selectionMode = true;
      _selectionFilterOverrides.push(
        const SelectionFilterState(
          vertex: false,
          edge: false,
          face: false,
          body: true,
          sketchPoint: false,
          sketchLine: false,
          sketchCircle: false,
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
    final profileRefs = feature.profileRefs;

    setState(() {
      _extrudeSketchFeature = sketchFeature;
      _editingExtrudeFeatureId = feature.id;
      _previewExtrudeFeatureId = feature.id;
      _extrudeEditSnapshot = (
        type: type,
        start: start,
        end: end,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
      _meshBeforeExtrude = _bodies;
      _extrudeType = type;
      _extrudeStartDistance = start;
      _extrudeEndDistance = end;
      _extrudeProfileRefs = profileRefs;
      _entitiesBeforeExtrude = _selectedEntities;
      _selectedEntities = {
        for (final bodyId in targetBodyIds)
          SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bodyId),
      };
      // See _openExtrudePanel's own comment on this same line.
      _selectionMode = true;
      _selectionFilterOverrides.push(
        const SelectionFilterState(
          vertex: false,
          edge: false,
          face: false,
          body: true,
          sketchPoint: false,
          sketchLine: false,
          sketchCircle: false,
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
    List<SketchEntityRefDto> profileRefs,
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
        profileRefs: profileRefs,
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
        profileRefs: profileRefs,
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
            _extrudeProfileRefs,
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
        _extrudeProfileRefs,
      );
      await _refreshFeatures();
      await _refreshSketchGeometries();
    });
    if (!mounted) return;
    setState(() {
      if (sketchFeature != null && !wasEditing) {
        _hiddenFeatureIds.add(sketchFeature.id);
        // This is *the* auto-hide-on-consume case [_autoHiddenSketchFeatureIds]
        // exists for - mark it so a later event that un-consumes this
        // Sketch (deleting its Extrude) can auto-restore its visibility.
        _autoHiddenSketchFeatureIds.add(sketchFeature.id);
      }
      _recomputeVisibleSketchGeometries();
      _extrudeSketchFeature = null;
      _previewExtrudeFeatureId = null;
      _meshBeforeExtrude = null;
      _editingExtrudeFeatureId = null;
      _extrudeEditSnapshot = null;
      _extrudeProfileRefs = [];
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
      _extrudeProfileRefs = [];
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
            profileRefs: editSnapshot.profileRefs,
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

  // --- Prompt F: Revolve ---------------------------------------------------
  // A full separate mirror of the Extrude section directly above, per this
  // project's established separate-not-shared convention - see that
  // section's own doc comments for the reasoning behind each method; only
  // pointed out below where Revolve's own shape genuinely differs (the axis
  // pick alongside target-body picking).

  /// Reverse of [_sketchIdForFeatureId] - the `sketch` SketchFeature id that
  /// wraps Sketch [sketchId], or null if none is found (defensive only - a
  /// real RevolveFeature's `axis_ref.sketch_id` always names a Sketch some
  /// SketchFeature in this Part wraps). Needed (unlike Fillet/Chamfer's
  /// `SubShapeRef`, whose `body_id` already *is* what [SelectionEntityRef.
  /// bodyId] wants) because [FeatureDto.axisRef] carries the real Sketch id,
  /// while [SelectionEntityRef.sketchFeatureId] wants the *Feature* id that
  /// wraps it - the same two-different-ids distinction
  /// [_sketchIdForFeatureId] already documents, just resolved in the other
  /// direction.
  String? _sketchFeatureIdForSketchId(String sketchId) {
    for (final feature in _features) {
      if (feature.type == 'sketch' && feature.sketchId == sketchId) return feature.id;
    }
    return null;
  }

  /// The `sketchLine` entity in [_selectedEntities] - the axis pick - or
  /// null if none is picked yet. Mirrors [_currentFilletBodyId]'s own
  /// manual-loop-with-early-return style.
  SelectionEntityRef? get _revolveAxisEntity {
    for (final entity in _selectedEntities) {
      if (entity.kind == SelectionEntityKind.sketchLine) return entity;
    }
    return null;
  }

  /// [_revolveAxisEntity] converted to the wire [SketchEntityRefDto] -
  /// mirrors [_pointRefDtoFor]'s own sketchPoint branch, resolving the real
  /// Sketch id via [_sketchIdForFeatureId]. Null whenever no axis is picked
  /// yet, or (defensive only) its Sketch can no longer be resolved.
  SketchEntityRefDto? _currentRevolveAxisRef() {
    final entity = _revolveAxisEntity;
    if (entity == null) return null;
    final sketchId = _sketchIdForFeatureId(entity.sketchFeatureId);
    if (sketchId == null) return null;
    return SketchEntityRefDto(sketchId: sketchId, entityType: 'line', entityId: entity.sketchEntityId);
  }

  /// Mirrors [_currentTargetBodyIds] exactly - every `body`-kind entity in
  /// [_selectedEntities], deduplicated.
  List<String> _currentRevolveTargetBodyIds() =>
      _selectedEntities
          .where((e) => e.kind == SelectionEntityKind.body)
          .map((e) => e.bodyId)
          .toSet()
          .toList();

  /// Mirrors [_openExtrudePanel] exactly, substituting Revolve's own state
  /// fields/filter - pushes [_revolveSelectionFilter] (axis + target-body,
  /// not bodies-only) instead of Extrude's own override.
  void _openRevolvePanel(FeatureDto sketchFeature, {List<SketchEntityRefDto> profileRefs = const []}) {
    setState(() {
      _revolveSketchFeature = sketchFeature;
      _previewRevolveFeatureId = null;
      _meshBeforeRevolve = _bodies;
      _revolveMode = RevolveMode.boss;
      _revolveAngle = 180.0;
      _revolveProfileRefs = profileRefs;
      _entitiesBeforeRevolve = _selectedEntities;
      _selectedEntities = {};
      _selectionMode = true;
      _selectionFilterOverrides.push(_revolveSelectionFilter);
    });
  }

  /// Mirrors [_openExtrudePanelForEdit] exactly, substituting Revolve's own
  /// fields - prefills [_selectedEntities] with *both* the reconstructed axis
  /// entity (via [_sketchFeatureIdForSketchId], the reverse mapping
  /// [_openExtrudePanelForEdit] never needed) and the target-body entities,
  /// so the live-edit session starts from exactly what's currently stored.
  /// Returns false (doing nothing else) if [feature]'s own Sketch or axis_ref
  /// can't be resolved (defensive only - a real RevolveFeature always has
  /// both) - the caller ends true-rollback immediately in that case, same as
  /// [_openExtrudePanelForEdit].
  bool _openRevolvePanelForEdit(FeatureDto feature) {
    final sketchFeatureId = feature.sketchFeatureId;
    final sketchFeature = sketchFeatureId == null ? null : _featureById(sketchFeatureId);
    final axisRef = feature.axisRef;
    if (sketchFeature == null || axisRef == null) return false;

    final mode = RevolveMode.fromApiValue(feature.mode ?? 'boss');
    final angle = feature.angle ?? 180.0;
    final targetBodyIds = feature.targetBodyIds;
    final profileRefs = feature.profileRefs;
    final axisSketchFeatureId = _sketchFeatureIdForSketchId(axisRef.sketchId);

    setState(() {
      _revolveSketchFeature = sketchFeature;
      _editingRevolveFeatureId = feature.id;
      _previewRevolveFeatureId = feature.id;
      _revolveEditSnapshot = (
        mode: mode,
        angle: angle,
        axisRef: axisRef,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
      _meshBeforeRevolve = _bodies;
      _revolveMode = mode;
      _revolveAngle = angle;
      _revolveProfileRefs = profileRefs;
      _entitiesBeforeRevolve = _selectedEntities;
      _selectedEntities = {
        if (axisSketchFeatureId != null)
          SelectionEntityRef(
            kind: SelectionEntityKind.sketchLine,
            sketchFeatureId: axisSketchFeatureId,
            sketchEntityId: axisRef.entityId,
          ),
        for (final bodyId in targetBodyIds)
          SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bodyId),
      };
      _selectionMode = true;
      _selectionFilterOverrides.push(_revolveSelectionFilter);
    });
    return true;
  }

  /// Mirrors [_ensureExtrudeFeatureExists] exactly (the simple pattern - no
  /// preview-mesh overlay, no self-exclusion - see this section's own header
  /// comment on why Revolve doesn't need either).
  Future<void> _ensureRevolveFeatureExists(
    RevolveMode mode,
    double angle,
    SketchEntityRefDto axisRef,
    List<String> targetBodyIds,
    List<SketchEntityRefDto> profileRefs,
  ) async {
    final part = _part;
    final sketchFeature = _revolveSketchFeature;
    if (part == null || sketchFeature == null) return;

    final existingId = _previewRevolveFeatureId;
    if (existingId == null) {
      final created = await _api.createRevolveFeature(
        part.id,
        sketchFeatureId: sketchFeature.id,
        axisRef: axisRef,
        angle: angle,
        mode: mode.apiValue,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
      _previewRevolveFeatureId = created.id;
    } else {
      await _api.updateRevolveFeature(
        part.id,
        existingId,
        axisRef: axisRef,
        angle: angle,
        mode: mode.apiValue,
        targetBodyIds: targetBodyIds,
        profileRefs: profileRefs,
      );
    }
    await _refreshMesh();
  }

  /// [RevolvePanel.onChanged] - mirrors [_onExtrudeValuesChanged].
  void _onRevolveValuesChanged(RevolveMode mode, double angle) {
    _revolveMode = mode;
    _revolveAngle = angle;
    _scheduleRevolvePreview();
  }

  /// Mirrors [_scheduleExtrudePreview] exactly, except the debounced re-solve
  /// is skipped entirely whenever no axis is picked yet (mirrors Fillet/
  /// Chamfer's own "nothing to solve without at least one edge" guard) -
  /// re-checked at fire time, not at schedule time, same "always the current
  /// value" convention every other debounced field in this file already
  /// uses.
  void _scheduleRevolvePreview() {
    _revolveDebounce?.cancel();
    _revolveDebounce = Timer(const Duration(milliseconds: 500), () {
      final axisRef = _currentRevolveAxisRef();
      if (axisRef == null) return;
      _runGuarded(() => _ensureRevolveFeatureExists(
            _revolveMode,
            _revolveAngle,
            axisRef,
            _currentRevolveTargetBodyIds(),
            _revolveProfileRefs,
          ));
    });
  }

  /// Mirrors [_confirmExtrude] exactly, including the auto-hide-the-
  /// consumed-Sketch behaviour (a Revolve consumes its Sketch's Profile
  /// exactly like an Extrude does) and the unconditional restore of
  /// [_selectedEntities]/pop of the filter override.
  Future<void> _confirmRevolve() async {
    _revolveDebounce?.cancel();
    final sketchFeature = _revolveSketchFeature;
    final wasEditing = _editingRevolveFeatureId != null;
    final axisRef = _currentRevolveAxisRef();
    final targetBodyIds = _currentRevolveTargetBodyIds();
    if (axisRef != null) {
      await _runGuarded(() async {
        await _ensureRevolveFeatureExists(
          _revolveMode,
          _revolveAngle,
          axisRef,
          targetBodyIds,
          _revolveProfileRefs,
        );
        await _refreshFeatures();
        await _refreshSketchGeometries();
      });
    }
    if (!mounted) return;
    setState(() {
      if (sketchFeature != null && !wasEditing) {
        _hiddenFeatureIds.add(sketchFeature.id);
        _autoHiddenSketchFeatureIds.add(sketchFeature.id);
      }
      _recomputeVisibleSketchGeometries();
      _revolveSketchFeature = null;
      _previewRevolveFeatureId = null;
      _meshBeforeRevolve = null;
      _editingRevolveFeatureId = null;
      _revolveEditSnapshot = null;
      _revolveProfileRefs = [];
      _selectedEntities = _entitiesBeforeRevolve ?? {};
      _entitiesBeforeRevolve = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    await _endRollback();
  }

  /// Mirrors [_cancelExtrude] exactly.
  Future<void> _cancelRevolve() async {
    _revolveDebounce?.cancel();
    final part = _part;
    final sketchFeature = _revolveSketchFeature;
    final previewId = _previewRevolveFeatureId;
    final meshBefore = _meshBeforeRevolve;
    final wasEditing = _editingRevolveFeatureId != null;
    final editSnapshot = _revolveEditSnapshot;
    setState(() {
      _revolveSketchFeature = null;
      _previewRevolveFeatureId = null;
      _meshBeforeRevolve = null;
      _editingRevolveFeatureId = null;
      _revolveEditSnapshot = null;
      _revolveProfileRefs = [];
      _selectedEntities = _entitiesBeforeRevolve ?? {};
      _entitiesBeforeRevolve = null;
      _selectionFilterOverrides.pop();
      if (sketchFeature != null && _selectedFeatureId == sketchFeature.id) {
        _selectedFeatureId = null;
      }
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateRevolveFeature(
            part.id,
            previewId,
            axisRef: editSnapshot.axisRef,
            angle: editSnapshot.angle,
            mode: editSnapshot.mode.apiValue,
            targetBodyIds: editSnapshot.targetBodyIds,
            profileRefs: editSnapshot.profileRefs,
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

  /// Mirrors [_targetBodyPickerBannerText], prefixed with the axis-pick
  /// status since Revolve's banner has two things to report rather than
  /// Extrude's one.
  String _revolvePickerBannerText() {
    final axisText = _revolveAxisEntity == null ? 'Select an axis line' : 'Axis selected';
    final count = _currentRevolveTargetBodyIds().length;
    final bodyText = _revolveMode == RevolveMode.cut
        ? (count == 0 ? 'select a target body' : '$count target body/bodies selected')
        : (count == 0 ? 'tap bodies to merge into (optional)' : '$count target body/bodies selected');
    return '$axisText, $bodyText';
  }

  // --- C2: Create Plane -----------------------------------------------------

  /// [SelectionContextPanel.onCreatePlane]'s callback - re-derives which of
  /// the three flows applies from [_selectedEntities]' current shape, the
  /// same check `selection_actions.dart`'s `contextActionsFor` already used
  /// to decide the button should be enabled in the first place (so this is
  /// never reached for any other selection shape).
  void _onCreatePlaneTapped() {
    final faces = _selectedEntities.where((e) => e.kind == SelectionEntityKind.face).toList();
    final edges = _selectedEntities.where((e) => e.kind == SelectionEntityKind.edge).toList();
    final vertices = _selectedEntities.where((e) => e.kind == SelectionEntityKind.vertex).toList();
    final points = _selectedEntities.where((e) => e.kind == SelectionEntityKind.sketchPoint).toList();
    final lines = _selectedEntities.where((e) => e.kind == SelectionEntityKind.sketchLine).toList();
    // C5: a fixed reference plane or an existing Plane is "plane-like" for
    // the same three combos a Body face already was - see
    // `selection_actions.dart`'s own `planeLikeCount`, which this mirrors
    // exactly (same precedence, same combo shapes).
    final referencePlanes = _selectedEntities.where((e) => e.kind == SelectionEntityKind.referencePlane);
    final createPlanes = _selectedEntities.where((e) => e.kind == SelectionEntityKind.createPlane);
    final planeLikes = [...faces, ...referencePlanes, ...createPlanes];

    // C4: exactly three points total (any mix of Body Vertices and Sketch
    // Points) - checked first, same precedence `selection_actions.dart`'s
    // `contextActionsFor` already gives this combo over the single-line-
    // plus-point/single-face checks below.
    if (vertices.length + points.length == 3 && _selectedEntities.length == 3) {
      _openCreatePlanePanel(mode: CreatePlaneMode.threePoints, pointEntities: [...vertices, ...points]);
      return;
    }
    if (planeLikes.length == 1 && _selectedEntities.length == 1) {
      _openCreatePlanePanel(mode: CreatePlaneMode.offsetFace, faceEntities: planeLikes);
      return;
    }
    if (planeLikes.length == 2 && _selectedEntities.length == 2) {
      _openCreatePlanePanel(mode: CreatePlaneMode.midplane, faceEntities: planeLikes);
      return;
    }
    // C4: exactly one Edge and one Vertex - Normal to Edge Through Vertex.
    if (edges.length == 1 && vertices.length == 1 && _selectedEntities.length == 2) {
      _openCreatePlanePanel(
        mode: CreatePlaneMode.normalToEdgeThroughVertex,
        edgeEntity: edges.single,
        vertexEntity: vertices.single,
      );
      return;
    }
    // C4/C5: exactly one plane-like entity and one Vertex - Parallel to
    // Face Through Vertex.
    if (planeLikes.length == 1 && vertices.length == 1 && _selectedEntities.length == 2) {
      _openCreatePlanePanel(
        mode: CreatePlaneMode.parallelToFaceThroughVertex,
        faceEntities: planeLikes,
        vertexEntity: vertices.single,
      );
      return;
    }
    if (points.length == 1 && lines.length == 1) {
      _openCreatePlanePanel(
        mode: CreatePlaneMode.normalToLineAtPoint,
        lineEntity: lines.single,
        pointEntity: points.single,
      );
    }
  }

  /// On-device feedback: "New Sketch on Face" - unlike [_onCreatePlaneTapped],
  /// this skips [CreatePlanePanel] entirely (the created Plane is a byproduct
  /// here, not something the user needs to review/adjust) and goes straight
  /// from "one face selected" to the same orientation-confirm step any
  /// plane-based new sketch already gets, via [_addSketchFeature]'s own
  /// [planeFeatureId] path. Always zero offset - "sketch flush against this
  /// face" is the whole point, not an offset plane; `contextActionsFor`
  /// only ever offers this button for exactly one selected Body face, so
  /// the length check here is defensive, not a real gate.
  ///
  /// Deliberately NOT wrapped in a single [_runGuarded] call spanning both
  /// steps: [_addSketchFeature] starts with `if (part == null || _busy)
  /// return;` and calls [_runGuarded] itself - nesting it inside an
  /// already-busy guard would make that check silently bail out.
  Future<void> _onNewSketchOnFaceTapped() async {
    final faces = _selectedEntities.where((e) => e.kind == SelectionEntityKind.face).toList();
    if (faces.length != 1) return;
    final part = _part;
    if (part == null) return;
    final faceEntity = faces.single;
    setState(() => _selectedEntities = {});

    FeatureDto? planeFeature;
    await _runGuarded(() async {
      planeFeature = await _api.createCreatePlaneFeature(
        part.id,
        planeType: 'offset_face',
        faceRefs: [_planeRefDtoFor(faceEntity)],
        offset: 0.0,
      );
      await _refreshFeatures();
    });
    final feature = planeFeature;
    if (feature == null || !mounted) return;
    await _addSketchFeature(planeFeatureId: feature.id);
  }

  /// On-device feedback (bug fix): "New Sketch" for a lone reference plane
  /// or existing Plane selected via [SelectionContextPanel] (Selection
  /// mode) - the same operation [_onPlaneTap]/[_onCreatePlaneFeatureTap]'s
  /// own tap-to-sheet flow already offers outside Selection mode
  /// ([_showPlaneContextSheet]/[_showCreatePlaneContextSheet]), just
  /// reachable from this panel too so both selection paths behave the
  /// same regardless of mode - see `selection_actions.dart`'s own
  /// `contextActionsFor` doc comment for why that panel used to silently
  /// drop this option for a plane-like (non-face) selection.
  Future<void> _onNewSketchTapped() async {
    final referencePlanes =
        _selectedEntities.where((e) => e.kind == SelectionEntityKind.referencePlane).toList();
    final createPlanes =
        _selectedEntities.where((e) => e.kind == SelectionEntityKind.createPlane).toList();
    if (referencePlanes.length + createPlanes.length != 1 || _selectedEntities.length != 1) return;
    setState(() => _selectedEntities = {});
    if (referencePlanes.isNotEmpty) {
      await _addSketchFeature(plane: referencePlanes.single.referencePlaneKind);
    } else {
      await _addSketchFeature(planeFeatureId: createPlanes.single.planeFeatureId);
    }
  }

  /// C4: converts a selected [SelectionEntityRef] into a [PointRefDto] for
  /// [CreatePlaneMode.threePoints] - a Body Vertex ([SelectionEntityKind.
  /// vertex], identified by [SelectionEntityRef.bodyId]/[SelectionEntityRef.id])
  /// or a Sketch Point ([SelectionEntityKind.sketchPoint], identified by
  /// [SelectionEntityRef.sketchFeatureId]/[SelectionEntityRef.sketchEntityId],
  /// resolved to a real Sketch id via [_sketchIdForFeatureId] the same way
  /// the normal-to-line-at-point flow already does) - never anything else,
  /// since [_onCreatePlaneTapped]'s own pool for this mode is exactly those
  /// two kinds.
  PointRefDto? _pointRefDtoFor(SelectionEntityRef entity) {
    if (entity.kind == SelectionEntityKind.vertex) {
      return PointRefDto(
        vertexRef: SubShapeRefDto(bodyId: entity.bodyId, shapeType: 'vertex', index: entity.id),
      );
    }
    assert(entity.kind == SelectionEntityKind.sketchPoint);
    final sketchId = _sketchIdForFeatureId(entity.sketchFeatureId);
    if (sketchId == null) return null; // Defensive - see _sketchIdForFeatureId's own doc comment.
    return PointRefDto(
      sketchPointRef: SketchEntityRefDto(
        sketchId: sketchId,
        entityType: 'point',
        entityId: entity.sketchEntityId,
      ),
    );
  }

  /// C5: converts a selected [SelectionEntityRef] into a [PlaneRefDto] for
  /// [CreatePlaneMode.offsetFace]/[CreatePlaneMode.midplane]/
  /// [CreatePlaneMode.parallelToFaceThroughVertex]'s `faceEntities` - a Body
  /// Face ([SelectionEntityKind.face]), a fixed reference plane
  /// ([SelectionEntityKind.referencePlane]), or an existing Plane
  /// ([SelectionEntityKind.createPlane]) - never anything else, since
  /// [_onCreatePlaneTapped]'s own pool for these three modes is exactly
  /// those three kinds (mirrors [_pointRefDtoFor]'s own doc comment).
  PlaneRefDto _planeRefDtoFor(SelectionEntityRef entity) {
    if (entity.kind == SelectionEntityKind.referencePlane) {
      return PlaneRefDto(fixedPlane: entity.referencePlaneKind!.apiValue);
    }
    if (entity.kind == SelectionEntityKind.createPlane) {
      return PlaneRefDto(planeFeatureId: entity.planeFeatureId);
    }
    assert(entity.kind == SelectionEntityKind.face);
    return PlaneRefDto(
      faceRef: SubShapeRefDto(bodyId: entity.bodyId, shapeType: 'face', index: entity.id),
    );
  }

  /// Creates the CreatePlaneFeature eagerly (mirrors [_ensureExtrudeFeatureExists]'s
  /// "create on open" pattern) from whichever refs [_onCreatePlaneTapped]
  /// resolved. Stashes/clears [_selectedEntities] the same way
  /// [_openExtrudePanel] does for target-body picking, since the
  /// face(s)/line/point that triggered this is baked into the created
  /// Feature, not something the user keeps adjusting in the viewport
  /// afterward. [faceEntities] has exactly one entry for [CreatePlaneMode.
  /// offsetFace]/[CreatePlaneMode.parallelToFaceThroughVertex] or exactly two
  /// for [CreatePlaneMode.midplane] (C3). C4: [edgeEntity]/[vertexEntity] are
  /// only meaningful for [CreatePlaneMode.normalToEdgeThroughVertex]/
  /// [CreatePlaneMode.parallelToFaceThroughVertex]; [pointEntities] (exactly
  /// three, each a Vertex or a Sketch Point) only for [CreatePlaneMode.
  /// threePoints].
  Future<void> _openCreatePlanePanel({
    required CreatePlaneMode mode,
    List<SelectionEntityRef> faceEntities = const [],
    SelectionEntityRef? lineEntity,
    SelectionEntityRef? pointEntity,
    SelectionEntityRef? edgeEntity,
    SelectionEntityRef? vertexEntity,
    List<SelectionEntityRef> pointEntities = const [],
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
        final faceRefs = faceEntities.map(_planeRefDtoFor).toList();
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: mode == CreatePlaneMode.offsetFace ? 'offset_face' : 'midplane',
          faceRefs: faceRefs,
          offset: mode == CreatePlaneMode.offsetFace ? _createPlaneOffset : null,
        );
      } else if (mode == CreatePlaneMode.normalToEdgeThroughVertex) {
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: 'normal_to_edge_through_vertex',
          edgeRef: SubShapeRefDto(bodyId: edgeEntity!.bodyId, shapeType: 'edge', index: edgeEntity.id),
          vertexRef: SubShapeRefDto(bodyId: vertexEntity!.bodyId, shapeType: 'vertex', index: vertexEntity.id),
        );
      } else if (mode == CreatePlaneMode.parallelToFaceThroughVertex) {
        final faceRefs = faceEntities.map(_planeRefDtoFor).toList();
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: 'parallel_to_face_through_vertex',
          faceRefs: faceRefs,
          vertexRef: SubShapeRefDto(bodyId: vertexEntity!.bodyId, shapeType: 'vertex', index: vertexEntity.id),
        );
      } else if (mode == CreatePlaneMode.threePoints) {
        final pointRefs = pointEntities.map(_pointRefDtoFor).toList();
        if (pointRefs.any((ref) => ref == null)) return; // Defensive - see _pointRefDtoFor's own doc comment.
        feature = await _api.createCreatePlaneFeature(
          part.id,
          planeType: 'three_points',
          pointRefs: pointRefs.cast<PointRefDto>(),
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
      'normal_to_edge_through_vertex' => CreatePlaneMode.normalToEdgeThroughVertex,
      'parallel_to_face_through_vertex' => CreatePlaneMode.parallelToFaceThroughVertex,
      'three_points' => CreatePlaneMode.threePoints,
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
        edgeRef: feature.edgeRef,
        vertexRef: feature.vertexRef,
        pointRefs: feature.pointRefs,
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
            edgeRef: editSnapshot.edgeRef,
            vertexRef: editSnapshot.vertexRef,
            pointRefs: editSnapshot.pointRefs,
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

  // --- Prompt D: Fillet -------------------------------------------------

  /// On-device feedback: the "Add" FAB's Feature picker's "Fillet" entry -
  /// mirrors [_startPlanePicker]'s shape (clear selection, force Selection
  /// mode, hint what to pick) - just [_openFilletPanel] with no edges yet,
  /// so the [FilletPanel] itself (radius field, Confirm/Cancel) flies up
  /// immediately rather than waiting for a separate "edges picked, now tap
  /// the ambient Fillet button" step (on-device feedback: the old
  /// picker-then-hand-off shape made the FAB entry feel like it hadn't
  /// actually done anything until that extra tap). No Feature exists until
  /// the first edge is actually picked - see [_ensureFilletFeatureExists]'s
  /// create-or-update branching, mirroring [_ensureExtrudeFeatureExists].
  void _startFilletPicker() {
    _openFilletPanel(edgeEntities: const []);
  }

  /// [SelectionContextPanel.onFillet]'s callback - `contextActionsFor` only
  /// ever enables this button for a selection that's one or more edges, all
  /// on the same Body, so there is no combination to re-derive the way
  /// [_onCreatePlaneTapped] has to for its own six flows.
  void _onFilletTapped() {
    final edges = _selectedEntities.where((e) => e.kind == SelectionEntityKind.edge).toList();
    _openFilletPanel(edgeEntities: edges);
  }

  /// Opens [FilletPanel] immediately, whether [edgeEntities] is empty (the
  /// "Add" FAB's guided entry - see [_startFilletPicker]) or already has
  /// edges (the ambient [SelectionContextPanel] button - see
  /// [_onFilletTapped]). No FilletFeature is created yet when
  /// [edgeEntities] is empty - there is nothing valid to create until at
  /// least one edge is picked - so this returns right after opening the
  /// panel in that case; [_ensureFilletFeatureExists] (via
  /// [_scheduleFilletPreview], fired by the first edge/face-loop tap) is
  /// what actually creates it, mirroring [_ensureExtrudeFeatureExists]'s own
  /// create-or-update branching.
  ///
  /// On-device feedback: the edge selection stays *live* for the panel's
  /// whole session - [_selectedEntities] keeps [edgeEntities] (rather than
  /// being cleared to `{}`) and a [_filletSelectionFilter] override is
  /// pushed, mirroring [_openExtrudePanel]'s live target-body picking
  /// exactly. Every subsequent edge/face-loop tap ([_toggleSelectedEntity]/
  /// [_toggleFilletFaceEdges]) reschedules [_scheduleFilletPreview] the same
  /// way a target-body tap reschedules [_scheduleExtrudePreview] - this is
  /// what actually lets edges be added to/removed from an in-progress
  /// Fillet, on both the create and (via [_openFilletPanelForEdit]) edit
  /// paths.
  Future<void> _openFilletPanel({required List<SelectionEntityRef> edgeEntities}) async {
    final part = _part;
    if (part == null) return;
    setState(() {
      _filletActive = true;
      _entitiesBeforeFillet = _selectedEntities;
      _selectedEntities = edgeEntities.toSet();
      _filletRadius = 1.0;
      _selectionMode = true;
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _selectionFilterOverrides.push(_filletSelectionFilter);
    });
    if (edgeEntities.isEmpty) return;
    await _runGuarded(() => _ensureFilletFeatureExists(_filletRadius, _currentFilletEdgeRefs()));
    if (_previewFilletFeatureId == null && mounted) {
      // Creation failed (e.g. mixed_body_selection/fillet_failed -
      // _errorMessage is already set by _runGuarded) - nothing to edit, so
      // close the panel back out rather than leaving it stuck open with no
      // real Feature behind it. Never reached for the empty-edges (Add FAB)
      // case above, since that returns before ever attempting a create.
      setState(() {
        _filletActive = false;
        _selectedEntities = _entitiesBeforeFillet ?? {};
        _entitiesBeforeFillet = null;
        _selectionFilterOverrides.pop();
      });
    }
  }

  /// B4: opens [FilletPanel] to edit an *already-existing* FilletFeature -
  /// mirrors [_openCreatePlanePanelForEdit], but unlike Create Plane, a
  /// Fillet actually modifies its target Body's shape in place, so the Body
  /// shown while editing must exclude *this* Fillet's own contribution -
  /// otherwise the viewport shows the already-filleted body and its
  /// original (pre-fillet) edges are gone, so they can't be added to/
  /// removed from the selection. [_onFeatureTap]'s preamble already rolls
  /// back Features *after* this one; this adds the tapped Fillet itself to
  /// the same [_rollbackExcludedFeatureIds] set (additive - see
  /// [_beginRollback]), relying on [_confirmFillet]/[_cancelFillet]'s
  /// existing [_endRollback] call to clear the whole set again once the
  /// panel closes.
  ///
  /// On-device feedback: [_selectedEntities] is now seeded with [feature]'s
  /// own current `edgeRefs` (rather than cleared to `{}`), and the same
  /// [_filletSelectionFilter] override [_openFilletPanel] pushes is pushed
  /// here too - the rolled-back body's original edges are both visible
  /// (thanks to the `_beginRollback` above) and now actually live-editable,
  /// which is the other half of the on-device "edges can't be added/
  /// removed" report the rollback fix alone didn't cover.
  Future<void> _openFilletPanelForEdit(FeatureDto feature) async {
    final radius = feature.radius ?? 1.0;
    setState(() {
      _filletActive = true;
      _editingFilletFeatureId = feature.id;
      _previewFilletFeatureId = feature.id;
      _filletRadius = radius;
      _filletEditSnapshot = (edgeRefs: feature.edgeRefs, radius: radius);
      _entitiesBeforeFillet = _selectedEntities;
      _selectedEntities = {
        for (final ref in feature.edgeRefs)
          SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: ref.bodyId, id: ref.index),
      };
      _selectionMode = true;
      _selectionFilterOverrides.push(_filletSelectionFilter);
    });
    await _beginRollback({feature.id});
  }

  /// [_selectedEntities]' edges while [_filletActive] - always
  /// [SelectionEntityKind.edge] entries only, mirroring
  /// [_currentTargetBodyIds] exactly (both flows force their own kind-only
  /// filter for the panel's whole lifetime, so nothing else ever ends up in
  /// here).
  List<SubShapeRefDto> _currentFilletEdgeRefs() => [
        for (final entity in _selectedEntities)
          if (entity.kind == SelectionEntityKind.edge)
            SubShapeRefDto(bodyId: entity.bodyId, shapeType: 'edge', index: entity.id),
      ];

  /// The Body id [_refreshFilletPreviewMesh] should fetch a preview for -
  /// any selected edge's `bodyId` (every edge in [_selectedEntities] shares
  /// one, same guarantee [_currentFilletEdgeRefs] relies on), or null if
  /// nothing is selected yet (nothing to preview).
  String? _currentFilletBodyId() {
    for (final entity in _selectedEntities) {
      if (entity.kind == SelectionEntityKind.edge) return entity.bodyId;
    }
    return null;
  }

  /// [FilletPanel.onRadiusChanged] - records the latest radius immediately
  /// (so [_confirmFillet]/[_cancelFillet] always have it, even mid-
  /// debounce) and (re)starts the same 500ms debounce
  /// [_toggleSelectedEntity]'s edge/face-loop taps also feed into, mirroring
  /// [_onExtrudeValuesChanged]/[_scheduleExtrudePreview]'s shared-debounce
  /// shape exactly.
  void _onFilletRadiusChanged(double radius) {
    _filletRadius = radius;
    _scheduleFilletPreview();
  }

  /// Shared by [_onFilletRadiusChanged] (a radius edit) and
  /// [_toggleSelectedEntity]/[_toggleFilletFaceEdges] (an edge pick
  /// changed) - either kind of change debounces the same live-preview
  /// re-solve, using whichever the *other* kind's latest value currently
  /// is.
  void _scheduleFilletPreview() {
    _filletDebounce?.cancel();
    _filletDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(() => _ensureFilletFeatureExists(_filletRadius, _currentFilletEdgeRefs()));
    });
  }

  /// Creates the preview FilletFeature on the first call with 1+ edges
  /// (mirrors [_ensureExtrudeFeatureExists]'s create-or-update branching -
  /// the "Add" FAB's [_startFilletPicker] opens the panel with no edges and
  /// nothing to create yet), or PATCHes the one already created/being
  /// edited on every later call, then refetches Features and mesh - shared
  /// by [_openFilletPanel]'s own initial attempt and every
  /// [_scheduleFilletPreview] debounce fire after. Skips the request
  /// entirely once [edgeRefs] is empty - the backend rejects an empty
  /// `edge_refs` with 422 either way, and "no edges picked/selected yet" is
  /// a normal state (both right after opening from the FAB, and mid-edit if
  /// every edge is briefly deselected), not an error worth surfacing.
  ///
  /// This whole method - the self-exclusion on create, the concurrent
  /// [_refreshFilletPreviewMesh] fetch - is the reference implementation
  /// for "a Feature that live-edits sub-shape picks of the Body it's
  /// modifying"; see `docs/live-preview-pattern.md` before building the
  /// same shape for Chamfer or anything else, rather than re-deriving it
  /// (or missing the self-exclusion bug this now guards against) from
  /// scratch.
  Future<void> _ensureFilletFeatureExists(double radius, List<SubShapeRefDto> edgeRefs) async {
    final part = _part;
    if (part == null || edgeRefs.isEmpty) return;
    final existingId = _previewFilletFeatureId;
    if (existingId == null) {
      final feature = await _api.createFilletFeature(part.id, edgeRefs: edgeRefs, radius: radius);
      _previewFilletFeatureId = feature.id;
      // Bug fix (on-device feedback): a newly-created Fillet must exclude
      // its *own* effect from every mesh refresh for the rest of this
      // live-edit session, exactly like _openFilletPanelForEdit already
      // does for an already-existing one (via _beginRollback - inlined
      // here, not called directly, since this whole function already runs
      // inside a _runGuarded call and _beginRollback wraps its own) -
      // otherwise the refresh below shows the *post*-fillet body, whose
      // edges are a new topology (the fillet's own rounded faces/edges
      // replacing the straight ones) with different ids from the
      // pre-fillet body `edge_refs` still needs to reference. The next edge
      // pick/removal would then send an edge id that only exists in that
      // post-fillet mesh, which `resolve_fillet`'s own self-exclusion
      // validates against the *pre*-fillet body instead - producing
      // exactly the "missing_reference" 422 this fixes (the reported
      // symptom: editing the selection "removes edges the fillet tool is
      // using"). Real filleted geometry is only ever shown again once
      // _confirmFillet's _endRollback() clears this exclusion.
      setState(() => _rollbackExcludedFeatureIds.add(feature.id));
      await _refreshFeatures();
      await Future.wait([_refreshMesh(), _refreshFilletPreviewMesh()]);
    } else {
      await _api.updateFilletFeature(part.id, existingId, edgeRefs: edgeRefs, radius: radius);
      await _refreshFeatures();
      await Future.wait([_refreshMesh(), _refreshFilletPreviewMesh()]);
    }
  }

  /// On-device feedback: fetches the *actual* current effect of the
  /// in-progress Fillet - the same `/mesh` endpoint [_refreshMesh] calls,
  /// but with this Feature's own id *not* excluded (the opposite of
  /// [_refreshMesh]'s own `_rollbackExcludedFeatureIds`, which must keep
  /// excluding it so [_bodies] stays the stable, pickable pre-fillet body -
  /// see [_ensureFilletFeatureExists]) - purely to have something to render
  /// as a visual preview (see [PartViewport.previewOverlayMesh]). Run
  /// alongside [_refreshMesh] via `Future.wait` (see
  /// [_ensureFilletFeatureExists]) rather than after it, so this doesn't
  /// double the live-preview round-trip latency on top of doubling the
  /// backend's recompute work.
  ///
  /// Bug fix (on-device feedback): mirrors [_refreshMesh]'s own fix - this
  /// used to mutate [_filletPreviewBodyId]/[_filletPreviewMesh] with no
  /// `setState` of its own, so the live rounded-corner visual could just as
  /// easily be left stale pending an unrelated later repaint. Now
  /// self-contained.
  Future<void> _refreshFilletPreviewMesh() async {
    final part = _part;
    final featureId = _previewFilletFeatureId;
    final bodyId = _currentFilletBodyId();
    if (part == null || featureId == null || bodyId == null) {
      if (!mounted) return;
      setState(() {
        _filletPreviewBodyId = null;
        _filletPreviewMesh = null;
      });
      return;
    }
    final response = await _api.getPartMesh(
      part.id,
      hiddenFeatureIds: _hiddenFeatureIds.toList(),
      rollbackExcludedFeatureIds:
          _rollbackExcludedFeatureIds.where((id) => id != featureId).toList(),
    );
    if (!mounted) return;
    BodyMeshDto? match;
    for (final body in response) {
      if (body.bodyId == bodyId) {
        match = body;
        break;
      }
    }
    setState(() {
      _filletPreviewBodyId = bodyId;
      _filletPreviewMesh = match?.mesh;
    });
  }

  /// Keeps the just-created/edited Feature, restores whatever was selected
  /// before the panel opened, and rolls B4 rollback forward - mirrors
  /// [_confirmCreatePlane] exactly, plus popping the
  /// [_filletSelectionFilter] override [_openFilletPanel]/
  /// [_openFilletPanelForEdit] pushed.
  Future<void> _confirmFillet() async {
    _filletDebounce?.cancel();
    setState(() {
      _filletActive = false;
      _selectedEntities = _entitiesBeforeFillet ?? {};
      _entitiesBeforeFillet = null;
      _previewFilletFeatureId = null;
      _editingFilletFeatureId = null;
      _filletEditSnapshot = null;
      _selectionFilterOverrides.pop();
      _filletPreviewBodyId = null;
      _filletPreviewMesh = null;
    });
    await _endRollback();
  }

  /// Deletes the just-created preview Feature (new-Fillet flow) or PATCHes
  /// [_filletEditSnapshot]'s stashed original values back (edit flow) -
  /// mirrors [_cancelCreatePlane]'s structure exactly, plus popping the
  /// filter override the same way [_confirmFillet] does.
  Future<void> _cancelFillet() async {
    _filletDebounce?.cancel();
    final part = _part;
    final previewId = _previewFilletFeatureId;
    final wasEditing = _editingFilletFeatureId != null;
    final editSnapshot = _filletEditSnapshot;
    setState(() {
      _filletActive = false;
      _selectedEntities = _entitiesBeforeFillet ?? {};
      _entitiesBeforeFillet = null;
      _previewFilletFeatureId = null;
      _editingFilletFeatureId = null;
      _filletEditSnapshot = null;
      _selectionFilterOverrides.pop();
      _filletPreviewBodyId = null;
      _filletPreviewMesh = null;
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateFilletFeature(
            part.id,
            previewId,
            edgeRefs: editSnapshot.edgeRefs,
            radius: editSnapshot.radius,
          );
          await _refreshFeatures();
          await _refreshMesh();
        });
      } else {
        await _runGuarded(() async {
          await _api.deleteFeature(part.id, previewId);
          await _refreshFeatures();
          await _refreshMesh();
        });
      }
    }
    await _endRollback();
  }

  // --- Prompt E: Chamfer -------------------------------------------------
  // Mirrors the entire Fillet section directly above, method for method -
  // see that section's own doc comments for the full reasoning behind each
  // one; only pointed out below where Chamfer's own shape differs.

  /// Mirrors [_startFilletPicker] exactly.
  void _startChamferPicker() {
    _openChamferPanel(edgeEntities: const []);
  }

  /// Mirrors [_onFilletTapped] exactly.
  void _onChamferTapped() {
    final edges = _selectedEntities.where((e) => e.kind == SelectionEntityKind.edge).toList();
    _openChamferPanel(edgeEntities: edges);
  }

  /// Mirrors [_openFilletPanel] exactly, substituting Chamfer's own state
  /// fields/filter/methods for Fillet's.
  Future<void> _openChamferPanel({required List<SelectionEntityRef> edgeEntities}) async {
    final part = _part;
    if (part == null) return;
    setState(() {
      _chamferActive = true;
      _entitiesBeforeChamfer = _selectedEntities;
      _selectedEntities = edgeEntities.toSet();
      _chamferDistance = 1.0;
      _selectionMode = true;
      _toolbarOpen = false;
      _featureTreeVisible = false;
      _selectionFilterOverrides.push(_chamferSelectionFilter);
    });
    if (edgeEntities.isEmpty) return;
    await _runGuarded(() => _ensureChamferFeatureExists(_chamferDistance, _currentChamferEdgeRefs()));
    if (_previewChamferFeatureId == null && mounted) {
      setState(() {
        _chamferActive = false;
        _selectedEntities = _entitiesBeforeChamfer ?? {};
        _entitiesBeforeChamfer = null;
        _selectionFilterOverrides.pop();
      });
    }
  }

  /// Mirrors [_openFilletPanelForEdit] exactly.
  Future<void> _openChamferPanelForEdit(FeatureDto feature) async {
    final distance = feature.distance ?? 1.0;
    setState(() {
      _chamferActive = true;
      _editingChamferFeatureId = feature.id;
      _previewChamferFeatureId = feature.id;
      _chamferDistance = distance;
      _chamferEditSnapshot = (edgeRefs: feature.edgeRefs, distance: distance);
      _entitiesBeforeChamfer = _selectedEntities;
      _selectedEntities = {
        for (final ref in feature.edgeRefs)
          SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: ref.bodyId, id: ref.index),
      };
      _selectionMode = true;
      _selectionFilterOverrides.push(_chamferSelectionFilter);
    });
    await _beginRollback({feature.id});
  }

  /// Mirrors [_currentFilletEdgeRefs] exactly.
  List<SubShapeRefDto> _currentChamferEdgeRefs() => [
        for (final entity in _selectedEntities)
          if (entity.kind == SelectionEntityKind.edge)
            SubShapeRefDto(bodyId: entity.bodyId, shapeType: 'edge', index: entity.id),
      ];

  /// Mirrors [_currentFilletBodyId] exactly.
  String? _currentChamferBodyId() {
    for (final entity in _selectedEntities) {
      if (entity.kind == SelectionEntityKind.edge) return entity.bodyId;
    }
    return null;
  }

  /// Mirrors [_onFilletRadiusChanged] exactly.
  void _onChamferDistanceChanged(double distance) {
    _chamferDistance = distance;
    _scheduleChamferPreview();
  }

  /// Mirrors [_scheduleFilletPreview] exactly.
  void _scheduleChamferPreview() {
    _chamferDebounce?.cancel();
    _chamferDebounce = Timer(const Duration(milliseconds: 500), () {
      _runGuarded(() => _ensureChamferFeatureExists(_chamferDistance, _currentChamferEdgeRefs()));
    });
  }

  /// Mirrors [_ensureFilletFeatureExists] exactly, including the same
  /// self-exclusion-on-create fix and concurrent preview-mesh fetch - see
  /// that method's own doc comment (and `docs/live-preview-pattern.md`) for
  /// the full reasoning.
  Future<void> _ensureChamferFeatureExists(double distance, List<SubShapeRefDto> edgeRefs) async {
    final part = _part;
    if (part == null || edgeRefs.isEmpty) return;
    final existingId = _previewChamferFeatureId;
    if (existingId == null) {
      final feature =
          await _api.createChamferFeature(part.id, edgeRefs: edgeRefs, distance: distance);
      _previewChamferFeatureId = feature.id;
      setState(() => _rollbackExcludedFeatureIds.add(feature.id));
      await _refreshFeatures();
      await Future.wait([_refreshMesh(), _refreshChamferPreviewMesh()]);
    } else {
      await _api.updateChamferFeature(part.id, existingId, edgeRefs: edgeRefs, distance: distance);
      await _refreshFeatures();
      await Future.wait([_refreshMesh(), _refreshChamferPreviewMesh()]);
    }
  }

  /// Mirrors [_refreshFilletPreviewMesh] exactly.
  ///
  /// Bug fix (on-device feedback): mirrors [_refreshFilletPreviewMesh]'s own
  /// fix - self-contained `setState` now, rather than relying on an
  /// unrelated later repaint to flush it.
  Future<void> _refreshChamferPreviewMesh() async {
    final part = _part;
    final featureId = _previewChamferFeatureId;
    final bodyId = _currentChamferBodyId();
    if (part == null || featureId == null || bodyId == null) {
      if (!mounted) return;
      setState(() {
        _chamferPreviewBodyId = null;
        _chamferPreviewMesh = null;
      });
      return;
    }
    final response = await _api.getPartMesh(
      part.id,
      hiddenFeatureIds: _hiddenFeatureIds.toList(),
      rollbackExcludedFeatureIds:
          _rollbackExcludedFeatureIds.where((id) => id != featureId).toList(),
    );
    if (!mounted) return;
    BodyMeshDto? match;
    for (final body in response) {
      if (body.bodyId == bodyId) {
        match = body;
        break;
      }
    }
    setState(() {
      _chamferPreviewBodyId = bodyId;
      _chamferPreviewMesh = match?.mesh;
    });
  }

  /// Mirrors [_confirmFillet] exactly.
  Future<void> _confirmChamfer() async {
    _chamferDebounce?.cancel();
    setState(() {
      _chamferActive = false;
      _selectedEntities = _entitiesBeforeChamfer ?? {};
      _entitiesBeforeChamfer = null;
      _previewChamferFeatureId = null;
      _editingChamferFeatureId = null;
      _chamferEditSnapshot = null;
      _selectionFilterOverrides.pop();
      _chamferPreviewBodyId = null;
      _chamferPreviewMesh = null;
    });
    await _endRollback();
  }

  /// Mirrors [_cancelFillet] exactly.
  Future<void> _cancelChamfer() async {
    _chamferDebounce?.cancel();
    final part = _part;
    final previewId = _previewChamferFeatureId;
    final wasEditing = _editingChamferFeatureId != null;
    final editSnapshot = _chamferEditSnapshot;
    setState(() {
      _chamferActive = false;
      _selectedEntities = _entitiesBeforeChamfer ?? {};
      _entitiesBeforeChamfer = null;
      _previewChamferFeatureId = null;
      _editingChamferFeatureId = null;
      _chamferEditSnapshot = null;
      _selectionFilterOverrides.pop();
      _chamferPreviewBodyId = null;
      _chamferPreviewMesh = null;
    });
    if (part != null && previewId != null) {
      if (wasEditing && editSnapshot != null) {
        await _runGuarded(() async {
          await _api.updateChamferFeature(
            part.id,
            previewId,
            edgeRefs: editSnapshot.edgeRefs,
            distance: editSnapshot.distance,
          );
          await _refreshFeatures();
          await _refreshMesh();
        });
      } else {
        await _runGuarded(() async {
          await _api.deleteFeature(part.id, previewId);
          await _refreshFeatures();
          await _refreshMesh();
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

  /// Cascade-deletes [feature] and every Feature that actually transitively
  /// depends on it (the real dependency graph - B2), once the user
  /// confirms exactly which ones will go.
  ///
  /// On-device feedback: this used to assume "every Feature at and after
  /// [feature]'s index in the list" - true only for the pre-B2 world where
  /// list order and dependency order always coincided (every single-body
  /// Part before A1's multi-body model). A Sketch feeding two independent
  /// Extrudes, or a Feature with no real dependents at all, could already
  /// show the wrong warning - naming Features that would in fact survive.
  /// [DocumentApiClient.previewCascadeDelete] asks the backend for the
  /// exact same computation the delete itself performs, instead.
  Future<void> _cascadeDeleteFeature(FeatureDto feature) async {
    final part = _part;
    if (part == null || _busy) return;

    List<String> toDeleteIds;
    try {
      toDeleteIds = await _api.previewCascadeDelete(part.id, feature.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
      return;
    }
    if (!mounted) return;
    final namesToDelete = [
      for (var i = 0; i < _features.length; i++)
        if (toDeleteIds.contains(_features[i].id)) featureDisplayName(_features, i),
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
      // stopped being locked - so the tree/viewport kept treating it as
      // hidden even once it was editable again. The Sketch was only ever
      // hidden because something depended on it; once the new last Feature
      // is unlocked again, there's nothing left to make it redundant clutter.
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
    final allEdgeSegments = [for (final body in _visibleBodies) ...edgeSegmentsFromMesh(body.mesh)];
    final ghostSegments = basis != null
        ? projectMeshEdgesOntoPlane(basis, allEdgeSegments)
        : const <((double, double), (double, double))>[];
    // Sketcher-roadmap Phase 4.3 v1: the ghost outline's own pick targets
    // for body-vertex dimensioning - see SketchController.
    // pickReferenceGhostVertex's own doc comment.
    final ghostVertices = basis != null
        ? [
            for (final body in _visibleBodies)
              ...projectMeshVerticesOntoPlane(basis, body.bodyId, body.mesh),
          ]
        : const <(String, int, double, double)>[];
    // Sketcher-roadmap Phase 4.3 v2: the same ghost outline's own pick
    // targets for whole-body-edge dimensioning - see SketchController.
    // pickReferenceGhostEdge's own doc comment. Deliberately its own list
    // rather than reusing [ghostSegments] (Phase 4.1's plain, id-less
    // wireframe still drives the actual dashed-line rendering unchanged) -
    // this one only exists to carry (bodyId, edgeId) through to a tap.
    final ghostEdges = basis != null
        ? [
            for (final body in _visibleBodies)
              ...projectMeshEdgesOntoPlaneWithIds(basis, body.bodyId, body.mesh),
          ]
        : const <(String, int, (double, double), (double, double))>[];

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SketchScreen(
          controller: SketchController(api: widget.sketchApiFactory?.call()),
          adoptSketchId: feature.sketchId,
          referenceGhostSegments: ghostSegments,
          referenceGhostVertices: ghostVertices,
          referenceGhostEdges: ghostEdges,
          bodies: _visibleBodies,
          documentPartId: _part?.id,
          sketchFeatureId: feature.id,
          planeBasis: basis,
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
      // other time, popping proceeds normally. Fillet's own guided entry
      // doesn't intercept back here, consistent with Extrude/Create Plane's
      // own "Confirm/Cancel are the only way out" panels once open - see
      // [_openFilletPanel].
      canPop: !_planeSelectionMode &&
          !_confirmingSketchOrientation &&
          !_sketchPickerActive &&
          !_revolveSketchPickerActive &&
          !_sweepSketchPickerActive &&
          !_profilePickerActive &&
          !_pathPickerActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_confirmingSketchOrientation) {
          _cancelPendingOrientation();
        } else if (_sketchPickerActive) {
          _cancelSketchPicker();
        } else if (_revolveSketchPickerActive) {
          _cancelRevolveSketchPicker();
        } else if (_sweepSketchPickerActive) {
          _cancelSweepSketchPicker();
        } else if (_profilePickerActive) {
          _cancelProfilePicker();
        } else if (_pathPickerActive) {
          _cancelPathPicker();
        } else {
          _cancelPlaneSelectionMode();
        }
      },
      child: _buildScaffold(context),
    );
  }

  /// The banner should reflect the file the user actually saved to/opened,
  /// not the backend `Part.name` - every brand-new Part is created with the
  /// same hardcoded `'Part 1'` server-side (see `_loadPart`), so without
  /// this the banner would say "Part 1" forever regardless of what the user
  /// names their save file. Falls back to `_part?.name` only when nothing's
  /// been saved/opened yet this session.
  String get _displayPartName {
    final savedName = _lastSavedFileName;
    if (savedName == null) return _part?.name ?? 'Part';
    return savedName.replaceFirst(RegExp(r'\.DIDSAprt$', caseSensitive: false), '');
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const DidsaLogoButton(),
        leadingWidth: 100,
        centerTitle: false,
        title: Text(_displayPartName, textAlign: TextAlign.right),
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
                  bodies: _visibleBodies,
                  selectedPlane: _selectedPlane,
                  sketchGeometries: _visibleSketchGeometries,
                  createPlanes: _createPlaneGeometries,
                  onCreatePlaneTap: _onCreatePlaneFeatureTap,
                  selectedCreatePlaneFeatureId: _selectedCreatePlaneFeatureId,
                  onPlaneTap: _onPlaneTap,
                  onBackgroundTap: _onViewportBackgroundTap,
                  // Prompt F: Revolve uses the same simple tinted-preview
                  // convention Extrude does (see docs/live-preview-pattern.md's
                  // decision tree - Boss/Cut target_body_ids are Body-level
                  // picks, stable across re-solves) - an `||`, not a separate
                  // overlay, since only one of the three is ever active at
                  // once. Sweep (also Body-level picks) joins the same `||`.
                  isPreviewMesh: _extrudeSketchFeature != null ||
                      _revolveSketchFeature != null ||
                      _sweepSketchFeature != null,
                  // Prompt E: only one of _filletActive/_chamferActive is
                  // ever true at a time (see the Chamfer state section's own
                  // header comment), so a simple ternary - not a list -
                  // picks whichever flow's preview overlay is currently
                  // live; see `docs/live-preview-pattern.md` if a third
                  // concurrent live-edit flow is ever added.
                  previewOverlayBodyId: _filletActive ? _filletPreviewBodyId : _chamferPreviewBodyId,
                  previewOverlayMesh: _filletActive ? _filletPreviewMesh : _chamferPreviewMesh,
                  referencePlanesHidden: _referencePlanesHidden,
                  renderMode: _renderMode,
                  bgColourHex: _bgColourHex,
                  bodyColourHex: _bodyColourHex,
                  bodyOpacity: _bodyOpacity,
                  roughness: _sceneRoughness,
                  lightIntensity: _sceneLightIntensity,
                  emissiveIntensity: _sceneEmissiveIntensity,
                  // On-device feedback: this used to be forced true for the
                  // whole Extrude panel lifetime, unconditionally overriding
                  // the mode-toggle FAB (itself hidden while the panel was
                  // open) - target-body picking needs Selection mode, but
                  // that shouldn't mean the user can never orbit to look
                  // around while the panel's open. [_openExtrudePanel]/
                  // [_openExtrudePanelForEdit] now only set [_selectionMode]
                  // true as a one-time default on open; the FAB (visible
                  // throughout, see floatingActionButton below) can toggle
                  // it either way from there, same as any other time.
                  selectionMode: _selectionMode,
                  selectedEntities: _selectedEntities,
                  onSelectionToggle: _toggleSelectedEntity,
                  onClearSelection: _clearSelectedEntities,
                  selectionFilter: _selectionFilter,
                  isPerspective: _isPerspective,
                  farClip: _farClip,
                  onFarClipChanged: _onFarClipChanged,
                  sketchLineLoopGroup: _sketchLineLoopGroup,
                  // On-device feedback: must track the camera live as the
                  // user orbits, not just refresh on a flip/rotate tap -
                  // see [PartViewport.sketchOrientationBasis]'s own doc
                  // comment for why this is a widget parameter into
                  // PartViewport's own build rather than an external
                  // overlay here.
                  sketchOrientationBasis: _confirmingSketchOrientation ? _pendingOrientationBasis : null,
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
                if (!_extrudeActive &&
                    !_createPlaneActive &&
                    !_filletActive &&
                    !_chamferActive &&
                    !_revolveActive &&
                    !_sweepActive &&
                    !_profilePickerActive &&
                    !_pathPickerActive)
                  Positioned.fill(
                    child: SelectionListDrawer(
                      selectedEntities: _selectedEntities,
                      onRemove: _toggleSelectedEntity,
                      header: SelectionContextPanel(
                        selectedEntities: _selectedEntities,
                        isPointOnLine: _isPointOnLine,
                        onCreatePlane: _onCreatePlaneTapped,
                        onFillet: _onFilletTapped,
                        onChamfer: _onChamferTapped,
                        onNewSketchOnFace: _onNewSketchOnFaceTapped,
                        onNewSketch: _onNewSketchTapped,
                      ),
                      bodyNames: _bodyNames,
                    ),
                  ),
                Positioned.fill(
                  child: FeatureTreePanel(
                    visible: _featureTreeVisible &&
                        !_extrudeActive &&
                        !_createPlaneActive &&
                        !_filletActive &&
                        !_chamferActive &&
                        !_revolveActive &&
                        !_sweepActive &&
                        !_profilePickerActive &&
                        !_pathPickerActive,
                    features: _features,
                    selectedFeatureId: _selectedFeatureId,
                    hiddenFeatureIds: _viewportHiddenFeatureIds,
                    onFeatureTap: _onFeatureTap,
                    onFeatureLongPress: _onFeatureLongPress,
                    onClose: () {
                      if (_sketchPickerActive) {
                        _cancelSketchPicker();
                      } else if (_revolveSketchPickerActive) {
                        _cancelRevolveSketchPicker();
                      } else if (_sweepSketchPickerActive) {
                        _cancelSweepSketchPicker();
                      } else {
                        setState(() => _featureTreeVisible = false);
                      }
                    },
                    // Prompt F: only one of _sketchPickerActive/
                    // _revolveSketchPickerActive/_sweepSketchPickerActive is
                    // ever true at a time (same "one panel/picker active"
                    // invariant every other flow in this file relies on), so a
                    // chain of ternaries picks whichever is live - mirrors the
                    // previewOverlayBodyId/previewOverlayMesh ternary above.
                    isSketchPickerMode:
                        _sketchPickerActive || _revolveSketchPickerActive || _sweepSketchPickerActive,
                    pickableSketchIds: _sketchPickerActive
                        ? _pickableSketchIds
                        : _revolveSketchPickerActive
                            ? _pickableRevolveSketchIds
                            : _pickableSweepSketchIds,
                    onSketchPicked: _sketchPickerActive
                        ? _onSketchPicked
                        : _revolveSketchPickerActive
                            ? _onRevolveSketchPicked
                            : _onSweepSketchPicked,
                    bodyIds: _computedBodyIds,
                    bodyNames: _bodyNames,
                    onBodyTap: _onBodyTap,
                    onBodyLongPress: _onBodyLongPress,
                    hiddenBodyIds: {for (final body in _bodies) if (body.hidden) body.bodyId},
                  ),
                ),
                Positioned.fill(
                  child: PartToolbar(
                    visible: _toolbarOpen,
                    referencePlanesHidden: _referencePlanesHidden,
                    onToggleReferencePlanes: _onToggleReferencePlanes,
                    renderMode: _renderMode,
                    onRenderModeChanged: _onRenderModeChanged,
                    onExit: _exitToConnectionScreen,
                    onSaveNative: _saveNativeFile,
                    onSaveAsNative: _saveAsNativeFile,
                    onOpenNative: _openNativeFile,
                    onStartNew: _startNewPart,
                    onExportPart: _exportPart,
                    onImportGeometry: _importGeometry,
                    bgColourHex: _bgColourHex,
                    bodyColourHex: _bodyColourHex,
                    bodyOpacity: _bodyOpacity,
                    onBgColourChanged: _onBgColourChanged,
                    onBodyColourChanged: _onBodyColourChanged,
                    onBodyOpacityChanged: _onBodyOpacityChanged,
                    sceneRoughness: _sceneRoughness,
                    sceneLightIntensity: _sceneLightIntensity,
                    sceneEmissiveIntensity: _sceneEmissiveIntensity,
                    onSceneRoughnessChanged: _onSceneRoughnessChanged,
                    onSceneLightIntensityChanged: _onSceneLightIntensityChanged,
                    onSceneEmissiveIntensityChanged: _onSceneEmissiveIntensityChanged,
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
                if (_filletActive)
                  Positioned.fill(
                    child: FilletPanel(
                      key: ValueKey(_editingFilletFeatureId ?? _previewFilletFeatureId),
                      title: _editingFilletFeatureId != null ? 'Edit Fillet' : 'Fillet',
                      initialRadius: _filletRadius,
                      onRadiusChanged: _onFilletRadiusChanged,
                      onConfirm: _confirmFillet,
                      onCancel: _cancelFillet,
                    ),
                  ),
                if (_chamferActive)
                  Positioned.fill(
                    child: ChamferPanel(
                      key: ValueKey(_editingChamferFeatureId ?? _previewChamferFeatureId),
                      title: _editingChamferFeatureId != null ? 'Edit Chamfer' : 'Chamfer',
                      initialDistance: _chamferDistance,
                      onDistanceChanged: _onChamferDistanceChanged,
                      onConfirm: _confirmChamfer,
                      onCancel: _cancelChamfer,
                    ),
                  ),
                if (_revolveActive)
                  Positioned.fill(
                    child: RevolvePanel(
                      key: ValueKey(_editingRevolveFeatureId ?? _revolveSketchFeature!.id),
                      title: _editingRevolveFeatureId != null ? 'Edit Revolve' : 'Revolve',
                      initialMode: _revolveMode,
                      initialAngle: _revolveAngle,
                      hasAxis: _revolveAxisEntity != null,
                      targetBodyCount: _currentRevolveTargetBodyIds().length,
                      onChanged: _onRevolveValuesChanged,
                      onConfirm: _confirmRevolve,
                      onCancel: _cancelRevolve,
                    ),
                  ),
                if (_sweepActive)
                  Positioned.fill(
                    child: SweepPanel(
                      key: ValueKey(_editingSweepFeatureId ?? _sweepSketchFeature!.id),
                      title: _editingSweepFeatureId != null ? 'Edit Sweep' : 'Sweep',
                      initialMode: _sweepMode,
                      pathSegmentCount: _sweepPathRefs.length,
                      pathIsClosed: _sweepPathIsClosed(),
                      targetBodyCount: _currentSweepTargetBodyIds().length,
                      onChanged: _onSweepValuesChanged,
                      onConfirm: _confirmSweep,
                      onCancel: _cancelSweep,
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
                // Prompt F: mirrors the Extrude banner directly above exactly,
                // substituting Revolve's own axis-plus-target-body banner
                // text and Cancel callback.
                if (_revolveActive)
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
                                      _revolvePickerBannerText(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _cancelRevolve,
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
                // Mirrors the Revolve banner directly above exactly,
                // substituting Sweep's own target-body-only banner text
                // (its path is already fixed by the time this panel shows -
                // see [_sweepPickerBannerText]'s own doc comment) and Cancel
                // callback.
                if (_sweepActive)
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
                                      _sweepPickerBannerText(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _cancelSweep,
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
                // Names the path-picking mode live - same top-center pill
                // convention as the plane-selection-mode/target-body-picking
                // banners above. Tap a line to extend the path (or the most
                // recently picked one again to undo it); the checkmark FAB
                // (see floatingActionButton below) confirms once at least one
                // segment is picked and opens SweepPanel.
                if (_pathPickerActive)
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
                                      _pathPickerBannerText(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _cancelPathPicker,
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
                // Prompt G: names the profile-picking mode live - same
                // top-center pill convention as the plane-selection-mode/
                // target-body-picking banners above. Tap a line or circle to
                // toggle its whole loop; the checkmark FAB (see floatingActionButton
                // below) confirms and opens the target panel.
                if (_profilePickerActive)
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
                                      _profilePickedCount() == 0
                                          ? 'Tap profiles to include, or confirm to use all'
                                          : '${_profilePickedCount()} profile(s) selected - tap '
                                              'checkmark to confirm',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _cancelProfilePicker,
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
                if (!_featureTreeVisible &&
                    !_planeSelectionMode &&
                    !_confirmingSketchOrientation &&
                    !_extrudeActive &&
                    !_createPlaneActive &&
                    !_filletActive &&
                    !_chamferActive &&
                    !_revolveActive &&
                    !_sweepActive &&
                    !_profilePickerActive &&
                    !_pathPickerActive)
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
                              child: const SvgIcon('assets/icons/feature/feature_tree.svg'),
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
                // On-device feedback: the orientation confirm step's
                // controls - bottom-centered so it doesn't collide with the
                // plane-selection banner's own top-centered spot (the two
                // are never shown at once: this only appears once
                // [_planeSelectionMode] has already exited via
                // [_onPlaneTap]). Shared between a brand new Sketch
                // ([_addSketchFeature]) and redefining an existing one's
                // orientation ([_redefineSketchOrientation], from its
                // long-press context menu - the sole entry point for that
                // now, replacing the old 2D-only hamburger-menu sheet).
                // Flip/rotate PATCH the pending Sketch's real orientation
                // immediately (see [_adjustPendingOrientation]'s own doc
                // comment); Confirm/Cancel behave differently per
                // [_pendingOrientationMode] - see their own doc comments.
                if (_confirmingSketchOrientation)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    right: 8,
                    child: SafeArea(
                      top: false,
                      child: Center(
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(24),
                          // Bug fix: this row of controls used to overflow
                          // on a narrow screen (no scroll fallback) - it
                          // also used to sit right underneath the
                          // bottom-right mode-toggle/Add FAB column, which
                          // painted on top and made Continue untappable
                          // (see the floatingActionButton hiding rule
                          // above for that half of the fix). Wrapped in a
                          // horizontal scroll view as a hard guarantee
                          // against overflow on any screen width.
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  // Bug fix: swapped - on-device feedback
                                  // reported these two felt reversed
                                  // (rotate_left visually rotated the
                                  // plate clockwise, and vice versa).
                                  tooltip: 'Rotate 90° counter-clockwise',
                                  icon: const Icon(Icons.rotate_left),
                                  onPressed: _busy
                                      ? null
                                      : () => _adjustPendingOrientation(rotationDelta: 1),
                                ),
                                IconButton(
                                  tooltip: 'Rotate 90° clockwise',
                                  icon: const Icon(Icons.rotate_right),
                                  onPressed: _busy
                                      ? null
                                      : () => _adjustPendingOrientation(rotationDelta: -1),
                                ),
                                IconButton(
                                  tooltip: _pendingOrientationFlip ? 'Un-flip' : 'Flip',
                                  icon: const Icon(Icons.flip),
                                  isSelected: _pendingOrientationFlip,
                                  onPressed: _busy
                                      ? null
                                      : () => _adjustPendingOrientation(flip: !_pendingOrientationFlip),
                                ),
                                const SizedBox(width: 4),
                                TextButton(
                                  onPressed: _busy ? null : _cancelPendingOrientation,
                                  child: const Text('Cancel'),
                                ),
                                const SizedBox(width: 4),
                                FilledButton(
                                  onPressed: _busy ? null : _confirmPendingOrientation,
                                  child: Text(
                                    _pendingOrientationMode == _PendingOrientationMode.newSketch
                                        ? 'Continue'
                                        : 'Done',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // On-device feedback: shown while [_filletActive] but no
                // FilletFeature exists yet ([_openFilletPanel] opened with
                // no edges - the "Add" FAB's guided entry, see
                // [_startFilletPicker]) - same shape as the plane-selection
                // banner just above. [FilletPanel] itself is already open
                // underneath this (see [_openFilletPanel]'s own doc comment
                // for why it opens immediately rather than waiting for a
                // separate pick-then-confirm step); Cancel here is the same
                // [_cancelFillet] the panel's own Cancel button uses - both
                // are a no-op past the "restore selection, close" step since
                // nothing was ever created to delete.
                if (_filletActive && _previewFilletFeatureId == null)
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
                                const Text('Select edges (or a face) to fillet'),
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: _cancelFillet,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Mirrors the Fillet banner directly above exactly, for
                // Chamfer's own guided "Add" FAB entry.
                if (_chamferActive && _previewChamferFeatureId == null)
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
                                const Text('Select edges (or a face) to chamfer'),
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: _cancelChamfer,
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
      // Stage 22 item 3: hidden while the toolbar is open - Scaffold always
      // paints floatingActionButton after the entire body (including the
      // body Stack's PartToolbar entry), so it would otherwise sit on top
      // of the open toolbar panel regardless of the body Stack's own child
      // order. That's the only case that hides the mode-toggle FAB itself
      // now (on-device feedback: it used to also hide for the whole
      // Extrude/Create Plane panel lifetime, leaving no way to switch to
      // Orbit mode and look around while confirming one of those - see
      // _openExtrudePanel's own comment on the selectionMode default this
      // replaced).
      //
      // The "Add" FAB stays hidden while either panel is open (you can't
      // start a second Feature mid-flow) - extra bottom padding while one
      // is active keeps the remaining mode-toggle FAB clear of that panel's
      // own bottom-sheet content, which sits in the body Stack rather than
      // a real `Scaffold.bottomSheet` Scaffold could otherwise push this
      // FAB above automatically.
      // Bug fix: the mode-toggle/Add FAB column sits bottom-right
      // (Scaffold's default floatingActionButtonLocation) and paints after
      // the whole body Stack, so it was covering the orientation confirm
      // step's own bottom banner - specifically its Continue button,
      // making the step impossible to accept. Hidden outright during that
      // step, same as it already is while [_toolbarOpen].
      floatingActionButton: _toolbarOpen || _confirmingSketchOrientation
          ? null
          : Padding(
              padding: EdgeInsets.only(
                bottom: (_extrudeActive ||
                        _createPlaneActive ||
                        _filletActive ||
                        _chamferActive ||
                        _revolveActive ||
                        _sweepActive)
                    ? 180
                    : 0,
              ),
              child: Column(
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
                    child: SvgIcon(
                      _selectionMode
                          ? 'assets/icons/viewport/viewport_orbit_mode.svg'
                          : 'assets/icons/viewport/viewport_selection_mode.svg',
                    ),
                  ),
                  if (!_extrudeActive &&
                      !_createPlaneActive &&
                      !_filletActive &&
                      !_chamferActive &&
                      !_revolveActive &&
                      !_sweepActive &&
                      !_profilePickerActive &&
                      !_pathPickerActive) ...[
                    const SizedBox(height: 12),
                    FloatingActionButton(
                      heroTag: 'add-fab',
                      tooltip: 'Add',
                      onPressed: _busy ? null : _onAddPressed,
                      child: const SvgIcon('assets/icons/viewport/viewport_add.svg'),
                    ),
                  ],
                  // Prompt G: the profile picker's own "confirm" FAB, in the
                  // Add FAB's place (never both at once, same "one FAB slot"
                  // convention every other mode here follows) - ticks off
                  // the currently-picked loops and opens the target panel
                  // (see [_confirmProfilePicker]).
                  if (_profilePickerActive) ...[
                    const SizedBox(height: 12),
                    FloatingActionButton(
                      heroTag: 'confirm-profile-picker-fab',
                      tooltip: 'Confirm profile selection',
                      onPressed: _busy ? null : _confirmProfilePicker,
                      child: const Icon(Icons.check),
                    ),
                  ],
                  // The path picker's own "confirm" FAB, mirroring the
                  // profile picker's own directly above - ticks off the
                  // currently-picked path and opens SweepPanel (see
                  // [_confirmPathPicker]). Disabled until at least one
                  // segment is picked, same "requires 1+" rule Cut's own
                  // target-body picking already enforces elsewhere.
                  if (_pathPickerActive) ...[
                    const SizedBox(height: 12),
                    FloatingActionButton(
                      heroTag: 'confirm-path-picker-fab',
                      tooltip: 'Confirm path selection',
                      onPressed: _busy || _pathPickerRefs.isEmpty ? null : _confirmPathPicker,
                      child: const Icon(Icons.check),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
