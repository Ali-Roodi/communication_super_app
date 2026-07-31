plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.communication_super_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.communication_super_app"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

flutter {
    source = "../.."
}
