package com.displayxr.installer

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
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

        ui.errorRetry.setOnClickListener { vm.refresh() }
        ui.unknownSourcesBtn.setOnClickListener { openUnknownSourcesSettings() }
        ui.overlayBtn.setOnClickListener { openRuntimeOverlaySettings() }
        ui.browserOptIn.setOnCheckedChangeListener { _, checked -> vm.setBrowserOptIn(checked) }

        ui.installBtn.setOnClickListener {
            val s = vm.state.value
            when {
                s.phase == Phase.RESOLVING || s.phase == Phase.RUNNING -> Unit
                // "Check again" must not start a run. With nothing to install the
                // run would still fire the launch-once step, which yanks the
                // screen over to the runtime's dashboard for no reason.
                s.phase == Phase.READY && s.rows.any { it.status in PLANNED } -> vm.install()
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
        // The two things the owner can change while this app is in the
        // background are the unknown-sources allowance and the runtime's overlay
        // app-op, so both are re-read here rather than cached from onCreate.
        renderPermissionCards()
        vm.refreshInstalledVersions()
    }

    // ------------------------------------------------------------------- UI

    private fun render(s: UiState) {
        ui.pinSource.text = s.pinSource
        ui.browserOptIn.isChecked = s.browserOptIn

        ui.errorCard.visibility = if (s.globalError == null) View.GONE else View.VISIBLE
        ui.errorText.text = s.globalError.orEmpty()

        for (row in s.rows) renderRow(row)

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
                if (s.rows.any { it.status in PLANNED }) getString(R.string.btn_install)
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
            append("   installed ").append(row.installed ?: "not installed")
            row.asset?.let { append("\n").append(it.name) }
        }

        val (label, color) = statusLabel(row)
        b.status.text = if (row.detail.isBlank()) label else "$label\n${row.detail}"
        b.status.setTextColor(ContextCompat.getColor(this, color))

        if (row.status == RowStatus.DOWNLOADING && row.progressPercent >= 0) {
            b.progress.visibility = View.VISIBLE
            b.progress.isIndeterminate = false
            b.progress.progress = row.progressPercent
        } else if (row.status == RowStatus.INSTALLING || row.status == RowStatus.RESOLVING) {
            b.progress.visibility = View.VISIBLE
            b.progress.isIndeterminate = true
        } else {
            b.progress.visibility = View.GONE
        }

        // The one row action there is: Android will not replace a package signed
        // with another key, and will not downgrade one. Both dead-end in the same
        // place, and both cost the app's data — so this offers the uninstall
        // explicitly instead of performing it.
        val needsUninstall = row.offerUninstall || row.status == RowStatus.NEWER_INSTALLED
        b.action.visibility = if (needsUninstall) View.VISIBLE else View.GONE
        b.action.text = "Uninstall ${row.component.displayName} (drops its data)"
        b.action.setOnClickListener {
            val intent = Intent(Intent.ACTION_DELETE, Uri.parse("package:${row.component.packageName}"))
            runCatching { startActivity(intent) }
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
        RowStatus.UP_TO_DATE -> "Up to date" to R.color.dxr_ok
        RowStatus.NEWER_INSTALLED ->
            "Installed build is NEWER than the pin. Android refuses a downgrade, so this is " +
                "skipped; uninstall it first if you really want the pinned build." to R.color.dxr_warn
        RowStatus.BLOCKED -> "Refused" to R.color.dxr_error
        RowStatus.SKIPPED -> "Not selected" to R.color.dxr_muted
        RowStatus.DOWNLOADING -> "Downloading…" to R.color.dxr_accent
        RowStatus.INSTALLING -> "Installing — confirm on screen" to R.color.dxr_accent
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
     * This is a navigation aid and nothing more: SYSTEM_ALERT_WINDOW is an
     * app-op, and no ordinary app can grant it to another package. Some OEM
     * builds also ignore the package-scoped form, hence the two fallbacks —
     * dropping the owner on the full list beats an ActivityNotFoundException.
     */
    private companion object {
        val PLANNED = setOf(RowStatus.INSTALL, RowStatus.UPDATE)
    }

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
