import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    // Same Kotlin as the app (android/settings.gradle.kts).
    kotlin("jvm") version "2.4.0"
}

// The crypto is compiled from THE APP'S OWN SOURCE, not a copy: a key file
// this tool writes is then one the app reads by construction, and the JVM
// tests in android/app/src/test cover both. Only the two Android-bound files
// (the MethodChannel handler and the file picker) are left out.
val appCrypto = "../../android/app/src/main/kotlin/com/example/communication_super_app/smscrypto"

sourceSets {
    main {
        kotlin {
            srcDir(appCrypto)
            exclude("**/SmsCryptoHandler.kt", "**/KeyFilePicker.kt", "**/SecureSmsInbox.kt")
        }
    }
}

dependencies {
    // Pinned to the app's version (android/app/build.gradle.kts).
    implementation("org.bouncycastle:bcprov-jdk18on:1.86")
}

// Java 11 bytecode: runs on any Java 11+ the Windows machine has.
java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_11
    }
}

// One self-contained jar: `java -jar hamresan-keybank.jar …`.
tasks.jar {
    archiveFileName = "hamresan-keybank.jar"
    manifest { attributes["Main-Class"] = "ir.hamrasan.keybank.MainKt" }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(configurations.runtimeClasspath.map { deps -> deps.map { if (it.isDirectory) it else zipTree(it) } })
    // Bouncy Castle's jar is signed; its signature files do not describe the
    // merged jar and would make the JVM refuse it.
    exclude("META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA", "META-INF/*.EC")
}
