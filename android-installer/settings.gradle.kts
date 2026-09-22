// Self-contained Gradle build. It deliberately does NOT live at the repo root:
// the rest of displayxr-installer is shell + NSIS + productbuild, and nothing
// there should acquire a Gradle dependency just because Android gained one.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "displayxr-android-installer"
include(":app")
