/// The home screen's three looks (concept sketches A, B and C, 13 Nov) and the theme each gives the screens reached from home.
///
/// A [HomeStyle] is a palette plus a few shape choices; [HomeTheme.themeData] turns it into a `ThemeData`, which `HomeThemed` wraps around
/// the home screen and every sub-menu opened from it (server, storage, settings, the tool chooser...), so they match. Screens that open
/// a tool (the part editor, the sketcher...) are not wrapped: they keep the app's own theme.
library;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HomeStyle {
  /// Dark navy grid paper, hairline frames with corner ticks, one cyan accent.
  blueprint,

  /// Dark graphite panel: status lights up top, one primary tile, list rows.
  instrument,

  /// A light sheet framed like an engineering drawing: numbered cells and a title block.
  drawing,
}

/// The palette and shape of one [HomeStyle].
class HomeTheme {
  const HomeTheme({
    required this.style,
    required this.label,
    required this.blurb,
    required this.brightness,
    required this.background,
    required this.tile,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.line,
    required this.frame,
    required this.ok,
    required this.bad,
    required this.neutral,
    required this.radius,
    required this.logoAsset,
  });

  final HomeStyle style;
  final String label;
  final String blurb;
  final Brightness brightness;
  final Color background;

  /// The fill of a tile.
  final Color tile;
  final Color foreground;
  final Color muted;
  final Color accent;

  /// Hairlines and tile borders.
  final Color line;

  /// The strong outline (the drawing sheet's frame, a focused tile).
  final Color frame;

  /// Status lights: connected / online, set up but unreachable, not set up.
  final Color ok;
  final Color bad;
  final Color neutral;
  final double radius;
  final String logoAsset;

  bool get dark => brightness == Brightness.dark;

  /// A mono-ish caption face (the platform's own: no font is bundled for it).
  TextStyle caption({Color? color, double size = 11}) => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
        fontSize: size,
        height: 1.35,
        color: color ?? muted,
      );

  static const blueprint = HomeTheme(
    style: HomeStyle.blueprint,
    label: 'Blueprint',
    blurb: 'Dark grid paper with hairline frames',
    brightness: Brightness.dark,
    background: Color(0xFF0C2233),
    tile: Color(0x0D5CC3F0),
    foreground: Color(0xFFE8F1F8),
    muted: Color(0xFF7FA3BD),
    accent: Color(0xFF5CC3F0),
    line: Color(0xFF25506E),
    frame: Color(0xFF5CC3F0),
    ok: Color(0xFF3EC28F),
    bad: Color(0xFFEE5D5D),
    neutral: Color(0xFF5A6B78),
    radius: 2,
    logoAsset: 'assets/images/didsa_logo.png',
  );

  static const instrument = HomeTheme(
    style: HomeStyle.instrument,
    label: 'Instrument panel',
    blurb: 'Graphite, status lights, one primary tile',
    brightness: Brightness.dark,
    background: Color(0xFF14181D),
    tile: Color(0xFF1C222A),
    foreground: Color(0xFFE9EDF1),
    muted: Color(0xFF8B97A3),
    accent: Color(0xFF3AA7DC),
    line: Color(0xFF2A323B),
    frame: Color(0xFF33414E),
    ok: Color(0xFF3EC28F),
    bad: Color(0xFFEE5D5D),
    neutral: Color(0xFF5A6B78),
    radius: 10,
    logoAsset: 'assets/images/didsa_logo.png',
  );

  static const drawing = HomeTheme(
    style: HomeStyle.drawing,
    label: 'Drawing sheet',
    blurb: 'Light sheet with a title block, for daylight',
    brightness: Brightness.light,
    background: Color(0xFFF4F6F8),
    tile: Color(0xFFFFFFFF),
    foreground: Color(0xFF111B24),
    muted: Color(0xFF5D6E7D),
    accent: Color(0xFF0A79B4),
    line: Color(0xFF9FB0BF),
    frame: Color(0xFF111B24),
    ok: Color(0xFF1E9E6A),
    bad: Color(0xFFD14343),
    neutral: Color(0xFF8795A1),
    radius: 0,
    logoAsset: 'assets/images/didsa_logo_dark.png',
  );

  static HomeTheme of(HomeStyle style) => switch (style) {
        HomeStyle.blueprint => blueprint,
        HomeStyle.instrument => instrument,
        HomeStyle.drawing => drawing,
      };

  static const all = [blueprint, instrument, drawing];

  /// The `ThemeData` every screen reached from home gets, so sub-menus match the home screen.
  ThemeData get themeData {
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : const Color(0xFF06141F);
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      error: bad,
      onError: Colors.white,
      surface: background,
      onSurface: foreground,
      onSurfaceVariant: muted,
      outline: line,
      outlineVariant: line,
      surfaceContainerHighest: tile,
      surfaceContainerHigh: tile,
      surfaceContainer: tile,
      surfaceContainerLow: background,
      primaryContainer: tile,
      onPrimaryContainer: foreground,
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: color, width: width));
    final base = ThemeData(brightness: brightness, colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: line,
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      textTheme: base.textTheme.apply(bodyColor: foreground, displayColor: foreground),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: foreground),
      ),
      iconTheme: IconThemeData(color: foreground),
      listTileTheme: ListTileThemeData(iconColor: accent, textColor: foreground, subtitleTextStyle: caption()),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: TextStyle(color: muted),
        hintStyle: TextStyle(color: muted.withValues(alpha: 0.7)),
        border: border(line),
        enabledBorder: border(line),
        focusedBorder: border(accent, 1.5),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape, foregroundColor: foreground, side: BorderSide(color: line)),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape, foregroundColor: accent)),
      cardTheme: CardThemeData(color: tile, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: line))),
      dialogTheme: DialogThemeData(backgroundColor: background, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: line))),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: background, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius)))),
      snackBarTheme: SnackBarThemeData(backgroundColor: foreground, contentTextStyle: TextStyle(color: background), behavior: SnackBarBehavior.floating),
      expansionTileTheme: ExpansionTileThemeData(iconColor: muted, collapsedIconColor: muted, textColor: foreground, collapsedTextColor: foreground),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(background),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : line),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}

/// Which look the home screen has: remembered across launches, and live (the home screen and its sub-menus rebuild when it changes).
class HomePreferences {
  HomePreferences._();

  static const styleKey = 'home_style';

  static final ValueNotifier<HomeStyle> style = ValueNotifier(HomeStyle.blueprint);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(styleKey);
    style.value = HomeStyle.values.where((s) => s.name == name).firstOrNull ?? HomeStyle.blueprint;
  }

  static Future<void> setStyle(HomeStyle value) async {
    style.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(styleKey, value.name);
  }
}

/// Gives [child] the current home theme, following [HomePreferences.style] live.
class HomeThemed extends StatelessWidget {
  const HomeThemed({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomeStyle>(
      valueListenable: HomePreferences.style,
      builder: (context, style, _) => Theme(data: HomeTheme.of(style).themeData, child: child),
    );
  }
}

/// Opens [builder]'s screen in the current home theme: every sub-menu of the home screen goes through this so it matches.
Future<T?> pushHomeRoute<T>(BuildContext context, WidgetBuilder builder) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(builder: (_) => HomeThemed(child: Builder(builder: builder))),
  );
}
