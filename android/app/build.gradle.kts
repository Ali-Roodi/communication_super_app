import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials, kept OUT of the repo.
//
// `android/key.properties` and `android/upload-keystore.jks` are both gitignored
// (`key.properties`, `**/*.jks`, `**/*.keystore`). When the file is absent — a
// fresh clone, CI without the secret — we fall back to the debug signing config
// below so `flutter build apk --release` still produces something installable
// instead of failing the configuration phase. A debug-signed release APK is
// exactly what Play Protect flags, so never ship one: check that
// `apksigner verify --print-certs` names CN=Hamrasan, not "Android Debug".
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    // The Kotlin package (and therefore R.class / BuildConfig) is deliberately
    // still `com.example.communication_super_app` while `applicationId` is
    // `ir.hamrasan.app`. AGP allows the two to differ: `namespace` names the
    // compiled *source* package, `applicationId` names the *installed app*, and
    // only the latter is what Play Protect, the package manager and the
    // default-app roles see.
    //
    // Renaming the namespace means moving every file under
    // src/main/kotlin/com/example/... , rewriting every `import`, and rewriting
    // the four hardcoded broadcast action strings that spell the old package
    // (SmsNotificationActionReceiver.ACTION_REPLY / ACTION_MARK_READ,
    // CallInCallService.ACTION_ANSWER / ACTION_DECLINE,
    // ScheduledSmsScheduler.ACTION) plus their manifest <intent-filter>s. That
    // is a separate, mechanical follow-up with no behavioural payoff.
    //
    // The MethodChannel / EventChannel names
    // ("com.example.communication_super_app/sms", …/call, …/call_log,
    // …/scheduled_sms, …/contact_extras, …/media, …/intents) must stay
    // BYTE-IDENTICAL on the Dart and Kotlin sides — they are opaque strings, not
    // package references. Do not "tidy" them into ir.hamrasan.* unless you
    // change lib/**/native_*_service.dart in the same commit.
    namespace = "com.example.communication_super_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // The shipping application id. It used to be
        // `com.example.communication_super_app`: the `com.example.*` prefix is a
        // Play Protect signal on its own (it is the sample/tutorial namespace and
        // Play refuses to publish it), and combined with an app that asks for
        // SMS + CALL_LOG + the default-SMS role and arrives from an unknown
        // installer it was enough to trip the "harmful app" heuristic on install.
        //
        // NOTE: changing this makes the build install as a NEW app — the old
        // com.example.communication_super_app install keeps its own database.
        applicationId = "ir.hamrasan.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The app ships arm64 only. See the `packaging` block below — this
        // declares the intent, that block is what enforces it.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    // Ship exactly ONE ABI directory.
    //
    // The engine (`libflutter.so` / `libapp.so`) is arm64-only, but plugin AARs
    // still contributed a stub `.so` for the other ABIs, so the APK carried an
    // otherwise-empty `lib/armeabi-v7a/` and `lib/x86_64/`. An armeabi-v7a
    // device reads that directory as "this ABI is supported": it installs
    // happily, picks v7a as its primary ABI, finds no libflutter.so and dies
    // with UnsatisfiedLinkError on the first launch. With the directory gone
    // the same device rejects the install outright — a clean "not compatible"
    // beats a crash on start.
    //
    // `defaultConfig.ndk.abiFilters` does NOT remove these on its own (the
    // arm64-only builds above already carried them), which is why the exclude
    // is spelled out here.
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/armeabi/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }

    signingConfigs {
        // Only declared when the credentials are actually present, so a clone
        // without key.properties configures cleanly instead of throwing on the
        // missing keystore file.
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // Relative to this module dir (android/app), hence the `../`.
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String

                // Spelled out rather than left to AGP's defaults, which picked
                // v2 ONLY here (verified with `apksigner verify --print-certs`).
                //  - v1 (JAR signing) is dead weight at minSdk 24: only ≤23
                //    reads it, and its META-INF entries are what make an APK
                //    look like an old repackaged one.
                //  - v3 is what makes signing-key ROTATION possible later. If
                //    this key ever leaks, a v2-only APK can never be re-keyed
                //    without a new package name — i.e. every install lost.
                //  - v4 needs a side-car .idsig and only speeds up incremental
                //    `adb install`; it is not part of a distributed APK.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = false
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Fallback so a fresh clone still builds. NOT shippable — see the
                // keystore comment at the top of this file.
                logger.warn(
                    "هم‌رسان: android/key.properties not found — signing the " +
                        "RELEASE build with the DEBUG key. Do not distribute this APK."
                )
                signingConfigs.getByName("debug")
            }

            // R8. A minified+shrunk release is both smaller and less
            // "unknown-shaped" to Play Protect's static scan. The keep rules in
            // proguard-rules.pro are load-bearing: this app is almost entirely
            // made of components the SYSTEM instantiates by name (four
            // SMS-role components, InCallService, ConnectionService, six
            // receivers) — see that file before touching anything here.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Pinned because the incoming-call notification uses NotificationCompat
    // .CallStyle — relying on whatever the embedding drags in would make that
    // compile or not depending on the Flutter version.
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")
}

// Replaces the `android { kotlinOptions { jvmTarget = … } }` block AGP 9 removed
// (KGP dropped the `kotlinOptions` DSL — https://kotl.in/u1r8ln).
//
// It must stay in lockstep with `compileOptions` above. A jvmTarget that
// disagrees with sourceCompatibility/targetCompatibility does not fail at the
// point of the mismatch — it fails wherever Kotlin and Java code share a class
// hierarchy, which here is everywhere: the Flutter embedding is Java and every
// handler in this app is Kotlin.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
