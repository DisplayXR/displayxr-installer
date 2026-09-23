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
}
