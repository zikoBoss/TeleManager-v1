plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.telemanager"
    compileSdk = flutter.compileSdkVersion

    // Task 05's TDLib test hooks are gated by BuildConfig.DEBUG.
    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.telemanager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Task 05: TDLib core:0.1.1 declares minSdk 26 in its manifest
        // (verified in Task 03 Phase 1); the manifest merger rejects the
        // Flutter default (24). Do not lower this or use
        // tools:overrideLibrary — the library may use APIs unavailable
        // below 26.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Task 03 decision: 64-bit ABIs only (arm64-v8a + x86_64).
        // The 32-bit libtdjni.so fails the 16KB page-size check.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Task 05: compile the native TDLib bridge from its Blueprint
    // location (android/native/tdlib_bridge/) alongside the app module
    // sources. srcDirs() replaces the list, so the defaults are kept.
    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/java", "src/main/kotlin", "../native/tdlib_bridge")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Task 03 evaluated artifact: TDLib 1.8.67 (core:0.1.1).
    // Do not change without a new evaluation (PROJECT_RULES #21).
    implementation("io.github.tdlib-android:core:0.1.1")
}
