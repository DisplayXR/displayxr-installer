plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

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
     * One distribution. There used to be a second, `cnsdk` flavor that carried the
     * vendor display-service APKs inside itself and could therefore never be published.
     * It is retired: this one APK now downloads the pinned services from
     * updates.displayxr.org on a 3D tablet (see DisplayServices.kt), so the public APK
     * is the only one anybody needs — and it still carries no vendor bytes, which
     * build-android-installer.yml and publish-bundle.yml both check from the file.
     */

    // THE release key (README "Signing"). One key for every published installer, because
    // Android updates an installed app only from an APK signed by the same key. The keystore
    // never enters the repo: CI decodes it from the `android-installer-release` environment
    // secrets (deployable from `main` only) and points these variables at the file.
    //
    // Without them — a fork's PR, a local build — the release variant is signed with the
    // DEBUG key instead, so it still builds and installs for testing, and it can never be
    // published: every workflow that attaches the APK to a release runs
    // scripts/verify-release-signature.sh, which refuses any signer but the pinned one.
    val releaseKeystore = System.getenv("ANDROID_INSTALLER_KEYSTORE_FILE")?.takeIf { it.isNotBlank() }
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                val ks = file(releaseKeystore)
                require(ks.isFile) { "ANDROID_INSTALLER_KEYSTORE_FILE=$releaseKeystore is not a file" }
                fun env(name: String) = System.getenv(name)?.takeIf { it.isNotEmpty() }
                    ?: throw GradleException("ANDROID_INSTALLER_KEYSTORE_FILE is set but $name is not")
                storeFile = ks
                storePassword = env("ANDROID_INSTALLER_KEYSTORE_PASSWORD")
                keyAlias = env("ANDROID_INSTALLER_KEY_ALIAS")
                keyPassword = env("ANDROID_INSTALLER_KEY_PASSWORD")
                // v2 only, stated rather than left to AGP's defaults: the shape every other
                // DisplayXR APK ships (runtime, demos, browser), and the one the release gate
                // asserts. v3 is not needed to rotate later — a v3 lineage added AT rotation
                // time is accepted by devices whose installed copy was v2-signed with the old
                // key (API 28+; every supported tablet is 31+).
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = false
                enableV4Signing = false
            }
        }
    }

    buildTypes {
        release {
            // No minification: the release variant is sideloaded, and R8 cannot be
            // validated from a build alone — a stripped ViewModel or ViewBinding shows up
            // only at run time, on the tablet. The ~200 KB is not worth that risk.
            isMinifyEnabled = false
            signingConfig = if (releaseKeystore != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("android-installer: ANDROID_INSTALLER_KEYSTORE_FILE unset — release variant " +
                    "signed with the DEBUG key (not publishable).")
                signingConfigs.getByName("debug")
            }
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
    // The real org.json for JVM tests: android.jar's copy is a stub that throws, and the
    // services manifest parser is exactly the kind of decision these tests exist for.
    testImplementation("org.json:json:20240303")
    // Signs synthetic APKs AT TEST TIME (v1-only, v2-only, v2+v3, key rotation, two signers)
    // so ApkSignatureReader is proven on real signing blocks without a single vendor byte or
    // a checked-in key in the repo. apksig is the library apksigner itself is built on;
    // bcpkix only mints the throwaway self-signed certificates.
    testImplementation("com.android.tools.build:apksig:8.7.3")
    testImplementation("org.bouncycastle:bcpkix-jdk18on:1.77")
}
