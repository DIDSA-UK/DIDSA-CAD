import 'package:flutter/material.dart';

import '../viewport3d/view_preferences.dart';
import 'sketcher_preferences.dart';

/// Reachable from the connection screen's own settings entry, attached to
/// the Connect button (see `connection_screen.dart`) - device-wide defaults
/// for the CAD/Part side of the app (as opposed to
/// `mesh_viewer_settings_screen.dart`'s own, entirely separate settings for
/// the standalone mesh viewer). Started as just the 2D/3D sketcher default;
/// the camera-orientation debug toggle below is unrelated to sketching
/// specifically, but this is the CAD side's one settings screen for now.
/// Mirrors `mesh_viewer_settings_screen.dart`'s own shape exactly
/// (load-on-init, a setter call per toggle change).
class SketcherSettingsScreen extends StatefulWidget {
  const SketcherSettingsScreen({super.key});

  @override
  State<SketcherSettingsScreen> createState() => _SketcherSettingsScreenState();
}

class _SketcherSettingsScreenState extends State<SketcherSettingsScreen> {
  bool _use3DSketcher = SketcherPreferences.defaultUse3DSketcher;
  bool _debugShowCameraOrientation = ViewPreferences.defaultDebugShowCameraOrientation;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await Future.wait([SketcherPreferences.load(), ViewPreferences.load()]);
    if (!mounted) return;
    setState(() {
      _use3DSketcher = SketcherPreferences.use3DSketcher;
      _debugShowCameraOrientation = ViewPreferences.debugShowCameraOrientation;
      _loaded = true;
    });
  }

  Future<void> _onUse3DSketcherChanged(bool value) async {
    setState(() => _use3DSketcher = value);
    await SketcherPreferences.setUse3DSketcher(value);
  }

  Future<void> _onDebugShowCameraOrientationChanged(bool value) async {
    setState(() => _debugShowCameraOrientation = value);
    await ViewPreferences.setDebugShowCameraOrientation(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CAD Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Default sketcher', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Sets which view a newly opened Sketch starts in - the flat 2D "
                  "canvas, or the 3D-embedded view (sketch entities placed directly "
                  "on their plane in the same viewport/camera as Orbit View). Either "
                  "way, the Orbit View toggle inside a Sketch still lets you switch "
                  "for that session. The 3D-embedded sketcher currently only supports "
                  "Point and Line placement - every other tool still needs the 2D "
                  "canvas.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('2D canvas (default)')),
                    ButtonSegment(value: true, label: Text('3D-embedded')),
                  ],
                  selected: {_use3DSketcher},
                  onSelectionChanged: (selection) => _onUse3DSketcherChanged(selection.first),
                ),
                const SizedBox(height: 24),
                Text('Debug: camera orientation readout', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Shows a live readout of which world axis currently reads as "
                  "screen-right/up/toward-camera - a temporary aid for confirming "
                  "camera-orientation math against the on-screen triad. Applies to "
                  "the Part viewport and any embedded 3D sketch view.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show camera orientation readout'),
                  value: _debugShowCameraOrientation,
                  onChanged: _onDebugShowCameraOrientationChanged,
                ),
              ],
            ),
    );
  }
}
