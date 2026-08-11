import 'package:flutter/material.dart';

import '../ai/ai_provider_settings_screen.dart';
import '../viewport3d/view_preferences.dart';

/// Reachable from the connection screen's own settings entry, attached to
/// the Connect button (see `connection_screen.dart`) - device-wide defaults
/// for the CAD/Part side of the app (as opposed to
/// `mesh_viewer_settings_screen.dart`'s own, entirely separate settings for
/// the standalone mesh viewer). The camera-orientation debug toggle below
/// is unrelated to sketching specifically, but this is the CAD side's one
/// settings screen for now. Mirrors `mesh_viewer_settings_screen.dart`'s
/// own shape exactly (load-on-init, a setter call per toggle change).
class SketcherSettingsScreen extends StatefulWidget {
  const SketcherSettingsScreen({super.key});

  @override
  State<SketcherSettingsScreen> createState() => _SketcherSettingsScreenState();
}

class _SketcherSettingsScreenState extends State<SketcherSettingsScreen> {
  bool _debugShowCameraOrientation = ViewPreferences.defaultDebugShowCameraOrientation;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ViewPreferences.load();
    if (!mounted) return;
    setState(() {
      _debugShowCameraOrientation = ViewPreferences.debugShowCameraOrientation;
      _loaded = true;
    });
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
                const SizedBox(height: 24),
                Text('AI Modelling', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Which AI provider (local/Ollama, OpenAI, or Anthropic) the AI "
                  "Modelling scoping conversation sends requests to, and each "
                  "provider's own connection details.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('AI Provider Settings'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiProviderSettingsScreen()),
                  ),
                ),
              ],
            ),
    );
  }
}
