package com.displayxr.installer

import android.app.AppOpsManager
import android.app.Application
import android.app.KeyguardManager
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File

class InstallerViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow(UiState(rows = Catalog.COMPONENTS.map { RowState(it) }))
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val ctx get() = getApplication<Application>()

    // ---------------------------------------------------------------- resolve

    fun refresh() {
        if (_state.value.phase == Phase.RUNNING) return
        _state.update { s ->
            s.copy(
                phase = Phase.RESOLVING,
                globalError = null,
                summary = "Reading the pinned versions…",
                rows = s.rows.map { it.copy(status = RowStatus.RESOLVING, detail = "", progressPercent = -1) },
            )
        }

        viewModelScope.launch(Dispatchers.IO) {
            val pins = try {
                GitHubReleases.readPins()
            } catch (e: InstallerFailure) {
                // Without the pin matrix there is nothing to show and nothing to
                // install, so this is the one failure that owns the whole screen.
                // It is never a spinner: the message says what could not be read.
                _state.update { s ->
                    s.copy(
                        phase = Phase.IDLE,
                        summary = "",
                        globalError = "Could not read the pinned versions.\n\n${e.message}",
                        rows = s.rows.map { it.copy(status = RowStatus.PENDING) },
                    )
                }
                return@launch
            }

            _state.update {
                it.copy(
                    pinSource = "pins: ${Catalog.PINS_REPO}@${Catalog.PINS_REF}   runtime ${pins["runtime"]}"
                )
            }

            for (c in Catalog.COMPONENTS) {
                val pin = pins[c.pinField]?.takeIf { it.isNotBlank() }
                val installed = ApkInstaller.installed(ctx, c)
                if (pin == null) {
                    setRow(c) {
                        it.copy(
                            status = RowStatus.NOT_PINNED,
                            installed = installed,
                            detail = "versions.json has no \"${c.pinField}\" pin, so there is nothing to resolve.",
                        )
                    }
                    continue
                }
                setRow(c) { it.copy(pin = pin, installed = installed, status = RowStatus.RESOLVING) }
                try {
                    val asset = GitHubReleases.resolve(c, pin)
                    setRow(c) {
                        it.copy(asset = asset, status = plannedStatus(installed, pin), detail = detailFor(c, installed))
                    }
                } catch (e: InstallerFailure) {
                    // Per-component, NOT global: one demo whose release has no
                    // Android asset must not look like a broken installer.
                    val status =
                        if (e is InstallerFailure.NoAndroidAsset) RowStatus.MISSING else RowStatus.UNRESOLVED
                    setRow(c) { it.copy(status = status, detail = e.message ?: "could not resolve this release") }
                }
            }

            applyBrowserGate()
            _state.update { it.copy(phase = Phase.READY, summary = plannedSummary()) }
        }
    }

    /**
     * The one row note that has to survive: when a component's installed version
     * cannot be read, say so and say what the number on screen actually is.
     */
    private fun detailFor(c: Component, installed: Installed): String = when (installed) {
        is Installed.Opaque ->
            "The installed build's DisplayXR version is not readable — ${installed.shown} is the " +
                "${c.opaqueVersionLabel ?: "package"} version, which several DisplayXR releases " +
                "share. Installing the pinned build is safe; it is an upgrade or a reinstall, " +
                "never a downgrade Android would refuse."
        else -> ""
    }

    fun setBrowserOptIn(optIn: Boolean) {
        _state.update { it.copy(browserOptIn = optIn) }
        applyBrowserGate()
        if (_state.value.phase == Phase.READY) {
            _state.update { it.copy(summary = plannedSummary()) }
        }
    }

    // ----------------------------------------------------------- browser gate

    /**
     * Why the browser is refused, or null if it may be installed.
     *
     * versions.json is a MATCHED SET, not seven independent numbers. The browser
     * is the one component where pairing it with a runtime other than its pinned
     * one has a silent failure mode: every 3D tile renders BLACK, with no error
     * on screen and no error in the app, while the demos keep weaving perfectly —
     * so it reads as broken content, and people reinstall the wrong thing
     * (displayxr-runtime#1302, displayxr-browser#188).
     *
     * The comparison is made on the RUNTIME's version, which is readable and is
     * genuinely the DisplayXR release version — not on the browser's, which is
     * not (see [Installed]). Exact: a locally built runtime reporting
     * `2.20.1-14-gabc1234` is not the pinned runtime, and is the case that has
     * to be caught rather than tolerated.
     */
    private fun browserRefusal(runtimePin: String?): String? {
        if (runtimePin == null) return "There is no runtime pin, so there is no pair to match."
        return when (val rt = ApkInstaller.installed(ctx, Catalog.runtime)) {
            Installed.Absent ->
                "The runtime is not installed on this tablet. The browser is only ever installed " +
                    "as half of the pinned pair — install the runtime above first."

            is Installed.Opaque ->
                "The installed runtime's version could not be read, so the pair cannot be " +
                    "verified. The browser is not installed on an unverified pair."

            is Installed.Exact ->
                if (Versions.same(rt.version, runtimePin)) {
                    null
                } else {
                    "Refused: this tablet has runtime ${rt.version}, but the pinned pair is " +
                        "runtime ${Versions.strip(runtimePin)}. Installing the pinned browser " +
                        "against a runtime that is not its match renders ALL 3D content in the " +
                        "browser BLACK, with no error on screen, while every other app keeps " +
                        "weaving. Install the pinned runtime first, then run this again."
                }
        }
    }

    private fun applyBrowserGate() {
        val browser = Catalog.COMPONENTS.first { it.id == "browser" }
        val snapshot = _state.value
        val runtimeRow = snapshot.rows.first { it.component.id == "runtime" }
        val row = snapshot.rows.first { it.component.id == browser.id }

        if (row.status in TERMINAL_STATUSES) return
        if (!snapshot.browserOptIn) {
            setRow(browser) {
                it.copy(status = RowStatus.SKIPPED, detail = "Not selected. Tick the box above to include it.")
            }
            return
        }
        if (row.status in UNRESOLVABLE_STATUSES) return

        val refusal = browserRefusal(runtimeRow.pin)
        when {
            refusal == null -> setRow(browser) {
                it.copy(
                    status = plannedStatus(it.installed, it.pin ?: ""),
                    detail = detailFor(browser, it.installed),
                )
            }

            // The runtime leg of THIS run will make the pair whole, so the gate is
            // deferred rather than shown as a refusal the owner cannot act on.
            runtimeRow.status in PLANNED_STATUSES -> setRow(browser) {
                it.copy(
                    status = plannedStatus(it.installed, it.pin ?: ""),
                    detail = "Queued after the runtime; the pair is checked again at that point.",
                )
            }

            else -> setRow(browser) { it.copy(status = RowStatus.BLOCKED, detail = refusal) }
        }
    }

    // ---------------------------------------------------------------- install

    fun install() {
        val phase = _state.value.phase
        if (phase == Phase.RUNNING || phase == Phase.RESOLVING) return

        // A run ends by opening the runtime, and it ends unattended after a long
        // download. Launching an app behind the keyguard is the documented crash
        // path for Model Viewer and Gaussian Splat (displayxr-runtime#1358), so
        // the run does not start into a locked screen either.
        if (keyguardLocked()) {
            _state.update {
                it.copy(
                    globalError = "Unlock the tablet before starting. This run ends by opening the " +
                        "runtime, and launching an app while the screen is locked crashes some " +
                        "demos (displayxr-runtime#1358)."
                )
            }
            return
        }

        _state.update { it.copy(phase = Phase.RUNNING, globalError = null, summary = "Working…") }

        viewModelScope.launch(Dispatchers.IO) {
            var installedCount = 0
            var failedCount = 0

            for (c in Catalog.COMPONENTS) {
                if (c.id == "browser") {
                    // Re-evaluated here, not only at planning time: the runtime
                    // leg may just have changed the answer, in either direction.
                    if (!_state.value.browserOptIn) {
                        setRow(c) { it.copy(status = RowStatus.SKIPPED) }
                        continue
                    }
                    val runtimePin = _state.value.rows.first { it.component.id == "runtime" }.pin
                    val refusal = browserRefusal(runtimePin)
                    if (refusal != null) {
                        setRow(c) { it.copy(status = RowStatus.BLOCKED, detail = refusal) }
                        failedCount++
                        continue
                    }
                    setRow(c) { it.copy(status = plannedStatus(it.installed, it.pin ?: "")) }
                }

                val row = _state.value.rows.first { it.component.id == c.id }
                val asset = row.asset
                if (asset == null || row.status !in PLANNED_STATUSES) continue

                val apk = File(ctx.cacheDir, asset.name)
                apk.delete()

                setRow(c) {
                    it.copy(status = RowStatus.DOWNLOADING, progressPercent = 0, detail = asset.name)
                }
                try {
                    Net.download(asset.url, asset.name, apk) { got, total ->
                        val pct = if (total > 0) ((got * 100) / total).toInt() else -1
                        setRow(c) { it.copy(progressPercent = pct) }
                    }
                } catch (e: InstallerFailure) {
                    setRow(c) {
                        it.copy(
                            status = RowStatus.FAILED,
                            progressPercent = -1,
                            detail = e.message ?: "the download failed",
                        )
                    }
                    failedCount++
                    if (c.id == "runtime") {
                        stopRun(
                            "The runtime could not be downloaded, so nothing after it was " +
                                "attempted — every app on this list needs it."
                        )
                        return@launch
                    }
                    continue
                }

                // Authoritative application id, read out of the archive rather
                // than trusted from the table.
                val pkg = ApkInstaller.packageOfArchive(ctx, apk) ?: c.packageName

                setRow(c) {
                    it.copy(
                        status = RowStatus.INSTALLING,
                        progressPercent = -1,
                        detail = "Confirm the install on screen…",
                    )
                }
                val outcome = ApkInstaller.install(ctx, apk, pkg, deleteAfterStaging = true) { confirm ->
                    // The whole point of the watchdog: stop claiming there is
                    // something on screen to confirm once there demonstrably is not.
                    when (confirm) {
                        ConfirmationWatchdog.State.STALLED -> setRow(c) {
                            it.copy(
                                status = RowStatus.CONFIRM_STALLED,
                                detail = "Android's confirmation dialog has not appeared. If one is " +
                                    "open, answer it. Otherwise tap RETRY below to ask for it again.",
                            )
                        }

                        ConfirmationWatchdog.State.RAISED -> setRow(c) {
                            it.copy(status = RowStatus.INSTALLING, detail = "Confirm the install on screen…")
                        }

                        else -> Unit
                    }
                }
                apk.delete()

                when (outcome) {
                    is InstallOutcome.Success -> {
                        installedCount++
                        setRow(c) {
                            it.copy(
                                status = RowStatus.DONE,
                                installed = ApkInstaller.installed(ctx, c),
                                detail = "Installed.",
                            )
                        }
                    }

                    is InstallOutcome.Failure -> {
                        failedCount++
                        setRow(c) { it.copy(status = RowStatus.FAILED, detail = failureText(c, outcome)) }
                        if (c.id == "runtime") {
                            stopRun(
                                "The runtime did not install, so nothing after it was attempted — " +
                                    "an app installed without a runtime only fails later, at startup."
                            )
                            return@launch
                        }
                    }
                }
            }

            val runtimePresent = ApkInstaller.installed(ctx, Catalog.runtime) != Installed.Absent
            _state.update { s ->
                s.copy(
                    phase = Phase.FINISHED,
                    summary = buildString {
                        append("$installedCount installed")
                        if (failedCount > 0) append(", $failedCount not installed — see the rows above")
                        append(". ")
                        append(if (runtimePresent) "Opening the runtime once…" else "No runtime is installed.")
                    },
                )
            }
            if (runtimePresent) launchRuntimeOnceWhenUnlocked()
        }
    }

    private fun failureText(c: Component, f: InstallOutcome.Failure): String = when {
        f.signatureMismatch ->
            "${f.message}\n\n${c.displayName} is already installed from a build signed with a " +
                "different key, and Android never upgrades across that. The fix drops that app's " +
                "data, so it is yours to make, not this installer's: Settings → Apps → " +
                "${c.displayName} → Uninstall, then run this again. (The uninstall is not offered " +
                "as a button here: on this tablet's OEM build the uninstall dialog opens and " +
                "closes again immediately without doing anything, so a button would be a lie.)"

        f.neverConfirmed -> f.message
        f.aborted -> "Cancelled at the Android confirmation dialog. Nothing was changed; run it again to retry."
        f.storageFull -> "${f.message}\n\nFree some space and retry."
        else -> f.message
    }

    private fun stopRun(why: String) {
        _state.update { it.copy(phase = Phase.FINISHED, globalError = why, summary = "Stopped.") }
    }

    // ----------------------------------------------- confirmation plumbing

    /** RETRY on a stalled row. */
    fun retryConfirmation() = ApkInstaller.retryConfirmation()

    /**
     * Called when the activity regains the foreground. A confirmation intent
     * started while this app was not foreground can be dropped as a background
     * activity start, so a stalled one is re-raised the moment there is a real
     * foreground activity to start it from.
     */
    fun onForeground() = ApkInstaller.reraiseIfStalled()

    // ------------------------------------------------------------- keyguard

    fun keyguardLocked(): Boolean =
        ctx.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true

    /**
     * Step 1 of android-bundle/INSTALL.md, and the most common virgin-install
     * failure.
     *
     * Uninstalling the runtime deregisters its `OpenXRRuntimeBroker`
     * ContentProvider, and Android's FLAG_STOPPED keeps it unresolvable until
     * the app has been opened at least once. Skip this and EVERY OpenXR app dies
     * at instance creation with XR_ERROR_RUNTIME_UNAVAILABLE. Nothing clears it
     * at boot.
     *
     * At the END of the pass on purpose: starting another app's activity puts
     * this installer in the background, and the per-package confirmation dialogs
     * for anything still queued would then stack on top of the runtime's
     * dashboard. Position does not matter for FLAG_STOPPED — only that it
     * happens before any OpenXR app is launched.
     *
     * And it WAITS for an unlocked screen. A run that ends after a long download
     * ends unattended; launching behind the keyguard is the documented crash
     * path for Model Viewer and Gaussian Splat (displayxr-runtime#1358). Polling
     * one boolean every 2 s beats a dynamic ACTION_USER_PRESENT receiver here:
     * the receiver dies with the process, and this is only ever armed while the
     * app is alive and in the foreground anyway.
     */
    private fun launchRuntimeOnceWhenUnlocked() {
        if (!keyguardLocked()) {
            launchRuntimeOnce()
            return
        }
        _state.update {
            it.copy(
                awaitingUnlock = true,
                summary = "Waiting for you to unlock the tablet before opening the runtime — " +
                    "launching an app behind the lockscreen crashes some demos.",
            )
        }
        viewModelScope.launch {
            val deadline = System.currentTimeMillis() + UNLOCK_WAIT_MS
            while (System.currentTimeMillis() < deadline) {
                delay(2_000)
                if (!keyguardLocked()) {
                    _state.update { it.copy(awaitingUnlock = false) }
                    launchRuntimeOnce()
                    return@launch
                }
            }
            _state.update {
                it.copy(
                    awaitingUnlock = false,
                    globalError = "The tablet stayed locked, so the runtime was not opened. " +
                        "OPEN THE \"DisplayXR\" APP ONCE before launching anything else, or every " +
                        "app will fail at startup with XR_ERROR_RUNTIME_UNAVAILABLE.",
                )
            }
        }
    }

    /** Open the runtime now. Also wired to a button, for when the wait timed out. */
    fun launchRuntimeOnce() {
        val intent = ctx.packageManager.getLaunchIntentForPackage(Catalog.RUNTIME_PACKAGE)
        if (intent == null) {
            _state.update {
                it.copy(
                    globalError = "Could not open the runtime automatically. OPEN THE \"DisplayXR\" " +
                        "APP ONCE by hand before launching anything else, or every app will fail " +
                        "at startup with XR_ERROR_RUNTIME_UNAVAILABLE."
                )
            }
            return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(intent) }.onFailure { t ->
            _state.update { s ->
                s.copy(
                    globalError = "Could not open the runtime automatically (${t.message}). " +
                        "Open the \"DisplayXR\" app once by hand before launching anything else."
                )
            }
        }
    }

    // ------------------------------------------------------------------ misc

    /**
     * Whether the RUNTIME holds SYSTEM_ALERT_WINDOW, or null when it cannot be read.
     *
     * `Settings.canDrawOverlays()` answers for the CALLER, which is useless here —
     * the app-op that matters belongs to the runtime. Reading another package's
     * app-op needs GET_APP_OPS_STATS (signature/privileged), so on most devices
     * this returns null and the UI says so rather than guessing.
     */
    fun runtimeOverlayGranted(): Boolean? {
        val uid = try {
            @Suppress("DEPRECATION")
            ctx.packageManager.getPackageUid(Catalog.RUNTIME_PACKAGE, 0)
        } catch (e: Exception) {
            return null
        }
        val ops = ctx.getSystemService(AppOpsManager::class.java) ?: return null
        return try {
            ops.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW,
                uid,
                Catalog.RUNTIME_PACKAGE,
            ) == AppOpsManager.MODE_ALLOWED
        } catch (t: Throwable) {
            null
        }
    }

    fun refreshInstalledVersions() {
        if (_state.value.phase == Phase.RUNNING) return
        _state.update { s ->
            s.copy(rows = s.rows.map { it.copy(installed = ApkInstaller.installed(ctx, it.component)) })
        }
    }

    /** Atomic per-row edit. Every status the UI shows goes through here. */
    private fun setRow(c: Component, f: (RowState) -> RowState) {
        _state.update { s ->
            s.copy(rows = s.rows.map { if (it.component.id == c.id) f(it) else it })
        }
    }

    private fun plannedSummary(): String {
        val s = _state.value
        val todo = s.rows.count { it.status in PLANNED_STATUSES }
        val problems = s.rows.count { it.status in ATTENTION_STATUSES }
        return buildString {
            append(
                if (todo == 0) "Nothing to install — everything pinned is already current"
                else "$todo to install or update"
            )
            if (problems > 0) append("  •  $problems need attention")
            append(". Android confirms each package separately.")
        }
    }

    private companion object {
        const val UNLOCK_WAIT_MS = 10 * 60 * 1000L

        val ATTENTION_STATUSES =
            setOf(RowStatus.MISSING, RowStatus.UNRESOLVED, RowStatus.BLOCKED, RowStatus.NEWER_INSTALLED)
        val UNRESOLVABLE_STATUSES =
            setOf(RowStatus.MISSING, RowStatus.UNRESOLVED, RowStatus.NOT_PINNED)
        val TERMINAL_STATUSES = setOf(
            RowStatus.DONE, RowStatus.FAILED, RowStatus.DOWNLOADING,
            RowStatus.INSTALLING, RowStatus.CONFIRM_STALLED,
        )
    }
}
