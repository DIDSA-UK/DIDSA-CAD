import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// "Share screen" (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 3). Two separate uses: presenting to a room
/// or TV (mirror, then Present) and working on a monitor (desktop windowing, not mirroring).
class ScreenShare {
  ScreenShare._();

  /// The same channel the Android activity already serves (`MainActivity.kt`); `openSettingsScreen` is the method here.
  static const MethodChannel channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');

  /// The system cast screen, and the display settings some OEMs fall back to when they have removed it.
  static const String castSettingsAction = 'android.settings.CAST_SETTINGS';
  static const String displaySettingsAction = 'android.settings.DISPLAY_SETTINGS';

  /// Tried in order: the first the device can open wins.
  static const List<String> androidSettingsActions = [castSettingsAction, displaySettingsAction];

  /// Opens the system cast settings on Android. False when no screen could be opened (or off Android). The launch
  /// itself cannot be tested headless: only the actions it asks for are.
  static Future<bool> openAndroidCastSettings() async {
    try {
      final opened = await channel.invokeMethod<bool>('openSettingsScreen', {'actions': androidSettingsActions});
      return opened ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The platform's way to start mirroring, as short instructions. Null on a platform with no mirroring built in
  /// (Linux): the dialog then only has the general text.
  static String? mirroringInstructions(TargetPlatform platform) => switch (platform) {
        TargetPlatform.android => 'Open the cast settings, pick the TV or screen (Cast / Smart View), then come back and tap Present.',
        TargetPlatform.iOS => 'Open Control Centre, tap Screen Mirroring and pick the Apple TV or AirPlay screen, then come back and tap Present.',
        TargetPlatform.windows => 'Press Win+K and pick the screen, then tap Present.',
        TargetPlatform.macOS => 'Use the Screen Mirroring item in the menu bar, then tap Present.',
        _ => null,
      };
}

/// What the Share screen dialog resolved to.
enum ShareScreenChoice { present, openCastSettings }

/// The Share screen dialog: "Present to a room or TV" and "Work on a monitor". [platform] is injectable for tests.
Future<ShareScreenChoice?> showShareScreenDialog(BuildContext context, {TargetPlatform? platform}) {
  final target = platform ?? defaultTargetPlatform;
  return showDialog<ShareScreenChoice>(
    context: context,
    builder: (context) => ShareScreenDialog(platform: target),
  );
}

class ShareScreenDialog extends StatelessWidget {
  const ShareScreenDialog({super.key, required this.platform});

  final TargetPlatform platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instructions = ScreenShare.mirroringInstructions(platform);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(text, style: theme.textTheme.titleSmall),
        );
    return AlertDialog(
      key: const ValueKey('share-screen-dialog'),
      title: const Text('Share screen'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading('Present to a room or TV'),
            const Text(
              'Mirror this screen (Cast or Smart View on Android, AirPlay on iOS, Win+K on Windows), then tap Present. '
              'Present hides the editing controls and fills the screen. A button in the top-right corner brings the '
              'presenter menu back. The audience will see the file picker and any dialog you open.',
            ),
            if (instructions != null) ...[
              const SizedBox(height: 8),
              Text(instructions),
            ],
            heading('Work on a monitor'),
            const Text(
              'Mirroring only makes the phone bigger. To work on a bigger screen use Samsung DeX or Android desktop mode, '
              'or Stage Manager on an iPad, so the app gets a real window. Add a Bluetooth mouse to get the desktop '
              'layout. Or use the desktop app on a PC against the same server.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        if (platform == TargetPlatform.android)
          TextButton(
            key: const ValueKey('share-open-cast-settings'),
            onPressed: () => Navigator.of(context).pop(ShareScreenChoice.openCastSettings),
            child: const Text('Open cast settings'),
          ),
        FilledButton(
          key: const ValueKey('share-present'),
          onPressed: () => Navigator.of(context).pop(ShareScreenChoice.present),
          child: const Text('Present'),
        ),
      ],
    );
  }
}
