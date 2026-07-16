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

  /// The `assets/icons/feature/parttoolbar_*.svg` glyph for this mode - a
  /// single delivered "shaded" icon covers both [shaded] and
  /// [shadedWithEdges] (mirroring the Material `Icons.layers_outlined` this
  /// replaces, which was already shared between the two), and a distinct
  /// "wireframe" one for [wireframe]. Consumed via `SvgIcon(mode.svgAsset)`
  /// - see `part_toolbar.dart`'s and `sketch_screen.dart`'s own render-mode
  /// pickers, both of which list every [ViewportRenderMode.values] entry.
  String get svgAsset => switch (this) {
        ViewportRenderMode.wireframe => 'assets/icons/feature/parttoolbar_wireframe_mode.svg',
        ViewportRenderMode.shaded ||
        ViewportRenderMode.shadedWithEdges =>
          'assets/icons/feature/parttoolbar_shaded_mode.svg',
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
