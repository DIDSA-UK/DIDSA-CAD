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

  PartDto? _part;
  List<FeatureDto> _features = [];
  MeshDto? _mesh;
  String? _selectedFeatureId;

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
    _loadPart();
  }

  @override
  void dispose() {
    if (widget.documentApi == null) {
      _api.close();
    }
    super.dispose();
  }

  Future<void> _loadPart() async {
    await _runGuarded(() async {
      final part = await _api.createPart('Part 1');
      _part = part;
      _mesh = (await _api.getPartMesh(part.id)).mesh;
      await _refreshFeatures();
    });
  }

  Future<void> _refreshFeatures() async {
    final part = _part;
    if (part == null) return;
    _features = await _api.listFeatures(part.id);
  }

  Future<void> _addSketchFeature() async {
    final part = _part;
    if (part == null || _busy) return;

    FeatureDto? created;
    await _runGuarded(() async {
      created = await _api.createSketchFeature(part.id);
      await _refreshFeatures();
    });

    final feature = created;
    if (feature != null && mounted) {
      await _openSketch(feature);
    }
  }

  /// A tap always selects/highlights the Feature; only an editable (not
  /// locked) Feature also opens its Sketch - tapping a locked Feature to
  /// re-edit it is explicitly out of scope for this stage.
  void _onFeatureTap(FeatureDto feature) {
    setState(() => _selectedFeatureId = feature.id);
    if (!feature.locked) {
      _openSketch(feature);
    }
  }

  /// A long-press on any Feature (locked or not) opens a context menu of
  /// actions for it, rather than triggering anything directly - the menu
  /// is what lets later stages add actions (rename, edit, ...) alongside
  /// Delete without reworking this entry point. Only Delete exists today.
  Future<void> _onFeatureLongPress(FeatureDto feature) async {
    if (_busy) return;

    final action = await showFeatureContextMenu(context);
    if (!mounted || action == null) return;

    switch (action) {
      case FeatureContextMenuAction.delete:
        await _cascadeDeleteFeature(feature);
    }
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
      if (_selectedFeatureId != null && !_features.any((f) => f.id == _selectedFeatureId)) {
        _selectedFeatureId = null;
      }
    });
  }

  void _showFeatureTree() {
    setState(() {
      _featureTreeVisible = true;
      _toolbarOpen = false;
    });
  }

  Future<void> _openSketch(FeatureDto feature) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SketchScreen(
          controller: SketchController(api: widget.sketchApiFactory?.call()),
          adoptSketchId: feature.sketchId,
        ),
      ),
    );
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
                PartViewport(mesh: _mesh),
                Positioned.fill(
                  child: FeatureTreePanel(
                    visible: _featureTreeVisible,
                    features: _features,
                    selectedFeatureId: _selectedFeatureId,
                    onFeatureTap: _onFeatureTap,
                    onFeatureLongPress: _onFeatureLongPress,
                    onClose: () => setState(() => _featureTreeVisible = false),
                  ),
                ),
                Positioned.fill(
                  child: PartToolbar(
                    visible: _toolbarOpen,
                    onShowFeatureTree: _showFeatureTree,
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
