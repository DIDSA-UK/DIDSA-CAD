import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../sketch/sketch_controller.dart';
import '../sketch/sketch_screen.dart';
import 'cascade_delete_dialog.dart';
import 'feature_context_menu.dart';
import 'feature_tree_panel.dart';
import 'part_toolbar.dart';
import 'part_viewport.dart';
import 'reference_planes.dart';
import 'sketch_geometry_3d.dart';

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

  /// Feature ids hidden from the 3D viewport via the long-press
  /// Hide/Show action - client-side only, never sent to the backend.
  final Set<String> _hiddenFeatureIds = {};

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

  @override
  void initState() {
    super.initState();
    _api = widget.documentApi ?? DocumentApiClient();
    _sketchApi = widget.sketchApiFactory?.call() ?? SketchApiClient();
    _loadPart();
  }

  @override
  void dispose() {
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
      _mesh = (await _api.getPartMesh(part.id)).mesh;
      debugPrint('[PartScreen] getPartMesh done: ${_mesh!.vertices.length} vertices');
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

  /// Re-fetches every Feature's Sketch content (points/lines/circles) and
  /// rebuilds [_allSketchGeometries]/[_visibleSketchGeometries] from it, so
  /// the 3D viewport's rendered Sketch geometry always matches the latest
  /// backend state. A single Feature's fetch failing (e.g. a test fixture
  /// that only stubs `GET /sketch/sketches/{id}`, or a transient network
  /// issue) only drops that Feature's geometry, not the whole viewport.
  Future<void> _refreshSketchGeometries() async {
    final updated = <String, SketchGeometry3D>{};
    for (final feature in _features) {
      try {
        final sketch = await _sketchApi.getSketch(feature.sketchId);
        final plane = referencePlaneKindFromApiValue(sketch.plane);
        if (plane == null) continue;
        final points = await _sketchApi.listPoints(feature.sketchId);
        final lines = await _sketchApi.listLines(feature.sketchId);
        final circles = await _sketchApi.listCircles(feature.sketchId);
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
  /// SketchScreen - the FAB's path defaults [plane] to XY; a plane tap in
  /// the 3D viewport instead passes the tapped plane through, via
  /// [_onNewSketchOnSelectedPlane].
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
      await _openSketch(feature);
    }
  }

  /// A tap that landed on a reference plane rectangle in the 3D viewport -
  /// selects it (brighter highlight) and slides the toolbar in with a "New
  /// Sketch on..." entry for it, per the project brief.
  void _onPlaneTap(ReferencePlaneKind plane) {
    setState(() {
      _selectedPlane = plane;
      _toolbarOpen = true;
      _featureTreeVisible = false;
    });
  }

  /// A tap that missed every reference plane - dismisses the toolbar and
  /// clears the selection, mirroring a tap on empty space elsewhere in the
  /// app deselecting whatever was selected.
  void _onViewportBackgroundTap() {
    setState(() {
      _selectedPlane = null;
      _toolbarOpen = false;
    });
  }

  Future<void> _onNewSketchOnSelectedPlane() async {
    final plane = _selectedPlane;
    if (plane == null) return;
    setState(() {
      _selectedPlane = null;
      _toolbarOpen = false;
    });
    await _addSketchFeature(plane: plane);
  }

  /// A tap always selects/highlights the Feature; only an editable (not
  /// locked) Feature also opens its Sketch - tapping a locked Feature to
  /// re-edit it is explicitly out of scope for this stage.
  void _onFeatureTap(FeatureDto feature) {
    setState(() => _selectedFeatureId = feature.id);
    if (!feature.locked) {
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
    await _openSketch(feature);
  }

  Future<ReferencePlaneKind?> _planeOfFeature(FeatureDto feature) async {
    try {
      final sketch = await _sketchApi.getSketch(feature.sketchId);
      return referencePlaneKindFromApiValue(sketch.plane);
    } catch (_) {
      return null;
    }
  }

  /// A long-press on any Feature (locked or not) opens a context menu of
  /// actions for it, rather than triggering anything directly - the menu
  /// is what lets later stages add actions (rename, edit, ...) alongside
  /// Delete without reworking this entry point. Only Delete exists today.
  Future<void> _onFeatureLongPress(FeatureDto feature) async {
    if (_busy) return;

    final action = await showFeatureContextMenu(
      context,
      isHidden: _hiddenFeatureIds.contains(feature.id),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case FeatureContextMenuAction.toggleVisibility:
        _toggleFeatureVisibility(feature);
      case FeatureContextMenuAction.delete:
        await _cascadeDeleteFeature(feature);
    }
  }

  /// Client-side-only Hide/Show for a Feature's 3D geometry - never sent to
  /// the backend, so this is purely a local Set toggle plus a recompute of
  /// [_visibleSketchGeometries] (the reference-plane/mesh viewport itself
  /// doesn't need this - only Sketch geometry can be hidden per Feature).
  void _toggleFeatureVisibility(FeatureDto feature) {
    setState(() {
      if (_hiddenFeatureIds.contains(feature.id)) {
        _hiddenFeatureIds.remove(feature.id);
      } else {
        _hiddenFeatureIds.add(feature.id);
      }
      _recomputeVisibleSketchGeometries();
    });
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
      for (var i = index; i < _features.length; i++) featureDisplayName(i),
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
      _recomputeVisibleSketchGeometries();
    });
  }

  void _showFeatureTree() {
    setState(() {
      _featureTreeVisible = true;
      _toolbarOpen = false;
    });
  }

  /// Pushes the Sketch screen and, once it returns (back button or the
  /// ribbon's Exit Sketch action - both just pop this route), re-fetches
  /// Features and their Sketch content: whatever was drawn during this
  /// visit must show up back in the 3D viewport, not only on the next
  /// unrelated Feature-creation refresh.
  Future<void> _openSketch(FeatureDto feature) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SketchScreen(
          controller: SketchController(api: widget.sketchApiFactory?.call()),
          adoptSketchId: feature.sketchId,
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
    return Scaffold(
      appBar: AppBar(title: Text(_part?.name ?? 'Part')),
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
                ),
                Positioned.fill(
                  child: FeatureTreePanel(
                    visible: _featureTreeVisible,
                    features: _features,
                    selectedFeatureId: _selectedFeatureId,
                    hiddenFeatureIds: _hiddenFeatureIds,
                    onFeatureTap: _onFeatureTap,
                    onFeatureLongPress: _onFeatureLongPress,
                    onClose: () => setState(() => _featureTreeVisible = false),
                  ),
                ),
                Positioned.fill(
                  child: PartToolbar(
                    visible: _toolbarOpen,
                    onShowFeatureTree: _showFeatureTree,
                    selectedPlane: _selectedPlane,
                    onNewSketchOnPlane: _busy ? null : _onNewSketchOnSelectedPlane,
                  ),
                ),
                // Always on top (last in the Stack) so it stays tappable
                // regardless of whether the toolbar underneath is open -
                // but hidden while the Feature tree is open since it sits
                // right on top of the tree's header text otherwise; the
                // tree's own X button is the way to dismiss it instead.
                if (!_featureTreeVisible)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: SafeArea(
                      bottom: false,
                      child: IconButton.filled(
                        tooltip: _toolbarOpen ? 'Close toolbar' : 'Open toolbar',
                        icon: Icon(_toolbarOpen ? Icons.close : Icons.menu),
                        onPressed: () => setState(() => _toolbarOpen = !_toolbarOpen),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add Sketch Feature',
        onPressed: _busy ? null : _addSketchFeature,
        child: const Icon(Icons.add),
      ),
    );
  }
}
