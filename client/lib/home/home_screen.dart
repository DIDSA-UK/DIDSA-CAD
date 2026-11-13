import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../ai/ai_generation_mode.dart';
import '../ai/ai_provider_preferences.dart';
import '../ai/ai_system_prompt_preferences.dart';
import '../config.dart';
import '../mesh_viewer/mesh_viewer_screen.dart';
import '../server_management/battery_optimization_controller.dart';
import '../tool_chooser_screen.dart';
import '../vr_pairing/headset_pairing_screen.dart';
import 'home_settings_screen.dart';
import 'home_status.dart';
import 'home_theme.dart';
import 'server_screen.dart';
import 'storage_screen.dart';

/// The first screen: the logo and five tiles, in one of three styles (`HomeStyle`, chosen from the settings wheel).
///
/// * **Mesh tools** - always available (on-device, no server).
/// * **CAD tools** - needs a server (greyed, with a lock, without one); opens the tool chooser.
/// * **Server** - define or connect the CAD server, or the on-device one; a green / red / grey light.
/// * **Storage** - local folder and cloud storage; a green / red / grey light.
/// * **Connect a VR headset** - needs a server.
///
/// A greyed tile still answers a tap: it looks again, and if the server really is not there it opens the Server screen with the reason,
/// instead of doing nothing.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.httpClient,
    this.batteryOptimizationController,
    this.statusController,
    this.meshViewerBuilder,
    this.toolChooserBuilder,
    this.headsetBuilder,
  });

  /// Overridable for tests, so no health check hits the real network.
  final http.Client? httpClient;

  /// Overridable for tests, so the Android battery-optimisation channel is never invoked for real.
  final BatteryOptimizationController? batteryOptimizationController;

  /// Overridable for tests: the status lights' source.
  final HomeStatusController? statusController;

  /// Overridable for tests: the screens the tiles open (the real ones need a viewport, a server, a camera).
  final WidgetBuilder? meshViewerBuilder;
  final WidgetBuilder? toolChooserBuilder;
  final WidgetBuilder? headsetBuilder;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final HomeStatusController _status;
  late final bool _ownsStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsStatus = widget.statusController == null;
    _status = widget.statusController ?? HomeStatusController(httpClient: widget.httpClient);
    unawaited(_loadSettings());
  }

  /// This screen is the app's one startup and return choke point (cold launch, File > Exit): the settings every later screen reads from
  /// memory are loaded here, as the old connection screen did. `AiModellingScreen` reads `AiProviderPreferences.active` and the others
  /// directly with no load of its own.
  Future<void> _loadSettings() async {
    await ApiConfig.load();
    await HomePreferences.load();
    await AiProviderPreferences.load();
    await AiSystemPromptPreferences.load();
    await AiGenerationModePreferences.load();
    if (!mounted) return;
    _status.start();
    unawaited(_maybeOfferBatteryOptimization());
  }

  /// Android-only: battery optimisation can kill the app in the background and take unsaved progress with it. Offers the exemption once.
  Future<void> _maybeOfferBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    final controller = widget.batteryOptimizationController ?? BatteryOptimizationController();
    if (await controller.isIgnoringOptimizations()) return;
    if (await controller.isPromptDismissed()) return;
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable battery optimisation?'),
        content: const Text(
          'Battery optimisation may unexpectedly kill this app and unsaved progress can be lost. '
          'Disabling it for this app keeps it running reliably in the background.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Disable')),
        ],
      ),
    );
    await controller.setPromptDismissed();
    if (accepted == true) await controller.requestIgnoreOptimizations();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_status.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsStatus) _status.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------- what the tiles do

  Future<void> _openServer({String? note}) async {
    await pushHomeRoute<bool>(context, (_) => ServerScreen(httpClient: widget.httpClient, note: note));
    if (mounted) unawaited(_status.refresh());
  }

  Future<void> _openStorage() async {
    await pushHomeRoute<void>(context, (_) => StorageScreen(httpClient: widget.httpClient));
    if (mounted) unawaited(_status.refresh());
  }

  /// A tile that needs the server: looks again first (the light may be stale), then opens [destination], or the Server screen saying why.
  Future<void> _needsServer(String what, WidgetBuilder destination) async {
    if (!_status.value.serverUsable) await _status.refresh();
    if (!mounted) return;
    if (_status.value.serverUsable) {
      await pushHomeRoute<void>(context, destination);
      return;
    }
    await _openServer(
      note: _status.value.server == ServerLight.notSetUp
          ? 'Connect a server to use $what.'
          : "The server isn't answering. Check it, or connect to another one, to use $what.",
    );
  }

  List<HomeTile> _tiles(HomeTheme home, HomeStatus status) {
    final usable = status.serverUsable;
    Color light(Color ok, Color bad, Color neutral, int kind) => switch (kind) {
          1 => ok,
          2 => bad,
          _ => neutral,
        };
    return [
      HomeTile(
        id: 'mesh',
        title: 'Mesh tools',
        subtitle: 'Works offline',
        icon: Icons.polyline_outlined,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: widget.meshViewerBuilder ?? (_) => const MeshViewerScreen()),
        ),
      ),
      HomeTile(
        id: 'cad',
        title: 'CAD tools',
        subtitle: usable ? 'Model and assemble' : 'Needs a server',
        icon: Icons.view_in_ar_outlined,
        locked: !usable,
        onTap: () => _needsServer('CAD tools', widget.toolChooserBuilder ?? (_) => const ToolChooserScreen()),
      ),
      HomeTile(
        id: 'server',
        title: 'Server',
        subtitle: switch (status.server) {
          ServerLight.checking => 'Checking…',
          _ => status.serverDetail,
        },
        icon: Icons.dns_outlined,
        light: light(
          home.ok,
          home.bad,
          home.neutral,
          switch (status.server) {
            ServerLight.connected => 1,
            ServerLight.unreachable => 2,
            _ => 0,
          },
        ),
        onTap: _openServer,
      ),
      HomeTile(
        id: 'storage',
        title: 'Storage',
        subtitle: switch (status.storage) {
          StorageLight.checking => 'Checking…',
          _ => status.storageDetail,
        },
        icon: Icons.folder_outlined,
        light: light(
          home.ok,
          home.bad,
          home.neutral,
          switch (status.storage) {
            StorageLight.online => 1,
            StorageLight.offline => 2,
            _ => 0,
          },
        ),
        onTap: _openStorage,
      ),
      HomeTile(
        id: 'vr',
        title: 'Connect a VR headset',
        subtitle: usable ? 'Pair with a QR code' : 'Needs a server',
        icon: Icons.vrpano_outlined,
        locked: !usable,
        onTap: () => _needsServer(
          'a VR headset',
          widget.headsetBuilder ?? (_) => HeadsetPairingScreen(httpClient: widget.httpClient),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return HomeThemed(
      child: ListenableBuilder(
        listenable: _status,
        builder: (context, _) => ValueListenableBuilder<HomeStyle>(
          valueListenable: HomePreferences.style,
          builder: (context, style, _) {
            final home = HomeTheme.of(style);
            final status = _status.value;
            final tiles = _tiles(home, status);
            final settings = IconButton(
              key: const ValueKey('home-settings'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => pushHomeRoute<void>(context, (_) => const HomeSettingsScreen()),
            );
            return Scaffold(
              body: switch (style) {
                HomeStyle.blueprint => _BlueprintHome(home: home, tiles: tiles, status: status, settings: settings),
                HomeStyle.instrument => _InstrumentHome(home: home, tiles: tiles, status: status, settings: settings),
                HomeStyle.drawing => _DrawingHome(home: home, tiles: tiles, status: status, settings: settings),
              },
            );
          },
        ),
      ),
    );
  }
}

/// One tile of the home screen, whatever the style: the three layouts draw the same data differently.
class HomeTile {
  const HomeTile({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.light,
    this.locked = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  /// A status light (Server, Storage): green / red / grey.
  final Color? light;

  /// Needs a server and there is none: greyed, with a lock. Still tappable (it says why).
  final bool locked;
}

/// The logo, with the wordmark as a fallback if the asset is missing.
class _Logo extends StatelessWidget {
  const _Logo({required this.home, this.height = 44});

  final HomeTheme home;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      home.logoAsset,
      key: const ValueKey('home-logo'),
      height: height,
      alignment: Alignment.centerLeft,
      errorBuilder: (context, error, stackTrace) => Text(
        'DIDSA',
        style: TextStyle(color: home.foreground, fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: 8),
      ),
    );
  }
}

/// A round status light with a soft glow when it is on.
class StatusLight extends StatelessWidget {
  const StatusLight({super.key, required this.color, this.glow = true, this.size = 9});

  final Color color;
  final bool glow;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 7)] : null,
      ),
    );
  }
}

/// Greys a tile that needs a server and has none.
class _Dimmed extends StatelessWidget {
  const _Dimmed({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => on ? Opacity(opacity: 0.4, child: child) : child;
}

Widget _tileCorner(HomeTheme home, HomeTile tile) {
  if (tile.light != null) return StatusLight(key: ValueKey('light-${tile.id}'), color: tile.light!, glow: tile.light != home.neutral);
  if (tile.locked) return Icon(Icons.lock_outline, key: ValueKey('lock-${tile.id}'), size: 15, color: home.muted);
  return const SizedBox.shrink();
}

// ================================================================================================ A: blueprint

class _BlueprintHome extends StatelessWidget {
  const _BlueprintHome({required this.home, required this.tiles, required this.status, required this.settings});

  final HomeTheme home;
  final List<HomeTile> tiles;
  final HomeStatus status;
  final Widget settings;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(home.accent.withValues(alpha: 0.07)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [settings]),
                  const SizedBox(height: 4),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _Logo(home: home, height: 46)),
                  const SizedBox(height: 14),
                  Container(height: 1, color: home.line),
                  const SizedBox(height: 22),
                  Row(children: [Expanded(child: _tile(tiles[0])), const SizedBox(width: 10), Expanded(child: _tile(tiles[1]))]),
                  const SizedBox(height: 10),
                  Row(children: [Expanded(child: _tile(tiles[2])), const SizedBox(width: 10), Expanded(child: _tile(tiles[3]))]),
                  const SizedBox(height: 10),
                  _tile(tiles[4], wide: true),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text('DIDSA-CAD', style: home.caption(size: 10)), Text('SHEET 1 / 1', style: home.caption(size: 10))],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(HomeTile tile, {bool wide = false}) {
    return _Dimmed(
      on: tile.locked,
      child: Semantics(
        button: true,
        label: '${tile.title}. ${tile.subtitle}',
        child: InkWell(
          key: ValueKey('tile-${tile.id}'),
          onTap: tile.onTap,
          child: CustomPaint(
            foregroundPainter: _CornerTicksPainter(home.accent),
            child: Container(
              constraints: BoxConstraints(minHeight: wide ? 96 : 124),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: home.tile, border: Border.all(color: home.line), borderRadius: BorderRadius.circular(home.radius)),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: _label(tile)),
                        _tileCorner(home, tile),
                        const SizedBox(width: 10),
                        Icon(tile.icon, color: home.accent, size: 30),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Icon(tile.icon, color: home.accent, size: 28), _tileCorner(home, tile)]),
                        const SizedBox(height: 26),
                        _label(tile),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(HomeTile tile) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tile.title, style: TextStyle(color: home.foreground, fontWeight: FontWeight.w600, fontSize: 14, height: 1.2)),
          const SizedBox(height: 3),
          Text(tile.subtitle, style: home.caption(size: 10)),
        ],
      );
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 20) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

class _CornerTicksPainter extends CustomPainter {
  const _CornerTicksPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const t = 8.0;
    canvas.drawPath(Path()..moveTo(0, t)..lineTo(0, 0)..lineTo(t, 0), paint);
    canvas.drawPath(Path()..moveTo(size.width - t, size.height)..lineTo(size.width, size.height)..lineTo(size.width, size.height - t), paint);
  }

  @override
  bool shouldRepaint(_CornerTicksPainter old) => old.color != color;
}

// ================================================================================================ B: instrument panel

class _InstrumentHome extends StatelessWidget {
  const _InstrumentHome({required this.home, required this.tiles, required this.status, required this.settings});

  final HomeTheme home;
  final List<HomeTile> tiles;
  final HomeStatus status;
  final Widget settings;

  @override
  Widget build(BuildContext context) {
    final mesh = tiles[0], cad = tiles[1], server = tiles[2], storage = tiles[3], vr = tiles[4];
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [settings]),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _Logo(home: home, height: 44)),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _led('server', server),
                    _led('storage', storage),
                  ],
                ),
                const SizedBox(height: 22),
                _row(cad, primary: true),
                const SizedBox(height: 8),
                _row(mesh),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Expanded(child: _square(server)), const SizedBox(width: 8), Expanded(child: _square(storage))],
                ),
                const SizedBox(height: 8),
                _row(vr),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _led(String name, HomeTile tile) => Container(
        key: ValueKey('led-$name'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: home.line), borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusLight(color: tile.light ?? home.neutral, glow: tile.light != home.neutral, size: 7),
            const SizedBox(width: 6),
            Text(name, style: home.caption(size: 10)),
          ],
        ),
      );

  BoxDecoration _box({bool primary = false}) => BoxDecoration(
        color: primary ? const Color(0xFF1F2831) : home.tile,
        border: Border.all(color: primary ? home.frame : home.line),
        borderRadius: BorderRadius.circular(home.radius),
      );

  Widget _row(HomeTile tile, {bool primary = false}) => _Dimmed(
        on: tile.locked,
        child: Semantics(
          button: true,
          label: '${tile.title}. ${tile.subtitle}',
          child: InkWell(
            key: ValueKey('tile-${tile.id}'),
            borderRadius: BorderRadius.circular(home.radius),
            onTap: tile.onTap,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: primary ? 20 : 14),
              decoration: _box(primary: primary),
              child: Row(
                children: [
                  Icon(tile.icon, color: home.accent, size: primary ? 32 : 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tile.title, style: TextStyle(color: home.foreground, fontWeight: FontWeight.w600, fontSize: primary ? 16 : 14)),
                        const SizedBox(height: 2),
                        Text(tile.subtitle, style: home.caption(size: 10)),
                      ],
                    ),
                  ),
                  Builder(builder: (context) {
                    final corner = _tileCorner(home, tile);
                    return corner is SizedBox ? Text('›', style: home.caption(size: 16)) : corner;
                  }),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _square(HomeTile tile) => Semantics(
        button: true,
        label: '${tile.title}. ${tile.subtitle}',
        child: InkWell(
          key: ValueKey('tile-${tile.id}'),
          borderRadius: BorderRadius.circular(home.radius),
          onTap: tile.onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 100),
            padding: const EdgeInsets.all(14),
            decoration: _box(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Icon(tile.icon, color: home.accent, size: 26), _tileCorner(home, tile)]),
                const SizedBox(height: 14),
                Text(tile.title, style: TextStyle(color: home.foreground, fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(tile.subtitle, style: home.caption(size: 10)),
              ],
            ),
          ),
        ),
      );
}

// ================================================================================================ C: drawing sheet

class _DrawingHome extends StatelessWidget {
  const _DrawingHome({required this.home, required this.tiles, required this.status, required this.settings});

  final HomeTheme home;
  final List<HomeTile> tiles;
  final HomeStatus status;
  final Widget settings;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [settings]),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: home.frame, width: 1.5)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: home.frame))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Logo(home: home, height: 42),
                              const SizedBox(height: 6),
                              Text('DESIGN TOOLS', style: home.caption(size: 10).copyWith(letterSpacing: 1.4)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: Row(children: [_cell(tiles[0], 1, rightBorder: true), _cell(tiles[1], 2)])),
                              Expanded(child: Row(children: [_cell(tiles[2], 3, rightBorder: true), _cell(tiles[3], 4)])),
                              Expanded(child: Row(children: [_cell(tiles[4], 5, wide: true)])),
                            ],
                          ),
                        ),
                        _titleBlock(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(HomeTile tile, int number, {bool rightBorder = false, bool wide = false}) {
    final border = BorderDirectional(
      bottom: BorderSide(color: home.frame),
      end: rightBorder ? BorderSide(color: home.frame) : BorderSide.none,
    );
    return Expanded(
      child: _Dimmed(
        on: tile.locked,
        child: Semantics(
          button: true,
          label: '${tile.title}. ${tile.subtitle}',
          child: InkWell(
            key: ValueKey('tile-${tile.id}'),
            onTap: tile.onTap,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: home.tile, border: border),
              child: Stack(
                children: [
                  Positioned(left: 0, top: 0, child: Text('0$number', style: home.caption(size: 9))),
                  Positioned(right: 0, top: 0, child: _tileCorner(home, tile)),
                  if (wide)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: _label(tile)),
                          Icon(tile.icon, color: home.accent, size: 30),
                        ],
                      ),
                    )
                  else ...[
                    Positioned(left: 0, top: 18, child: Icon(tile.icon, color: home.accent, size: 28)),
                    Align(alignment: Alignment.bottomLeft, child: _label(tile)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(HomeTile tile) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tile.title, style: TextStyle(color: home.foreground, fontWeight: FontWeight.w600, fontSize: 14, height: 1.2)),
          const SizedBox(height: 2),
          Text(tile.subtitle, style: home.caption(size: 10), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      );

  Widget _titleBlock() {
    Widget cell(String label, String value, {bool last = false}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(border: last ? null : Border(right: BorderSide(color: home.frame))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: home.caption(size: 8).copyWith(letterSpacing: 1)),
                Text(value, style: home.caption(size: 10, color: home.foreground), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        );
    return Container(
      key: const ValueKey('title-block'),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: home.frame))),
      child: IntrinsicHeight(
        child: Row(
          children: [
            cell('Device', ApiConfig.effectiveDeviceName),
            cell('Server', switch (status.server) {
              ServerLight.connected => 'connected',
              ServerLight.unreachable => 'unreachable',
              ServerLight.notSetUp => 'not set up',
              ServerLight.checking => 'checking',
            }),
            cell('Storage', switch (status.storage) {
              StorageLight.online => 'cloud online',
              StorageLight.offline => 'cloud offline',
              StorageLight.localOnly => 'local folder',
              StorageLight.checking => 'checking',
            }, last: true),
          ],
        ),
      ),
    );
  }
}
