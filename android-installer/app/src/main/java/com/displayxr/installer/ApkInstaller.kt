package com.displayxr.installer

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.IOException

sealed class InstallOutcome {
    object Success : InstallOutcome()

    /**
     * @param signatureMismatch the installed package was signed with a different
     *        key. Android never upgrades across that, and the only fix drops the
     *        app's data — so this is reported, never performed.
     * @param aborted the owner declined the confirmation dialog.
     * @param neverConfirmed no confirmation dialog ever appeared. Distinct from
     *        [aborted]: the owner did not decline, they were never asked.
     */
    data class Failure(
        val status: Int,
        val message: String,
        val signatureMismatch: Boolean = false,
        val aborted: Boolean = false,
        val storageFull: Boolean = false,
        val neverConfirmed: Boolean = false,
    ) : InstallOutcome()
}

/**
 * Which activity is currently resumed, or null.
 *
 * `startActivity` from a Context that is not a foreground Activity is a
 * background activity start, which Android 12+ may silently drop — one of the
 * two candidate causes of the hour-long stall on the K68. So the confirmation
 * intent is started FROM the resumed activity whenever there is one, and only
 * falls back to the application context (with `FLAG_ACTIVITY_NEW_TASK`, which is
 * mandatory there) when there is not.
 */
object Foreground {
    @Volatile
    var activity: Activity? = null

    /** Set once, so the fallback path has a Context even with no activity resumed. */
    @Volatile
    var appContext: Context? = null
}

/**
 * Receives the result of a [PackageInstaller] session.
 *
 * Declared in the manifest and NOT exported: the Intent handed to `commit()`
 * names this class explicitly, so the system delivers it back into this process
 * as us.
 */
class InstallResultReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // Android confirms EVERY package unless the installer is a device
            // owner or a privileged system app. This is that confirmation; it is
            // expected, not an error, and cannot be suppressed here.
            val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            }
            if (confirm == null) {
                ApkInstaller.complete(
                    sessionId,
                    InstallOutcome.Failure(
                        status,
                        "Android asked for confirmation but sent no dialog to show.",
                        neverConfirmed = true,
                    ),
                )
            } else {
                ApkInstaller.onPendingUserAction(sessionId, confirm)
            }
            return
        }

        val outcome = if (status == PackageInstaller.STATUS_SUCCESS) {
            InstallOutcome.Success
        } else {
            InstallOutcome.Failure(
                status = status,
                message = message.ifBlank { describe(status) },
                signatureMismatch = message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") ||
                    message.contains("INCONSISTENT_CERTIFICATES") ||
                    status == PackageInstaller.STATUS_FAILURE_CONFLICT,
                aborted = status == PackageInstaller.STATUS_FAILURE_ABORTED,
                storageFull = status == PackageInstaller.STATUS_FAILURE_STORAGE,
            )
        }
        ApkInstaller.complete(sessionId, outcome)
    }

    private fun describe(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED -> "Cancelled at the Android confirmation dialog."
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Blocked by the device (policy or another installer)."
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "Conflicts with a package already installed."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "Not compatible with this device."
        PackageInstaller.STATUS_FAILURE_INVALID -> "Android rejected the APK as invalid."
        PackageInstaller.STATUS_FAILURE_STORAGE -> "Not enough free storage."
        else -> "Install failed (status $status)."
    }
}

object ApkInstaller {

    private const val ACTION = "com.displayxr.installer.INSTALL_RESULT"

    private class Pending(
        val sessionId: Int,
        val deferred: CompletableDeferred<InstallOutcome>,
        val watchdog: ConfirmationWatchdog,
    ) {
        @Volatile
        var confirmIntent: Intent? = null
    }

    /**
     * At most one session is ever in flight: several at once would stack
     * confirmation dialogs the owner cannot tell apart.
     */
    @Volatile
    private var active: Pending? = null

    internal fun complete(sessionId: Int, outcome: InstallOutcome) {
        val p = active ?: return
        if (p.sessionId != sessionId) return
        p.watchdog.onAnswered()
        p.deferred.complete(outcome)
    }

    internal fun onPendingUserAction(sessionId: Int, confirm: Intent) {
        val p = active ?: return
        if (p.sessionId != sessionId) return
        p.confirmIntent = confirm
        raise(confirm)
        p.watchdog.onRaised(SystemClock.elapsedRealtime())
    }

    /** Start the confirmation intent, preferring a real foreground activity. */
    private fun raise(confirm: Intent): Boolean {
        val a = Foreground.activity
        if (a != null) {
            val ok = runCatching { a.startActivity(Intent(confirm)) }.isSuccess
            if (ok) return true
        }
        // No resumed activity (or that start failed). FLAG_ACTIVITY_NEW_TASK is
        // mandatory from a non-Activity context; the start may still be dropped
        // as a background activity start, which is exactly what the watchdog's
        // soft timeout is there to surface.
        val app = Foreground.appContext ?: return false
        return runCatching {
            app.startActivity(Intent(confirm).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
    }

    /** The owner tapped RETRY on a stalled confirmation. */
    fun retryConfirmation() {
        val p = active ?: return
        val intent = p.confirmIntent ?: return
        if (p.watchdog.state != ConfirmationWatchdog.State.STALLED) return
        raise(intent)
        p.watchdog.onRetry(SystemClock.elapsedRealtime())
    }

    /**
     * Called when the activity regains the foreground. Re-raises a confirmation
     * that has already been reported stalled — never one merely in flight, since
     * the dialog itself pauses and resumes this activity and re-raising there
     * would be a loop rather than a recovery.
     */
    fun reraiseIfStalled() {
        val p = active ?: return
        if (!p.watchdog.shouldReraiseOnForeground()) return
        p.confirmIntent?.let { raise(it) }
    }

    fun hasPendingConfirmation(): Boolean {
        val p = active ?: return false
        return p.confirmIntent != null &&
            (p.watchdog.state == ConfirmationWatchdog.State.RAISED ||
                p.watchdog.state == ConfirmationWatchdog.State.STALLED)
    }

    // ------------------------------------------------------------- inspection

    /**
     * The application id of a downloaded APK, read out of the archive.
     *
     * Deliberately not derived from the file name: the Gaussian Splat package is
     * `com.displayxr.gausssplat_vk_android` — three s — matching neither the
     * repo nor the asset name.
     */
    fun packageOfArchive(context: Context, apk: File): String? =
        context.packageManager.getPackageArchiveInfo(apk.absolutePath, 0)?.packageName

    /**
     * What is installed for [component], and whether its version can be compared.
     *
     * For everything but the browser, `versionName` IS the DisplayXR release
     * version. For `org.chromium.chrome` it is the Chromium version, so the
     * manifest stamp is read instead and, when absent, the answer is
     * [Installed.Opaque] — see the doc on [Installed].
     */
    fun installed(context: Context, component: Component): Installed {
        val pm = context.packageManager
        val versionName = try {
            pm.getPackageInfo(component.packageName, 0).versionName
        } catch (e: PackageManager.NameNotFoundException) {
            return Installed.Absent
        } ?: ""

        val key = component.versionStampKey ?: return Installed.Exact(versionName)

        val stamp = try {
            @Suppress("DEPRECATION")
            pm.getApplicationInfo(component.packageName, PackageManager.GET_META_DATA)
                .metaData?.get(key)?.toString()?.trim()
        } catch (e: PackageManager.NameNotFoundException) {
            null
        } catch (e: RuntimeException) {
            null
        }

        return if (!stamp.isNullOrBlank()) {
            Installed.Exact(stamp)
        } else {
            Installed.Opaque(
                listOfNotNull(component.opaqueVersionLabel, versionName.ifBlank { null })
                    .joinToString(" ")
                    .ifBlank { "installed" }
            )
        }
    }

    // --------------------------------------------------------------- install

    /**
     * Stream [apk] into a PackageInstaller session and wait for the verdict.
     *
     * Suspends until Android answers. While waiting it ticks a
     * [ConfirmationWatchdog] and reports its state through [onConfirmState], so
     * the caller can say "the confirmation did not appear" instead of "confirm
     * on screen" when nothing is on screen — and so a confirmation that never
     * arrives ends the wait instead of pinning the run forever.
     */
    suspend fun install(
        context: Context,
        apk: File,
        expectedPackage: String?,
        deleteAfterStaging: Boolean,
        onConfirmState: (ConfirmationWatchdog.State) -> Unit = {},
    ): InstallOutcome {
        Foreground.appContext = context.applicationContext
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        expectedPackage?.let { params.setAppPackageName(it) }
        // Lets Android fail fast and legibly when the tablet is out of space,
        // instead of at some arbitrary point in the stream.
        params.setSize(apk.length())
        params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        // Best effort only. Android honours it for an update of a package THIS
        // app originally installed; on a first install, or over a package some
        // other installer owns, the confirmation still appears.
        params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)

        val sessionId = try {
            installer.createSession(params)
        } catch (e: IOException) {
            return InstallOutcome.Failure(
                status = PackageInstaller.STATUS_FAILURE,
                message = "Could not open an install session: ${e.message}. " +
                    "This is normally free space — ${apk.length() / (1024 * 1024)} MB was needed.",
                storageFull = true,
            )
        }

        val pending = Pending(sessionId, CompletableDeferred(), ConfirmationWatchdog())
        active = pending

        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("apk", 0, apk.length()).use { out ->
                    apk.inputStream().use { input -> input.copyTo(out, 256 * 1024) }
                    session.fsync(out)
                }
                val callback = Intent(context, InstallResultReceiver::class.java).setAction(ACTION)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                val pi = PendingIntent.getBroadcast(context, sessionId, callback, flags)
                session.commit(pi.intentSender)
            }
        } catch (e: IOException) {
            active = null
            runCatching { installer.abandonSession(sessionId) }
            return InstallOutcome.Failure(
                status = PackageInstaller.STATUS_FAILURE,
                message = "Could not stage the APK: ${e.message}",
            )
        }

        // The bytes now live in the session, so the downloaded copy is dead
        // weight. The browser APK is ~326 MB; dropping it here halves the peak.
        if (deleteAfterStaging) apk.delete()

        try {
            var last: ConfirmationWatchdog.State? = null
            while (true) {
                val done = withTimeoutOrNull(TICK_MS) { pending.deferred.await() }
                if (done != null) return done

                val state = pending.watchdog.onTick(SystemClock.elapsedRealtime())
                if (state != last) {
                    last = state
                    onConfirmState(state)
                }
                if (state == ConfirmationWatchdog.State.GAVE_UP) {
                    runCatching { installer.abandonSession(sessionId) }
                    return InstallOutcome.Failure(
                        status = PackageInstaller.STATUS_FAILURE,
                        message = "No confirmation dialog ever appeared for this package, so the " +
                            "session was abandoned and the run moved on. Nothing was installed and " +
                            "nothing was changed. Retry this app on its own; if it happens every " +
                            "time, install this one APK by hand.",
                        neverConfirmed = true,
                    )
                }
            }
        } finally {
            active = null
        }
    }

    private const val TICK_MS = 1_000L
}
