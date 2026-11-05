import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'orbit_camera.dart';

/// Presentation mode (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 3B): the part and assembly screens with
/// the editing chrome hidden, for mirroring to a TV or room screen.

/// A slow constant orbit for an unattended display. [tick] turns the camera by the same step every call and [stop]
/// (a touch, the menu toggle) ends it; it never restarts on its own.
class Turntable {
  /// Horizontal drag pixels fed to the orbit each tick: a slow turn (0.2 px x 0.01 rad per px x 60 ticks a second is
  /// about 0.12 rad/s, a revolution in roughly 50 seconds).
  static const double pixelsPerTick = 0.2;

  bool _running = false;
  bool get running => _running;

  void start() => _running = true;
  void stop() => _running = false;

  /// A pointer went down: a touch takes the view back from the turntable.
  void onPointerDown() => stop();

  /// One step, about [pivot] when one is set, else about the camera's target. Does nothing while stopped.
  void tick(OrbitCamera camera, {vm.Vector3? pivot}) {
    if (!_running) return;
    if (pivot != null) {
      camera.orbitAboutPointByScreenDelta(pixelsPerTick, 0, pivot);
    } else {
      camera.orbitByScreenDelta(pixelsPerTick, 0);
    }
  }
}

/// The system UI and orientation while presenting: immersive, and landscape so a phone's mirror fills a 16:9 screen
/// instead of a portrait strip with black bars. Both are only applied while presenting and fully undone on exit, so
/// nothing fights a desktop-windowing session (DeX, Stage Manager) outside it.
class PresentationSystemUi {
  const PresentationSystemUi({this.enabled});

  /// Whether to touch the system UI at all. Null: only on Android and iOS (a desktop window is left alone).
  final bool? enabled;

  bool get _active =>
      enabled ?? (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> enter() async {
    if (!_active) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> exit() async {
    if (!_active) return;
    // An empty list lifts the lock: the platform's own orientations apply again.
    await SystemChrome.setPreferredOrientations(const []);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}

/// What the presenter menu asks [PartScreen] to do.
class PresenterMenuActions {
  const PresenterMenuActions({
    required this.onOpenModel,
    required this.onToggleTurntable,
    required this.turntableOn,
    required this.onResetView,
    required this.onClearPivot,
    required this.hasPivot,
    required this.onToggleControls,
    required this.controlsShown,
    required this.onStop,
    this.onPreviousScene,
    this.onNextScene,
  });

  final VoidCallback onOpenModel;
  final VoidCallback onToggleTurntable;
  final bool turntableOn;
  final VoidCallback onResetView;
  final VoidCallback onClearPivot;
  final bool hasPivot;
  final VoidCallback onToggleControls;
  final bool controlsShown;
  final VoidCallback onStop;

  /// Null when there are no scenes to step through.
  final VoidCallback? onPreviousScene;
  final VoidCallback? onNextScene;
}

/// The presenter button: always in the top-right corner while presenting. It fades to a faint ghost when untouched, so
/// it does not sit on the audience's picture, but it never disappears and stays tappable at any opacity, so the
/// presenter can always find it.
class PresenterButton extends StatelessWidget {
  const PresenterButton({super.key, required this.faded, required this.menuOpen, required this.onPressed});

  static const double fadedOpacity = 0.18;
  static const double activeOpacity = 0.85;

  final bool faded;
  final bool menuOpen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 400),
      opacity: faded && !menuOpen ? fadedOpacity : activeOpacity,
      child: IconButton.filledTonal(
        key: const ValueKey('presenter-button'),
        tooltip: 'Presenter menu',
        icon: Icon(menuOpen ? Icons.close : Icons.slideshow),
        onPressed: onPressed,
      ),
    );
  }
}

/// The presenter menu: a compact card under the presenter button, not the full editing UI. "Show all controls" is the
/// escape hatch for anything it does not list.
class PresenterMenu extends StatelessWidget {
  const PresenterMenu({super.key, required this.actions, required this.onDismiss});

  final PresenterMenuActions actions;

  /// Closes the menu (every entry calls this after its own action).
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    Widget entry({
      required String key,
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool checked = false,
      bool keepOpen = false,
    }) {
      return ListTile(
        key: ValueKey('presenter-$key'),
        dense: true,
        visualDensity: VisualDensity.compact,
        enabled: onTap != null,
        leading: Icon(icon),
        title: Text(label),
        trailing: checked ? const Icon(Icons.check, size: 18) : null,
        onTap: onTap == null
            ? null
            : () {
                if (!keepOpen) onDismiss();
                onTap();
              },
      );
    }

    return Material(
      key: const ValueKey('presenter-menu'),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 280, maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              entry(key: 'open', icon: Icons.folder_open, label: 'Open model…', onTap: actions.onOpenModel),
              if (actions.onPreviousScene != null)
                entry(key: 'scene-previous', icon: Icons.skip_previous, label: 'Previous scene', onTap: actions.onPreviousScene, keepOpen: true),
              if (actions.onNextScene != null)
                entry(key: 'scene-next', icon: Icons.skip_next, label: 'Next scene', onTap: actions.onNextScene, keepOpen: true),
              entry(
                key: 'turntable',
                icon: Icons.threed_rotation,
                label: 'Turntable',
                checked: actions.turntableOn,
                onTap: actions.onToggleTurntable,
              ),
              entry(key: 'reset-view', icon: Icons.restart_alt, label: 'Reset view', onTap: actions.onResetView),
              entry(
                key: 'clear-pivot',
                icon: Icons.gps_off,
                label: 'Clear pivot',
                onTap: actions.hasPivot ? actions.onClearPivot : null,
              ),
              const Divider(height: 1),
              entry(
                key: 'controls',
                icon: actions.controlsShown ? Icons.visibility_off_outlined : Icons.tune,
                label: actions.controlsShown ? 'Hide controls' : 'Show all controls',
                onTap: actions.onToggleControls,
              ),
              entry(key: 'stop', icon: Icons.stop_circle_outlined, label: 'Stop presenting', onTap: actions.onStop),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Stop presenting?": what Back asks when no menu is open and no controls are shown. True means stop.
Future<bool> confirmStopPresenting(BuildContext context) async {
  final stop = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Stop presenting?'),
      content: const Text('The normal screen comes back.'),
      actions: [
        TextButton(
          key: const ValueKey('presenting-keep'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep presenting'),
        ),
        FilledButton(
          key: const ValueKey('presenting-stop'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Stop'),
        ),
      ],
    ),
  );
  return stop ?? false;
}
