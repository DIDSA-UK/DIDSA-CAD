import 'package:flutter/material.dart';

import 'ai/ai_modelling_screen.dart';
import 'gear/gear_design_screen.dart';
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
      // Scrollable rather than a bare Center: a fourth tile (AI Modelling)
      // pushed this past a fixed-height overflow on shorter viewports -
      // docs/ai-modelling/02-scoping-conversation.md's own doc-fix note.
      body: SafeArea(
        child: SingleChildScrollView(
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
                    const SizedBox(height: 16),
                    _ToolTile(
                      icon: 'assets/icons/feature/feature_revolve.svg',
                      label: 'Gear Design',
                      subtitle: 'External/internal gears and racks',
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const GearDesignScreen()),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ToolTile(
                      materialIcon: Icons.auto_awesome,
                      label: 'AI Modelling',
                      // `docs/ai-modelling/00-conventions.md`'s own explicit
                      // callout: this always starts a brand-new Part via a
                      // scoping conversation - it never assists an
                      // already-open one.
                      subtitle: 'Start a new part with AI help',
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const AiModellingScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  /// An SVG asset path (the original icon set every pre-existing tile
  /// uses) - exactly one of this or [materialIcon] should be given.
  final String? icon;

  /// A plain Material [IconData] fallback for a tile with no matching
  /// hand-off SVG glyph yet (AI Modelling's own tile) - avoids adding a new
  /// asset just for one tile.
  final IconData? materialIcon;

  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolTile({this.icon, this.materialIcon, required this.label, required this.subtitle, required this.onTap})
      : assert(icon != null || materialIcon != null, 'Provide either icon or materialIcon');

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
              if (icon != null) SvgIcon(icon!, color: Colors.white70, size: 32) else Icon(materialIcon, color: Colors.white70, size: 32),
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
