import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../sketch/sketch_controller.dart';
import '../sketch/sketch_screen.dart';
import 'feature_tree_panel.dart';
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
      debugPrint('[PartScreen] createPart...');
      final part = await _api.createPart('Part 1');
      debugPrint('[PartScreen] createPart done: ${part.id}');
      _part = part;
      debugPrint('[PartScreen] getPartMesh...');
      _mesh = (await _api.getPartMesh(part.id)).mesh;
      debugPrint('[PartScreen] getPartMesh done: ${_mesh!.vertices.length} vertices');
      await _refreshFeatures();
      debugPrint('[PartScreen] refreshFeatures done');
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
            child: Row(
              children: [
                FeatureTreePanel(
                  features: _features,
                  selectedFeatureId: _selectedFeatureId,
                  onFeatureTap: _onFeatureTap,
                ),
                Expanded(child: PartViewport(mesh: _mesh)),
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
