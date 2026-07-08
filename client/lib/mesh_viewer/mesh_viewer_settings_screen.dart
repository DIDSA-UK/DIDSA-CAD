import 'package:flutter/material.dart';

import 'mesh_data.dart' show MeshUpAxis;
import 'mesh_viewer_preferences.dart';

/// Reachable from a gear icon next to "View a mesh file" on the connection
/// screen (see `connection_screen.dart`) - device/pipeline-wide defaults for
/// the "View Complex Mesh" viewer. Deliberately separate from that viewer's
/// own live "View" menu (`mesh_viewer_screen.dart`'s Scene/Facets/Mesh/Up
/// axis entries): these two settings are "how does *this* device/export
/// pipeline behave in general" choices, set once and rarely revisited, not
/// something to re-tune per file - see `mesh_viewer_preferences.dart`'s own
/// doc comment for the same split [ScenePreferences] already draws between
/// persisted defaults and live per-session controls.
class MeshViewerSettingsScreen extends StatefulWidget {
  const MeshViewerSettingsScreen({super.key});

  @override
  State<MeshViewerSettingsScreen> createState() => _MeshViewerSettingsScreenState();
}

class _MeshViewerSettingsScreenState extends State<MeshViewerSettingsScreen> {
  int _maxTriangles = MeshViewerPreferences.defaultMaxTriangles;
  MeshUpAxis _upAxis = MeshViewerPreferences.defaultUpAxis;
  bool _mirror = MeshViewerPreferences.defaultMirror;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await MeshViewerPreferences.load();
    if (!mounted) return;
    setState(() {
      _maxTriangles = MeshViewerPreferences.maxTriangles;
      _upAxis = MeshViewerPreferences.upAxis;
      _mirror = MeshViewerPreferences.mirror;
      _loaded = true;
    });
  }

  Future<void> _onMaxTrianglesChanged(double value) async {
    final rounded = value.round();
    setState(() => _maxTriangles = rounded);
    await MeshViewerPreferences.setMaxTriangles(rounded);
  }

  Future<void> _onUpAxisChanged(MeshUpAxis axis) async {
    setState(() => _upAxis = axis);
    await MeshViewerPreferences.setUpAxis(axis);
  }

  Future<void> _onMirrorChanged(bool mirror) async {
    setState(() => _mirror = mirror);
    await MeshViewerPreferences.setMirror(mirror);
  }

  static String _formatTriangleCount(int n) {
    if (n >= 1000000) {
      final millions = (n / 100000).round() / 10;
      return millions == millions.roundToDouble()
          ? '${millions.toStringAsFixed(0)}M triangles'
          : '${millions.toStringAsFixed(1)}M triangles';
    }
    return '${(n / 1000).round()}K triangles';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mesh Viewer Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Decimation', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "A large photogrammetry-scale mesh is decimated down to this many "
                  "triangles before it's rendered, so it stays smooth on this device. "
                  "Raise it on a more powerful device; lower it if the viewer feels "
                  "sluggish or runs out of memory.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(_formatTriangleCount(_maxTriangles), style: Theme.of(context).textTheme.bodyMedium),
                Slider(
                  value: _maxTriangles
                      .toDouble()
                      .clamp(MeshViewerPreferences.minMaxTriangles.toDouble(), MeshViewerPreferences.maxMaxTriangles.toDouble()),
                  min: MeshViewerPreferences.minMaxTriangles.toDouble(),
                  max: MeshViewerPreferences.maxMaxTriangles.toDouble(),
                  divisions: (MeshViewerPreferences.maxMaxTriangles - MeshViewerPreferences.minMaxTriangles) ~/ 250000,
                  label: _formatTriangleCount(_maxTriangles),
                  onChanged: _onMaxTrianglesChanged,
                ),
                const SizedBox(height: 24),
                Text('Default up axis', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Most files are Y-up. Some Blender exports skip the standard axis "
                  "conversion and need Z-up instead - this sets the default for newly "
                  "opened files (still overridable per file from the viewer's own View menu).",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<MeshUpAxis>(
                  segments: const [
                    ButtonSegment(value: MeshUpAxis.y, label: Text('Y-up (default)')),
                    ButtonSegment(value: MeshUpAxis.z, label: Text('Z-up')),
                  ],
                  selected: {_upAxis},
                  onSelectionChanged: (selection) => _onUpAxisChanged(selection.first),
                ),
                const SizedBox(height: 24),
                Text('Mirror', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Some export pipelines produce genuinely mirrored geometry (e.g. a "
                  "Blender export where the model itself is a left-right flip of the real "
                  "object) - this sets the default for newly opened files (still "
                  "overridable per file from the viewer's own View menu).",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Off (default)')),
                    ButtonSegment(value: true, label: Text('Mirrored')),
                  ],
                  selected: {_mirror},
                  onSelectionChanged: (selection) => _onMirrorChanged(selection.first),
                ),
              ],
            ),
    );
  }
}
