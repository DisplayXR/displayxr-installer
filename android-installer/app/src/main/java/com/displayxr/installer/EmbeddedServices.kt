package com.displayxr.installer

import android.content.Context
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/**
 * The vendor display-service APKs that the `cnsdk` flavor carries inside itself.
 *
 * The `standard` flavor carries none and this whole file is inert there: [load]
 * finds no index and returns an empty list. The services come from a PRIVATE
 * vendor repo, so the only way an installer can offer them is to embed the exact
 * bytes CI downloaded — which is why that flavor is never attached to a public
 * release (see android-installer/README.md, "Two flavors").
 *
 * They install as UPDATES to built-in apps, and only because they are signed with
 * the OEM key of the app they replace. Any installer may perform that update —
 * verified on an NP02J with the stock file manager — so nothing here needs a
 * privilege the rest of the app does not already have.
 *
 * The index is written at build time by `android-installer/scripts/stage-cnsdk.sh`,
 * which reads package, versionName and versionCode out of each APK with aapt2.
 * They are read from the APK rather than typed by hand because a hand-typed digest
 * in this repo has already false-passed once (build-android-bundle.yml, header).
 */
data class EmbeddedApk(
    /** File name under `assets/cnsdk/apks/`. */
    val fileName: String,
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val sha256: String,
    val size: Long,
) {
    val assetPath: String get() = "${EmbeddedServices.ASSET_DIR}/apks/$fileName"
}

data class EmbeddedBundle(
    /** The CNSDK release tag the APKs came from (`v0.10.69`) — versions.json `cnsdk_services`. */
    val tag: String,
    /** In install order: device-service first, then head tracking. */
    val services: List<EmbeddedApk>,
    /** File names under `assets/cnsdk/licenses/`. */
    val licenses: List<String>,
)

/** Thrown for an index that cannot be trusted. Its message ends up on screen. */
class EmbeddedIndexException(message: String) : IOException(message)

object EmbeddedServices {

    const val ASSET_DIR = "cnsdk"
    const val INDEX = "$ASSET_DIR/index.tsv"

    /**
     * The install order, and the complete list of packages this installer will ever
     * install from its own assets.
     *
     * device-service FIRST because it is the package that carries the CNSDK core
     * (`libleiaCore-impl.so`) — not the head-tracking service, and not the runtime
     * (android-bundle/INSTALL.md, "Order matters"). Both go before the runtime, the
     * same order Routes A/B/C use.
     *
     * An index naming any OTHER package is rejected outright rather than installed:
     * an asset list is not a licence to push an arbitrary package at the owner.
     */
    val SERVICE_ORDER = listOf(
        "com.leialoft.display.config",   // device-service: display config, backlight, the CNSDK core
        "com.leia.headtrackingservice",  // headTracking-service
    )

    /** Licence files the vendor release ships and the redistribution must carry. */
    val REQUIRED_LICENSES = listOf("LICENSE.txt", "LICENSE-3RD-PARTY.txt")

    /** Row labels. Kept here, next to the order, so the two cannot drift. */
    fun displayName(packageName: String): String = when (packageName) {
        SERVICE_ORDER[0] -> "Display service (device-service)"
        SERVICE_ORDER[1] -> "Head-tracking service"
        else -> packageName
    }

    /**
     * Parse `index.tsv`. Pure, so the rules are JVM-tested:
     *  - exactly one `tag` line;
     *  - exactly one `apk` line per package in [SERVICE_ORDER], and none for any other;
     *  - every [REQUIRED_LICENSES] file listed.
     *
     * Anything else is an [EmbeddedIndexException], never a partial result: a
     * with-services installer that silently installs ONE service is how a tablet ends
     * up with a head-tracking update over a stale core, which "updates nothing about
     * 3D prediction" while looking done.
     */
    fun parseIndex(text: String): EmbeddedBundle {
        var tag: String? = null
        val apks = LinkedHashMap<String, EmbeddedApk>()
        val licenses = ArrayList<String>()

        text.lineSequence().forEachIndexed { i, raw ->
            val line = raw.trimEnd('\r')
            if (line.isBlank() || line.startsWith("#")) return@forEachIndexed
            val f = line.split('\t')
            when (f[0]) {
                "tag" -> {
                    if (f.size != 2 || f[1].isBlank()) bad(i, "tag line needs one value")
                    if (tag != null) bad(i, "more than one tag line")
                    tag = f[1]
                }

                "apk" -> {
                    if (f.size != 7) bad(i, "apk line needs 6 fields, has ${f.size - 1}")
                    val code = f[4].toLongOrNull() ?: bad(i, "versionCode '${f[4]}' is not a number")
                    val size = f[6].toLongOrNull() ?: bad(i, "size '${f[6]}' is not a number")
                    val pkg = f[2]
                    if (pkg !in SERVICE_ORDER) {
                        bad(i, "package $pkg is not one of the display services this installer may install")
                    }
                    if (pkg in apks) bad(i, "package $pkg is listed twice")
                    if (!SHA256.matches(f[5])) bad(i, "sha256 for ${f[1]} is not 64 hex digits")
                    if (f[1].isBlank() || f[1].contains('/')) bad(i, "bad file name '${f[1]}'")
                    if (f[3].isBlank()) bad(i, "versionName for $pkg is empty")
                    apks[pkg] = EmbeddedApk(
                        fileName = f[1],
                        packageName = pkg,
                        versionName = f[3],
                        versionCode = code,
                        sha256 = f[5].lowercase(),
                        size = size,
                    )
                }

                "license" -> {
                    if (f.size != 2 || f[1].isBlank() || f[1].contains('/')) bad(i, "bad license line")
                    licenses += f[1]
                }

                else -> bad(i, "unknown record '${f[0]}'")
            }
        }

        val t = tag ?: throw EmbeddedIndexException("index has no tag line")
        val missing = SERVICE_ORDER.filter { it !in apks }
        if (missing.isNotEmpty()) {
            throw EmbeddedIndexException("index lists no APK for ${missing.joinToString()}")
        }
        val missingLic = REQUIRED_LICENSES.filter { it !in licenses }
        if (missingLic.isNotEmpty()) {
            throw EmbeddedIndexException(
                "index lists no ${missingLic.joinToString()} — the services are redistributed " +
                    "binaries and must not travel without their licence notices"
            )
        }
        return EmbeddedBundle(t, SERVICE_ORDER.map { apks.getValue(it) }, licenses)
    }

    private fun bad(line: Int, why: String): Nothing =
        throw EmbeddedIndexException("index line ${line + 1}: $why")

    private val SHA256 = Regex("^[0-9a-fA-F]{64}$")

    /**
     * The embedded bundle, or null when this build carries none (the `standard`
     * flavor). A present-but-broken index throws: that is a build defect and it
     * must be shown, not treated as "no services".
     */
    fun load(context: Context): EmbeddedBundle? {
        val text = try {
            context.assets.open(INDEX).use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (e: FileNotFoundException) {
            return null
        }
        return parseIndex(text)
    }

    fun readLicense(context: Context, name: String): String =
        context.assets.open("$ASSET_DIR/licenses/$name").use { it.readBytes().toString(Charsets.UTF_8) }

    /**
     * Copy an embedded APK out to [dest] and prove the copy is the bytes the
     * index names. PackageInstaller needs a stream of known length, and a
     * truncated or substituted asset must be caught here rather than reported by
     * Android as an opaque "invalid APK".
     */
    fun extract(context: Context, apk: EmbeddedApk, dest: File) {
        dest.delete()
        context.assets.open(apk.assetPath).use { input -> copyVerified(input, dest, apk) }
    }

    /** The verifying copy, split out so it is testable without an AssetManager. */
    fun copyVerified(input: InputStream, dest: File, apk: EmbeddedApk) {
        val md = MessageDigest.getInstance("SHA-256")
        var n = 0L
        dest.outputStream().use { out ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val r = input.read(buf)
                if (r < 0) break
                md.update(buf, 0, r)
                out.write(buf, 0, r)
                n += r
            }
        }
        val got = md.digest().joinToString("") { "%02x".format(it) }
        if (n != apk.size || got != apk.sha256) {
            dest.delete()
            throw EmbeddedIndexException(
                "${apk.fileName} inside this installer is not the file its index names " +
                    "($n bytes, sha256 ${got.take(12)}…; expected ${apk.size} bytes, " +
                    "${apk.sha256.take(12)}…). This installer build is damaged — nothing was installed."
            )
        }
    }
}
