package uk.snail_shell.didsa_cad_client

import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Bridges the Server Management screen's Termux control calls (see
/// client/lib/server_management/termux_controller.dart) to Android's
/// Intent/permission APIs - no Flutter plugin exposes an explicit-component
/// Service intent carrying a third-party app's own custom permission, so
/// this is a small hand-written channel rather than a dependency.
///
/// Permission results: MainActivity *is* the Activity that calls
/// ActivityCompat.requestPermissions below, so Android delivers the result
/// straight to this class's own onRequestPermissionsResult override - no
/// PluginRegistry.RequestPermissionsResultListener/addRequestPermissionsResultListener
/// needed (that mechanism is for a separate Flutter *plugin* listening via
/// an ActivityPluginBinding it doesn't itself own; FlutterActivity doesn't
/// expose it as a method to call on itself at all - confirmed the hard way,
/// by a real Kotlin compile failure - "Unresolved reference" - the first
/// time this actually got compiled against the real Flutter embedding API).
class MainActivity : FlutterActivity() {
    private val channelName = "uk.snail_shell.didsa_cad_client/termux"
    private val runCommandPermission = "com.termux.permission.RUN_COMMAND"
    private val permissionRequestCode = 7421

    // Only one request can be in flight at a time (the screen disables its
    // own "Grant permission" button while a request is pending), so a
    // single field - not a queue - is enough to carry the pending Flutter
    // result across onRequestPermissionsResult's own separate callback.
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasRunCommandPermission())
                "requestPermission" -> requestRunCommandPermission(result)
                "runCommand" -> {
                    val executable = call.argument<String>("executable")
                    val arguments = call.argument<List<String>>("arguments")
                    if (executable == null || arguments == null) {
                        result.error("bad_args", "executable and arguments are required", null)
                    } else {
                        result.success(sendRunCommandIntent(executable, arguments))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasRunCommandPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, runCommandPermission) == PackageManager.PERMISSION_GRANTED

    private fun requestRunCommandPermission(result: MethodChannel.Result) {
        if (hasRunCommandPermission()) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(runCommandPermission), permissionRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // Real Activity/FlutterActivity override (Unit-returning) - forward
        // to super first in case any other Flutter plugin's own permission
        // handling depends on it, same as any responsible override of a
        // framework callback.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /// Fires a RUN_COMMAND intent at Termux's RunCommandService - see
    /// https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent.
    /// [arguments] is delivered to Android as a real String[] extra (an
    /// exec()-style argv array, never re-parsed as a shell string by
    /// Android or by Termux), so [executable]/[arguments] need no shell
    /// escaping at this layer - only the final "bash -lc <script>" element
    /// built by termux_commands.dart's own command builders needs the
    /// values it interpolates (branch name, API key) shell-quoted, which it
    /// already does. Background (no visible terminal session): this
    /// returns as soon as Android accepts the intent, without waiting for
    /// the command to finish - actual success/failure is confirmed by the
    /// Dart side polling the backend's own /health endpoint afterward, not
    /// by this call's return value. Returns false only if the intent
    /// couldn't be dispatched at all (missing permission, Termux not
    /// installed, or the call itself throwing) - true means Android handed
    /// the intent to Termux, not that the command inside it succeeded.
    ///
    /// Plain startService, not startForegroundService, despite the Termux
    /// wiki recommending the latter for API 26+: on-device testing showed
    /// the notification for a dispatched command flashing briefly and then
    /// nothing running at all, with the exact same script succeeding
    /// instantly when run by hand - consistent with Android killing
    /// RunCommandService for not calling Service.startForeground() within
    /// its ~5s grace window after being started via startForegroundService,
    /// before the script ever got to run. startService has no such window
    /// to miss, and Android's background-service-start restrictions it
    /// would otherwise be subject to don't apply here anyway - this is
    /// always called while DIDSA itself is in the foreground (a direct
    /// button tap), which is the standard exemption. Not confirmed against
    /// a system log (no adb access in that debugging session), but this
    /// matches every symptom observed and is the documented failure mode
    /// for exactly this Android API.
    private fun sendRunCommandIntent(executable: String, arguments: List<String>): Boolean {
        if (!hasRunCommandPermission()) return false
        return try {
            val intent = Intent()
            intent.setClassName("com.termux", "com.termux.app.RunCommandService")
            intent.action = "com.termux.RUN_COMMAND"
            intent.putExtra("com.termux.RUN_COMMAND_PATH", executable)
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arguments.toTypedArray())
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            startService(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
