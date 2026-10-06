import org.jetbrains.compose.desktop.application.dsl.TargetFormat

// «پنل صدور هم‌رسان» — the issuance panel for the authority's Windows machine.
//
// Like the command line next door it compiles THE APP'S OWN crypto source (and
// the command line's shared Activation / Issuance files), never a copy: a key
// file or an activation code it produces is one the app accepts by
// construction. The installer carries its own Java runtime, so the target
// machine needs nothing installed.
plugins {
    kotlin("jvm")
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0"
    id("org.jetbrains.compose") version "1.12.1"
}

val appCrypto = "../../../android/app/src/main/kotlin/com/example/communication_super_app/smscrypto"

sourceSets {
    main {
        kotlin {
            srcDir(appCrypto)
            srcDir("../src/main/kotlin")
            // The Android-bound files, and the command line's entry point.
            exclude("**/SmsCryptoHandler.kt", "**/KeyFilePicker.kt", "**/SecureSmsInbox.kt", "**/Main.kt")
        }
        // The app's own font, so Persian looks the same here as on the phone.
        resources.srcDir("../../../assets/fonts")
    }
}

// Bouncy Castle's jar is signed. ProGuard rewrites its classes but keeps the
// signature files, and the JVM then refuses the first class it loads
// («SHA-256 digest error») — caught by `--self-test` on the installed build.
// So the panel uses an unsigned copy, the same way the command line's jar
// drops those files.
val bouncyCastle: Configuration by configurations.creating
val unsignedBouncyCastle by tasks.registering(Jar::class) {
    archiveFileName = "bcprov-unsigned.jar"
    destinationDirectory = layout.buildDirectory.dir("unsigned")
    from(bouncyCastle.elements.map { jars -> jars.map { zipTree(it) } })
    exclude("META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA", "META-INF/*.EC")
}

dependencies {
    // Pinned to the app's version (android/app/build.gradle.kts).
    bouncyCastle("org.bouncycastle:bcprov-jdk18on:1.86")
    implementation(files(unsignedBouncyCastle))
    implementation(compose.desktop.currentOs)
    implementation("org.jetbrains.compose.material3:material3:1.9.0")
    // Frozen at 1.7.3 upstream (Material Symbols replace it); fine for a handful of icons.
    implementation("org.jetbrains.compose.material:material-icons-extended:1.7.3")
}

kotlin {
    jvmToolchain(21)
}

compose.desktop {
    application {
        mainClass = "ir.hamrasan.panel.PanelAppKt"
        javaHome = javaToolchains.launcherFor {
            languageVersion = JavaLanguageVersion.of(21)
        }.get().metadata.installationPath.asFile.absolutePath

        buildTypes.release.proguard {
            obfuscate = false
            optimize = false
            configurationFiles.from(project.file("rules.pro"))
        }

        nativeDistributions {
            targetFormats(TargetFormat.Msi)
            packageName = "HamresanPanel"
            packageVersion = "1.0.0"
            description = "Hamresan issuance panel"
            vendor = "Hamresan"
            // From `suggestRuntimeModules`; java.prefs remembers the authority file's path (never its password).
            modules("java.instrument", "java.naming", "java.prefs", "java.sql", "jdk.unsupported")
            windows {
                menuGroup = "Hamresan"
                shortcut = true
                dirChooser = true
                perUserInstall = true
                // Fixed for ever: an installer with the same id upgrades in place.
                upgradeUuid = "6f3a2d4e-8b1c-4f7a-9e25-1d0c7b8a4e61"
                iconFile.set(project.file("icon.ico"))
            }
        }
    }
}

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
