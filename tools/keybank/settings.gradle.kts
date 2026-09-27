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
    }
}

rootProject.name = "hamresan-keybank"
