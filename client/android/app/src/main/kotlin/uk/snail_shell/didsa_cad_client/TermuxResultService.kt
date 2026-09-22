package uk.snail_shell.didsa_cad_client

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

/// Receives whatever Termux sends back via the PendingIntent passed as
/// com.termux.RUN_COMMAND_PENDING_INTENT (see MainActivity.kt's
/// sendRunCommandIntent) - the Termux wiki documents specific result keys
/// (a "result" Bundle extra containing stdout/stderr/exitCode/err/errmsg),
/// but that documentation is symbolic constant names from termux-shared's
/// TermuxConstants, not directly confirmed literal strings, and getting a
/// key wrong would mean silently capturing nothing. So this deliberately
/// doesn't assume the exact schema: it walks every extra actually present
/// on the returned Intent (recursing one level into any nested Bundle) and
/// records all of it, verbatim, as plain text - giving real ground truth
/// about what Termux actually returns, rather than a guess that could be
/// silently wrong. Written to SharedPreferences (not passed back over a
/// live Flutter callback) because this fires asynchronously, an unknown
/// amount of time after the original RUN_COMMAND dispatch - the Activity
/// may not even be alive when it happens - so MainActivity's own
/// getLastCommandResult channel method reads it back on demand instead.
class TermuxResultService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        val editor = prefs.edit()
            .putString(lastResultKey, dumpIntentExtras(intent))
            .putLong(lastResultTimeKey, System.currentTimeMillis())
        val stdout = extractStdout(intent)
        if (stdout != null) {
            editor.putString(lastStdoutKey, stdout)
        } else {
            editor.remove(lastStdoutKey)
        }
        val error = extractError(intent)
        if (error != null) {
            editor.putString(lastErrorKey, error)
        } else {
            editor.remove(lastErrorKey)
        }
        editor.apply()
        stopSelf(startId)
        return START_NOT_STICKY
    }

    /// Termux's documented RUN_COMMAND result schema nests stdout/stderr/
    /// exitCode inside a "result" Bundle extra - unlike [dumpIntentExtras]
    /// (which deliberately stays schema-agnostic, see this class's own doc
    /// comment above), this one field is read by its documented, literal
    /// key name, since the First Installation screen's status check needs
    /// exactly this value, not a human-readable dump of everything present.
    /// Returns null - never a placeholder string - if the "result"/"stdout"
    /// extras aren't there, so the Dart side can tell "no data" apart from a
    /// real, empty captured string.
    private fun extractStdout(intent: Intent?): String? {
        val resultBundle = intent?.extras?.getBundle("result") ?: return null
        return resultBundle.getString("stdout")
    }

    /// The same "result" bundle's own "err"/"errmsg" pair (Termux's
    /// documented RUN_COMMAND error fields - err is a nonzero int, errmsg
    /// the human-readable reason, e.g. "RunCommandService requires
    /// `allow-external-apps`..." when that Termux property isn't set) -
    /// this is what actually let a real device's own Termux error report
    /// confirm the true cause of a First Installation dispatch going
    /// nowhere, instead of the Dart side only ever seeing a bare timeout.
    /// Only stored when Termux actually reported a nonzero err/non-null
    /// errmsg - a successful dispatch has neither.
    private fun extractError(intent: Intent?): String? {
        val resultBundle = intent?.extras?.getBundle("result") ?: return null
        val errCode = resultBundle.getInt("err", 0)
        val errMsg = resultBundle.getString("errmsg")
        if (errCode == 0 && errMsg.isNullOrEmpty()) return null
        return "Termux error $errCode: ${errMsg ?: "(no message)"}"
    }

    private fun dumpIntentExtras(intent: Intent?): String {
        if (intent == null) return "(null result intent - Termux may not have sent one at all)"
        val extras = intent.extras
        if (extras == null || extras.isEmpty) return "(result intent had no extras at all)"
        val sb = StringBuilder()
        for (key in extras.keySet()) {
            @Suppress("DEPRECATION")
            val value = extras.get(key)
            if (value is Bundle) {
                sb.append("$key: {\n")
                if (value.isEmpty) {
                    sb.append("  (empty)\n")
                } else {
                    for (innerKey in value.keySet()) {
                        @Suppress("DEPRECATION")
                        sb.append("  $innerKey = ${value.get(innerKey)}\n")
                    }
                }
                sb.append("}\n")
            } else {
                sb.append("$key = $value\n")
            }
        }
        return sb.toString()
    }

    companion object {
        const val prefsName = "termux_result"
        const val lastResultKey = "last_result"
        const val lastResultTimeKey = "last_result_time"
        const val lastStdoutKey = "last_stdout"
        const val lastErrorKey = "last_error"
    }
}
