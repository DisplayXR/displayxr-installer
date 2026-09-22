package com.displayxr.installer

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

sealed class InstallOutcome {
    object Success : InstallOutcome()

    /**
     * @param signatureMismatch the installed package was signed with a different
     *        key. Android will never upgrade across that, and the only fix drops
     *        the app's data — so this installer reports it and stops rather than
     *        uninstalling anything on its own.
     * @param aborted the owner declined the confirmation dialog.
     */
    data class Failure(
        val status: Int,
        val message: String,
        val signatureMismatch: Boolean = false,
        val aborted: Boolean = false,
        val storageFull: Boolean = false,
    ) : InstallOutcome()
}

/**
 * Receives the result of a [PackageInstaller] session.
 *
 * Declared in the manifest and NOT exported: the Intent we hand to `commit()`
 * names this class explicitly, so the system delivers it back into this process
 * as us. A dynamically registered receiver with a custom action would need an
 * export flag on API 34+ and buys nothing.
 */
class InstallResultReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // Android confirms EVERY package unless the installer is a device
            // owner or a privileged system app. This is that confirmation; it is
            // expected, not an error, and there is no way to suppress it here.
            val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            }
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(confirm)
            } else {
                ApkInstaller.complete(
                    sessionId,
                    InstallOutcome.Failure(
                        status,
                        "Android asked for confirmation but sent no dialog to show. " +
                            "Install this APK by hand, or retry."
                    )
                )
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

    private val pending = ConcurrentHashMap<Int, CompletableDeferred<InstallOutcome>>()

    internal fun complete(sessionId: Int, outcome: InstallOutcome) {
        pending.remove(sessionId)?.complete(outcome)
    }

    /**
     * The application id of a downloaded APK, read out of the archive.
     *
     * Deliberately not derived from the file name, and only cross-checked
     * against [Component.packageName]: the Gaussian Splat package is
     * `com.displayxr.gausssplat_vk_android` — three s — matching neither the
     * repo nor the asset name. `install-android.sh` learned this the same way
     * and reads the name with aapt2 for the same reason.
     */
    fun packageOfArchive(context: Context, apk: File): String? =
        context.packageManager.getPackageArchiveInfo(apk.absolutePath, 0)?.packageName

    fun versionOfArchive(context: Context, apk: File): String? =
        context.packageManager.getPackageArchiveInfo(apk.absolutePath, 0)?.versionName

    fun installedVersion(context: Context, pkg: String): String? = try {
        context.packageManager.getPackageInfo(pkg, 0).versionName
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    /**
     * Stream [apk] into a PackageInstaller session and wait for the verdict.
     *
     * Suspends until the owner has answered Android's confirmation dialog, so
     * the caller drives one install at a time; running several sessions at once
     * stacks confirmation dialogs the owner cannot tell apart.
     */
    suspend fun install(
        context: Context,
        apk: File,
        expectedPackage: String?,
        deleteAfterStaging: Boolean,
    ): InstallOutcome {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        expectedPackage?.let { params.setAppPackageName(it) }
        // Lets Android fail fast and legibly when the tablet is out of space,
        // instead of at some arbitrary point in the stream.
        params.setSize(apk.length())
        params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        // Best effort only. Android honours it for an update of a package THIS
        // app originally installed; on a first install, or over a package some
        // other installer owns, the confirmation still appears. Requesting it is
        // what makes the second run of this installer quieter than the first.
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

        val deferred = CompletableDeferred<InstallOutcome>()
        pending[sessionId] = deferred

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
            pending.remove(sessionId)
            runCatching { installer.abandonSession(sessionId) }
            return InstallOutcome.Failure(
                status = PackageInstaller.STATUS_FAILURE,
                message = "Could not stage the APK: ${e.message}",
            )
        }

        // The bytes now live in the session, so the downloaded copy is dead
        // weight. The browser APK is ~326 MB; keeping both halves the number of
        // tablets with room to finish.
        if (deleteAfterStaging) apk.delete()

        return deferred.await()
    }
}
