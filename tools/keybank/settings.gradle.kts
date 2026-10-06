// The key-bank tool for the authority's Windows machine. A plain JVM build,
// separate from the Flutter/Android one; see README.md.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        // The panel's Compose needs a few androidx artifacts that only Google
        // Maven serves, and Google Maven answers 404 to this development
        // network. JetBrains' cache redirector serves the same files; scoped
        // to androidx so it can never stand in for anything else.
        maven("https://cache-redirector.jetbrains.com/dl.google.com/dl/android/maven2/") {
            content { includeGroupByRegex("androidx(\\..*)?") }
        }
    }
}

rootProject.name = "hamresan-keybank"

// «پنل صدور هم‌رسان»: the same issuance with a window, packaged as a Windows
// installer that carries its own Java. See panel/build.gradle.kts.
include("panel")
