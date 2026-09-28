plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

/*
 * Where the with-services (cnsdk) build takes the vendor display-service APKs and
 * their licence files from: a directory laid out by scripts/stage-cnsdk.sh, passed as
 * -PcnsdkStagingDir=<dir>. It holds <dir>/cnsdk/{index.tsv,apks/,licenses/} and is
 * mounted as an extra assets root for the cnsdk flavor ONLY.
 *
 * Those APKs come from a private vendor repo. They are never committed here and the
 * standard flavor never sees this directory — that separation is what lets the
 * standard APK go on a public release (see README "Two flavors").
 */
val cnsdkStagingDir: String? =
    (project.findProperty("cnsdkStagingDir") as String?)?.takeIf { it.isNotBlank() }

android {
    namespace = "com.displayxr.installer"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.displayxr.installer"
        // minSdk 31 is a hard requirement, not a default: the two tablets this
        // installer exists for are Android 13 (K68 / NP02J) and Android 12
        // (Lume Pad 2). Raising it past 31 silently drops the Lume Pad 2.
        minSdk = 31
        targetSdk = 35
        versionCode = (project.findProperty("installerVersionCode") as String).toInt()
        versionName = project.findProperty("installerVersionName") as String

        // English only: the app ships no translations of its own, so AppCompat's
        // bundled locales are dead weight. Measured at 138 KB of a ~7.4 MB APK —
        // worth taking, but it is not where the size is. The APK is dominated by
        // an un-minified classes.dex, and minification stays OFF deliberately:
        // R8 cannot be validated from a build alone, and a stripped ViewModel or
        // ViewBinding surfaces only at run time, on the tablet.
        resourceConfigurations += "en"
    }

    /*
     * Two distributions of one app.
     *
     *  standard  DisplayXR-Installer-<ver>.apk. Downloads everything from public
     *            releases. Carries no vendor bytes, so it is attached to every public
     *            bundle release.
     *  cnsdk     DisplayXR-Installer-<ver>-with-cnsdk.apk. Additionally CARRIES the two
     *            pinned vendor display-service APKs and installs them first. Private:
     *            shipped inside the tablet-bundle zip and as a CI artifact, never on a
     *            public release.
     *
     * The cnsdk build has its own application id. Both can then sit on one tablet, and
     * — while CI signs with a throwaway debug key per run — installing one never fails
     * as a signature-mismatched "update" of the other.
     */
    flavorDimensions += "distribution"
    productFlavors {
        create("standard") {
            dimension = "distribution"
            buildConfigField("boolean", "EMBEDS_CNSDK", "false")
        }
        create("cnsdk") {
            dimension = "distribution"
            applicationIdSuffix = ".cnsdk"
            // Read at run time: a cnsdk build that finds no services says so on screen
            // instead of behaving like the standard installer.
            buildConfigField("boolean", "EMBEDS_CNSDK", "true")
        }
    }

    sourceSets {
        getByName("cnsdk") {
            cnsdkStagingDir?.let { assets.srcDir(it) }
        }
    }

    // The embedded APKs are already zip archives; deflating them again costs build time
    // and buys nothing. Stored, they are also streamed out at install time unchanged.
    androidResources {
        noCompress += "apk"
    }

    buildTypes {
        release {
            // No minification: the release variant is only ever built to be
            // sideloaded, and an obfuscated stack trace from a tester's tablet
            // is worth less than the ~200 KB saved.
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }
}

/*
 * A cnsdk APK with no services in it would install, run, and quietly behave like the
 * standard installer — while its owner believes it updated the display services. So
 * packaging a cnsdk variant FAILS unless the staging directory holds a complete index,
 * every APK it names, and the licence notices those binaries must travel with. Unit
 * tests do not merge assets and are unaffected.
 */
val checkCnsdkStaging by tasks.registering {
    val dir = cnsdkStagingDir
    doLast {
        fun fail(why: String): Nothing = throw GradleException(
            "cnsdk flavor: $why\n" +
                "Stage the vendor display services first:\n" +
                "  scripts/stage-cnsdk.sh --tag <cnsdk_services tag> --apks <dir> --licenses <dir> --out <staging>\n" +
                "then build with -PcnsdkStagingDir=<staging>."
        )
        if (dir == null) fail("-PcnsdkStagingDir is not set")
        val index = file("$dir/cnsdk/index.tsv")
        if (!index.isFile) fail("$index does not exist")
        var apks = 0
        var licenses = 0
        index.readLines().filter { it.isNotBlank() && !it.startsWith("#") }.forEach { line ->
            val f = line.split('\t')
            when (f.getOrNull(0)) {
                "apk" -> {
                    val a = file("$dir/cnsdk/apks/${f.getOrNull(1)}")
                    if (!a.isFile || a.length() == 0L) fail("index names $a, which is missing or empty")
                    if (a.length() != f.getOrNull(6)?.toLongOrNull()) fail("$a is not the size the index records")
                    apks++
                }
                "license" -> {
                    val l = file("$dir/cnsdk/licenses/${f.getOrNull(1)}")
                    if (!l.isFile || l.length() == 0L) fail("index names $l, which is missing or empty")
                    licenses++
                }
            }
        }
        if (apks != 2) fail("index lists $apks service APKs, expected 2 (device-service + headTracking)")
        if (licenses < 2) fail("index lists $licenses licence files, expected LICENSE.txt + LICENSE-3RD-PARTY.txt at least")
    }
}
tasks.configureEach {
    if (name.startsWith("mergeCnsdk") && name.endsWith("Assets")) dependsOn(checkCnsdkStaging)
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // JVM-only tests. They cover the two pieces that can be checked without a
    // tablet: asset resolution against real release asset lists, and the version
    // comparison the browser gate rests on.
    testImplementation("junit:junit:4.13.2")
}
