import 'package:material_ui/material_ui.dart';

/// Look-and-feel for the AI tool's screens (AI Modelling, AI Provider
/// Settings, AI System Prompt). The rest of the app is light-only, so the AI
/// tool scopes its own theme, following the system light/dark setting.
class AiTheme {
  AiTheme._();

  static const Color _seed = Color(0xFF5B5BD6);

  /// The themed [ThemeData] for the current platform brightness.
  static ThemeData of(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    return build(brightness);
  }

  static ThemeData build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);

    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: border(Colors.transparent),
        enabledBorder: border(Colors.transparent),
        disabledBorder: border(Colors.transparent),
        focusedBorder: border(scheme.primary, 1.5),
        errorBorder: border(scheme.error),
        focusedErrorBorder: border(scheme.error, 1.5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.7), space: 24),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Wraps [builder] in the AI theme. The inner [BuildContext] handed to
  /// [builder] sees the themed [Theme], so `Theme.of(context)` and
  /// [AiPalette.of] resolve correctly inside it.
  static Widget wrap(BuildContext context, WidgetBuilder builder) =>
      Theme(data: of(context), child: Builder(builder: builder));
}

/// Semantic status colours that stay legible in both light and dark mode
/// (the stock `Colors.green`/`redAccent`/`white54` are not: `white54` is
/// invisible on a light background).
class AiPalette {
  final Color success;
  final Color warning;
  final Color danger;

  /// De-emphasised secondary text.
  final Color muted;

  const AiPalette._(this.success, this.warning, this.danger, this.muted);

  static const _light = (success: Color(0xFF1B7F4B), warning: Color(0xFFB45309), danger: Color(0xFFC62828));
  static const _dark = (success: Color(0xFF5BD08A), warning: Color(0xFFF5B748), danger: Color(0xFFF28B82));

  static AiPalette of(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.brightness == Brightness.dark ? _dark : _light;
    return AiPalette._(c.success, c.warning, c.danger, theme.colorScheme.onSurfaceVariant);
  }
}
