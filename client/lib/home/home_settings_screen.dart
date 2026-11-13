import 'package:material_ui/material_ui.dart';

import '../mesh_viewer/mesh_viewer_settings_screen.dart';
import '../sketch/sketcher_settings_screen.dart';
import '../viewport3d/controls_settings_screen.dart';
import 'home_theme.dart';

/// The home screen's settings wheel: the home screen's **style** (Blueprint, Instrument panel, Drawing sheet) and the settings that used
/// to sit as gears on the old connection screen (sketcher, mesh viewer) plus the mouse and keyboard controls.
class HomeSettingsScreen extends StatelessWidget {
  const HomeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final home = HomeTheme.of(HomePreferences.style.value);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text(text.toUpperCase(), style: home.caption(color: home.accent).copyWith(letterSpacing: 1.2)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              children: [
                heading('Home screen style'),
                ValueListenableBuilder<HomeStyle>(
                  valueListenable: HomePreferences.style,
                  builder: (context, current, _) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        for (final option in HomeTheme.all) ...[
                          _StyleOption(option: option, selected: option.style == current),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                ),
                heading('Tools'),
                ListTile(
                  key: const ValueKey('settings-sketcher'),
                  leading: const Icon(Icons.draw_outlined),
                  title: const Text('Sketcher'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => pushHomeRoute<void>(context, (_) => const SketcherSettingsScreen()),
                ),
                ListTile(
                  key: const ValueKey('settings-mesh-viewer'),
                  leading: const Icon(Icons.polyline_outlined),
                  title: const Text('Mesh viewer'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => pushHomeRoute<void>(context, (_) => const MeshViewerSettingsScreen()),
                ),
                ListTile(
                  key: const ValueKey('settings-controls'),
                  leading: const Icon(Icons.mouse_outlined),
                  title: const Text('Mouse and keyboard'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => pushHomeRoute<void>(context, (_) => const ControlsSettingsScreen()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One style: a small swatch drawn in its own colours, its name, and what it is.
class _StyleOption extends StatelessWidget {
  const _StyleOption({required this.option, required this.selected});

  final HomeTheme option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final current = HomeTheme.of(HomePreferences.style.value);
    return Semantics(
      selected: selected,
      button: true,
      label: '${option.label}. ${option.blurb}',
      child: InkWell(
        key: ValueKey('style-${option.style.name}'),
        borderRadius: BorderRadius.circular(current.radius),
        onTap: () => HomePreferences.setStyle(option.style),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? current.accent : current.line, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(current.radius),
            color: current.tile,
          ),
          child: Row(
            children: [
              _Swatch(option: option),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(option.blurb, style: current.caption(size: 11)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: current.accent) else Icon(Icons.circle_outlined, color: current.line),
            ],
          ),
        ),
      ),
    );
  }
}

/// A miniature of a style's home screen: its background, four tiles and a status light, in its own colours.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.option});

  final HomeTheme option;

  @override
  Widget build(BuildContext context) {
    Widget cell() => Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: option.tile == Colors.transparent ? null : option.tile,
              border: Border.all(color: option.style == HomeStyle.drawing ? option.frame : option.line, width: 1),
              borderRadius: BorderRadius.circular(option.radius / 2),
            ),
          ),
        );
    return Container(
      width: 64,
      height: 64,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: option.background, border: Border.all(color: option.line), borderRadius: BorderRadius.circular(option.radius / 2)),
      child: Column(
        children: [
          Container(height: 5, width: 26, margin: const EdgeInsets.only(bottom: 4), color: option.accent, alignment: Alignment.centerLeft),
          Expanded(child: Row(children: [cell(), const SizedBox(width: 3), cell()])),
          const SizedBox(height: 3),
          Expanded(child: Row(children: [cell(), const SizedBox(width: 3), Expanded(child: Container(decoration: BoxDecoration(color: option.ok.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(2))))])),
        ],
      ),
    );
  }
}
