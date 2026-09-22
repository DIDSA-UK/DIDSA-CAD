import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper over the `uk.snail_shell.didsa_cad_client/termux`
/// MethodChannel's battery-optimisation methods (see
/// android/.../MainActivity.kt's `isIgnoringBatteryOptimizations`/
/// `requestIgnoreBatteryOptimizations`) - same channel and shape as
/// [TermuxController], Android-only in practice since nothing calls this on
/// other platforms (see `connection_screen.dart`'s `Platform.isAndroid`
/// guard).
class BatteryOptimizationController {
  static const MethodChannel _channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');

  static const String _dismissedPrefKey = 'battery_optimization_prompt_dismissed';

  /// False (the OS is still allowed to kill this app in the background)
  /// means the app should consider offering [requestIgnoreOptimizations].
  Future<bool> isIgnoringOptimizations() async {
    final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return result ?? false;
  }

  /// Launches the system settings screen for the user to grant the
  /// exemption - see MainActivity.kt's own doc comment on why there's no
  /// direct "was it granted" result here; the Dart side re-checks
  /// [isIgnoringOptimizations] once the user returns to the app.
  Future<bool> requestIgnoreOptimizations() async {
    final result = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    return result ?? false;
  }

  /// Whether the user has already dismissed the startup prompt once - see
  /// [setPromptDismissed]. Prevents the app from asking every single cold
  /// launch once the user has said no; [isIgnoringOptimizations] itself
  /// remains the real, always-fresh source of truth for whether the OS
  /// setting is actually on, so a user who dismissed and later disables
  /// optimisation manually (or has it re-enabled by the OS) is simply never
  /// asked again unless this flag is cleared.
  Future<bool> isPromptDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_dismissedPrefKey) ?? false;
  }

  Future<void> setPromptDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dismissedPrefKey, true);
  }
}
