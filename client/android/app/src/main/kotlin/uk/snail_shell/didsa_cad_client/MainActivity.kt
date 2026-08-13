package uk.snail_shell.didsa_cad_client

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
                "getLastCommandResult" -> result.success(getLastCommandResult())
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
            intent.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", buildResultPendingIntent())
            startService(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /// A PendingIntent targeting TermuxResultService, passed to Termux as
    /// com.termux.RUN_COMMAND_PENDING_INTENT so it can hand back the real
    /// result (whatever shape that actually turns out to be - see
    /// TermuxResultService's own doc comment on why the receiver doesn't
    /// assume an exact schema) instead of this app having to infer success/
    /// failure purely from polling /health afterward.
    ///
    /// FLAG_MUTABLE is required on API 31+ (Android 12+): Termux fills in
    /// its own result extras onto this PendingIntent's Intent when it fires
    /// it, and an immutable PendingIntent (the default on 31+ when neither
    /// flag is specified) silently drops any extras the sender tries to
    /// add - the result would arrive with none of what Termux actually
    /// meant to send. FLAG_ONE_SHOT since each dispatched command only
    /// expects one result delivery.
    private fun buildResultPendingIntent(): PendingIntent {
        val resultIntent = Intent(this, TermuxResultService::class.java)
        var flags = PendingIntent.FLAG_ONE_SHOT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        return PendingIntent.getService(this, 0, resultIntent, flags)
    }

    /// Reads back whatever TermuxResultService last wrote - see that
    /// class's own doc comment for why this is a raw, generic dump rather
    /// than parsed named fields. Returns a human-readable placeholder
    /// (never null/throws) if nothing has arrived yet, so the Dart side can
    /// always just display whatever this returns directly.
    private fun getLastCommandResult(): String {
        val prefs = getSharedPreferences(TermuxResultService.prefsName, MODE_PRIVATE)
        val result = prefs.getString(TermuxResultService.lastResultKey, null)
            ?: return "(no result received yet from any dispatched command)"
        val time = prefs.getLong(TermuxResultService.lastResultTimeKey, 0L)
        return "Received at $time (epoch ms):\n$result"
    }
}
