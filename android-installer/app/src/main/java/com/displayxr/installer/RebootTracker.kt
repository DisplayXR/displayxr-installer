package com.displayxr.installer

import android.content.Context
import android.provider.Settings
import android.os.SystemClock

/**
 * Which boot this is, as far as the device will say.
 *
 * [bootCount] is `Settings.Global.BOOT_COUNT` — incremented by the system on every
 * boot, readable without a permission. [bootEpochMs] is the wall-clock moment of this
 * boot (`currentTimeMillis - elapsedRealtime`): a fallback for a build that does not
 * keep BOOT_COUNT. It drifts slightly with clock adjustments, hence the tolerance in
 * [RebootTracker.stillPending].
 */
data class BootId(val bootCount: Int?, val bootEpochMs: Long?)

/**
 * "The display services changed; reboot" — persisted until an ACTUAL reboot.
 *
 * Found on the NP02J: the red reboot card lived only in the screen's memory, so
 * relaunching the installer made it vanish although the tablet had not been
 * rebooted. That is the one post-install step whose omission is invisible — the
 * lens-controller HAL can be left not answering, every app reports 3D, and the glass
 * stays 2D (android-bundle/INSTALL.md, "Reboot. It is not optional"). So the flag is
 * written with the boot it was raised in, and cleared only once a DIFFERENT boot is
 * observed.
 */
object RebootTracker {

    private const val PREFS = "installer"
    private const val K_COUNT = "reboot_pending_boot_count"
    private const val K_EPOCH = "reboot_pending_boot_epoch_ms"
    private const val K_SET = "reboot_pending"

    /** Two boot epochs closer than this are the same boot (clock nudges, NTP). */
    const val EPOCH_TOLERANCE_MS = 60_000L

    /**
     * Pure. Is a reboot recorded in [recorded] still outstanding at [now]?
     *
     * Boot counts decide when both are known. Otherwise boot epochs decide, with
     * [EPOCH_TOLERANCE_MS]. When neither can be compared the answer is "still pending":
     * a reboot reminder shown once too often costs a restart; one hidden too early
     * costs a tablet whose glass silently stays 2D.
     */
    fun stillPending(recorded: BootId, now: BootId): Boolean {
        if (recorded.bootCount != null && now.bootCount != null) return recorded.bootCount == now.bootCount
        if (recorded.bootEpochMs != null && now.bootEpochMs != null) {
            return kotlin.math.abs(recorded.bootEpochMs - now.bootEpochMs) < EPOCH_TOLERANCE_MS
        }
        return true
    }

    fun currentBoot(context: Context): BootId {
        val count = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1).takeIf { it >= 0 }
        } catch (t: Throwable) {
            null
        }
        return BootId(count, System.currentTimeMillis() - SystemClock.elapsedRealtime())
    }

    fun markPending(context: Context) {
        val b = currentBoot(context)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(K_SET, true)
            .putInt(K_COUNT, b.bootCount ?: -1)
            .putLong(K_EPOCH, b.bootEpochMs ?: -1L)
            .apply()
    }

    /** True while a recorded reboot is outstanding; forgets it once a reboot is seen. */
    fun isPending(context: Context): Boolean {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!p.getBoolean(K_SET, false)) return false
        val recorded = BootId(
            p.getInt(K_COUNT, -1).takeIf { it >= 0 },
            p.getLong(K_EPOCH, -1L).takeIf { it >= 0 },
        )
        val pending = stillPending(recorded, currentBoot(context))
        if (!pending) p.edit().remove(K_SET).remove(K_COUNT).remove(K_EPOCH).apply()
        return pending
    }
}

/**
 * The browser opt-in, remembered across launches. Found on the NP02J: a relaunch reset
 * the box to unchecked, so the screen said "Nothing to install" while the browser the
 * owner had asked for was not installed — a false "done".
 */
object Prefs {
    private const val PREFS = "installer"
    private const val K_BROWSER = "browser_opt_in"

    fun browserOptIn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(K_BROWSER, false)

    fun setBrowserOptIn(context: Context, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(K_BROWSER, value).apply()
    }
}
