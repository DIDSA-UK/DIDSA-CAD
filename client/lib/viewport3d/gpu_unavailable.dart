import 'package:material_ui/material_ui.dart';

/// Key of the message shown in place of a 3D view's loading spinner when
/// `Scene.initializeStaticResources()` fails (flutter_scene 0.24 completes
/// it with the error). Tests that wait for the spinner to go away treat this
/// message as "no GPU here, skip".
const gpuUnavailableKey = ValueKey('viewport-gpu-unavailable');

/// "3D view unavailable on this device: `error`". On a phone this replaces an
/// endless spinner with the reason (see the `EnableFlutterGPU` note in
/// `AndroidManifest.xml`).
Widget gpuUnavailableMessage(BuildContext context, String error) => Center(
      key: gpuUnavailableKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '3D view unavailable on this device: $error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
          textAlign: TextAlign.center,
        ),
      ),
    );
