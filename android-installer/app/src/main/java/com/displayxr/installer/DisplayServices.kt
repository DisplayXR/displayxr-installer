package com.displayxr.installer

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.MalformedURLException
import java.net.URL
import java.security.MessageDigest

/**
 * The tablet's vendor display services — `com.leialoft.display.config` (device-service,
 * which carries the CNSDK core) and `com.leia.headtrackingservice` — and how this
 * installer updates them.
 *
 * Why it has to: on the FACTORY services the DisplayXR stack runs but is unusable
 * (measured on an NP02J: content stays 2D, vertical parallax is inverted, apps freeze).
 * The factory core predates the eye APIs the runtime needs. So every tablet must be on
 * the pinned CNSDK (`versions.json` → `cnsdk_services`).
 *
 * Where the bytes come from: `updates.displayxr.org/services/cnsdk/<tag>/`, published by
 * `.github/workflows/publish-cnsdk-services.yml`. That host is NOT a trust boundary.
 * What is trusted is (a) the pin, read from versions.json like every other pin, and
 * (b) the two signing certificates hard-coded below. The manifest's sha256 and size
 * catch a damaged download; the certificate pin is what stops a substituted one — and
 * Android itself refuses an update to a built-in app that is not signed with the key of
 * the app it replaces, so a wrong key could never install anyway. The check here makes
 * that refusal a sentence on the row instead of an opaque INSTALL_FAILED_*.
 *
 * Everything in this object is pure (no Android types) and JVM-tested; the two calls that
 * need a PackageManager live in [ApkInstaller.archiveIdentity] and [ApkInstaller.deviceServiceIsSystem].
 */
object DisplayServices {

    const val DEVICE_SERVICE = "com.leialoft.display.config"
    const val HEADTRACKING = "com.leia.headtrackingservice"

    /**
     * Install order, and the complete list of packages this installer will ever take
     * from the services host.
     *
     * device-service FIRST because it is the package that carries the CNSDK core
     * (`libleiaCore-impl.so`) — not the head-tracking service, and not the runtime
     * (android-bundle/INSTALL.md, "Order matters"). Both go before the runtime.
     */
    val SERVICE_ORDER = listOf(DEVICE_SERVICE, HEADTRACKING)

    /**
     * SHA-256 of each service's signing certificate, as `apksigner verify --print-certs`
     * prints it. Identical on the NP02J/K68, the Lume Pad 2 and the Lume Phone (measured;
     * see build-android-bundle.yml's device-coverage note).
     *
     * The same table lives in `android-installer/scripts/service-signers.tsv`, which the
     * publishing workflow checks the vendor APKs against before anything is published;
     * `DisplayServicesTest` fails if the two disagree. Changing a key here is a decision,
     * not a refresh: it is what lets bytes from the host onto a tablet.
     */
    val PINNED_SIGNERS: Map<String, String> = mapOf(
        DEVICE_SERVICE to "dbc2792f775902a74302d500ab00c6224a4aeb89adb7d5dfdd4c3eeba763811c",
        HEADTRACKING to "113ec0526354587c047183f7f6c1d90ee06d1286b0e848a168b38ad131c05096",
    )

    /**
     * The services host. The feed for the DisplayXR Browser lives on the same host
     * (`/feed.json`); nothing links to `/services/`, and there is no directory listing.
     */
    const val HOST = "https://updates.displayxr.org"

    /** Resolved from the pinned tag, so the manifest can never name a different release. */
    fun manifestUrl(tag: String): String = "$HOST/services/cnsdk/$tag/manifest.json"

    fun displayName(packageName: String): String = when (packageName) {
        DEVICE_SERVICE -> "Display service (device-service)"
        HEADTRACKING -> "Head-tracking service"
        else -> packageName
    }

    /**
     * Is this a tablet whose display services this installer should manage?
     *
     * Yes only when device-service is installed AND is a system app — i.e. it shipped
     * in the OEM image. `FLAG_SYSTEM` stays set after an update (the package is then
     * also `FLAG_UPDATED_SYSTEM_APP`), so an already-updated tablet still qualifies.
     * A sideloaded copy of the package on some other phone does not: this installer
     * must never push display firmware at a device that did not ship with it.
     *
     * @param deviceServiceIsSystem null when device-service is not installed at all.
     */
    fun isTargetDevice(deviceServiceIsSystem: Boolean?): Boolean = deviceServiceIsSystem == true

    // ------------------------------------------------------------------ manifest

    /**
     * Parse the host's manifest. Pure. Every rule below is a refusal with a sentence,
     * never a partial result: a half-valid manifest that installs ONE service is how a
     * tablet ends up with a head-tracking update over a stale core, which "changes
     * nothing about 3D prediction" while looking done.
     *
     *  - `schema` is 1 and `cnsdk_tag` equals the tag versions.json pins;
     *  - exactly one entry per package in [SERVICE_ORDER], none for any other;
     *  - each entry's `versionName` is the pinned tag (without `v`) — the same rule the
     *    publishing workflow applies, checked again here against the pin;
     *  - each entry's `signer_sha256` equals [PINNED_SIGNERS] — a manifest that claims a
     *    different key is refused before a byte is downloaded;
     *  - file names are plain names, resolved against the manifest's own URL.
     */
    fun parseManifest(json: String, manifestUrl: String, pinnedTag: String): ServiceManifest {
        val root = try {
            JSONObject(json)
        } catch (e: JSONException) {
            throw ServiceManifestException("the services manifest is not valid JSON (${e.message})")
        }
        try {
            val schema = root.optInt("schema", -1)
            if (schema != 1) bad("unsupported manifest schema $schema (this installer reads schema 1)")
            val tag = root.getString("cnsdk_tag")
            if (!Versions.same(tag, pinnedTag)) {
                bad("the host serves CNSDK $tag, but versions.json pins $pinnedTag")
            }
            val build = root.optString("cnsdk_build").ifBlank { Versions.strip(tag) }

            val base = try {
                URL(manifestUrl)
            } catch (e: MalformedURLException) {
                bad("bad manifest URL $manifestUrl")
            }

            val services = LinkedHashMap<String, ServiceApk>()
            val arr: JSONArray = root.getJSONArray("services")
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val pkg = o.getString("package")
                if (pkg !in SERVICE_ORDER) bad("package $pkg is not one of the display services this installer may install")
                if (pkg in services) bad("package $pkg is listed twice")
                val file = plainFileName(o.getString("file"))
                val versionName = o.getString("versionName")
                if (!Versions.same(versionName, tag)) {
                    bad("$pkg is versionName $versionName, but the release is $tag")
                }
                val code = o.getLong("versionCode")
                if (code <= 0) bad("$pkg has versionCode $code")
                val sha = o.getString("sha256").lowercase()
                if (!SHA256.matches(sha)) bad("sha256 for $pkg is not 64 hex digits")
                val size = o.getLong("size")
                if (size <= 0) bad("$pkg has size $size")
                val signer = o.getString("signer_sha256").lowercase()
                if (signer != PINNED_SIGNERS.getValue(pkg)) {
                    bad(
                        "$pkg is declared as signed by ${signer.take(16)}…, not the vendor key this " +
                            "installer trusts (${PINNED_SIGNERS.getValue(pkg).take(16)}…). Refused."
                    )
                }
                services[pkg] = ServiceApk(
                    packageName = pkg,
                    fileName = file,
                    url = URL(base, file).toString(),
                    versionName = versionName,
                    versionCode = code,
                    sha256 = sha,
                    size = size,
                    signerSha256 = signer,
                )
            }
            val missing = SERVICE_ORDER.filter { it !in services }
            if (missing.isNotEmpty()) bad("the manifest lists no APK for ${missing.joinToString()}")

            val licenses = ArrayList<LicenseFile>()
            root.optJSONArray("licenses")?.let { la ->
                for (i in 0 until la.length()) {
                    val file = plainFileName(la.getJSONObject(i).getString("file"))
                    licenses += LicenseFile(file, URL(base, file).toString())
                }
            }
            return ServiceManifest(tag, build, SERVICE_ORDER.map { services.getValue(it) }, licenses)
        } catch (e: JSONException) {
            throw ServiceManifestException("the services manifest is missing a field (${e.message})")
        }
    }

    private fun plainFileName(name: String): String {
        if (name.isBlank() || name.contains('/') || name.contains('\\') || name.startsWith(".") ||
            name.contains(':') || name.contains('?') || name.contains('#')
        ) bad("bad file name '$name' in the manifest")
        return name
    }

    private fun bad(why: String): Nothing = throw ServiceManifestException(why)

    private val SHA256 = Regex("^[0-9a-f]{64}$")

    // --------------------------------------------------------------- verification

    fun sha256Of(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val r = input.read(buf)
                if (r < 0) break
                md.update(buf, 0, r)
            }
        }
        return md.digest().toHex()
    }

    fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    /**
     * The downloaded file is the file the manifest names: size, then sha256. Deletes the
     * file and throws on a mismatch — a truncated or substituted APK is refused here with
     * a sentence rather than handed to Android to fail as an opaque "invalid APK".
     */
    fun verifyFile(file: File, apk: ServiceApk) {
        val n = file.length()
        val got = if (n == apk.size) sha256Of(file) else null
        if (n != apk.size || got != apk.sha256) {
            file.delete()
            throw ServiceVerificationException(
                "${apk.fileName} is not the file the manifest names ($n bytes" +
                    (got?.let { ", sha256 ${it.take(12)}…" } ?: "") +
                    "; expected ${apk.size} bytes, sha256 ${apk.sha256.take(12)}…). It was deleted and " +
                    "nothing was installed. Tap Retry to download it again."
            )
        }
    }

    /**
     * What Android reads out of the downloaded archive must agree with the manifest AND
     * with the certificate pin. Pure; the caller feeds it `getPackageArchiveInfo`.
     *
     * @param signers SHA-256 digests of the archive's CURRENT signing certificate(s),
     *        or empty when Android could not read them. Exactly one, equal to the pin.
     * @return null when the archive is acceptable, otherwise the reason it is not.
     */
    fun archiveProblem(
        apk: ServiceApk,
        archivePackage: String?,
        archiveVersionCode: Long?,
        signers: List<String>,
    ): String? {
        val pinned = PINNED_SIGNERS[apk.packageName]
            ?: return "${apk.packageName} is not a display service this installer may install."
        if (archivePackage == null) return "Android could not read ${apk.fileName} as an APK."
        if (archivePackage != apk.packageName) {
            return "${apk.fileName} is package $archivePackage, not ${apk.packageName}."
        }
        if (archiveVersionCode != apk.versionCode) {
            return "${apk.fileName} is versionCode $archiveVersionCode, not ${apk.versionCode} as the manifest says."
        }
        if (signers.isEmpty()) {
            return "Android could not read the signing certificate of ${apk.fileName}, so it cannot be " +
                "checked against the vendor key. Refused."
        }
        val norm = signers.map { it.lowercase() }.distinct()
        if (norm != listOf(pinned)) {
            return "${apk.fileName} is signed by ${norm.joinToString { it.take(16) + "…" }}, not the " +
                "vendor key this installer trusts (${pinned.take(16)}…). Refused — nothing was installed."
        }
        return null
    }

    // ------------------------------------------------------------ staleness

    /**
     * Which services are older than the pin — the state in which DisplayXR runs but 3D
     * does not work correctly. Pure.
     *
     * With the manifest, decided on versionCode (Android's own rule). Without it (host
     * unreachable) the versionName is compared with the pinned tag; for the vendor
     * services versionName is the CNSDK release (factory 0.8.29, pinned 0.10.69), so
     * that comparison is meaningful. This verdict only ever produces a WARNING — it
     * never skips, removes or downgrades anything — so the weaker signal is acceptable
     * here in a way it would not be for NEWER_INSTALLED.
     *
     * An [Installed.Opaque] version is never called stale: no claim without a comparison.
     */
    fun staleServices(
        installed: Map<String, Installed>,
        pinnedTag: String,
        manifest: ServiceManifest?,
    ): List<String> = SERVICE_ORDER.filter { pkg ->
        when (val i = installed[pkg] ?: Installed.Absent) {
            Installed.Absent -> true
            is Installed.Opaque -> false
            is Installed.Exact -> {
                val want = manifest?.services?.firstOrNull { it.packageName == pkg }
                val code = i.versionCode
                if (want != null && code != null) code < want.versionCode
                else Versions.compare(i.version, pinnedTag) < 0
            }
        }
    }

    /** The one sentence that must appear whenever [staleServices] is non-empty. */
    fun staleWarning(stale: List<String>, installed: Map<String, Installed>, pinnedTag: String): String =
        "3D WILL NOT WORK CORRECTLY on this tablet until its display services are updated. " +
            stale.joinToString("; ") { "${displayName(it)}: installed ${(installed[it] ?: Installed.Absent).label()}" } +
            " — DisplayXR needs CNSDK ${Versions.strip(pinnedTag)}. On older services content stays 2D, " +
            "vertical parallax is inverted and apps can freeze. Make sure the tablet is online, tap " +
            "Check again, then Install / update."
}

data class ServiceApk(
    val packageName: String,
    /** Plain file name on the host, relative to the manifest. */
    val fileName: String,
    val url: String,
    val versionName: String,
    val versionCode: Long,
    val sha256: String,
    val size: Long,
    val signerSha256: String,
)

data class LicenseFile(val name: String, val url: String)

data class ServiceManifest(
    /** The CNSDK release tag (`v0.10.69`) — versions.json `cnsdk_services`. */
    val tag: String,
    /** The full CNSDK build string (`0.10.69+193.8291a2e`). */
    val build: String,
    /** In install order: device-service first, then head tracking. */
    val services: List<ServiceApk>,
    val licenses: List<LicenseFile>,
)

/** The manifest cannot be trusted. Its message ends up on screen. */
class ServiceManifestException(message: String) : IOException(message)

/** A downloaded service APK is not the one the manifest and the pin describe. */
class ServiceVerificationException(message: String) : IOException(message)
