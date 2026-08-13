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
        prefs.edit()
            .putString(lastResultKey, dumpIntentExtras(intent))
            .putLong(lastResultTimeKey, System.currentTimeMillis())
            .apply()
        stopSelf(startId)
        return START_NOT_STICKY
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
    }
}
