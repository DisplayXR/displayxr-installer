package com.displayxr.installer

/**
 * The screen's data model and the pure decisions behind it.
 *
 * Deliberately free of Android types: everything here is driven directly by JVM
 * tests, because the two defects the tablet found in the first pass were both
 * decisions, not plumbing — a comparison the code could not actually make, and
 * a state with no way out.
 */

enum class Phase { IDLE, RESOLVING, READY, RUNNING, FINISHED }

enum class RowStatus {
    PENDING,              // nothing known yet
    RESOLVING,            // reading the release
    NOT_PINNED,           // versions.json has no pin for this component
    MISSING,              // pinned, but that release publishes no Android APK
    UNRESOLVED,           // network / API failure while resolving THIS component
    INSTALL,              // not installed; will be installed
    UPDATE,               // installed, older than the pin
    UPDATE_UNVERIFIABLE,  // installed, but its DisplayXR version cannot be read
    UP_TO_DATE,           // installed version == pin
    NEWER_INSTALLED,      // installed version > pin; Android refuses a downgrade
    BLOCKED,              // refused on purpose (the browser gate)
    SKIPPED,              // opt-in and not opted in
    DOWNLOADING,
    INSTALLING,           // session committed, confirmation raised
    CONFIRM_STALLED,      // the confirmation dialog never appeared — offer a retry
    DONE,
    FAILED,
}

/**
 * What is installed, and — the part that matters — whether its version can be
 * compared with the pin at all.
 *
 * `versionName` is the DisplayXR release version for the runtime and the demos.
 * It is **not** for the browser: `org.chromium.chrome` reports the Chromium
 * version (`154.0.8037.17`), and several DisplayXR browser releases share one
 * Chromium base, so no comparison exists to make (displayxr-browser-pvt#158).
 * The first version of this installer compared `v1.0.4` against `154.0.8037.17`,
 * concluded "installed is newer" — the only conclusion that comparison can ever
 * reach — and offered to uninstall the tester's browser, dropping its profile,
 * to resolve a conflict that did not exist.
 *
 * Hence [Opaque]: a version string that means something else is not a weaker
 * signal, it is the wrong one, and the honest answer is "unknown".
 */
sealed class Installed {
    object Absent : Installed()

    /**
     * The version is the release version and may be compared. [versionCode] is
     * carried for the embedded display services, where it — not the name — is what
     * Android's downgrade rule is decided on; see [servicePlannedStatus].
     */
    data class Exact(val version: String, val versionCode: Long? = null) : Installed()

    /** Installed, but its DisplayXR version is not readable. [shown] is what IS known. */
    data class Opaque(val shown: String) : Installed()

    /** One line for the row, never a bare number that invites a false comparison. */
    fun label(): String = when (this) {
        Absent -> "not installed"
        is Exact -> version
        is Opaque -> "unknown ($shown)"
    }
}

data class RowState(
    val component: Component,
    val pin: String? = null,
    val asset: Asset? = null,
    val installed: Installed = Installed.Absent,
    val status: RowStatus = RowStatus.PENDING,
    val detail: String = "",
    val progressPercent: Int = -1,
)

data class UiState(
    val phase: Phase = Phase.IDLE,
    val pinSource: String = "",
    val globalError: String? = null,
    val rows: List<RowState> = emptyList(),
    val browserOptIn: Boolean = false,
    val summary: String = "",
    /** Set while the launch-once step is waiting for the owner to unlock. */
    val awaitingUnlock: Boolean = false,
    /**
     * Set once any embedded display service has been installed in this run, and the
     * owner must then reboot. Skipping it is invisible: the display service is
     * replaced under a running system, the lens-controller HAL can be left writing
     * 3D commands the controller never answers, and every app weaves and tracks
     * while the glass stays flat 2D (android-bundle/INSTALL.md, "Reboot. It is not
     * optional"). Sticky for the life of the screen on purpose: the run ends by
     * opening the runtime, and the notice has to still be there when the owner
     * comes back.
     */
    val rebootRequired: Boolean = false,
    /** Whether this build carries the display services (the `cnsdk` flavor). */
    val hasEmbeddedServices: Boolean = false,
)

/**
 * What the run intends to do with a component.
 *
 * The one rule this encodes: an unreadable version NEVER produces
 * [RowStatus.NEWER_INSTALLED]. "Newer" is a claim, and a claim the code cannot
 * support is what led to offering a destructive uninstall.
 */
fun plannedStatus(installed: Installed, pin: String): RowStatus = when (installed) {
    Installed.Absent -> RowStatus.INSTALL
    is Installed.Opaque -> RowStatus.UPDATE_UNVERIFIABLE
    is Installed.Exact -> when {
        Versions.same(installed.version, pin) -> RowStatus.UP_TO_DATE
        Versions.compare(installed.version, pin) > 0 -> RowStatus.NEWER_INSTALLED
        else -> RowStatus.UPDATE
    }
}

/**
 * What the run intends to do with an EMBEDDED display service.
 *
 * Not [plannedStatus], for one reason: for these packages Android decides
 * "downgrade" on `versionCode`, and the vendor's versionCode is a real, readable
 * signal (`290010069` for device-service 0.10.69). So "newer" is claimed only when
 * Android itself would refuse the install — the one comparison that is certainly
 * the right one — and never on the strength of a versionName, which on a factory
 * or dev build may be in some other scheme.
 *
 * Consistent with the README's "Versions that cannot be read" rule: the verdict
 * that has consequences ([RowStatus.NEWER_INSTALLED], which skips the package)
 * rests only on Android's own rule, and nothing destructive is offered for any
 * verdict — there is no uninstall anywhere in the app.
 */
fun servicePlannedStatus(installed: Installed, embedded: EmbeddedApk): RowStatus = when (installed) {
    Installed.Absent -> RowStatus.INSTALL
    is Installed.Opaque -> RowStatus.UPDATE_UNVERIFIABLE
    is Installed.Exact -> {
        val code = installed.versionCode
        when {
            // No readable versionCode: install is offered, "newer" never claimed.
            code == null ->
                if (Versions.same(installed.version, embedded.versionName)) RowStatus.UP_TO_DATE
                else RowStatus.UPDATE_UNVERIFIABLE

            code > embedded.versionCode -> RowStatus.NEWER_INSTALLED
            code < embedded.versionCode -> RowStatus.UPDATE
            // Same versionCode. Same name as well is the plain "already current";
            // a different name at the same code is a build we cannot place, and
            // Android permits reinstalling over it, so it is offered, not asserted.
            Versions.same(installed.version, embedded.versionName) -> RowStatus.UP_TO_DATE
            else -> RowStatus.UPDATE_UNVERIFIABLE
        }
    }
}

val PLANNED_STATUSES = setOf(
    RowStatus.INSTALL,
    RowStatus.UPDATE,
    RowStatus.UPDATE_UNVERIFIABLE,
)
