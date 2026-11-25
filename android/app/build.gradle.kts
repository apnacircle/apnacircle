plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase (v0.3): apply the google-services plugin ONLY when
// google-services.json exists in this folder. It is gitignored —
// it exists on machines where the console project was set up, and
// is injected as a CI secret on the GitHub runner. Without the
// file the app builds fine and runs in local demo mode.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.apnacircle.app"
    // Regenerated with Flutter 3.35.7 template (22 Nov 2026, Run #8 fix):
    // the old Flutter 3.24 Groovy Gradle files are rejected by Flutter
    // 3.35 ("unsupported Gradle project"). Template is now Kotlin DSL.
    // compileSdk/targetSdk 35 (not 36): SDK 35 is guaranteed on the GitHub
    // runner; plugins that need 36 (geolocator_android) only log a warning.
    compileSdk = 35
    // NDK 27.0.12077973 = AGP 8.9.1 default.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Run #204 fix (24 Nov 2026): flutter_local_notifications
        // (v0.6.10) needs core library desugaring — without this the
        // release build fails at :app:checkReleaseAarMetadata.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.apnacircle.app"
        // minSdk 24 = Android 7.0 (raised from 21 on 22 Nov 2026).
        // Flutter 3.35's Gradle plugin FAILS the build when minSdk < 23
        // and warns below 24, so Android 5.0/6.0 are no longer supported.
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // AndroidManifest.xml uses ${applicationName}; Flutter's plugin
        // only injects it when defaultConfig does NOT override
        // manifestPlaceholders, so define it here or the manifest
        // merger fails (Run #7, 22 Nov 2026).
        manifestPlaceholders["applicationName"] =
            "io.flutter.app.FlutterApplication"
    }

    signingConfigs {
        // Release signing is configured on the build machine:
        // create a keystore with keytool, put its path/passwords in
        // android/key.properties (NEVER commit it). See README.
        create("release") {
            keyAlias = "apnacircle"
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

flutter {
    source = "../.."
}

dependencies {
    // Keep in step with the Kotlin plugin version in settings.gradle.kts (2.1.0).
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
    // Run #204 fix (24 Nov 2026): desugaring library required by
    // flutter_local_notifications (v0.6.10) — pairs with
    // isCoreLibraryDesugaringEnabled above. Run #215 proved 2.0.4
    // is NOT enough: the plugin needs 2.1.4 or above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
