allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://jitpack.io")
        }
        // Verified, vendored copies of the few artifacts Google Maven cannot
        // serve on this development network — see third_party/maven/README.md.
        // Last, and scoped to its group, so it never shadows a real repository.
        maven {
            url = uri("${rootDir}/third_party/maven")
            content { includeGroup("androidx.sqlite") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
