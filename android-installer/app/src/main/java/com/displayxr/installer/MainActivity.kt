package com.displayxr.installer

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.displayxr.installer.databinding.ActivityMainBinding
import com.displayxr.installer.databinding.RowComponentBinding
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var ui: ActivityMainBinding
    private val vm: InstallerViewModel by viewModels()

    /** component id -> its row views, created once and updated in place. */
    private val rowViews = LinkedHashMap<String, RowComponentBinding>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = ActivityMainBinding.inflate(layoutInflater)
        setContentView(ui.root)
        Foreground.appContext = applicationContext

        ui.errorRetry.setOnClickListener { vm.refresh() }
        ui.unknownSourcesBtn.setOnClickListener { openUnknownSourcesSettings() }
        ui.overlayBtn.setOnClickListener { openRuntimeOverlaySettings() }
        ui.runtimeLaunchBtn.setOnClickListener { vm.launchRuntimeOnce() }
        ui.browserOptIn.setOnCheckedChangeListener { _, checked -> vm.setBrowserOptIn(checked) }

        ui.installBtn.setOnClickListener {
            val s = vm.state.value
            when {
                s.phase == Phase.RESOLVING || s.phase == Phase.RUNNING -> Unit
                // "Check again" must not start a run. With nothing to install the
                // run would still fire the launch-once step, which yanks the
                // screen over to the runtime's dashboard for no reason.
                s.phase == Phase.READY && s.rows.any { it.status in PLANNED_STATUSES } -> vm.install()
                else -> vm.refresh()
            }
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                vm.state.collect { render(it) }
            }
        }

        if (vm.state.value.phase == Phase.IDLE) vm.refresh()
    }

    override fun onResume() {
        super.onResume()
        // Two reasons this matters beyond bookkeeping:
        //  - ApkInstaller starts the confirmation intent FROM the resumed
        //    activity when there is one. A background activity start can be
        //    dropped silently, which is a candidate cause of the K68's stall.
        //  - A confirmation already reported stalled is re-raised here, so
        //    coming back to the app is itself a recovery.
        Foreground.activity = this
        vm.onForeground()

        // The two things the owner can change while this app is in the
        // background are the unknown-sources allowance and the runtime's overlay
        // app-op, so both are re-read here rather than cached from onCreate.
        renderPermissionCards()
        vm.refreshInstalledVersions()
    }

    override fun onPause() {
        if (Foreground.activity === this) Foreground.activity = null
        super.onPause()
    }

    // ------------------------------------------------------------------- UI

    private fun render(s: UiState) {
        ui.browserOptIn.isChecked = s.browserOptIn

        ui.errorCard.visibility = if (s.globalError == null) View.GONE else View.VISIBLE
        ui.errorText.text = s.globalError.orEmpty()

        for (row in s.rows) renderRow(row)

        // A run can take many minutes on a large download, and this app must stay
        // foreground across it: that is both how the confirmation intents get a
        // legal activity start, and the simplest defence against the OEM's
        // CpuFreezerManagerServiceV2, which targets apps that are not.
        if (s.phase == Phase.RUNNING || s.awaitingUnlock) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        ui.runtimeLaunchBtn.visibility =
            if (s.phase == Phase.FINISHED || s.awaitingUnlock) View.VISIBLE else View.GONE

        ui.installBtn.isEnabled = when (s.phase) {
            Phase.RESOLVING, Phase.RUNNING -> false
            else -> true
        }
        ui.installBtn.text = when (s.phase) {
            Phase.RESOLVING -> "Checking versions…"
            Phase.RUNNING -> "Installing…"
            Phase.FINISHED -> "Check again"
            Phase.IDLE -> if (s.globalError != null) getString(R.string.btn_retry) else "Check versions"
            Phase.READY ->
                if (s.rows.any { it.status in PLANNED_STATUSES }) getString(R.string.btn_install)
                else "Check again"
        }

        ui.pinSource.text = buildString {
            append(s.pinSource)
            if (s.summary.isNotBlank()) {
                if (isNotEmpty()) append("\n")
                append(s.summary)
            }
        }

        renderPermissionCards()
    }

    private fun renderRow(row: RowState) {
        val b = rowViews.getOrPut(row.component.id) {
            RowComponentBinding.inflate(layoutInflater, ui.rows, true)
        }

        b.name.text = row.component.displayName
        b.versions.text = buildString {
            append("pinned ").append(row.pin ?: "—")
            // Never a bare number here for a package whose version cannot be
            // compared: Installed.label() prints "unknown (Chromium 154.0.…)".
            append("   installed ").append(row.installed.label())
            row.asset?.let { append("\n").append(it.name) }
        }

        val (label, color) = statusLabel(row)
        b.status.text = if (row.detail.isBlank()) label else "$label\n${row.detail}"
        b.status.setTextColor(ContextCompat.getColor(this, color))

        when {
            row.status == RowStatus.DOWNLOADING && row.progressPercent >= 0 -> {
                b.progress.visibility = View.VISIBLE
                b.progress.isIndeterminate = false
                b.progress.progress = row.progressPercent
            }

            row.status == RowStatus.INSTALLING || row.status == RowStatus.RESOLVING -> {
                b.progress.visibility = View.VISIBLE
                b.progress.isIndeterminate = true
            }

            else -> b.progress.visibility = View.GONE
        }

        // The only row action left is RETRY on a confirmation that never
        // appeared. There is deliberately NO uninstall button: it was offered on
        // the strength of a version comparison the code could not make, and on
        // this OEM build the uninstall dialog opens and closes again in the same
        // second without doing anything — so it would be a destructive-looking
        // control that does nothing, chosen for a reason that was wrong.
        if (row.status == RowStatus.CONFIRM_STALLED) {
            b.action.visibility = View.VISIBLE
            b.action.text = getString(R.string.btn_retry_confirm)
            b.action.setOnClickListener { vm.retryConfirmation() }
        } else {
            b.action.visibility = View.GONE
            b.action.setOnClickListener(null)
        }
    }

    private fun statusLabel(row: RowState): Pair<String, Int> = when (row.status) {
        RowStatus.PENDING -> "—" to R.color.dxr_muted
        RowStatus.RESOLVING -> "Checking the release…" to R.color.dxr_muted
        RowStatus.NOT_PINNED -> "Not pinned" to R.color.dxr_warn
        RowStatus.MISSING -> "No Android APK on the pinned release" to R.color.dxr_warn
        RowStatus.UNRESOLVED -> "Could not be resolved" to R.color.dxr_error
        RowStatus.INSTALL -> "Will be installed" to R.color.dxr_accent
        RowStatus.UPDATE -> "Update available" to R.color.dxr_accent
        RowStatus.UPDATE_UNVERIFIABLE -> "Will install the pinned build" to R.color.dxr_accent
        RowStatus.UP_TO_DATE -> "Up to date" to R.color.dxr_ok
        RowStatus.NEWER_INSTALLED ->
            "Installed build is newer than the pin. Android refuses a downgrade, so this is " +
                "skipped." to R.color.dxr_warn
        RowStatus.BLOCKED -> "Refused" to R.color.dxr_error
        RowStatus.SKIPPED -> "Not selected" to R.color.dxr_muted
        RowStatus.DOWNLOADING -> "Downloading…" to R.color.dxr_accent
        RowStatus.INSTALLING -> "Installing — confirm on screen" to R.color.dxr_accent
        RowStatus.CONFIRM_STALLED -> "Waiting — no confirmation appeared" to R.color.dxr_warn
        RowStatus.DONE -> "Installed" to R.color.dxr_ok
        RowStatus.FAILED -> "Failed" to R.color.dxr_error
    }

    private fun renderPermissionCards() {
        val canInstall = packageManager.canRequestPackageInstalls()
        ui.unknownSourcesCard.visibility = if (canInstall) View.GONE else View.VISIBLE

        ui.overlayState.text = when (vm.runtimeOverlayGranted()) {
            true -> getString(R.string.overlay_granted)
            false -> "Not allowed yet — see-through apps will render on black."
            // Reading another package's app-op needs a privileged permission this
            // app does not have and should not ask for, so on most devices the
            // honest answer is "look at the switch yourself".
            null -> "This installer cannot read another app's app-op, so it cannot tell you " +
                "whether this is already on. Open the screen and look."
        }
    }

    // -------------------------------------------------------------- settings

    private fun openUnknownSourcesSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        )
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            runCatching { startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)) }
        }
    }

    /**
     * Deep-link to the runtime's "Display over other apps" switch.
     *
     * A navigation aid and nothing more: SYSTEM_ALERT_WINDOW is an app-op, and no
     * ordinary app can grant it to another package. Some OEM builds also ignore
     * the package-scoped form, hence the two fallbacks — dropping the owner on
     * the full list beats an ActivityNotFoundException.
     */
    private fun openRuntimeOverlaySettings() {
        val targeted = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${Catalog.RUNTIME_PACKAGE}"),
        )
        val list = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
        val details = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${Catalog.RUNTIME_PACKAGE}"),
        )
        for (i in listOf(targeted, list, details)) {
            if (runCatching { startActivity(i) }.isSuccess) return
        }
    }
}
