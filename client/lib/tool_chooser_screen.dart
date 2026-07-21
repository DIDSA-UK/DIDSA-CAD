import 'package:flutter/material.dart';

import 'sketch/sketch_screen.dart';
import 'viewport3d/part_screen.dart';
import 'viewport3d/svg_icon.dart';

/// Shown right after a successful [ConnectionScreen] connect, in place of
/// jumping straight to [PartScreen] - lets the user pick which tool they
/// actually want: [PartScreen] (3D Part design - Sketch/Extrude/Revolve/
/// Sweep/etc., the app's original and still-primary tool) or a standalone,
/// Part-free [SketchScreen] (the new "2D Drawing" tool - floor plans and
/// other purely-flat drawings, reached from `SketchScreen.standalone`'s own
/// doc comment). Both destinations are server-backed (a Sketch, like a
/// Part, lives in the backend's in-memory store - see `SketchScreen`'s own
/// standalone-usage doc comments), so this only ever runs after Connect has
/// already succeeded, never before it the way `MeshViewerScreen` (fully
/// on-device, no server needed) can be reached from [ConnectionScreen]
/// directly.
class ToolChooserScreen extends StatelessWidget {
  const ToolChooserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const backgroundColor = Color(0xFF1E1E2E);
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'What would you like to open?',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _ToolTile(
                    icon: 'assets/icons/feature/feature_extrude.svg',
                    label: '3D Part Design',
                    subtitle: 'Sketch, extrude, and build a solid model',
                    onTap: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const PartScreen()),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ToolTile(
                    icon: 'assets/icons/feature/feature_new_sketch.svg',
                    label: '2D Drawing',
                    subtitle: 'Floor plans and other flat drawings',
                    onTap: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const SketchScreen(standalone: true)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  final String icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolTile({required this.icon, required this.label, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              SvgIcon(icon, color: Colors.white70, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
