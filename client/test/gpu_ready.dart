import 'package:didsa_cad_client/viewport3d/gpu_unavailable.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// True once a 3D viewport has stopped showing its loading spinner *and* is
/// not showing the "3D view unavailable" message either.
///
/// flutter_scene 0.24 completes `Scene.initializeStaticResources()` with its
/// error when there is no GPU (every `flutter test` run), and the viewport
/// then shows [gpuUnavailableMessage] in place of the spinner. That is "not
/// ready": the tests that need a real GPU skip, same as when the spinner
/// used to stay up forever.
bool gpuSpinnerGone() =>
    find.byType(CircularProgressIndicator).evaluate().isEmpty && find.byKey(gpuUnavailableKey).evaluate().isEmpty;
