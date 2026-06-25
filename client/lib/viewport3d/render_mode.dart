import 'package:flutter/material.dart' show IconData, Icons;
import 'package:vector_math/vector_math.dart' as vm;

/// Stage 11's three viewport display modes, toggled from [PartToolbar]'s
/// flyout: `shaded` (the pre-Stage-11 default - filled faces only),
/// `shadedWithEdges` (filled faces plus the Part's real OCCT edge
/// polylines drawn on top), and `wireframe` (edges only, no filled faces).
/// [PartScreen] owns the current mode, persisted via [ViewPreferences]
/// (`view_render_mode`) since Stage 19a Item 5 - was in-memory only, always
/// resetting to [ViewportRenderMode.shaded] on app restart.
enum ViewportRenderMode { shaded, shadedWithEdges, wireframe }

extension ViewportRenderModeX on ViewportRenderMode {
  String get label => switch (this) {
        ViewportRenderMode.shaded => 'Shaded',
        ViewportRenderMode.shadedWithEdges => 'Shaded + Edges',
        ViewportRenderMode.wireframe => 'Wireframe',
      };

  IconData get icon => switch (this) {
        ViewportRenderMode.shaded => Icons.layers_outlined,
        ViewportRenderMode.shadedWithEdges => Icons.layers_outlined,
        ViewportRenderMode.wireframe => Icons.grid_3x3_outlined,
      };

  bool get showsFilledFaces => this != ViewportRenderMode.wireframe;

  bool get showsEdges => this != ViewportRenderMode.shaded;

  /// Edge line color for this mode - dark grey (#333333) for
  /// `shadedWithEdges` (reads clearly against filled faces without
  /// overpowering them), mid grey (#666666) for `wireframe` (the only
  /// geometry on screen, so it can afford to be lighter). Unused (never
  /// read) when [showsEdges] is false.
  vm.Vector4 get edgeColor => switch (this) {
        ViewportRenderMode.shadedWithEdges => vm.Vector4(0x33 / 255, 0x33 / 255, 0x33 / 255, 1.0),
        ViewportRenderMode.wireframe => vm.Vector4(0x66 / 255, 0x66 / 255, 0x66 / 255, 1.0),
        ViewportRenderMode.shaded => vm.Vector4(0, 0, 0, 0),
      };
}
