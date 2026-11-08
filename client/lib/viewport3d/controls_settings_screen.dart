import 'package:material_ui/material_ui.dart';

import '../layout/layout_mode.dart';
import 'controls_preferences.dart';
import 'edge_batching.dart' show kEdgeLimitSteps;
import 'keyboard_shortcuts.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` section 4): the mouse and
/// keyboard settings - which package's view bindings to follow, inverted
/// wheel zoom, how fast a mouse drag orbits - and a way to the shortcut
/// list. Opened from the part screen's View menu, the sketch screen's menu
/// and the tool chooser; each change is saved at once and takes effect in
/// every canvas (they all read [ControlsPreferences]).
class ControlsSettingsScreen extends StatefulWidget {
  const ControlsSettingsScreen({super.key});

  @override
  State<ControlsSettingsScreen> createState() => _ControlsSettingsScreenState();
}

class _ControlsSettingsScreenState extends State<ControlsSettingsScreen> {
  NavigationPreset _preset = ControlsPreferences.preset;
  bool _invertWheel = ControlsPreferences.invertWheel;
  double _orbitSpeed = ControlsPreferences.orbitSpeed;
  LayoutPreference _layout = ControlsPreferences.layoutPreference;
  bool _hideEdges = ControlsPreferences.hideEdgesWhileMoving;
  int _edgeLimit = ControlsPreferences.edgeLimit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ControlsPreferences.load();
    if (!mounted) return;
    setState(() {
      _preset = ControlsPreferences.preset;
      _invertWheel = ControlsPreferences.invertWheel;
      _orbitSpeed = ControlsPreferences.orbitSpeed;
      _layout = ControlsPreferences.layoutPreference;
      _hideEdges = ControlsPreferences.hideEdgesWhileMoving;
      _edgeLimit = ControlsPreferences.edgeLimit;
    });
  }

  Future<void> _reset() async {
    await ControlsPreferences.reset();
    if (!mounted) return;
    setState(() {
      _preset = ControlsPreferences.preset;
      _invertWheel = ControlsPreferences.invertWheel;
      _orbitSpeed = ControlsPreferences.orbitSpeed;
      _layout = ControlsPreferences.layoutPreference;
      _hideEdges = ControlsPreferences.hideEdgesWhileMoving;
      _edgeLimit = ControlsPreferences.edgeLimit;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Controls')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Mouse navigation', style: theme.textTheme.titleMedium),
              ),
              RadioGroup<NavigationPreset>(
                groupValue: _preset,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _preset = value);
                  ControlsPreferences.setPreset(value);
                },
                child: Column(
                  children: [
                    for (final preset in NavigationPreset.values)
                      RadioListTile<NavigationPreset>(
                        value: preset,
                        title: Text(preset.label),
                        subtitle: Text(preset.description),
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'In every preset the wheel zooms to the cursor and a right click without a drag opens a menu. '
                  'A middle double-click zooms to fit.',
                ),
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Invert wheel zoom'),
                subtitle: const Text('Scroll up to zoom out instead of in.'),
                value: _invertWheel,
                onChanged: (value) {
                  setState(() => _invertWheel = value);
                  ControlsPreferences.setInvertWheel(value);
                },
              ),
              ListTile(
                title: Text('Orbit speed: ${_orbitSpeed.toStringAsFixed(2)}x'),
                subtitle: Slider(
                  value: _orbitSpeed,
                  min: ControlsPreferences.minOrbitSpeed,
                  max: ControlsPreferences.maxOrbitSpeed,
                  divisions: 11,
                  label: '${_orbitSpeed.toStringAsFixed(2)}x',
                  onChanged: (value) {
                    setState(() => _orbitSpeed = value);
                    ControlsPreferences.setOrbitSpeed(value);
                  },
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Layout', style: theme.textTheme.titleMedium),
              ),
              RadioGroup<LayoutPreference>(
                groupValue: _layout,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _layout = value);
                  ControlsPreferences.setLayoutPreference(value);
                  LayoutModeScope.controllerOf(context)?.preference = value;
                },
                child: Column(
                  children: [
                    for (final preference in LayoutPreference.values)
                      RadioListTile<LayoutPreference>(
                        value: preference,
                        title: Text(preference.label),
                        subtitle: Text(preference.description),
                      ),
                  ],
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Performance', style: theme.textTheme.titleMedium),
              ),
              SwitchListTile(
                key: const ValueKey('hide-edges-switch'),
                title: const Text('Hide edges while moving on large models'),
                subtitle: const Text('Edges come back when the view stops. Off by default.'),
                value: _hideEdges,
                onChanged: (value) {
                  setState(() => _hideEdges = value);
                  ControlsPreferences.setHideEdgesWhileMoving(value);
                },
              ),
              ListTile(
                title: Text('Edge limit: ${_formatCount(_edgeLimit)} segments'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Slider(
                      key: const ValueKey('edge-limit-slider'),
                      value: kEdgeLimitSteps.indexOf(_edgeLimit).clamp(0, kEdgeLimitSteps.length - 1).toDouble(),
                      min: 0,
                      max: (kEdgeLimitSteps.length - 1).toDouble(),
                      divisions: kEdgeLimitSteps.length - 1,
                      label: _formatCount(_edgeLimit),
                      onChanged: _hideEdges
                          ? (value) {
                              final limit = kEdgeLimitSteps[value.round()];
                              setState(() => _edgeLimit = limit);
                              ControlsPreferences.setEdgeLimit(limit);
                            }
                          : null,
                    ),
                    if (ControlsPreferences.visibleEdgeSegments > 0)
                      Text(
                        'This model: ${_formatCount(ControlsPreferences.visibleEdgeSegments)}',
                        key: const ValueKey('edge-count-label'),
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.keyboard_outlined),
                title: const Text('Keyboard shortcuts'),
                subtitle: const Text('The list of keys (also on ? or F1 in each screen).'),
                onTap: () => showCadShortcutSheet(context, CadShortcut.values),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset to defaults'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 11918 as "11,918".
String _formatCount(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
